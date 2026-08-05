;;; liberime-regexp.el --- Search Chinese text with Rime codes  -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; Version: 0.2.1
;; Package-Requires: ((emacs "27.1") (liberime "0.0.7"))
;; Keywords: convenience, i18n, matching

;; This file is not part of GNU Emacs.

;;; Commentary:

;; `liberime-regexp-mode' expands lower-case Rime codes in searches.  For
;; example, a search for "ni" can match both the literal code and candidates
;; such as "你".  The mode integrates with isearch, `orderless-regexp', and
;; Evil's `evil-ex-search-full-pattern' when those functions are available.
;;
;; Candidate lookup normally uses liberime's default session so that an
;; automatically committed prefix is retained.  By default, candidates which
;; consume only a prefix of the supplied code are discarded.  If the default
;; session already has an active composition, cached results remain available;
;; an uncached code is left unexpanded so that the composition is untouched.
;;
;; Basic setup:
;;
;;   (require 'liberime-regexp)
;;   (liberime-regexp-mode 1)

;;; Code:

(require 'isearch)
(require 'subr-x)

(declare-function liberime-load "liberime")
(declare-function liberime-workable-p "liberime")
(declare-function liberime-clear-composition "ext:liberime-core")
(declare-function liberime-get-candidates "ext:liberime-core"
                  (&optional limit index))
(declare-function liberime-get-commit "ext:liberime-core")
(declare-function liberime-get-context "ext:liberime-core")
(declare-function liberime-get-input "ext:liberime-core")
(declare-function liberime-get-status "ext:liberime-core")
(declare-function liberime-process-key "ext:liberime-core"
                  (keycode &optional mask))
(declare-function liberime-search "ext:liberime-core"
                  (string &optional limit index))

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

(defcustom liberime-regexp-require-full-code-match t
  "Whether candidates must consume the complete Rime code.

When non-nil, navigate the candidate menu without committing and keep only
candidates whose composition selection reaches the original input end.  This
prevents a code such as `lcdsviyu' from matching merely `老', which is a Rime
prefix candidate for `lao dong zhi yu'.

When nil, preserve liberime's complete candidate list, including candidates
which consume only an initial part of the code."
  :type 'boolean
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
  "Cache used by `liberime-regexp-get-candidates-list'.")

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

(defun liberime-regexp--full-consumption-candidates ()
  "Return current candidates which consume the entire Rime code.

Candidate highlighting changes the composition selection without committing
or learning a candidate.  Compare each highlighted candidate's selection end
with the original composition length to detect prefix-only candidates."
  (let* ((context (liberime-get-context))
         (input-end (alist-get 'length (alist-get 'composition context)))
         (limit (liberime-regexp--candidate-limit))
         (seen (make-hash-table :test #'equal))
         (examined 0)
         result)
    (when input-end
      (catch 'done
        (while context
          (let* ((composition (alist-get 'composition context))
                 (menu (alist-get 'menu context))
                 (index (alist-get 'highlighted-candidate-index menu))
                 (candidate (and index
                                 (nth index (alist-get 'candidates menu))))
                 (state (and candidate
                             (cons (alist-get 'page-no menu) index))))
            (when (or (null state) (gethash state seen))
              (throw 'done nil))
            (puthash state t seen)
            (setq examined (1+ examined))
            (when (equal (alist-get 'sel-end composition) input-end)
              (push candidate result))
            (when (and limit (>= examined limit))
              (throw 'done nil))
            ;; XK_Down moves the highlight, including across menu pages.
            (unless (liberime-process-key #xff54 0)
              (throw 'done nil))
            (setq context (liberime-get-context))))))
    (liberime-regexp--normalize-candidates (nreverse result))))

(defun liberime-regexp--current-candidates ()
  "Return candidates from the current liberime session."
  (if liberime-regexp-require-full-code-match
      (liberime-regexp--full-consumption-candidates)
    (liberime-regexp--normalize-candidates
     (liberime-get-candidates (liberime-regexp--candidate-limit)))))

(defun liberime-regexp--isolated-query (code)
  "Return an isolated-session candidate result for CODE."
  (let ((candidates
         (liberime-regexp--normalize-candidates
          (liberime-search code (liberime-regexp--candidate-limit)))))
    (and candidates (cons nil candidates))))

(defun liberime-regexp--default-session-query (code)
  "Return commit and candidates for CODE using the default session."
  (let (commit candidates remaining-input)
    (unwind-protect
        (progn
          (liberime-clear-composition)
          (mapc (lambda (character)
                  (liberime-process-key character 0))
                code)
          (setq candidates (liberime-regexp--current-candidates)
                commit (liberime-get-commit)
                remaining-input (liberime-get-input)))
      (liberime-clear-composition))
    ;; A commit without a complete residual candidate can itself be only an
    ;; automatically committed prefix.  Keep it alone only if no input remains.
    (when (and commit
               (null candidates)
               remaining-input
               (not (string-empty-p remaining-input)))
      (setq commit nil))
    (and (or commit candidates) (cons commit candidates))))

(defun liberime-regexp--cache-result (key result)
  "Cache RESULT under KEY when caching is enabled, then return RESULT."
  (when (> liberime-regexp-cache-size 0)
    (when (>= (hash-table-count liberime-regexp--candidate-cache)
              liberime-regexp-cache-size)
      (liberime-regexp-clear-cache))
    (puthash key (copy-tree result) liberime-regexp--candidate-cache))
  result)

(defun liberime-regexp-load-liberime ()
  "Load and start liberime if necessary."
  (unless (featurep 'liberime-core)
    (require 'liberime))
  (unless (liberime-workable-p)
    (liberime-load)))

(defun liberime-regexp-get-candidates-list (str)
  "Return the Rime commit and candidates for code STR.

The return value has the form (COMMIT . CANDIDATES).  COMMIT is nil unless
Rime automatically committed a prefix.  For example, possible results are:

  (nil 计算 谋算)
  (计算 与 瓦)

STR must contain only lower-case ASCII letters and apostrophes.  Apostrophes
are removed before the code is sent to Rime.  Return nil if STR is invalid,
too long according to `liberime-regexp-max-code-length', or has no matches."
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
                        liberime-regexp-require-full-code-match
                        (liberime-regexp--status-key)))
             (cached (gethash key liberime-regexp--candidate-cache
                              liberime-regexp--unset)))
        (cond
         ((not (eq cached liberime-regexp--unset))
          (copy-tree cached))
         ;; A strict query needs the default session.  Leave an existing
         ;; composition untouched and retry after it ends.
         ((and active-composition-p
               liberime-regexp-require-full-code-match)
          nil)
         (t
          (liberime-regexp--cache-result
           key
           (if active-composition-p
               (liberime-regexp--isolated-query code)
             (liberime-regexp--default-session-query code)))))))))

(defun liberime-regexp--code-regexp (code)
  "Return a regexp matching CODE or any of its Rime expansions."
  (let* ((commit-and-candidates
          (liberime-regexp-get-candidates-list code))
         (commit (car commit-and-candidates))
         (candidates (cdr commit-and-candidates))
         (converted
          (cond
           ((and commit candidates)
            (mapcar (lambda (candidate)
                      (concat commit candidate))
                    candidates))
           (commit (list commit))
           (candidates candidates))))
    (if converted
        (regexp-opt (delete-dups (cons code converted)))
      code)))

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
(defun liberime-regexp-enable ()
  "Enable `liberime-regexp-mode'."
  (liberime-regexp-mode 1))

(provide 'liberime-regexp)

;;; liberime-regexp.el ends here
