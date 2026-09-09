;;; prog.el --- general programming support -*- lexical-binding: t -*-
;;; Commentary:
;; General programming support: eglot, flycheck, citre, apheleia, treesit and
;; compilation configuration.
;;; Code:


(use-package citre
  :ensure t
  :after (eglot projectile)
  :init
  ;; This is needed in `:init' block for lazy load to work.
  ;; (require 'citre-config)
  :custom
  ;; (citre-project-root-function #'projectile-project-root)
  (citre-default-create-tags-file-location 'global-cache)
  (citre-edit-ctags-options-manually nil)
  (citre-auto-enable-citre-mode-modes '(prog-mode))
  ;; citre makes imenu messy, i dont like it
  (citre-enable-imenu-integration nil)
  :config
  ;; gd will also triger citre-jump (with last priority, so its append)
  (setq evil-goto-definition-functions (append evil-goto-definition-functions
                                               '((lambda (symbol &rest _) (citre-jump)))))
  ;; HACK only enable citre-auto-enable-citre-mode when not on tramp
  (add-hook 'find-file-hook
            (lambda ()
              (unless (file-remote-p default-directory)
                (citre-auto-enable-citre-mode))))
  )

(use-package flycheck
  :ensure t
  :preface
  (defun +prog/flycheck-skip-remote-revert-h ()
    "Skip Flycheck's automatic post-revert check in remote buffers."
    (when (file-remote-p default-directory)
      (remove-hook 'after-revert-hook #'flycheck-handle-revert t)))

  :config
  (add-hook 'after-init-hook #'global-flycheck-mode)
  (add-hook 'flycheck-mode-hook #'+prog/flycheck-skip-remote-revert-h)
  ;; Flycheck registers its built-in `flycheck-eldoc-function' buffer-locally.
  ;; It composes Eglot and chained-checker diagnostics in the same Eldoc view.

  :custom
  (flycheck-disabled-checkers '(emacs-lisp-checkdoc))
  ;; flycheck has performace issues, make it less automate
  (flycheck-check-syntax-automatically '(save mode-enabled idle-change))
  (flycheck-idle-change-delay 4))

(use-package flycheck-eglot
  :ensure t
  :after (flycheck eglot)
  :custom
  (flycheck-eglot-exclusive nil)
  :config
  (global-flycheck-eglot-mode 1))

(use-package consult-eglot
  :ensure t)

(use-package consult-eglot-embark
  :ensure t
  :after embark
  :config
  (consult-eglot-embark-mode 1))

(use-package eglot
  :ensure t
  :config
  (setq eglot-ignored-server-capabilities '(:documentHighlightProvider ; no highlight
                                            :semanticTokensProvider))
  (setq eglot-watch-files-outside-project-root nil)
  (setq eglot-confirm-server-edits nil))

(use-package eldoc-box
  :ensure t
  :after eglot
  :if window-system ;; do not load eldoc-box on termial emacs
  :preface
  (declare-function eldoc-box--follow-cursor "eldoc-box" ())
  (declare-function eldoc-box--frame-visible-p "eldoc-box" ())
  (declare-function eldoc-box--update-childframe-geometry
                    "eldoc-box" (frame window))
  (declare-function eldoc-box-quit-frame "eldoc-box" ())

  (defun +prog/eldoc-box-follow-cursor-h ()
    "Hide stale docs while allowing new asynchronous docs to display."
    (if (memq this-command eldoc-box-self-insert-command-list)
        (when (eldoc-box--frame-visible-p)
          (eldoc-box--update-childframe-geometry
           eldoc-box--frame
           (frame-selected-window eldoc-box--frame)))
      (eldoc-box-quit-frame)))

  (defun +prog/eldoc-box-sync-h ()
    "Keep `eldoc-box-hover-at-point-mode' in sync with `eldoc-mode'."
    (cond
     ((and eldoc-mode (not eldoc-box-hover-at-point-mode))
      (eldoc-box-hover-at-point-mode 1))
     ((and (not eldoc-mode) eldoc-box-hover-at-point-mode)
      (eldoc-box-hover-at-point-mode -1)))
    (if eldoc-box-hover-at-point-mode
        (progn
          ;; The package's 0.5 second movement inhibition races with
          ;; `eldoc-idle-delay', which can leave a populated frame hidden.
          (remove-hook 'post-command-hook #'eldoc-box--follow-cursor t)
          (add-hook 'post-command-hook
                    #'+prog/eldoc-box-follow-cursor-h t t))
      (remove-hook 'post-command-hook
                   #'+prog/eldoc-box-follow-cursor-h t)))

  :config
  ;; `default-frame-alist' maximizes normal frames.  Child frames inherit
  ;; that parameter unless it is explicitly overridden, and a maximized
  ;; Eldoc frame cannot be resized to fit its contents.
  (add-to-list 'eldoc-box-frame-parameters '(fullscreen . nil))
  (add-hook 'eldoc-box-buffer-setup-hook
            (lambda (_orig-buffer)
              (setq-local cursor-type nil
                          cursor-in-non-selected-windows nil)))
  (add-hook 'eldoc-mode-hook #'+prog/eldoc-box-sync-h))

;; compilation mode
(setopt compilation-max-output-line-length nil) ; no max output, do not wrap
(setopt compilation-always-kill t)
(setopt ansi-color-for-compilation-mode t)
(setopt compilation-ask-about-save t)
(setopt compilation-scroll-output 'first-error)
;; NOTE always use current window for compilation
;; (add-to-list 'display-buffer-alist
;;              '("\\*compilation\\*"
;;                (display-buffer-reuse-window display-buffer-same-window)
;;                (reusable-frames . visible)
;;                (inhibit-switch-frames . nil)))

;; compile
(defun +prog/compile-with-no-preset ()
  "Prompt for a compile command, initially using the active region if any."
  (interactive)
  (let* ((compile-command (if (use-region-p) (buffer-substring-no-properties (region-beginning) (region-end)) "")))
    (call-interactively 'compile)))

(defun +prog/compile-with-comint ()
  "Prompt for a compile command and run it with Comint interaction."
  (interactive)
  (let* ((compile-command (if (use-region-p) (buffer-substring-no-properties (region-beginning) (region-end)) ""))
         (current-prefix-arg '(4)))
    (call-interactively 'compile)))

;; Use full tree-sitter fontification by default.
(setopt treesit-font-lock-level 4)

;;; -----------------------------------------------------------
;;; apheleia - Deferred Loading
;;; -----------------------------------------------------------

(use-package apheleia
  :ensure t
  :custom
  (apheleia-remote-algorithm 'local)
  :hook (after-init . (lambda () (apheleia-global-mode +1)))
  ;; NOTE use elgot-format
  ;; https://github.com/radian-software/apheleia/issues/153#issuecomment-1446651497
  ;; (cl-defun apheleia-indent-eglot-managed-buffer
  ;;     (&key buffer scratch callback &allow-other-keys)
  ;;   (with-current-buffer scratch
  ;;     (setq-local eglot--cached-server
  ;;                 (with-current-buffer buffer
  ;;                   (eglot-current-server)))
  ;;     (let ((buffer-file-name (buffer-local-value 'buffer-file-name buffer)))
  ;;       (eglot-format-buffer))
  ;;     (funcall callback)))

  ;; declare new formatters for eglot
  ;; (add-to-list 'apheleia-formatters
  ;;              '(eglot-managed . apheleia-indent-eglot-managed-buffer))

  ;; NOTE add all eglot-ensured modes
  ;; This determines what formatter to use in buffers without a
  ;; setting for apheleia-formatter. The keys are major mode
  ;; (add-to-list 'apheleia-mode-alist '(c++-ts-mode-hook . eglot-managed))
  ;; (add-to-list 'apheleia-mode-alist '(rust-ts-mode-hook . eglot-managed))
  ;; (add-to-list 'apheleia-mode-alist '(cmake-ts-mode . cmake-format))
  )

;;; -----------------------------------------------------------
;;; tree-sitter - Optimized for Emacs 30+
;;; -----------------------------------------------------------

;; Emacs 30+: Enable native compilation and use treesit-auto for better performance
(use-package treesit-auto
  :ensure t
  :custom
  (treesit-auto-install 'prompt)
  :preface
  (defun +prog/treesit-auto-setup-h ()
    "Register generic tree-sitter associations before language overrides."
    (require 'treesit-auto)
    (treesit-auto-add-to-auto-mode-alist 'all))
  :hook (after-init . +prog/treesit-auto-setup-h)
  :config
  ;; NOTE toggle mode automatically
  (defun +prog/treesit-auto-toggle ()
    "Toggle global-treesit-auto-mode."
    (interactive)
    (if global-treesit-auto-mode
        (progn
          (global-treesit-auto-mode -1)
          (message "global-treesit-auto-mode disabled"))
      (global-treesit-auto-mode 1)
      (message "global-treesit-auto-mode enabled"))))


(provide 'init-prog)
;;; prog.el ends here
