;;; liberime-regexp.el --- Search Chinese text with Rime codes  -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; Version: 0.3.0
;; Package-Requires: ((emacs "27.1") (avy "0.5.0") (liberime "0.0.11"))
;; Keywords: convenience, i18n, matching

;; This file is not part of GNU Emacs.

;;; Commentary:

;; `liberime-regexp-mode' expands lower-case Rime codes in searches.  For
;; example, a search for "ni" can match both the literal code and candidates
;; such as "你".  The mode integrates with isearch, `orderless-regexp', and
;; Evil's `evil-ex-search-full-pattern' when those functions are available.
;; `liberime-regexp-avy-mode' adds the same expansion to Avy character jumps.
;;
;; Candidate lookup uses a reusable separate session for full-context searches.
;; Automatically committed prefixes are retained.  The shortest prefix
;; candidates may be composed recursively, but every expansion must consume
;; the complete code.
;;
;; Basic setup:
;;
;;   (require 'liberime-regexp)
;;   (liberime-regexp-mode 1)

;;; Code:

(require 'avy)
(require 'isearch)
(require 'ring)
(require 'seq)
(require 'subr-x)

(declare-function liberime-load "liberime")
(declare-function liberime-workable-p "liberime")
(declare-function liberime-get-status "ext:liberime-core" (&optional session))
(declare-function liberime-get-switches "ext:liberime-core")
(declare-function liberime-get-option "ext:liberime-core"
                  (option &optional session))
(declare-function liberime-set-option "ext:liberime-core"
                  (option value &optional session))
(declare-function liberime-search "ext:liberime-core"
                  (code &optional limit index schema full-context session))
(declare-function liberime-session-create "ext:liberime-core" (&optional schema))
(declare-function liberime-session-destroy "ext:liberime-core" (session))

(defgroup liberime-regexp nil
  "Build regular expressions from Rime candidates."
  :group 'matching
  :prefix "liberime-regexp-")

(defcustom liberime-regexp-max-code-length 0
  "Maximum Rime code length to expand.

A value less than or equal to zero means no limit.  Set this to the maximum
code length of a shape-based input method to prevent a long English word from
being split and partially converted by Rime."
  :type 'integer
  :group 'liberime-regexp)

(defcustom liberime-regexp-candidate-limit 100
  "Maximum number of Rime candidates examined for one code.

Nil or a non-positive value means no limit.  Keeping this value bounded is
recommended for incremental search because short codes can have thousands of
candidates."
  :type '(choice (const :tag "No limit" nil)
                 (integer :tag "Maximum candidates"))
  :group 'liberime-regexp)

(defcustom liberime-regexp-cache-size 256
  "Maximum number of candidate queries cached.

A non-positive value disables caching.  When full, the cache evicts the
oldest entries first."
  :type 'integer
  :group 'liberime-regexp)

(defcustom liberime-regexp-omit-code-separators t
  "Whether whitespace between adjacent Rime codes may match nothing.

When non-nil, a query such as `ni shijie' can match contiguous Chinese text
such as `你世界'.  The whitespace remains an alternative, so text
which contains the original separator can still match."
  :type 'boolean
  :group 'liberime-regexp)

(defconst liberime-regexp--code-pattern "[a-z][a-z']*"
  "Regexp matching a Rime code embedded in a search string.")

(defconst liberime-regexp--advised-functions
  '(orderless-regexp evil-ex-search-full-pattern))

(defconst liberime-regexp--unset (make-symbol "unset"))

(defvar liberime-regexp--candidate-cache (make-hash-table :test #'equal)
  "Cache candidate queries and their generated regexps.")

(defvar liberime-regexp--cache-order
  (make-ring (max 1 liberime-regexp-cache-size))
  "Cached query keys in FIFO order.")

(defconst liberime-regexp--status-options
  '(("ascii_mode" . is_ascii_mode)
    ("full_shape" . is_full_shape)
    ("simplification" . is_simplified)
    ("traditional" . is_traditional)
    ("ascii_punct" . is_ascii_punct)))

(defvar liberime-regexp--schema-options nil
  "Current schema and its additional switch option names.")

(defvar liberime-regexp--query-session nil
  "Reusable session for full-context candidate searches.")

(defvar liberime-regexp--saved-isearch-search-fun-function nil)

(defun liberime-regexp--status-key ()
  "Return the Rime state relevant to candidate lookup."
  (let* ((status (liberime-get-status))
         (schema (alist-get 'schema_id status))
         (options
          (mapcar (lambda (entry)
                    (cons (car entry) (alist-get (cdr entry) status)))
                  liberime-regexp--status-options)))
    (unless (equal schema (car liberime-regexp--schema-options))
      (setq liberime-regexp--schema-options
            (cons schema
                  (seq-difference
                   (delete-dups
                    (mapcan (lambda (switch)
                              (or (nth 3 switch) (list (car switch))))
                            (liberime-get-switches)))
                   (mapcar #'car liberime-regexp--status-options)))))
    (dolist (name (cdr liberime-regexp--schema-options))
      (push (cons name (liberime-get-option name)) options))
    (cons schema options)))

(defun liberime-regexp-clear-cache ()
  "Clear cached Rime candidate queries."
  (interactive)
  (clrhash liberime-regexp--candidate-cache)
  (setq liberime-regexp--cache-order
        (make-ring (max 1 liberime-regexp-cache-size))))

(defun liberime-regexp--destroy-query-session ()
  "Release the reusable query session."
  (when liberime-regexp--query-session
    (liberime-session-destroy liberime-regexp--query-session)
    (setq liberime-regexp--query-session nil)))

(defun liberime-regexp--reset-rime-state ()
  "Discard state retained from a previous Rime instance."
  ;; Old session ids may have been recycled for the new default session.
  (setq liberime-regexp--query-session nil
        liberime-regexp--schema-options nil)
  (liberime-regexp-clear-cache))

(defun liberime-regexp--batch-session-query (code limit state)
  "Query CODE with LIMIT candidates in a session synchronized with STATE."
  (let ((status (and liberime-regexp--query-session
                     (condition-case nil
                         (liberime-get-status liberime-regexp--query-session)
                       (rimeerr nil)))))
    ;; Rime expires idle sessions; a schema change also needs a new session.
    (unless (equal (car state) (alist-get 'schema_id status))
      (liberime-regexp--destroy-query-session)
      (setq liberime-regexp--query-session
            (liberime-session-create (car state)))))
  (dolist (option (cdr state))
    (liberime-set-option (car option) (cdr option)
                         liberime-regexp--query-session))
  (let* ((query (liberime-search code limit nil nil t
                                 liberime-regexp--query-session))
         (full (delete-dups (delete "" (plist-get query :full))))
         (prefix (delete-dups (delete "" (plist-get query :prefix))))
         (commit (plist-get query :commit))
         (remaining-input (plist-get query :remaining-input)))
    ;; An automatic commit with unusable residual input is only a prefix.
    (when (and commit (null full) (null prefix)
               remaining-input (not (string-empty-p remaining-input)))
      (setq commit nil))
    (when (or commit full prefix)
      (setf (plist-get query :commit) commit
            (plist-get query :full) full
            (plist-get query :prefix) prefix)
      (nconc query (list :regexp-code nil :regexp nil)))))

(defun liberime-regexp-load-liberime ()
  "Load and start liberime if necessary."
  (unless (featurep 'liberime-core)
    (require 'liberime))
  (unless (liberime-workable-p)
    (liberime-load)))

(defun liberime-regexp--query-code (str)
  "Return cached candidate expansion data for Rime code STR.

Return nil if STR is invalid, too long according to
`liberime-regexp-max-code-length', or has no expansions."
  (let ((code (replace-regexp-in-string "'" "" str t t)))
    (when (and (not (string-empty-p code))
               (let ((case-fold-search nil))
                 (string-match-p "\\`[a-z']+\\'" str))
               (or (<= liberime-regexp-max-code-length 0)
                   (<= (length code) liberime-regexp-max-code-length)))
      (liberime-regexp-load-liberime)
      (let* ((state (liberime-regexp--status-key))
             (limit (and liberime-regexp-candidate-limit
                         (> liberime-regexp-candidate-limit 0)
                         liberime-regexp-candidate-limit))
             (key (list code limit state))
             (cached (if (> liberime-regexp-cache-size 0)
                         (gethash key liberime-regexp--candidate-cache
                                  liberime-regexp--unset)
                       liberime-regexp--unset)))
        (if (not (eq cached liberime-regexp--unset))
            cached
          (let ((result (liberime-regexp--batch-session-query code limit state)))
            (when (> liberime-regexp-cache-size 0)
              (unless (= (ring-size liberime-regexp--cache-order)
                         liberime-regexp-cache-size)
                (dolist (key (nthcdr liberime-regexp-cache-size
                                    (ring-elements liberime-regexp--cache-order)))
                  (remhash key liberime-regexp--candidate-cache))
                (ring-resize liberime-regexp--cache-order
                             liberime-regexp-cache-size))
              (when (= (ring-length liberime-regexp--cache-order)
                       liberime-regexp-cache-size)
                (remhash (ring-ref liberime-regexp--cache-order -1)
                         liberime-regexp--candidate-cache))
              (ring-insert liberime-regexp--cache-order key)
              (puthash key result liberime-regexp--candidate-cache))
            result))))))

