;;; c-cpp.el --- C and C++ configuration -*- lexical-binding: t -*-
;;; Commentary:
;; C/C++ checkers, sibling navigation, GDB and tree-sitter associations.
;; Keep the existing +prog/ command names for callers and personal bindings.
;;; Code:

(defun +prog/flycheck-c++20-h ()
  "Use C++20 for Flycheck's standalone C++ checkers."
  (setq-local flycheck-clang-language-standard "c++20"
              flycheck-cppcheck-standards '("c++20")))

(with-eval-after-load 'flycheck
  (add-hook 'c++-mode-hook #'+prog/flycheck-c++20-h)
  (add-hook 'c++-ts-mode-hook #'+prog/flycheck-c++20-h))

;; sibling files (for c/c++)
(add-to-list 'find-sibling-rules
             '("/\\([^/]+\\)\\.c\\(c\\|pp\\)?\\'" "\\1.h\\(h\\|pp\\)?\\'"))
(add-to-list 'find-sibling-rules
             '("/\\([^/]+\\)\\.h\\(h\\|pp\\)?\\'" "\\1.c\\(c\\|pp\\)?\\'"))

(setopt gdb-show-main t)

;;; -----------------------------------------------------------
;;; flycheck-google-cpplint
;;; -----------------------------------------------------------

(use-package flycheck-google-cpplint
  :ensure t
  :after flycheck-eglot
  :custom
  (flycheck-c/c++-googlelint-executable "cpplint")
  (flycheck-googlelint-verbose "0")
  (flycheck-googlelint-linelength "80")
  (flycheck-googlelint-filter
   (concat
    "-whitespace,"
    "-whitespace/braces,"
    "-whitespace/indent,"
    "-build/include_order,"
    "-build/header_guard,"
    "-runtime/reference,"
    ))
  :config
  (flycheck-add-next-checker 'eglot-check
                             '(warning . c/c++-googlelint))
  )

(defun +lang-c-cpp/auto-mode-setup-h ()
  "Apply C/C++ associations after the generic tree-sitter associations."
  (dolist (mode '(c++-mode c-mode c-or-c++-mode))
    (setq auto-mode-alist (rassq-delete-all mode auto-mode-alist)))
  (add-to-list 'auto-mode-alist '("\\.h\\'" . c++-ts-mode))
  (add-to-list 'auto-mode-alist '("\\.hpp\\'" . c++-ts-mode))
  (add-to-list 'auto-mode-alist '("\\.cc\\'" . c++-ts-mode))
  (add-to-list 'auto-mode-alist '("\\.cpp\\'" . c++-ts-mode)))

;; Generic treesit-auto registration runs at the default depth of zero.
(add-hook 'after-init-hook #'+lang-c-cpp/auto-mode-setup-h 90)

(provide 'init-lang-c-cpp)
;;; c-cpp.el ends here
