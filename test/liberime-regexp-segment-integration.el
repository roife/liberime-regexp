;;; liberime-regexp-segment-integration.el --- Real Rime tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'liberime-regexp)
(module-load (getenv "LIBERIME_TEST_MODULE"))
(liberime-start (getenv "LIBERIME_TEST_HOME") (getenv "LIBERIME_TEST_HOME"))
;; This runner starts the module explicitly and never loads user init files.
(fset 'liberime-regexp-load-liberime #'ignore)

(ert-deftest liberime-segment-integration-words-and-canonical-codes ()
  (should (equal (liberime-regexp-split-string "研究生命" "full") '("研究" "生命")))
  (should (equal (liberime-regexp-split-string "研究生命" "double") '("研究" "生命")))
  (should (equal (liberime-regexp-split-string "重庆形码词龘" "double") '("重庆" "形码词" "龘")))
  (should (equal (liberime-regexp-split-string "研究词典" "double") '("研究" "词典")))
  (should (equal (liberime-regexp-segment "a𠀀研究！" "full") '((0 . 1) (1 . 3) (3 . 4)))))

(ert-deftest liberime-segment-integration-rejects-sentences ()
  (liberime-regexp--segment-ensure-session)
  (let ((edges (liberime-regexp--segment-request "研究生命" "full" '(8 64 128))))
    (should (cl-find-if (lambda (edge) (equal (cl-subseq edge 0 2) [0 2])) edges))
    (should-not (cl-find-if (lambda (edge) (equal (cl-subseq edge 0 2) [0 4])) edges))))

(ert-deftest liberime-segment-integration-session-isolation-and-recovery ()
  (liberime-select-schema "double")
  (liberime-simulate-key-sequence "yj")
  (let ((input (liberime-get-input)) (status (liberime-get-status)))
    (liberime-regexp-split-string "研究生命")
    (should (equal input (liberime-get-input)))
    (should (equal status (liberime-get-status)))
    (let ((session liberime-regexp--segment-session))
      (liberime-session-destroy session)
      ;; Cache hits never touch the session; force a query to test recovery.
      (liberime-regexp-clear-cache)
      (should (equal (liberime-regexp-split-string "研究生命") '("研究" "生命")))
      (should (liberime-get-status liberime-regexp--segment-session)))
    (should (equal input (liberime-get-input)))
    (should (equal status (liberime-get-status)))))

(ert-deftest liberime-segment-integration-missing-configuration ()
  (should-error (liberime-regexp-segment "研究" "missing") :type 'user-error)
  (should-error (liberime-regexp-segment "研究" "unmapped") :type 'user-error))

(ert-deftest liberime-segment-integration-long-text-and-restart ()
  (let* ((text (concat (make-string 63 ?龘) "研究生命"))
         (ranges (liberime-regexp-segment text "full")))
    (should (equal (last ranges 2) '((63 . 65) (65 . 67)))))
  (liberime-finalize)
  (liberime-start (getenv "LIBERIME_TEST_HOME") (getenv "LIBERIME_TEST_HOME"))
  (run-hooks 'liberime-after-start-hook)
  (should (equal (liberime-regexp-split-string "研究生命" "full") '("研究" "生命"))))

(unwind-protect
    (ert-run-tests-batch-and-exit)
  (liberime-finalize))
