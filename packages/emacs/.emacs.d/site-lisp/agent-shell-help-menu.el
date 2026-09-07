;;; agent-shell-help-menu.el --- Extended help menu for Agent Shell -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jamie Cui
;; Author: Jamie Cui <jamie.cui@outlook.com>
;; Version: 0.1.0
;; URL: https://github.com/Jamie-Cui/dotfiles/tree/main/packages/emacs/.emacs.d/site-lisp
;; Keywords: convenience, tools, ai
;; Package-Requires: ((emacs "30.1") (agent-shell "0.60.2") (agent-shell-permission-transient "0.1.0") (evil "1.15.0") (transient "0.11.0"))

;;; Commentary:

;; Extend `agent-shell-help-menu' with common navigation, lifecycle, permission,
;; and shell-switching commands.  The menu is displayed below the selected
;; Agent Shell window, and Evil normal state opens it with `?'.

;;; Code:

(require 'agent-shell)
(require 'agent-shell-permission-transient)
(require 'evil)
(require 'transient)

(defun agent-shell-help-menu--display-buffer (buffer alist)
  "Display transient BUFFER below the selected window using ALIST."
  (let ((window (selected-window)))
    (display-buffer-in-direction
     buffer
     (append `((direction . below) (window . ,window)) alist))))

(defun agent-shell-help-menu--permissions-pending-p ()
  "Return non-nil when Agent Shell has a pending permission request."
  (> (agent-shell-permission-transient-pending-count) 0))

;;;###autoload
(defun agent-shell-help-menu-install ()
  "Install additions to `agent-shell-help-menu'."
  (interactive)
  (when-let* ((prefix (get 'agent-shell-help-menu 'transient--prefix)))
    (oset prefix display-action
          '(agent-shell-help-menu--display-buffer
            (dedicated . t)
            (inhibit-same-window . t))))
  (dolist (command '(agent-shell-ui-toggle-fragment
                     agent-shell-ui-toggle-all-fragments
                     agent-shell-restart
                     agent-shell-reload
                     agent-shell-fork
                     agent-shell-permission-transient-menu
                     agent-shell-switch-buffer
                     agent-shell-other-buffer))
    (transient-remove-suffix 'agent-shell-help-menu command))
  (transient-append-suffix
    'agent-shell-help-menu 'agent-shell-previous-item
    '("z" "Toggle item" agent-shell-ui-toggle-fragment :transient t))
  (transient-append-suffix
    'agent-shell-help-menu 'agent-shell-ui-toggle-fragment
    '("Z" "Toggle all" agent-shell-ui-toggle-all-fragments :transient t))
  (transient-append-suffix
    'agent-shell-help-menu 'agent-shell-interrupt
    '("r" "Restart" agent-shell-restart))
  (transient-append-suffix
    'agent-shell-help-menu 'agent-shell-restart
    '("R" "Reload" agent-shell-reload))
  (transient-append-suffix
    'agent-shell-help-menu 'agent-shell-reload
    '("f" "Fork" agent-shell-fork))
  (transient-append-suffix
    'agent-shell-help-menu 'agent-shell-fork
    '("P" "Permissions" agent-shell-permission-transient-menu
      :if agent-shell-help-menu--permissions-pending-p))
  (transient-append-suffix
    'agent-shell-help-menu 'agent-shell-new-shell
    '("s" "Switch shell" agent-shell-switch-buffer))
  (transient-append-suffix
    'agent-shell-help-menu 'agent-shell-switch-buffer
    '("O" "Shell/viewport" agent-shell-other-buffer)))

(agent-shell-help-menu-install)

(evil-define-key* 'normal agent-shell-mode-map (kbd "?")
  #'agent-shell-help-menu)

(provide 'agent-shell-help-menu)
;;; agent-shell-help-menu.el ends here
