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

(provide 'module-boundaries-test)
;;; module-boundaries-test.el ends here
