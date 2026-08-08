;;; liberime-regexp.el --- Search Chinese text with Rime codes  -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; Version: 0.3.0
;; Package-Requires: ((emacs "27.1") (avy "0.5.0") (liberime "0.0.7"))
;; Keywords: convenience, i18n, matching

;; This file is not part of GNU Emacs.

;;; Commentary:

;; `liberime-regexp-mode' expands lower-case Rime codes in searches.  For
;; example, a search for "ni" can match both the literal code and candidates
;; such as "你".  The mode integrates with isearch, `orderless-regexp', and
;; Evil's `evil-ex-search-full-pattern' when those functions are available.
;; `liberime-regexp-avy-mode' adds the same expansion to Avy character jumps.
;;
;; Candidate lookup normally uses liberime's default session so that an
;; automatically committed prefix is retained.  The shortest prefix candidates
;; may be composed recursively, but every generated expansion must consume the
;; complete supplied code.  If the default session already has an active
;; composition, cached results remain available; an uncached code is left
;; unexpanded so that the composition is untouched.
;;
;; Basic setup:
;;
;;   (require 'liberime-regexp)
;;   (liberime-regexp-mode 1)

;;; Code:

(require 'avy)
(require 'isearch)
(require 'subr-x)

(declare-function liberime-load "liberime")
(declare-function liberime-workable-p "liberime")
(declare-function liberime-clear-composition "ext:liberime-core")
(declare-function liberime-get-commit "ext:liberime-core")
(declare-function liberime-get-context "ext:liberime-core")
(declare-function liberime-get-input "ext:liberime-core")
(declare-function liberime-get-status "ext:liberime-core")
(declare-function liberime-process-key "ext:liberime-core"
                  (keycode &optional mask))

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

A non-positive value disables caching.  The whole cache is cleared when this
many entries have accumulated."
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

(defvar liberime-regexp--saved-isearch-search-fun-function nil)

(defun liberime-regexp--candidate-limit ()
  "Return the effective candidate limit, or nil for no limit."
  (and liberime-regexp-candidate-limit
       (> liberime-regexp-candidate-limit 0)
       liberime-regexp-candidate-limit))

(defun liberime-regexp--status-key ()
  "Return the Rime state relevant to candidate lookup."
  (let ((status (liberime-get-status)))
    (list (alist-get 'schema_id status)
          (alist-get 'is_ascii_mode status)
          (alist-get 'is_full_shape status)
          (alist-get 'is_simplified status)
          (alist-get 'is_traditional status))))

(defun liberime-regexp-clear-cache ()
  "Clear cached Rime candidate queries."
  (interactive)
  (clrhash liberime-regexp--candidate-cache))

(defun liberime-regexp--normalize-candidates (candidates)
  "Return CANDIDATES without empty strings or duplicates."
  (let ((seen (make-hash-table :test #'equal))
        result)
    (dolist (candidate candidates)
      (unless (or (string-empty-p candidate) (gethash candidate seen))
        (puthash candidate t seen)
        (push candidate result)))
    (nreverse result)))

(defun liberime-regexp--candidate-expansions ()
  "Return full and shortest-prefix candidates for the current Rime input.

The return value is a plist with keys `:full', `:prefix', and `:remainder'.
FULL candidates consume the input completely.  PREFIX candidates all consume
the same shortest non-empty prefix, and REMAINDER is the unconsumed suffix.

Candidate highlighting changes the composition selection without committing
or learning a candidate.  Rime leaves an unselected raw-code suffix in the
preedit for a prefix candidate."
  (let* ((context (liberime-get-context))
         (input-end (alist-get 'length (alist-get 'composition context)))
         (limit (liberime-regexp--candidate-limit))
         (seen (make-hash-table :test #'equal))
         (examined 0)
         full prefix remainder)
    (when input-end
      (catch 'done
        (while context
          (let* ((composition (alist-get 'composition context))
                 (menu (alist-get 'menu context))
                 (index (alist-get 'highlighted-candidate-index menu))
                 (candidate (and index
                                 (nth index (alist-get 'candidates menu))))
                 (preedit (alist-get 'preedit composition))
                 (selection-end (alist-get 'sel-end composition))
                 (state (and candidate
                             (cons (alist-get 'page-no menu) index))))
            (when (or (null state) (gethash state seen))
              (throw 'done nil))
            (puthash state t seen)
            (setq examined (1+ examined))
            (if (equal selection-end input-end)
                (push candidate full)
              (let ((rest (substring preedit selection-end)))
                ;; A longer remainder means that this candidate consumed a
                ;; shorter prefix.  Retain only that least-consuming group so
                ;; recursive regexp construction stays linear.
                (unless (string-empty-p rest)
                  (cond
                   ((or (null remainder)
                        (> (length rest) (length remainder)))
                    (setq remainder rest
                          prefix (list candidate)))
                   ((string= rest remainder)
                    (push candidate prefix))))))
            (when (and limit (>= examined limit))
              (throw 'done nil))
            ;; XK_Down moves the highlight, including across menu pages.
            (unless (liberime-process-key #xff54 0)
              (throw 'done nil))
            (setq context (liberime-get-context))))))
    (list :full (liberime-regexp--normalize-candidates (nreverse full))
          :prefix (liberime-regexp--normalize-candidates (nreverse prefix))
          :remainder remainder)))

(defun liberime-regexp--default-session-query (code)
  "Return a candidate expansion plist for CODE using the default session."
  (let (commit expansions remaining-input)
    (unwind-protect
        (progn
          (liberime-clear-composition)
          (mapc (lambda (character)
                  (liberime-process-key character 0))
                code)
          (setq remaining-input (liberime-get-input)
                expansions
                (and remaining-input
                     (not (string-empty-p remaining-input))
                     (liberime-regexp--candidate-expansions))
                commit (liberime-get-commit)))
      (liberime-clear-composition))
    (let ((full (plist-get expansions :full))
          (prefix (plist-get expansions :prefix))
          (remainder (plist-get expansions :remainder)))
      ;; A commit followed by unusable residual input can itself be only an
      ;; automatically committed prefix, so do not expose it as a complete
      ;; expansion.
      (when (and commit
                 (null full)
                 (null prefix)
                 remaining-input
                 (not (string-empty-p remaining-input)))
        (setq commit nil))
      (and (or commit full prefix)
           (list :commit commit
                 :full full
                 :prefix prefix
                 :remainder remainder
                 :remaining-input remaining-input
                 :regexp-code nil
                 :regexp nil)))))

(defun liberime-regexp--cache-result (key result)
  "Cache RESULT under KEY when caching is enabled, then return RESULT."
  (when (> liberime-regexp-cache-size 0)
    (when (>= (hash-table-count liberime-regexp--candidate-cache)
              liberime-regexp-cache-size)
      (liberime-regexp-clear-cache))
    (puthash key result liberime-regexp--candidate-cache))
  result)

(defun liberime-regexp-load-liberime ()
  "Load and start liberime if necessary."
  (unless (featurep 'liberime-core)
    (require 'liberime))
  (unless (liberime-workable-p)
    (liberime-load)))

(defun liberime-regexp--query-code (str)
  "Return cached candidate expansion data for Rime code STR.

The result is an internal plist produced by
`liberime-regexp--default-session-query'.  Return nil if STR is invalid, too
long according to `liberime-regexp-max-code-length', or has no expansions."
  (let ((code (replace-regexp-in-string "'" "" str t t)))
    (when (and (not (string-empty-p code))
               (let ((case-fold-search nil))
                 (string-match-p "\\`[a-z']+\\'" str))
               (or (<= liberime-regexp-max-code-length 0)
                   (<= (length code) liberime-regexp-max-code-length)))
      (liberime-regexp-load-liberime)
      (let* ((input (liberime-get-input))
             (active-composition-p
              (and input (not (string-empty-p input))))
             (key (list code
                        (liberime-regexp--candidate-limit)
                        (liberime-regexp--status-key)))
             (cached (gethash key liberime-regexp--candidate-cache
                              liberime-regexp--unset)))
        (cond
         ((not (eq cached liberime-regexp--unset))
          cached)
         ;; Candidate consumption data needs the default session.  Leave an
         ;; existing composition untouched and retry after it ends.
         (active-composition-p
          nil)
         (t
          (liberime-regexp--cache-result
           key
           (liberime-regexp--default-session-query code))))))))

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
