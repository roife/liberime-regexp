;;; liberime-regexp-segment.el --- Rime dictionary word boundaries -*- lexical-binding: t; -*-

;;; Commentary:

;; Loaded by liberime-regexp.  The Lua gateway owns Rime dictionary access;
;; this file owns the transport, character offsets, segmentation and editing.

;;; Code:

(require 'cl-lib)
(require 'hex-util)
(require 'ring)

(declare-function liberime-regexp-load-liberime "liberime-regexp")
(autoload 'liberime-regexp-load-liberime "liberime-regexp")
(declare-function liberime-get-status "ext:liberime-core" (&optional session))
(declare-function liberime-session-create "ext:liberime-core" (&optional schema))
(declare-function liberime-session-destroy "ext:liberime-core" (session))
(declare-function liberime-search "ext:liberime-core"
                  (code &optional limit index schema full-context session))
(declare-function liberime-regexp--session-schema "liberime-regexp" (session))
(declare-function liberime-regexp--cache-get "liberime-regexp" (table key))
(declare-function liberime-regexp--cache-put "liberime-regexp" (table order key value))
(defvar liberime-regexp-cache-size)
(defvar liberime-regexp--unset)

(defgroup liberime-regexp-segment nil
  "Segment Chinese text using a Rime static dictionary."
  :group 'liberime-regexp)

(defcustom liberime-regexp-segment-schema "liberime_regexp_segment"
  "Deployed Rime schema hosting the Lua segmentation translator."
  :type 'string :group 'liberime-regexp-segment)

(defcustom liberime-regexp-segment-max-word-length 8
  "Maximum number of characters in a dictionary word, from 1 through 64."
  :type 'integer :group 'liberime-regexp-segment)

(defcustom liberime-regexp-segment-combination-limit 64
  "Maximum code combinations per word, a positive integer."
  :type 'integer :group 'liberime-regexp-segment)

(defcustom liberime-regexp-segment-candidate-limit 128
  "Maximum candidates examined per code, a positive integer."
  :type 'integer :group 'liberime-regexp-segment)

(defvar liberime-regexp--segment-session nil)
(defvar liberime-regexp--segment-cache (make-hash-table :test #'equal))
(defvar liberime-regexp--segment-cache-order (make-ring 256))

(defsubst liberime-regexp--han-p (char)
  "Return non-nil if CHAR is a Han character."
  (eq (aref char-script-table char) 'han))

(defsubst liberime-regexp--other-word-p (char)
  "Return non-nil if CHAR is a non-Han word constituent."
  (and (eq (char-syntax char) ?w) (not (liberime-regexp--han-p char))))

(defsubst liberime-regexp--word-char-p (char)
  "Return non-nil if CHAR belongs to a Han or non-Han word."
  (or (liberime-regexp--han-p char) (eq (char-syntax char) ?w)))

(defun liberime-regexp--segment-clear-cache ()
  "Discard segmentation results."
  (clrhash liberime-regexp--segment-cache)
  (setq liberime-regexp--segment-cache-order
        (make-ring (max 1 liberime-regexp-cache-size))))

(defun liberime-regexp--segment-reset ()
  "Forget the session ID after Rime restarts; the cache is cleared with core's."
  (setq liberime-regexp--segment-session nil))

(defun liberime-regexp--segment-destroy-session ()
  "Release the segmentation session, including an expired session."
  (when liberime-regexp--segment-session
    (liberime-session-destroy liberime-regexp--segment-session)
    (setq liberime-regexp--segment-session nil)))

(defun liberime-regexp--segment-ensure-session ()
  "Create or recover the isolated segmentation session."
  (unless (equal liberime-regexp-segment-schema
                 (liberime-regexp--session-schema liberime-regexp--segment-session))
    (liberime-regexp--segment-destroy-session)
    (setq liberime-regexp--segment-session
          (liberime-session-create liberime-regexp-segment-schema))))

(defun liberime-regexp--segment-request (text schema limits)
  "Query TEXT for SCHEMA with LIMITS; return dictionary edges.
Each edge is a vector [START END WEIGHT] with character offsets."
  (let* ((request (format "%sg%dg%dg%dg%sz"
                          (encode-hex-string (encode-coding-string schema 'utf-8))
                          (nth 0 limits) (nth 1 limits) (nth 2 limits)
                          (encode-hex-string (encode-coding-string text 'utf-8))))
         (records (liberime-search request nil nil nil nil
                                    liberime-regexp--segment-session)))
    (when (equal (car records) "error")
      (user-error "Rime segmentation: %s" (get-text-property 0 :comment (car records))))
    (unless (equal (car (last records)) "done")
      (user-error "Rime segmentation gateway did not respond; check librime-lua and redeploy Rime"))
    (mapcar #'json-parse-string (butlast records))))

(defun liberime-regexp--segment-edges (text schema limits)
  "Collect dictionary edges across overlapping TEXT chunks.
SCHEMA and LIMITS select the dictionary and query bounds."
  (let ((start 0) (size (length text)) edges)
    (while (< start size)
      (let* ((end (min size (+ start 64)))
             (reply (liberime-regexp--segment-request (substring text start end) schema limits)))
        (dolist (edge reply)
          (push (vector (+ start (aref edge 0)) (+ start (aref edge 1)) (aref edge 2)) edges))
        (setq start (if (= end size) size (- end (1- (car limits)))))))
    edges))

(defun liberime-regexp--segment-best-path (size edges)
  "Select a maximum-weight path covering SIZE characters using EDGES."
  (let ((outgoing (make-vector size nil))
        (scores (make-vector (1+ size) 0.0))
        (counts (make-vector (1+ size) 0))
        (next (make-vector size nil))
        result)
    (dolist (edge edges) (push edge (aref outgoing (aref edge 0))))
    (cl-loop for start downfrom (1- size) to 0 do
             (let ((choices (aref outgoing start)) best-score best-count best-end)
               (unless (cl-some (lambda (edge) (= (aref edge 1) (1+ start))) choices)
                 (push (vector start (1+ start) -30.0) choices))
               (dolist (edge choices)
                 (let* ((end (aref edge 1))
                        (score (+ (aref edge 2) (aref scores end)))
                        (count (1+ (aref counts end))))
                   (when (or (null best-score) (> score best-score)
                             (and (= score best-score)
                                  (or (< count best-count)
                                      (and (= count best-count) (> end best-end)))))
                     (setq best-score score best-count count best-end end))))
               (aset scores start best-score)
               (aset counts start best-count)
               (aset next start best-end)))
    (let ((start 0))
      (while (< start size)
        (push (cons start (aref next start)) result)
        (setq start (aref next start))))
    (nreverse result)))

(defun liberime-regexp--segment-han (text schema)
  "Return word boundaries for a contiguous Han TEXT using SCHEMA."
  ;; Positive limits bound Lua's search; the word limit also ensures that
  ;; overlapping 64-character chunks always advance.
  (cl-check-type liberime-regexp-segment-max-word-length (integer 1 64))
  (cl-check-type liberime-regexp-segment-combination-limit (integer 1 *))
  (cl-check-type liberime-regexp-segment-candidate-limit (integer 1 *))
  (liberime-regexp-load-liberime)
  (let* ((schema (or schema (alist-get 'schema_id (liberime-get-status))))
         (limits (list liberime-regexp-segment-max-word-length
                       liberime-regexp-segment-combination-limit
                       liberime-regexp-segment-candidate-limit))
         ;; Dictionary configuration is fixed until Rime restarts and clears the cache.
         (key (list text schema limits))
         (cached (liberime-regexp--cache-get liberime-regexp--segment-cache key)))
    (if (not (eq cached liberime-regexp--unset))
        cached
      (liberime-regexp--segment-ensure-session)
      (liberime-regexp--cache-put
       liberime-regexp--segment-cache liberime-regexp--segment-cache-order key
       (liberime-regexp--segment-best-path
        (length text) (liberime-regexp--segment-edges text schema limits))))))

;;;###autoload
(defun liberime-regexp-segment (string &optional schema)
  "Return word boundaries in STRING using the dictionary of SCHEMA.
Each boundary is a zero-based (START . END) character range, END exclusive.
SCHEMA defaults to the current input schema.  Han runs use static Rime
dictionary weights; other words use the current buffer's syntax table.
Whitespace and punctuation are omitted.  This does not change Rime input."
  (let ((position 0) (size (length string)) result)
    (while (< position size)
      (let ((start position) (char (aref string position)))
        (cond
         ((liberime-regexp--han-p char)
          (while (and (< position size) (liberime-regexp--han-p (aref string position)))
            (setq position (1+ position)))
          (dolist (range (liberime-regexp--segment-han (substring string start position) schema))
            (push (cons (+ start (car range)) (+ start (cdr range))) result)))
         ((eq (char-syntax char) ?w)
          (while (and (< position size) (liberime-regexp--other-word-p (aref string position)))
            (setq position (1+ position)))
          (push (cons start position) result))
         (t (setq position (1+ position))))))
    (nreverse result)))

;;;###autoload
(defun liberime-regexp-split-string (string &optional schema)
  "Return the words of STRING using SCHEMA, omitting whitespace/punctuation."
  (mapcar (lambda (range) (substring string (car range) (cdr range)))
          (liberime-regexp-segment string schema)))

(defun liberime-regexp--segment-buffer-run ()
  "Return absolute word ranges for the Han run containing point."
  (save-excursion
    (let ((origin (point)) start end)
      (while (and (> (point) (point-min)) (liberime-regexp--han-p (preceding-char)))
        (backward-char))
      (setq start (point))
      (goto-char origin)
      (while (and (< (point) (point-max)) (liberime-regexp--han-p (following-char)))
        (forward-char))
      (setq end (point))
      (mapcar (lambda (range) (cons (+ start (car range)) (+ start (cdr range))))
              (liberime-regexp--segment-han (buffer-substring-no-properties start end) nil)))))

(defun liberime-regexp--move-word (backward)
  "Move across one word; move backwards when BACKWARD is non-nil."
  (let ((char (if backward #'preceding-char #'following-char))
        (step (if backward -1 1))
        (boundary (if backward (point-min) (point-max))))
    (while (and (/= (point) boundary)
                (not (liberime-regexp--word-char-p (funcall char))))
      (forward-char step))
    (cond
     ((= (point) boundary) nil)
     ((liberime-regexp--han-p (funcall char))
      (let* ((position (point))
             (ranges (liberime-regexp--segment-buffer-run))
             (range (if backward
                        (cl-find-if (lambda (range) (< (car range) position)) ranges :from-end t)
                      (cl-find-if (lambda (range) (> (cdr range) position)) ranges))))
        (goto-char (if backward (car range) (cdr range))) t))
     (t
      (while (and (/= (point) boundary) (liberime-regexp--other-word-p (funcall char)))
        (forward-char step))
      t))))

;;;###autoload
(defun liberime-regexp-forward-word (&optional arg)
  "Move forward ARG words using Rime Han boundaries; negative ARG goes back."
  (interactive "^p")
  (let ((arg (or arg 1)) (success t))
    (dotimes (_ (abs arg))
      (unless (liberime-regexp--move-word (< arg 0)) (setq success nil)))
    success))

;;;###autoload
(defun liberime-regexp-backward-word (&optional arg)
  "Move backward ARG words using Rime Han boundaries."
  (interactive "^p")
  (liberime-regexp-forward-word (- (or arg 1))))

;;;###autoload
(defun liberime-regexp-kill-word (arg)
  "Kill forward ARG words using Rime Han boundaries."
  (interactive "p")
  (kill-region (point) (save-excursion (liberime-regexp-forward-word arg) (point))))

;;;###autoload
(defun liberime-regexp-backward-kill-word (arg)
  "Kill backward ARG words using Rime Han boundaries."
  (interactive "p")
  (liberime-regexp-kill-word (- arg)))

;;;###autoload
(defun liberime-regexp-mark-word (&optional arg allow-extend)
  "Mark ARG words using Rime boundaries, extending when ALLOW-EXTEND is set."
  (interactive "P\np")
  (let ((count (prefix-numeric-value arg))
        (backward (and (mark t) (< (mark) (point)))))
    (if (and allow-extend (mark t)
             (or (eq last-command this-command) (region-active-p)))
        (set-mark (save-excursion
                    (goto-char (mark))
                    (liberime-regexp-forward-word
                     (if arg count (if backward -1 1)))
                    (point)))
      (push-mark (save-excursion (liberime-regexp-forward-word count) (point)) nil t))))

;;;###autoload
(defun liberime-regexp-word-at-point ()
  "Return the word containing point, or the preceding word at its end."
  (save-excursion
    (when (and (not (liberime-regexp--word-char-p (following-char)))
               (> (point) (point-min))
               (liberime-regexp--word-char-p (preceding-char)))
      (backward-char))
    (cond
     ((liberime-regexp--han-p (following-char))
      (let ((range (cl-find-if (lambda (range) (<= (car range) (point) (1- (cdr range))))
                               (liberime-regexp--segment-buffer-run))))
        (buffer-substring-no-properties (car range) (cdr range))))
     ((eq (char-syntax (following-char)) ?w)
      (while (and (> (point) (point-min)) (liberime-regexp--other-word-p (preceding-char)))
        (backward-char))
      (let ((start (point)))
        (liberime-regexp--move-word nil)
        (buffer-substring-no-properties start (point)))))))

(defvar liberime-regexp-segment-mode-map
  (let ((map (make-sparse-keymap)))
    (dolist (command '(forward-word backward-word kill-word backward-kill-word mark-word))
      (define-key map (vector 'remap command)
                  (intern (concat "liberime-regexp-" (symbol-name command)))))
    map))

;;;###autoload
(define-minor-mode liberime-regexp-segment-mode
  "Globally use Rime word boundaries for word movement, killing and marking."
  :global t :group 'liberime-regexp-segment :keymap liberime-regexp-segment-mode-map
  (unless liberime-regexp-segment-mode
    (liberime-regexp--segment-destroy-session)
    (liberime-regexp--segment-clear-cache)))

(add-hook 'liberime-after-start-hook #'liberime-regexp--segment-reset)
(add-hook 'kill-emacs-hook #'liberime-regexp--segment-destroy-session)

(provide 'liberime-regexp-segment)
;;; liberime-regexp-segment.el ends here
