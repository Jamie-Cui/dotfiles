;;; module-boundaries-test.el --- Module loading regressions -*- lexical-binding: t -*-
;;; Commentary:
;; Exercise real modules in fresh processes so earlier ERT package loads cannot
;; hide dependency or ordering mistakes.  The test runner supplies an isolated
;; HOME and offline ELPA; PDF installation is stubbed to avoid building epdfinfo.
;;; Code:

(require 'cl-lib)
(require 'ert)

(defconst module-boundaries-test--root
  (file-name-directory
   (directory-file-name (file-name-directory (or load-file-name buffer-file-name))))
  "Root of the Emacs configuration under test.")

(defun module-boundaries-test--run (&rest forms)
  "Evaluate FORMS in a fresh offline Emacs and include failures in ERT output."
  (let ((program (expand-file-name invocation-name invocation-directory)))
    (with-temp-buffer
      (let ((status
             (call-process
              program nil t nil "-Q" "--batch" "--eval"
              (prin1-to-string
               `(progn
                  (setq load-prefer-newer t
                        use-package-ensure-function #'ignore
                        use-package-expand-minimally t)
                  (require 'package)
                  (package-initialize)
                  (require 'use-package)
                  (require 'ert)
                  (require 'cl-lib)
                  (defvar +emacs/repo-directory ,module-boundaries-test--root)
                  (dolist (dir '("lisp" "lisp/core" "site-lisp"))
                    (add-to-list 'load-path
                                 (expand-file-name dir +emacs/repo-directory)))
                  (defun module-boundaries-test--load (name)
                    (load (expand-file-name
                           (concat "lisp/modules/" name ".el")
                           +emacs/repo-directory)
                          nil t t))
                  ,@forms)))))
        (ert-info ((buffer-string))
          (should (equal status 0)))))))

(ert-deftest module-boundaries-language-overrides-run-after-generic-rules ()
  (module-boundaries-test--run
   '(progn
      ;; Load language modules first to prove that hook depth, not registration
      ;; order, determines which associations win.
      (setq after-init-hook nil)
      (module-boundaries-test--load "lang/c-cpp")
      (module-boundaries-test--load "lang/cmake")
      (module-boundaries-test--load "lang/rust")
      (module-boundaries-test--load "prog")
      (let ((after-init-hook
             (cl-remove-if-not
              (lambda (fn)
                (memq fn '(+prog/treesit-auto-setup-h
                           +lang-c-cpp/auto-mode-setup-h
                           +lang-cmake/auto-mode-setup-h)))
              after-init-hook)))
        (should (= (length after-init-hook) 3))
        (run-hooks 'after-init-hook))
      (should (featurep 'treesit-auto))
      (dolist (file '("test.h" "test.hpp" "test.cc" "test.cpp"))
        (should (eq (assoc-default file auto-mode-alist #'string-match)
                    'c++-ts-mode)))
      (should (eq (assoc-default "CMakeLists.txt" auto-mode-alist
                                #'string-match)
                  'cmake-ts-mode))
      (with-temp-buffer
        (run-hooks 'c++-mode-hook)
        (should (equal flycheck-clang-language-standard "c++20"))
        (should (equal flycheck-cppcheck-standards '("c++20"))))
      (should gdb-show-main)
      (should (member '(warning . c/c++-googlelint)
                      (flycheck-checker-get 'eglot-check 'next-checkers)))
      (should (memq #'flycheck-rust-setup flycheck-mode-hook))
      (dolist (rule '(rustic-error rustic-warning rustic-info rustic-panic))
        (should (memq rule compilation-error-regexp-alist))
        (should (assoc rule compilation-error-regexp-alist-alist)))
      (should (string-match (car +prog/rust-compilation-error)
                            "error[E0308]: mismatched types\n --> src/main.rs:3:7"))
      (should (equal (match-string 1
                                  "error[E0308]: mismatched types\n --> src/main.rs:3:7")
                     "src/main.rs")))))

(ert-deftest module-boundaries-text-and-python-defer-eglot-policy ()
  (module-boundaries-test--run
   '(progn
      (module-boundaries-test--load "editor")
      (module-boundaries-test--load "lang/python")
      (should-not (featurep 'eglot))
      (require 'eglot)
      (should (equal (cdr (assoc '(python-mode python-ts-mode)
                                eglot-server-programs))
                     '("uvx" "--from" "pyright" "pyright-langserver" "--stdio")))
      (should (equal (cdr (assq 'text-mode eglot-server-programs))
                     '("harper-ls" "--stdio")))
      (should (equal (plist-get (plist-get
                                (default-value 'eglot-workspace-configuration)
                                :harper-ls)
                               :dialect)
                     "American")))))

(ert-deftest module-boundaries-pdf-does-not-load-tex-or-overleaf ()
  (module-boundaries-test--run
   '(progn
      (require 'general)
      (require 'evil)
      (require 'pdf-tools)
      (require 'ultra-scroll)
      (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
                ((symbol-function 'pdf-tools-install) #'ignore))
        (module-boundaries-test--load "pdf")
        (module-boundaries-test--load "pdf"))
      (should-not (featurep 'tex))
      (should-not (featurep 'git-overleaf))
      (should-not (boundp 'TeX-view-program-selection))
      (should (= (cl-count #'+latex/roll-setup pdf-view-mode-hook) 1))
      (should (equal (+latex/roll-prefetch-candidates 1 5) '(2 3)))
      (should (equal (+latex/roll-prefetch-candidates 5 5) '(4 3)))
      (should (advice-member-p #'+latex/roll-ultra-scroll-a 'ultra-scroll))
      (require 'pdf-roll)
      (should (advice-member-p #'+latex/roll-pre-redisplay-a
                               'pdf-roll-pre-redisplay))
      (should-not (advice-member-p #'+latex/roll-ultra-scroll-a
                                   'pdf-roll-pre-redisplay))
      (let ((calls 0))
        (cl-letf (((symbol-function 'pdf-roll-scroll-forward)
                   (lambda (pixels window relative)
                     (should (= pixels 12))
                     (should (window-live-p window))
                     (should relative)
                     (cl-incf calls)))
                  ((symbol-function '+latex/roll-prefetch-nearby) #'ignore))
          (+latex/roll-scroll-by-pixels -12 (selected-window)))
        (should (= calls 1))))))

(defun module-boundaries-test--synctex-order (pdf-first)
  "Check SyncTeX registration, loading the PDF module first if PDF-FIRST."
  (module-boundaries-test--run
   `(progn
      (require 'general)
      (require 'evil)
      (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t)))
        (if ,pdf-first
            (progn
              (require 'pdf-tools)
              (cl-letf (((symbol-function 'pdf-tools-install) #'ignore))
                (module-boundaries-test--load "pdf"))
              (should-not (featurep 'tex))
              (module-boundaries-test--load "lang/latex"))
          (module-boundaries-test--load "lang/latex")
          (require 'tex)
          (should-not (featurep 'pdf-tools))
          (should-not (equal TeX-view-program-list
                             '(("PDF Tools" +latex/pdf-tools-sync-view))))
          (require 'pdf-tools)
          (cl-letf (((symbol-function 'pdf-tools-install) #'ignore))
            (module-boundaries-test--load "pdf")))
        (require 'tex)
        (module-boundaries-test--load "lang/latex"))
      (should (equal TeX-view-program-selection '((output-pdf "PDF Tools"))))
      (should (equal TeX-view-program-list
                     '(("PDF Tools" +latex/pdf-tools-sync-view))))
      (should TeX-source-correlate-start-server)
      (should TeX-PDF-mode)
      (should (null pdf-sync-forward-display-action))
      (should (eq pdf-sync-backward-search-method 'generic))
      (should (= (cl-count #'TeX-source-correlate-mode LaTeX-mode-hook) 1))
      (should (= (cl-count #'TeX-revert-document-buffer
                           TeX-after-compilation-finished-functions) 1))
      (should (commandp '+latex/isolate-sentence))
      (should-not (featurep 'git-overleaf)))))

(ert-deftest module-boundaries-synctex-pdf-first ()
  (module-boundaries-test--synctex-order t))

(ert-deftest module-boundaries-synctex-tex-first ()
  (module-boundaries-test--synctex-order nil))

(ert-deftest module-boundaries-overleaf-works-without-latex-in-terminal ()
  (module-boundaries-test--run
   '(progn
      (should-not (display-graphic-p))
      (require 'init-config-evil)
      (module-boundaries-test--load "vc")
      (module-boundaries-test--load "pdf")
      (module-boundaries-test--load "lang/latex")
      (should (featurep 'git-overleaf))
      (should (featurep 'git-overleaf-magit))
      (should-not (featurep 'pdf-tools))
      (should-not (featurep 'tex))
      (should-not (featurep 'init-config-xenops)))))

(ert-deftest module-boundaries-pdf-skips-installation-on-windows ()
  (module-boundaries-test--run
   '(progn
      (require 'pdf-macs)
      (let ((system-type 'windows-nt))
        (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
                  ((symbol-function 'pdf-tools-install)
                   (lambda (&rest _) (ert-fail "Installed PDF Tools on Windows"))))
          (module-boundaries-test--load "pdf")))
      (should-not (featurep 'pdf-tools)))))

(ert-deftest module-boundaries-password-input-survives-empty-reader-maps ()
  (module-boundaries-test--run
   '(progn
      (require 'ert-x)
      (require 'core-startup)
      (let* ((original-map (current-global-map))
             (empty-map (make-sparse-keymap))
             (overriding-local-map empty-map)
             (overriding-terminal-local-map empty-map)
             (inhibit-quit t))
        (unwind-protect
            (progn
              ;; Reproduce read-key's maps and a timer's inhibited quitting.
              (use-global-map empty-map)
              (should (equal (ert-simulate-keys (kbd "test RET")
                               (read-passwd "Test input: "))
                             "test"))
              (should (eq (current-global-map) empty-map))
              (should (eq overriding-local-map empty-map))
              (should (eq overriding-terminal-local-map empty-map))
              (should inhibit-quit)
              (should
               (eq (condition-case nil
                       (ert-simulate-keys (kbd "C-g")
                         (read-passwd "Test cancellation: "))
                     (quit :cancelled))
                   :cancelled))
              (should (zerop (minibuffer-depth)))
              (should (eq (current-global-map) empty-map))
              (should (eq overriding-local-map empty-map))
              (should (eq overriding-terminal-local-map empty-map)))
          (use-global-map original-map))))))

(ert-deftest module-boundaries-password-error-restores-reader-maps ()
  (module-boundaries-test--run
   '(progn
      (require 'core-startup)
      (let* ((original-map (current-global-map))
             (empty-map (make-sparse-keymap))
             (overriding-local-map empty-map)
             (overriding-terminal-local-map empty-map)
             (inhibit-quit t))
        (unwind-protect
            (progn
              (use-global-map empty-map)
              (should-error
               (+emacs/read-passwd-with-input-maps-a
                (lambda (&rest _) (error "Test reader failure")) "Test: "))
              (should (eq (current-global-map) empty-map))
              (should (eq overriding-local-map empty-map))
              (should (eq overriding-terminal-local-map empty-map))
              (should inhibit-quit))
          (use-global-map original-map))))))

(ert-deftest module-boundaries-password-timer-cancellation-stops-gpg-process ()
  (module-boundaries-test--run
   '(progn
      (require 'ert-x)
      (require 'core-startup)
      (let* ((original-map (current-global-map))
             (context (epg-make-context))
             (epg-key-id "test-key")
             ;; A pipe suffices to exercise EasyPG's process cancellation.
             (process (make-pipe-process :name "password-test" :noquery t))
             (timer
              (run-at-time
               3600 nil
               (lambda ()
                 (ert-simulate-keys (kbd "C-g")
                   (epg--status-GET_HIDDEN context "passphrase.enter"))))))
        (unwind-protect
            (progn
              (setf (epg-context-process context) process
                    (epg-context-passphrase-callback context)
                    (cons (lambda (&rest _) (read-passwd "Test GPG: ")) nil))
              ;; Dispatch the real timer handler inside read-key's map scope.
              (cl-letf (((symbol-function 'read-key-sequence-vector)
                         (lambda (&rest _)
                           (should-not (eq (current-global-map) original-map))
                           (timer-event-handler timer)
                           [?x])))
                (should (eq (read-key) ?x)))
              (should (memq 'quit
                            (mapcar #'car (epg-context-result-for context 'error))))
              (should-not (process-live-p process))
              (should (zerop (minibuffer-depth)))
              (should (eq (current-global-map) original-map)))
          (cancel-timer timer)
          (when (process-live-p process) (delete-process process)))))))

(provide 'module-boundaries-test)
;;; module-boundaries-test.el ends here
