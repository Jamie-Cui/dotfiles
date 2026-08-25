;;; init-config-eshell.el --- Eshell configuration -*- lexical-binding: t -*-
;;; Commentary:
;;; Code:

(require 'subr-x)

(defun +shell/zsh ()
  "Call /bin/zsh in shell mode"
  (interactive)
  (let ((explicit-shell-file-name "/bin/zsh") )
    (shell)))

(defun +shell/bash ()
  "Call /bin/bash in shell mode"
  (interactive)
  (let ((explicit-shell-file-name "/bin/bash") )
    (shell)))

(defun +shell/sh ()
  "Call /bin/sh in shell mode"
  (interactive)
  (let ((explicit-shell-file-name "/bin/sh") )
    (shell)))

;; Treat these commands as visual (run in a term buffer, not plain Eshell).
(with-eval-after-load 'em-term
  ;; Full-command visual overrides.
  (add-to-list 'eshell-visual-commands "dnf")
  (add-to-list 'eshell-visual-commands "brew")
  (add-to-list 'eshell-visual-commands "cmake")
  (add-to-list 'eshell-visual-commands "ninja")
  (add-to-list 'eshell-visual-commands "nmap")
  ;; Subcommand-level override: "sudo dnf" should use a term buffer too.
  (add-to-list 'eshell-visual-subcommands '("sudo" "dnf")))

(setopt eshell-scroll-show-maximum-output nil
        eshell-highlight-prompt nil
        eshell-destroy-buffer-when-process-dies t)

(setopt eshell-scroll-to-bottom-on-input 'all
        eshell-scroll-to-bottom-on-output 'all
        eshell-kill-processes-on-exit t
        eshell-hist-ignoredups t
        eshell-input-filter (lambda (input) (not (string-match-p "\\`\\s-+" input)))
        eshell-glob-case-insensitive t
        eshell-error-if-no-glob t)

(setopt eshell-prompt-function
        (lambda nil
          (let* ((cwd (abbreviate-file-name (eshell/pwd))))
            (concat (propertize
                     ;; the above line
                     (format "%s [%s]"
                             (propertize (user-login-name) 'font-lock-face 'font-lock-comment-face)
                             (propertize cwd 'font-lock-face 'font-lock-constant-face)
                             )
                     'read-only t
                     'front-sticky   '(font-lock-face read-only)
                     'rear-nonsticky '(font-lock-face read-only))
                    ;; input line
                    " $ "
                    ))))

(setopt eshell-banner-message
        '(format "%s %s\n"
                 (propertize (format " %s " (string-trim (buffer-name)))
                             'face 'mode-line-highlight)
                 (propertize (current-time-string)
                             'face 'font-lock-keyword-face)))

;; always get a new eshell
(defun +eshell/new ()
  (interactive)
  (let ((current-prefix-arg ""))
    (call-interactively 'eshell)))

(defun eshell/set-proxy ()
  "Enable the configured proxy throughout the Emacs session."
  (interactive)
  (+emacs/set-proxy)
  (eshell/show-proxy))

(defun eshell/unset-proxy ()
  "Disable the proxy throughout the Emacs session."
  (interactive)
  (+emacs/unset-proxy)
  (eshell/show-proxy))

(defun eshell/show-proxy ()
  "Display current proxy settings."
  (interactive)
  (eshell-printn (format "[url] http_proxy  : %s"
                         (alist-get "http" url-proxy-services nil nil
                                    #'string=)))
  (eshell-printn (format "[url] https_proxy : %s"
                         (alist-get "https" url-proxy-services nil nil
                                    #'string=)))
  (eshell-printn (format "[env] http_proxy  : %s" (getenv "http_proxy")))
  (eshell-printn (format "[env] https_proxy : %s" (getenv "https_proxy")))
  (eshell-printn (format "[env] all_proxy   : %s" (getenv "all_proxy"))))

;; HACK redefine eshell/clear function using advice
(defun +eshell/clear-buffer-a (&rest _)
  "Clear the eshell buffer by erasing its contents."
  (let ((inhibit-read-only t))
    (erase-buffer)))
(advice-add 'eshell/clear :override #'+eshell/clear-buffer-a)

(provide 'init-config-eshell)
;;; init-config-eshell.el ends here
