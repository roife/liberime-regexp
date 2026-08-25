;;; liberime-regexp.el --- Search Chinese text with Rime codes  -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; Version: 0.5.0
;; Package-Requires: ((emacs "27.1") (avy "0.5.0") (liberime "0.0.7"))
;; Keywords: convenience, i18n, matching

;; This file is not part of GNU Emacs.

;;; Commentary:

;; `liberime-regexp-mode' expands lower-case Rime codes in searches.  For
;; example, a search for "ni" can match both the literal code and candidates
;; such as "你".  The mode integrates with isearch, `orderless-regexp', and
;; Evil's `evil-ex-search-full-pattern' when those functions are available.
;; `liberime-regexp-avy-mode' adds the same expansion to Avy character jumps.
;; `liberime-regexp-segment-mode' builds a weighted word graph from librime's
;; Dictionary and ReverseLookupDictionary for Chinese word motion, killing,
;; and marking.  It reads canonical spellings from the active Rime dictionary,
;; so keyboard layouts such as full Pinyin, double Pinyin, and Cangjie need no
;; package-specific conversion.
;;
;; Candidate lookup normally reuses an isolated Rime session.  It falls back to
;; the default session when the active option state cannot be reproduced.  The
;; shortest prefix candidates may be composed recursively, but every generated
;; expansion must consume the complete supplied code.  When its native module
;; is available, this package calls librime's public set_input API directly;
;; Liberime itself needs no package-specific changes.
;;
;; Basic setup:
;;
;;   (require 'liberime-regexp)
;;   (liberime-regexp-mode 1)
;;   (liberime-regexp-segment-mode 1)

;;; Code:

(require 'avy)
(require 'cl-lib)
(require 'isearch)
(require 'subr-x)

(declare-function liberime-load "liberime")
(declare-function liberime-workable-p "liberime")
(declare-function liberime-clear-composition "ext:liberime-core")
(declare-function liberime-get-commit "ext:liberime-core")
(declare-function liberime-get-context "ext:liberime-core")
(declare-function liberime-get-input "ext:liberime-core")
(declare-function liberime-get-status "ext:liberime-core" (&optional session))
(declare-function liberime-process-key "ext:liberime-core"
                  (keycode &optional mask))
(declare-function liberime-search "ext:liberime-core"
                  (string &optional limit index schema-id full-context session))
(declare-function liberime-session-create "ext:liberime-core"
                  (&optional schema-id))
(declare-function liberime-session-destroy "ext:liberime-core" (session))
(declare-function liberime-regexp--native-query
                  "ext:liberime-regexp-core" (session input &optional limit))
(declare-function liberime-regexp--native-segment-han
                  "ext:liberime-regexp-core"
                  (schema-id namespace text max-word-length
                             code-limit single-weight))
(declare-function liberime-regexp--native-clear-cache
                  "ext:liberime-regexp-core" ())

(defgroup liberime-regexp nil
  "Build regular expressions from Rime candidates."
  :group 'matching
  :prefix "liberime-regexp-")

(defconst liberime-regexp--directory
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory containing the liberime-regexp package.")

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

(defcustom liberime-regexp-segment-max-word-length 6
  "Maximum Chinese word length considered by the segmenter.

The segmenter tries longer Rime dictionary entries first.  Larger values make
segmentation more expensive because more substrings have to be looked up."
  :type 'integer
  :group 'liberime-regexp)

(defcustom liberime-regexp-segment-code-limit 64
  "Maximum reverse-dictionary code combinations tried for one substring.

This bounds combinations for polyphonic and shape-code dictionary entries.  A
non-positive value means no limit."
  :type 'integer
  :group 'liberime-regexp)

(defcustom liberime-regexp-segment-dictionary-namespace "translator"
  "Schema namespace from which the librime Dictionary is created."
  :type 'string
  :group 'liberime-regexp)

(defcustom liberime-regexp-segment-context-length 32
  "Maximum Han context examined on each side of point for word motion."
  :type 'integer
  :group 'liberime-regexp)

(defcustom liberime-regexp-segment-single-character-weight -12.0
  "Fallback graph weight assigned to each single Han character."
  :type 'number
  :group 'liberime-regexp)

(defcustom liberime-regexp-module-file nil
  "Optional path to the liberime-regexp native module."
  :type '(choice (const nil) file)
  :group 'liberime-regexp)

(defconst liberime-regexp--code-pattern "[a-z][a-z']*"
  "Regexp matching a Rime code embedded in a search string.")

(defconst liberime-regexp--advised-functions
  '(orderless-regexp evil-ex-search-full-pattern))

(defconst liberime-regexp--unset (make-symbol "unset"))

(defvar liberime-regexp--candidate-cache (make-hash-table :test #'equal)
  "Cache candidate queries and their generated regexps.")

(defvar liberime-regexp--segment-cache (make-hash-table :test #'equal)
  "Cache complete segmentation results.")

(defvar liberime-regexp--search-session nil
  "Isolated librime session reused for search expansion.")

(defvar liberime-regexp--search-session-key nil
  "Rime status key associated with `liberime-regexp--search-session'.")

(defvar liberime-regexp--search-session-unavailable-key nil
  "Status key for which an equivalent isolated session could not be made.")

(defvar liberime-regexp--saved-isearch-search-fun-function nil)

(defun liberime-regexp--candidate-limit ()
  "Return the effective candidate limit, or nil for no limit."
  (and liberime-regexp-candidate-limit
       (> liberime-regexp-candidate-limit 0)
       liberime-regexp-candidate-limit))

(defun liberime-regexp--status-key (&optional status)
  "Return the Rime state relevant to candidate lookup."
  (let ((status (or status (liberime-get-status))))
    (list (alist-get 'schema_id status)
          (alist-get 'is_ascii_mode status)
          (alist-get 'is_full_shape status)
          (alist-get 'is_simplified status)
          (alist-get 'is_traditional status))))

(defun liberime-regexp-clear-cache ()
  "Clear cached Rime candidate queries."
  (interactive)
  (clrhash liberime-regexp--candidate-cache)
  (clrhash liberime-regexp--segment-cache))

(defun liberime-regexp-clear-dictionary-cache ()
  "Release native Dictionary objects and cached segmentation results."
  (interactive)
  (when (fboundp 'liberime-regexp--native-clear-cache)
    (liberime-regexp--native-clear-cache))
  (clrhash liberime-regexp--segment-cache))

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

(defun liberime-regexp--make-query-result
    (commit expansions remaining-input)
  "Build a query result from COMMIT, EXPANSIONS, and REMAINING-INPUT."
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
               :regexp nil))))

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
    (liberime-regexp--make-query-result
     commit expansions remaining-input)))

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

(defun liberime-regexp-close-search-session ()
  "Destroy the isolated Rime session used by search expansion."
  (when liberime-regexp--search-session
    (ignore-errors
      (liberime-session-destroy liberime-regexp--search-session)))
  (setq liberime-regexp--search-session nil
        liberime-regexp--search-session-key nil
        liberime-regexp--search-session-unavailable-key nil))

(defun liberime-regexp--ensure-search-session (status)
  "Return an isolated session equivalent to default-session STATUS."
  (let ((key (liberime-regexp--status-key status)))
    (cond
     ((and liberime-regexp--search-session
           (equal key liberime-regexp--search-session-key))
      liberime-regexp--search-session)
     ((equal key liberime-regexp--search-session-unavailable-key)
      nil)
     ((not (and (fboundp 'liberime-session-create)
                (fboundp 'liberime-session-destroy)))
      nil)
     (t
      (liberime-regexp-close-search-session)
      (condition-case nil
          (let* ((session
                  (liberime-session-create (alist-get 'schema_id status)))
                 (session-key
                  (liberime-regexp--status-key
                   (liberime-get-status session))))
            (if (equal key session-key)
                (progn
                  (setq liberime-regexp--search-session session
                        liberime-regexp--search-session-key key)
                  session)
              (liberime-session-destroy session)
              (setq liberime-regexp--search-session-unavailable-key key)
              nil))
        (error
         (setq liberime-regexp--search-session-unavailable-key key)
         nil))))))

(defun liberime-regexp--isolated-session-query (code status)
  "Query CODE in an isolated session matching default-session STATUS."
  (when-let* ((session (liberime-regexp--ensure-search-session status)))
    (condition-case nil
        (let ((result
               (or (and (liberime-regexp--try-load-native-module)
                        (fboundp 'liberime-regexp--native-query)
                        (liberime-regexp--native-query
                         session code
                         (or (liberime-regexp--candidate-limit) 0)))
                   ;; The native module is optional.  Liberime's ordinary
                   ;; public search binding remains the compatibility path.
                   (liberime-search code (liberime-regexp--candidate-limit)
                                    nil nil t session))))
          ;; Keep the cached regexp in the same plist object even when the
          ;; Liberime compatibility result did not reserve these slots.
          (when result
            (setq result (plist-put result :regexp-code nil)
                  result (plist-put result :regexp nil)))
          result)
      (error
       (liberime-regexp-close-search-session)
       nil))))

(defun liberime-regexp--try-load-native-module ()
  "Try to load this package's native module and return non-nil on success."
  (unless (featurep 'liberime-regexp-core)
    (when (and liberime-regexp-module-file
               (file-exists-p liberime-regexp-module-file))
      (load-file liberime-regexp-module-file))
    (let ((load-path (cons (expand-file-name "src"
                                             liberime-regexp--directory)
                           load-path)))
      (require 'liberime-regexp-core nil t)))
  (featurep 'liberime-regexp-core))

(defun liberime-regexp-load-native-module ()
  "Load the native candidate-query and static-dictionary module."
  (unless (liberime-regexp--try-load-native-module)
    (user-error "Build liberime-regexp-core with make first")))

(defun liberime-regexp--query-code (str &optional preserve-separators)
  "Return cached candidate expansion data for Rime code STR.

The result is an internal plist produced by
`liberime-regexp--default-session-query'.  Return nil if STR is invalid, too
long according to `liberime-regexp-max-code-length', or has no expansions.
When PRESERVE-SEPARATORS is non-nil, send apostrophes to Rime instead of
removing them."
  (let ((code (if preserve-separators
                  str
                (replace-regexp-in-string "'" "" str t t))))
    (when (and (not (string-empty-p code))
               (let ((case-fold-search nil))
                 (string-match-p "\\`[a-z']+\\'" str))
               (or (<= liberime-regexp-max-code-length 0)
                   (<= (length code) liberime-regexp-max-code-length)))
      (liberime-regexp-load-liberime)
      (let* ((status (liberime-get-status))
             (input (liberime-get-input))
             (active-composition-p
              (and input (not (string-empty-p input))))
             (key (list code
                        (liberime-regexp--candidate-limit)
                        (liberime-regexp--status-key status)))
             (cached (gethash key liberime-regexp--candidate-cache
                              liberime-regexp--unset)))
        (cond
         ((not (eq cached liberime-regexp--unset))
          cached)
         ((let ((result
                 (liberime-regexp--isolated-session-query code status)))
            (and result (liberime-regexp--cache-result key result))))
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

(defun liberime-regexp--han-character-p (character)
  "Return non-nil when CHARACTER uses the Han script."
  (and character (eq (aref char-script-table character) 'han)))

(defun liberime-regexp--segment-han-with-dictionary (string)
  "Segment Han STRING using librime's reverse dictionary and binary tables."
  (liberime-regexp-load-native-module)
  (mapcar (lambda (bounds)
            (cons (aref bounds 0) (aref bounds 1)))
          (append
           (liberime-regexp--native-segment-han
            (alist-get 'schema_id (liberime-get-status))
            liberime-regexp-segment-dictionary-namespace string
            (max 1 liberime-regexp-segment-max-word-length)
            (max 0 liberime-regexp-segment-code-limit)
            (float liberime-regexp-segment-single-character-weight))
           nil)))

(defun liberime-regexp--segment-with-dictionary (string)
  "Segment STRING using the librime Dictionary backend."
  (let ((position 0)
        (length (length string))
        bounds)
    (while (< position length)
      (let ((character (aref string position)))
        (cond
         ((liberime-regexp--han-character-p character)
          (let ((beginning position))
            (while (and (< position length)
                        (liberime-regexp--han-character-p
                         (aref string position)))
              (setq position (1+ position)))
            (dolist (bound
                     (liberime-regexp--segment-han-with-dictionary
                      (substring string beginning position)))
              (push (cons (+ beginning (car bound))
                          (+ beginning (cdr bound)))
                    bounds))))
         ((memq (char-syntax character) '(?w ?_))
          (let ((beginning position))
            (while (and (< position length)
                        (not (liberime-regexp--han-character-p
                              (aref string position)))
                        (memq (char-syntax (aref string position)) '(?w ?_)))
              (setq position (1+ position)))
            (push (cons beginning position) bounds)))
         (t
          (setq position (1+ position))))))
    (nreverse bounds)))

(defun liberime-regexp--cache-segmentation (key result)
  "Cache segmentation RESULT under KEY, then return RESULT."
  (when (> liberime-regexp-cache-size 0)
    (when (>= (hash-table-count liberime-regexp--segment-cache)
              liberime-regexp-cache-size)
      (clrhash liberime-regexp--segment-cache))
    (puthash key result liberime-regexp--segment-cache))
  result)

(defun liberime-regexp-segment (string)
  "Segment STRING and return a list of word bounds.

Each bound is a cons cell (BEGINNING . END), using zero-based character
positions as in `substring'.  The reverse-dictionary backend constructs a
weighted word graph from raw librime table entries and selects its
maximum-weight path.  Non-Chinese words use the usual Emacs character syntax."
  (liberime-regexp-load-liberime)
  (let* ((key (list string
                    liberime-regexp-segment-max-word-length
                    liberime-regexp-segment-code-limit
                    liberime-regexp-segment-single-character-weight
                    liberime-regexp-segment-dictionary-namespace
                    (alist-get 'schema_id (liberime-get-status))))
         (cached (gethash key liberime-regexp--segment-cache
                          liberime-regexp--unset)))
    (if (not (eq cached liberime-regexp--unset))
        cached
      (liberime-regexp--cache-segmentation
       key (liberime-regexp--segment-with-dictionary string)))))

(defun liberime-regexp-split-string (string)
  "Split STRING into words using the active Rime dictionary.

Whitespace and punctuation are not included in the result.  Use
`liberime-regexp-segment' when the original positions are needed."
  (mapcar (lambda (bounds)
            (substring string (car bounds) (cdr bounds)))
          (liberime-regexp-segment string)))

(defun liberime-regexp--han-window-at-point (backward)
  "Return bounded Han context around point, or nil.

When BACKWARD is non-nil, associate a word boundary with the character before
point; otherwise associate it with the character after point."
  (let* ((anchor (if backward (1- (point)) (point)))
         (limit (max 1 liberime-regexp-segment-context-length)))
    (when (and (>= anchor (point-min))
               (< anchor (point-max))
               (liberime-regexp--han-character-p (char-after anchor)))
      (let ((beginning anchor)
            (end (1+ anchor))
            (minimum (max (point-min) (- anchor (1- limit))))
            (maximum (min (point-max) (+ anchor limit))))
        (while (and (> beginning minimum)
                    (liberime-regexp--han-character-p
                     (char-after (1- beginning))))
          (setq beginning (1- beginning)))
        (while (and (< end maximum)
                    (liberime-regexp--han-character-p (char-after end)))
          (setq end (1+ end)))
        (list beginning end anchor)))))

(defun liberime-regexp-words-at-point (&optional backward)
  "Return the selected Chinese word at point.

Each result has the form (WORD LEFT RIGHT), where LEFT and RIGHT are distances
from point to the word's beginning and end.  At a word boundary, use the word
after point by default; when BACKWARD is non-nil, use the word before point."
  (when-let* ((window (liberime-regexp--han-window-at-point backward))
              (window-beginning (nth 0 window))
              (window-end (nth 1 window))
              (anchor (nth 2 window)))
    (let* ((text (buffer-substring-no-properties window-beginning window-end))
           (anchor-offset (- anchor window-beginning))
           (point-offset (- (point) window-beginning))
           (bounds (cl-find-if
                    (lambda (bound)
                      (and (<= (car bound) anchor-offset)
                           (< anchor-offset (cdr bound))))
                    (liberime-regexp-segment text))))
      (when bounds
        (list (list (substring text (car bounds) (cdr bounds))
                    (- point-offset (car bounds))
                    (- (cdr bounds) point-offset)))))))

(defun liberime-regexp--longest-distance (words index)
  "Return the greatest non-negative distance at INDEX in WORDS."
  (let ((distance 0))
    (dolist (word words distance)
      (setq distance (max distance (max 0 (nth index word)))))))

(defun liberime-regexp-forward-word (&optional arg)
  "Move forward ARG Chinese or ordinary words.

Chinese word boundaries are obtained from the active Rime dictionary.  Move
backward when ARG is negative."
  (interactive "^p")
  (setq arg (or arg 1))
  (if (< arg 0)
      (liberime-regexp-backward-word (- arg))
    (let ((count 0)
          stopped)
      (while (and (< count arg) (< (point) (point-max)) (not stopped))
        (unless (memq (char-syntax (or (char-after) 0)) '(?w ?_))
          (skip-syntax-forward "^w_"))
        (if (>= (point) (point-max))
            (setq stopped t)
          (if (liberime-regexp--han-character-p (char-after))
              (forward-char
               (max 1 (liberime-regexp--longest-distance
                       (liberime-regexp-words-at-point) 2)))
            (forward-word 1))
          (setq count (1+ count))))
      (= count arg))))

(defun liberime-regexp-backward-word (&optional arg)
  "Move backward ARG Chinese or ordinary words.

Chinese word boundaries are obtained from the active Rime dictionary.  Move
forward when ARG is negative."
  (interactive "^p")
  (setq arg (or arg 1))
  (if (< arg 0)
      (liberime-regexp-forward-word (- arg))
    (let ((count 0)
          stopped)
      (while (and (< count arg) (> (point) (point-min)) (not stopped))
        (unless (memq (char-syntax (or (char-before) 0)) '(?w ?_))
          (skip-syntax-backward "^w_"))
        (if (<= (point) (point-min))
            (setq stopped t)
          (if (liberime-regexp--han-character-p (char-before))
              (backward-char
               (max 1 (liberime-regexp--longest-distance
                       (liberime-regexp-words-at-point t) 1)))
            (backward-word 1))
          (setq count (1+ count))))
      (= count arg))))

(defun liberime-regexp-kill-word (arg)
  "Kill ARG words forward, using Rime for Chinese word boundaries."
  (interactive "p")
  (kill-region (point)
               (save-excursion
                 (liberime-regexp-forward-word arg)
                 (point))))

(defun liberime-regexp-backward-kill-word (arg)
  "Kill ARG words backward, using Rime for Chinese word boundaries."
  (interactive "p")
  (liberime-regexp-kill-word (- arg)))

(defun liberime-regexp-mark-word (&optional arg)
  "Mark ARG words, using Rime for Chinese word boundaries."
  (interactive "p")
  (setq arg (or arg 1))
  (push-mark (point) t t)
  (liberime-regexp-forward-word arg))

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

(defvar liberime-regexp-segment-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map [remap forward-word]
                #'liberime-regexp-forward-word)
    (define-key map [remap backward-word]
                #'liberime-regexp-backward-word)
    (define-key map [remap kill-word]
                #'liberime-regexp-kill-word)
    (define-key map [remap backward-kill-word]
                #'liberime-regexp-backward-kill-word)
    (define-key map [remap mark-word]
                #'liberime-regexp-mark-word)
    map)
  "Keymap for `liberime-regexp-segment-mode'.")

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
        (ignore-errors
          (liberime-regexp--ensure-search-session
           (liberime-get-status)))
        (liberime-regexp--install-integrations))
    (liberime-regexp--remove-integrations)
    (liberime-regexp-close-search-session)
    (liberime-regexp-clear-cache)))

;;;###autoload
(define-minor-mode liberime-regexp-avy-mode
  "Use Rime codes with Avy character commands."
  :global t
  :group 'liberime-regexp
  :keymap liberime-regexp-avy-mode-map)

;;;###autoload
(define-minor-mode liberime-regexp-segment-mode
  "Use the active Rime dictionary for Chinese word operations."
  :global t
  :group 'liberime-regexp
  :keymap liberime-regexp-segment-mode-map
  (when liberime-regexp-segment-mode
    (liberime-regexp-load-liberime)))

;;;###autoload
(defun liberime-regexp-enable ()
  "Enable `liberime-regexp-mode'."
  (liberime-regexp-mode 1))

(provide 'liberime-regexp)

;;; liberime-regexp.el ends here