(defun liberime-regexp-get-candidates-list (str)
  "Return the Rime commit and full-consumption candidates for code STR.

The return value has the form (COMMIT . CANDIDATES).  COMMIT is nil unless
Rime automatically committed a prefix.  For example, possible results are:

  (nil 计算 谋算)
  (计算 与 瓦)

STR must contain only lower-case ASCII letters and apostrophes.  Apostrophes
are removed before the code is sent to Rime.  Candidates which consume only a
prefix of STR are discarded.  Return nil if STR is invalid, too long according
to `liberime-regexp-max-code-length', or has no matches."
  (let* ((query (liberime-regexp--query-code str))
         (commit (plist-get query :commit))
         (full (plist-get query :full))
         (remaining-input (plist-get query :remaining-input)))
    (when (or full
              (and commit
                   (or (null remaining-input)
                       (string-empty-p remaining-input))))
      (cons commit full))))

(defun liberime-regexp--code-regexp (code)
  "Return a regexp matching CODE or any of its Rime expansions."
  (let* ((query (liberime-regexp--query-code code))
         (cached (and (equal code (plist-get query :regexp-code))
                      (plist-get query :regexp))))
    (or cached
        (let* ((commit (plist-get query :commit))
               (full (plist-get query :full))
               (prefix (plist-get query :prefix))
               (remainder (plist-get query :remainder))
               (remaining-input (plist-get query :remaining-input))
               (converted
                (cond
                 ((and commit full)
                  (mapcar (lambda (candidate)
                            (concat commit candidate))
                          full))
                 (full full)
                 ((and commit
                       (or (null remaining-input)
                           (string-empty-p remaining-input)))
                  (list commit))))
               (base (regexp-opt (cons code converted)))
               (recursive
                (and prefix
                     (concat
                      (regexp-opt
                       (if commit
                           (mapcar (lambda (candidate)
                                     (concat commit candidate))
                                   prefix)
                         prefix))
                      (liberime-regexp--code-regexp remainder))))
               (regexp (if recursive
                           (format "\\(?:%s\\|%s\\)" base recursive)
                         base)))
          (when query
            (setf (plist-get query :regexp-code) code
                  (plist-get query :regexp) regexp))
          regexp))))

(defun liberime-regexp--tokenize (str)
  "Split STR into tagged Rime-code and literal tokens."
  (let ((case-fold-search nil)
        (position 0)
        tokens)
    (while (string-match liberime-regexp--code-pattern str position)
      (let ((beginning (match-beginning 0))
            (end (match-end 0)))
        (when (> beginning position)
          (push (cons 'literal (substring str position beginning)) tokens))
        (push (cons 'code (match-string 0 str)) tokens)
        (setq position end)))
    (when (< position (length str))
      (push (cons 'literal (substring str position)) tokens))
    (nreverse tokens)))

(defun liberime-regexp-build-regexp-string (str &optional literal)
  "Build a regexp from Rime codes embedded in STR.

Lower-case code runs are expanded independently, so every part of
`ni shijie' has one-to-many candidate matching.  When LITERAL is non-nil,
quote non-code parts of STR; this is used for non-regexp isearch."
  (let* ((tokens (vconcat (liberime-regexp--tokenize str)))
         (count (length tokens))
         pieces)
    (dotimes (index count)
      (let* ((token (aref tokens index))
             (kind (car token))
             (text (cdr token)))
        (push
         (pcase kind
           ('code (liberime-regexp--code-regexp text))
           ('literal
            (if (and liberime-regexp-omit-code-separators
                     (> index 0)
                     (< index (1- count))
                     (eq (car (aref tokens (1- index))) 'code)
                     (eq (car (aref tokens (1+ index))) 'code)
                     (string-match-p "\\`[[:space:]]+\\'" text))
                (format "\\(?:%s\\)?" (regexp-quote text))
              (if literal (regexp-quote text) text))))
         pieces)))
    (mapconcat #'identity (nreverse pieces) "")))

(defun liberime-regexp--avy-input-regexp (input)
  "Build an Avy regexp from INPUT."
  (liberime-regexp-build-regexp-string input t))

(defun liberime-regexp-avy-goto-char (char &optional arg)
  "Jump to CHAR or a Rime candidate for its code.

ARG reverses the value of `avy-all-windows'."
  (interactive (list (read-char "char: " t)
                     current-prefix-arg))
  (avy-with avy-goto-char
    (avy-jump
     (liberime-regexp--avy-input-regexp
      (string (if (= char 13) ?\n char)))
     :window-flip arg)))

(defun liberime-regexp-avy-goto-char-in-line (char)
  "Jump within the current line to CHAR or a Rime candidate for its code."
  (interactive (list (read-char "char: " t)))
  (avy-with avy-goto-char
    (avy-jump
     (liberime-regexp--avy-input-regexp (string char))
     :beg (line-beginning-position)
     :end (line-end-position))))

(defun liberime-regexp-avy-goto-char-2
    (char1 char2 &optional arg beg end)
  "Jump to CHAR1 CHAR2 or a Rime candidate for their combined code.

ARG reverses `avy-all-windows'.  BEG and END limit the search range."
  (interactive (list (read-char "char 1: " t)
                     (read-char "char 2: " t)
                     current-prefix-arg))
  (avy-with avy-goto-char-2
    (avy-jump
     (liberime-regexp--avy-input-regexp
      (string (if (= char1 13) ?\n char1)
              (if (= char2 13) ?\n char2)))
     :window-flip arg
     :beg beg
     :end end)))

(defun liberime-regexp-avy-goto-char-timer (&optional arg)
  "Read a Rime code and jump to one of its visible candidates.

ARG reverses the value of `avy-all-windows'."
  (interactive "P")
  (let ((avy-all-windows (if arg
                             (not avy-all-windows)
                           avy-all-windows)))
    (avy-with avy-goto-char-timer
      (setq avy--old-cands
            (avy--read-candidates #'liberime-regexp--avy-input-regexp))
      (avy-process avy--old-cands))))

(defvar liberime-regexp-avy-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map [remap avy-goto-char]
                #'liberime-regexp-avy-goto-char)
    (define-key map [remap avy-goto-char-in-line]
                #'liberime-regexp-avy-goto-char-in-line)
    (define-key map [remap avy-goto-char-2]
                #'liberime-regexp-avy-goto-char-2)
    (define-key map [remap avy-goto-char-timer]
                #'liberime-regexp-avy-goto-char-timer)
    map)
  "Keymap for `liberime-regexp-avy-mode'.")

(defun liberime-regexp-filter-args (args)
  "Replace the first string in ARGS with its Rime-aware regexp."
  (cons (liberime-regexp-build-regexp-string (car args)) (cdr args)))

(defun liberime-regexp--isearch-search-function ()
  "Return an isearch function which expands Rime codes."
  (let ((base (or liberime-regexp--saved-isearch-search-fun-function
                  #'isearch-search-fun-default)))
    (if isearch-regexp-function
        ;; Preserve word and symbol isearch semantics.
        (funcall base)
      (let ((literal (not isearch-regexp)))
        (lambda (string &optional bound noerror count)
          ;; The transformed string is always a regexp, even for an ordinary
          ;; literal isearch.  Ask the prior provider to treat it as such.
          (let ((isearch-regexp t)
                (isearch-regexp-function nil))
            (funcall (funcall base)
                     (liberime-regexp-build-regexp-string string literal)
                     bound noerror count)))))))

(defun liberime-regexp--update-advices (enable)
  "Add search advices when ENABLE is non-nil, otherwise remove them."
  (dolist (function liberime-regexp--advised-functions)
    (when (fboundp function)
      (if enable
          (unless (advice-member-p #'liberime-regexp-filter-args function)
            (advice-add function :filter-args
                        #'liberime-regexp-filter-args))
        (when (advice-member-p #'liberime-regexp-filter-args function)
          (advice-remove function #'liberime-regexp-filter-args))))))

(defun liberime-regexp--install-integrations ()
  "Install integrations for currently loaded packages."
  (liberime-regexp--update-advices t)
  (unless liberime-regexp--saved-isearch-search-fun-function
    (setq liberime-regexp--saved-isearch-search-fun-function
          isearch-search-fun-function))
  (setq isearch-search-fun-function
        #'liberime-regexp--isearch-search-function))

(defun liberime-regexp--remove-integrations ()
  "Remove all integrations installed by this package."
  (liberime-regexp--update-advices nil)
  (when liberime-regexp--saved-isearch-search-fun-function
    ;; Do not overwrite a provider installed by another package while this
    ;; mode was active.
    (when (eq isearch-search-fun-function
              #'liberime-regexp--isearch-search-function)
      (setq isearch-search-fun-function
            liberime-regexp--saved-isearch-search-fun-function))
    (setq liberime-regexp--saved-isearch-search-fun-function nil)))

(with-eval-after-load 'orderless
  (when (bound-and-true-p liberime-regexp-mode)
    (liberime-regexp--update-advices t)))

(with-eval-after-load 'evil-search
  (when (bound-and-true-p liberime-regexp-mode)
    (liberime-regexp--update-advices t)))

(add-hook 'liberime-after-start-hook #'liberime-regexp--reset-rime-state)
(add-hook 'kill-emacs-hook #'liberime-regexp--destroy-query-session)

;;;###autoload
(define-minor-mode liberime-regexp-mode
  "Globally expand lower-case Rime codes in supported searches."
  :global t
  :group 'liberime-regexp
  (if liberime-regexp-mode
      (progn
        (liberime-regexp-load-liberime)
        (liberime-regexp-clear-cache)
        (liberime-regexp--install-integrations))
    (liberime-regexp--remove-integrations)
    (liberime-regexp--destroy-query-session)
    (liberime-regexp-clear-cache)))

;;;###autoload
(define-minor-mode liberime-regexp-avy-mode
  "Use Rime codes with Avy character commands."
  :global t
  :group 'liberime-regexp
  :keymap liberime-regexp-avy-mode-map)

;;;###autoload
(defun liberime-regexp-enable ()
  "Enable `liberime-regexp-mode'."
  (liberime-regexp-mode 1))

(provide 'liberime-regexp)

;;; liberime-regexp.el ends here
