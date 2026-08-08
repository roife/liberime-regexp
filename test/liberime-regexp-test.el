;;; liberime-regexp-test.el --- Tests for liberime-regexp  -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'liberime-regexp)

(ert-deftest liberime-regexp-test-keeps-shortest-prefix-group ()
  (let* ((contexts
          (vector
           '((composition
              (length . 6) (sel-end . 6) (preedit . "abcdef"))
             (menu
              (page-no . 0) (highlighted-candidate-index . 0)
              (candidates "完整")))
           '((composition
              (length . 6) (sel-end . 4) (preedit . "abcdef"))
             (menu
              (page-no . 0) (highlighted-candidate-index . 1)
              (candidates "unused" "中词")))
           '((composition
              (length . 6) (sel-end . 2) (preedit . "abcdef"))
             (menu
              (page-no . 0) (highlighted-candidate-index . 2)
              (candidates "unused" "unused" "短")))))
         (context-index 0))
    (cl-letf (((symbol-function 'liberime-get-context)
               (lambda () (aref contexts context-index)))
              ((symbol-function 'liberime-process-key)
               (lambda (&rest _)
                 (when (< context-index (1- (length contexts)))
                   (setq context-index (1+ context-index))
                   t))))
      (should
       (equal (liberime-regexp--candidate-expansions)
              '(:full ("完整") :prefix ("短") :remainder "cdef"))))))

(ert-deftest liberime-regexp-test-composes-without-prefix-only-match ()
  (let ((whole-query
         (list :commit nil :full '("整词") :prefix '("甲" "假")
               :remainder "cd" :remaining-input "abcd"
               :regexp-code nil :regexp nil))
        (suffix-query
         (list :commit nil :full '("乙") :prefix nil
               :remainder nil :remaining-input "cd"
               :regexp-code nil :regexp nil)))
    (cl-letf (((symbol-function 'liberime-regexp--query-code)
               (lambda (code)
                 (if (string= code "abcd") whole-query suffix-query))))
      (let ((regexp (liberime-regexp--code-regexp "abcd")))
        (should (string-match-p (concat "\\`" regexp "\\'") "甲乙"))
        (should (string-match-p (concat "\\`" regexp "\\'") "整词"))
        (should (string-match-p (concat "\\`" regexp "\\'") "abcd"))
        (should-not (string-match-p (concat "\\`" regexp "\\'") "甲"))
        (should (eq regexp (liberime-regexp--code-regexp "abcd")))))))

(ert-deftest liberime-regexp-test-avy-char-2-uses-combined-code ()
  (let (builder-args jump-args)
    (cl-letf (((symbol-function 'liberime-regexp-build-regexp-string)
               (lambda (&rest args)
                 (setq builder-args args)
                 "expanded"))
              ((symbol-function 'avy-jump)
               (lambda (&rest args)
                 (setq jump-args args))))
      (liberime-regexp-avy-goto-char-2 ?n ?i 'flip 10 20)
      (should (equal builder-args '("ni" t)))
      (should (equal jump-args
                     '("expanded" :window-flip flip :beg 10 :end 20))))))

(ert-deftest liberime-regexp-test-avy-timer-uses-rime-builder ()
  (let (builder-args processed)
    (cl-letf (((symbol-function 'liberime-regexp-build-regexp-string)
               (lambda (&rest args)
                 (setq builder-args args)
                 "expanded"))
              ((symbol-function 'avy--read-candidates)
               (lambda (builder)
                 (should (equal (funcall builder "ni") "expanded"))
                 'candidates))
              ((symbol-function 'avy-process)
               (lambda (candidates)
                 (setq processed candidates))))
      (liberime-regexp-avy-goto-char-timer)
      (should (equal builder-args '("ni" t)))
      (should (eq processed 'candidates)))))

(ert-deftest liberime-regexp-test-avy-mode-remaps-commands ()
  (unwind-protect
      (progn
        (liberime-regexp-avy-mode 1)
        (should (eq (command-remapping 'avy-goto-char)
                    #'liberime-regexp-avy-goto-char))
        (should (eq (command-remapping 'avy-goto-char-timer)
                    #'liberime-regexp-avy-goto-char-timer)))
    (liberime-regexp-avy-mode -1)))

(provide 'liberime-regexp-test)

;;; liberime-regexp-test.el ends here
