;;; init-config-xenops-test.el --- Tests for Xenops configuration -*- lexical-binding: t; -*-

;;; Commentary:

;; Focused regression tests for Xenops source fontification, scale refresh,
;; and async lifecycle state.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'init-config-xenops)

(ert-deftest init-config-xenops-keeps-src-delimiter-newline-unfontified ()
  (with-temp-buffer
    (insert "#+begin_src bash\n"
            "npm config set prefix \"$HOME/.local\"\n"
            "#+end_src\n")
    (org-mode)
    (goto-char (point-min))
    (search-forward "bash")
    (let ((delimiter-newline (point))
          (contents-end (progn
                          (search-forward "#+end_src")
                          (line-beginning-position))))
      (remove-text-properties
       (point-min) (point-max) '(syntax-table nil))
      (org-src-font-lock-fontify-block
       "bash" delimiter-newline contents-end)
      (should-not
       (get-text-property delimiter-newline 'syntax-table))
      (org-element-cache-reset)
      (goto-char (point-min))
      (should
       (equal "bash"
              (org-element-property :language
                                    (org-element-at-point)))))))

(ert-deftest init-config-xenops-normalizes-corrupt-idle-semaphore ()
  (let ((xenops-math-latex-max-tasks-in-flight 2))
    (with-temp-buffer
      (setq-local xenops-math-latex-tasks-semaphore (aio-sem 2))
      (setf (aio-sem-value xenops-math-latex-tasks-semaphore) 4)
      (should (fn/xenops-math-render-queue-idle-p))
      (fn/xenops-math-normalize-idle-semaphore)
      (should (= (aio-sem-value xenops-math-latex-tasks-semaphore) 2))
      (should (null (car (aio-sem-queue
                          xenops-math-latex-tasks-semaphore)))))))

(ert-deftest init-config-xenops-does-not-refresh-a-busy-queue ()
  (let ((xenops-math-latex-max-tasks-in-flight 2)
        scheduled
        rendered)
    (with-temp-buffer
      (setq-local xenops-mode t)
      (setq-local fn/xenops-math-refresh-pending t)
      (setq-local xenops-math-latex-tasks-semaphore (aio-sem 2))
      (aio-sem-wait xenops-math-latex-tasks-semaphore)
      (cl-letf (((symbol-function 'run-at-time)
                 (lambda (&rest _)
                   (setq scheduled t)
                   'test-timer))
                ((symbol-function 'fn/xenops-math-render-current-scale)
                 (lambda () (setq rendered t))))
        (fn/xenops-math-finish-scheduled-refresh
         (current-buffer)
         (fn/xenops-math-buffer-generation)))
      (should scheduled)
      (should-not rendered)
      (should fn/xenops-math-refresh-pending))))

(ert-deftest init-config-xenops-rejects-an-old-buffer-generation ()
  (with-temp-buffer
    (setq-local xenops-mode t)
    (let ((generation (fn/xenops-math-buffer-generation)))
      (should (fn/xenops-math-current-generation-p
               (current-buffer) generation))
      (fn/xenops-math-advance-buffer-generation)
      (should-not (fn/xenops-math-current-generation-p
                   (current-buffer) generation)))))

(ert-deftest init-config-xenops-posts-to-the-acquired-semaphore ()
  (let ((old-semaphore (aio-sem 1))
        (new-semaphore (aio-sem 1))
        displayed)
    (with-temp-buffer
      (setq-local xenops-mode t)
      (setq-local xenops-math-latex-tasks-semaphore old-semaphore)
      (cl-letf (((symbol-function 'xenops-math-set-marker-on-element)
                 #'ignore)
                ((symbol-function 'xenops-math-latex-process-get)
                 (lambda (key)
                   (pcase key
                     (:image-input-type "xdv")
                     (:image-output-type "svg")
                     (:image-output-ppi nil))))
                ((symbol-function 'xenops-math-latex-make-commands)
                 (lambda (&rest _) nil))
                ((symbol-function 'xenops-math-latex-make-latex-document)
                 (lambda (&rest _) ""))
                ((symbol-function 'copy-file) #'ignore)
                ((symbol-function 'xenops-math-parse-element-at)
                 (lambda (&rest _) '(:begin 1 :end 1)))
                ((symbol-function 'xenops-math-deactivate-marker-on-element)
                 #'ignore))
        (let ((promise
               (fn/xenops-math-latex-create-image-a
                '(:begin-marker marker)
                "x" '("0" "1") "/tmp/xenops-test.svg"
                (lambda (&rest _) (setq displayed t)))))
          ;; Simulate a major-mode restart installing a new buffer-local
          ;; semaphore while the old generation is still completing.
          (setq-local xenops-math-latex-tasks-semaphore new-semaphore)
          (aio-wait-for promise)))
      (should displayed)
      (should (= (aio-sem-value old-semaphore) 1))
      (should (= (aio-sem-value new-semaphore) 1)))))

(ert-deftest init-config-xenops-installs-async-lifecycle-override ()
  (should
   (advice-member-p #'fn/xenops-math-latex-create-image-a
                    'xenops-math-latex-create-image)))

(ert-deftest init-config-xenops-inline-parser-keeps-unexpected-errors-visible ()
  (with-temp-buffer
    (setq-local xenops-mode t)
    (insert "Text $x$ text")
    (goto-char (point-min))
    (should-not (fn/xenops-math-inline-editing-element))
    (search-forward "$x")
    (should (fn/xenops-math-inline-editing-element))
    (cl-letf (((symbol-function 'xenops-math-parse-inline-element-at-point)
               (lambda () (error "Unexpected parser failure"))))
      (should-error (fn/xenops-math-inline-editing-element)))))

(ert-deftest init-config-xenops-disable-cleans-up-outside-narrowing ()
  (with-temp-buffer
    (insert "math\ntext\n")
    (let ((math (make-overlay 1 5))
          (other (make-overlay 6 10))
          (timer (run-at-time 60 nil #'ignore))
          (generation (fn/xenops-math-buffer-generation))
          restored)
      (unwind-protect
          (progn
            (overlay-put math 'xenops-overlay-type 'xenops-math-waiting)
            (narrow-to-region 6 10)
            (should (fn/xenops-math-buffer-has-overlays-p))
            (should (fn/xenops-math-buffer-has-overlays-p 'xenops-math-waiting))
            (should-not (fn/xenops-math-buffer-has-overlays-p 'xenops-overlay))
            (setq-local xenops-mode nil
                        fn/xenops-math-refresh-pending t
                        fn/xenops-math-refresh-timer timer
                        fn/xenops-math-smartparens-suspended t)
            (cl-letf (((symbol-function 'smartparens-mode)
                       (lambda (arg) (setq restored arg))))
              (fn/xenops-math-mode-state-h))
            (should (= restored 1))
            (should-not fn/xenops-math-smartparens-suspended)
            (should-not fn/xenops-math-refresh-pending)
            (should-not fn/xenops-math-refresh-timer)
            (should-not (memq timer timer-list))
            (should (> (fn/xenops-math-buffer-generation) generation))
            (should-not (overlay-buffer math))
            (should (overlay-buffer other))
            (should (= (point-min) 6)))
        (cancel-timer timer)))))

(ert-deftest init-config-xenops-svg-baseline-tolerates-missing-metadata ()
  (skip-unless (fboundp 'libxml-parse-xml-region))
  (let ((file (make-temp-file "xenops-baseline-" nil ".svg")))
    (unwind-protect
        (dolist (case '(("<g id='page1' transform='matrix(1 0 0 2 0 0)'><desc id='xenops-baseline' data-x='0' data-y='7.5'/></g>" . 75)
                        ("<desc id='xenops-baseline' data-x='0'/>" . nil)
                        ("" . nil)))
          (with-temp-file file
            (insert "<svg viewBox='0 0 10 20'>" (car case) "</svg>"))
          (should (equal (fn/xenops-math-svg-baseline-ascent file) (cdr case))))
      (delete-file file))))

(provide 'init-config-xenops-test)
;;; init-config-xenops-test.el ends here
