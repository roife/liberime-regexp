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

(ert-deftest liberime-regexp-test-query-prefers-isolated-session ()
  (let ((liberime-regexp--candidate-cache (make-hash-table :test #'equal))
        default-called)
    (cl-letf (((symbol-function 'liberime-regexp-load-liberime) #'ignore)
              ((symbol-function 'liberime-get-status)
               (lambda (&optional _) '((schema_id . "test"))))
              ((symbol-function 'liberime-get-input) (lambda () nil))
              ((symbol-function 'liberime-regexp--isolated-session-query)
               (lambda (_code _status)
                 '(:full ("隔离") :prefix nil :remaining-input "geli")))
              ((symbol-function 'liberime-regexp--default-session-query)
               (lambda (_code) (setq default-called t))))
      (should (equal (plist-get (liberime-regexp--query-code "geli") :full)
                     '("隔离")))
      (should-not default-called))))

(ert-deftest liberime-regexp-test-native-query-stays-in-regexp-module ()
  (let (native-args liberime-search-called)
    (cl-letf (((symbol-function 'liberime-regexp--ensure-search-session)
               (lambda (_status) 42))
              ((symbol-function 'liberime-regexp--try-load-native-module)
               (lambda () t))
              ((symbol-function 'liberime-regexp--native-query)
               (lambda (&rest args)
                 (setq native-args args)
                 '(:commit nil :full ("你") :prefix nil :remainder nil
                   :remaining-input "ni" :regexp-code nil :regexp nil)))
              ((symbol-function 'liberime-search)
               (lambda (&rest _)
                 (setq liberime-search-called t))))
      (should
       (equal (liberime-regexp--isolated-session-query
               "ni" '((schema_id . "test")))
              '(:commit nil :full ("你") :prefix nil :remainder nil
                :remaining-input "ni" :regexp-code nil :regexp nil)))
      (should-not liberime-search-called)
      (should (equal native-args '(42 "ni" 100))))))

(ert-deftest liberime-regexp-test-preserves-regexp-composition ()
  (cl-letf (((symbol-function 'liberime-regexp--code-regexp)
             (lambda (code)
               (pcase code
                 ("ni" "\\(?:ni\\|你\\)")
                 ("hao" "\\(?:hao\\|好\\)")
                 (_ (regexp-quote code))))))
    (let ((regexp
           (liberime-regexp-build-regexp-string "^ni.*hao$")))
      (should (string-match-p regexp "你很好"))
      (should-not (string-match-p regexp "甲你很好乙")))
    ;; Ordinary isearch quotes regexp punctuation while still expanding codes.
    (let ((literal
           (liberime-regexp-build-regexp-string "ni.*" t)))
      (should (string-match-p (concat "\\`" literal "\\'") "你.*"))
      (should-not (string-match-p (concat "\\`" literal "\\'")
                                  "你abc")))))

(ert-deftest liberime-regexp-test-filter-args-preserves-call-shape ()
  (cl-letf (((symbol-function 'liberime-regexp-build-regexp-string)
             (lambda (regexp &optional _) (concat "expanded:" regexp))))
    (should (equal (liberime-regexp-filter-args
                    '("^ni$" secondary :option value))
                   '("expanded:^ni$" secondary :option value)))))

(ert-deftest liberime-regexp-test-orderless-and-evil-advices-compose ()
  (dolist (function '(orderless-regexp evil-ex-search-full-pattern))
    (let ((old-definition (and (fboundp function)
                               (symbol-function function))))
      (unwind-protect
          (progn
            (fset function (lambda (&rest args) args))
            (cl-letf (((symbol-function
                        'liberime-regexp-build-regexp-string)
                       (lambda (regexp &optional _)
                         (concat "expanded:" regexp))))
              (liberime-regexp--update-advices t)
              (should (equal (funcall function "^ni$" 'keep)
                             '("expanded:^ni$" keep)))
              (liberime-regexp--update-advices nil)))
        (when (advice-member-p #'liberime-regexp-filter-args function)
          (advice-remove function #'liberime-regexp-filter-args))
        (if old-definition
            (fset function old-definition)
          (fmakunbound function))))))

(ert-deftest liberime-regexp-test-isearch-search-function-composes ()
  (cl-letf (((symbol-function 'liberime-regexp--code-regexp)
             (lambda (code)
               (if (string= code "ni") "\\(?:ni\\|你\\)" code))))
    (with-temp-buffer
      (insert "甲你乙")
      (goto-char (point-min))
      (let ((isearch-forward t)
            (isearch-regexp t)
            (isearch-regexp-function nil)
            (liberime-regexp--saved-isearch-search-fun-function nil))
        (should (funcall (liberime-regexp--isearch-search-function)
                         "ni" nil t 1))
        (should (= (point) 3))))))

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

(ert-deftest liberime-regexp-test-pinyin-code-provider ()
  (let ((liberime-regexp--pinyin-character-cache nil))
    (should (member "ni'hao"
                    (liberime-regexp-segment-pinyin-codes "你好")))
    (should (member "yu'yan'chu'li"
                    (liberime-regexp-segment-pinyin-codes "語言處理")))))

(ert-deftest liberime-regexp-test-segments-mixed-text ()
  (cl-letf (((symbol-function 'liberime-regexp--segment-han-with-dictionary)
             (lambda (_text) '((0 . 2) (2 . 4) (4 . 7)))))
    (should (equal (liberime-regexp--segment-with-dictionary
                    "我爱北京天安门, Emacs42")
                   '((0 . 2) (2 . 4) (4 . 7) (9 . 16))))))

(ert-deftest liberime-regexp-test-word-motion-uses-rime-boundaries ()
  (cl-letf (((symbol-function 'liberime-regexp-segment)
             (lambda (_text) '((0 . 2) (2 . 4) (4 . 7)))))
    (with-temp-buffer
      (insert "，我爱北京天安门！hello")
      (goto-char (point-min))
      (should (liberime-regexp-forward-word 1))
      (should (= (point) 4))
      (should (liberime-regexp-forward-word 2))
      (should (= (point) 9))
      (should (liberime-regexp-backward-word 1))
      (should (= (point) 6))
      (should (liberime-regexp-backward-word 2))
      (should (= (point) 2)))))

(ert-deftest liberime-regexp-test-native-segmentation-boundaries ()
  (let ((liberime-regexp-segment-code-function
         (lambda (_word) '("yan'jiu'sheng'ming'qi'yuan")))
        (liberime-regexp--segment-cache (make-hash-table :test #'equal)))
    (cl-letf (((symbol-function 'liberime-regexp-load-liberime) #'ignore)
              ((symbol-function 'liberime-regexp-load-native-module) #'ignore)
              ((symbol-function 'liberime-get-status)
               (lambda () '((schema_id . "test"))))
              ((symbol-function 'liberime-regexp--native-segment-han)
               (lambda (&rest _)
                 [[0 2] [2 4] [4 6]])))
      (should (equal (liberime-regexp-split-string "研究生命起源")
                     '("研究" "生命" "起源"))))))

(ert-deftest liberime-regexp-test-segment-mode-remaps-word-commands ()
  (cl-letf (((symbol-function 'liberime-regexp-load-liberime) #'ignore))
    (unwind-protect
        (progn
          (liberime-regexp-segment-mode 1)
          (should (eq (command-remapping 'forward-word)
                      #'liberime-regexp-forward-word))
          (should (eq (command-remapping 'backward-kill-word)
                      #'liberime-regexp-backward-kill-word)))
      (liberime-regexp-segment-mode -1))))

(provide 'liberime-regexp-test)

;;; liberime-regexp-test.el ends here
