;;; rust.el --- Rust diagnostics -*- lexical-binding: t -*-
;;; Commentary:
;; Rust compilation links and Flycheck integration.  Existing +prog/ names
;; are retained so callers do not need to change with this module move.
;;; Code:

(require 'compile)

;; rust, see: https://github.com/brotzeit/rustic/blob/1f4d6a315824487c88b5e1f6c0ad8a984def2c3d/rustic-compile.el
(defvar +prog/rust-compilation-error
  (let ((err "^error[^:]*:[^\n]*\n\s*-->\s")
        (file "\\([^\n]+\\)")
        (start-line "\\([0-9]+\\)")
        (start-col  "\\([0-9]+\\)"))
    (let ((re (concat err file ":" start-line ":" start-col)))
      (cons re '(1 2 3))))
  "Create hyperlink in compilation buffers for rust errors.")

(defvar +prog/rust-compilation-warning
  (let ((warning "^warning:[^\n]*\n\s*-->\s")
        (file "\\([^\n]+\\)")
        (start-line "\\([0-9]+\\)")
        (start-col  "\\([0-9]+\\)"))
    (let ((re (concat warning file ":" start-line ":" start-col)))
      (cons re '(1 2 3 1)))) ;; 1 for warning
  "Create hyperlink in compilation buffers for rust warnings.")

(defvar +prog/rust-compilation-info
  (let ((file "\\([^\n]+\\)")
        (start-line "\\([0-9]+\\)")
        (start-col  "\\([0-9]+\\)"))
    (let ((re (concat "^ *::: " file ":" start-line ":" start-col)))
      (cons re '(1 2 3 0)))) ;; 0 for info type
  "Create hyperlink in compilation buffers for file paths preceded by ':::'.")

(defvar +prog/rust-compilation-panic
  (let ((panic "thread '[^']+' panicked at '[^']+', ")
        (file "\\([^\n]+\\)")
        (start-line "\\([0-9]+\\)")
        (start-col  "\\([0-9]+\\)"))
    (let ((re (concat panic file ":" start-line ":" start-col)))
      (cons re '(1 2 3))))
  "Match thread panics.")

(add-to-list 'compilation-error-regexp-alist-alist
             (cons 'rustic-error +prog/rust-compilation-error))
(add-to-list 'compilation-error-regexp-alist-alist
             (cons 'rustic-warning +prog/rust-compilation-warning))
(add-to-list 'compilation-error-regexp-alist-alist
             (cons 'rustic-info +prog/rust-compilation-info))
(add-to-list 'compilation-error-regexp-alist-alist
             (cons 'rustic-panic +prog/rust-compilation-panic))

(add-to-list 'compilation-error-regexp-alist 'rustic-error)
(add-to-list 'compilation-error-regexp-alist 'rustic-warning)
(add-to-list 'compilation-error-regexp-alist 'rustic-info)
(add-to-list 'compilation-error-regexp-alist 'rustic-panic)

(use-package flycheck-rust
  :ensure t
  :config
  (add-hook 'flycheck-mode-hook #'flycheck-rust-setup))

(provide 'init-lang-rust)
;;; rust.el ends here
