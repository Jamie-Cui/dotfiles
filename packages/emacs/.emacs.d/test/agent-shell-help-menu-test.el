;;; agent-shell-help-menu-test.el --- Tests for Agent Shell help menu -*- lexical-binding: t; -*-

;;; Commentary:

;; Focused tests for the local Agent Shell help-menu extensions.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'agent-shell-help-menu)

(ert-deftest agent-shell-help-menu-displays-below-selected-window ()
  (let ((selected (selected-window))
        displayed-buffer
        display-alist)
    (cl-letf (((symbol-function 'display-buffer-in-direction)
               (lambda (buffer alist)
                 (setq displayed-buffer buffer
                       display-alist alist)
                 :menu-window)))
      (should
       (eq (agent-shell-help-menu--display-buffer
            (current-buffer) '((dedicated . t)))
           :menu-window))
      (should (eq displayed-buffer (current-buffer)))
      (should (eq (alist-get 'window display-alist) selected))
      (should (eq (alist-get 'direction display-alist) 'below)))))

(ert-deftest agent-shell-help-menu-installs-custom-suffixes ()
  (dolist (entry '(("z" . agent-shell-ui-toggle-fragment)
                   ("Z" . agent-shell-ui-toggle-all-fragments)
                   ("r" . agent-shell-restart)
                   ("R" . agent-shell-reload)
                   ("f" . agent-shell-fork)
                   ("P" . agent-shell-permission-transient-menu)
                   ("s" . agent-shell-switch-buffer)
                   ("O" . agent-shell-other-buffer)))
    (should
     (eq (plist-get
          (cdr (transient-get-suffix 'agent-shell-help-menu (car entry)))
         :command)
         (cdr entry)))))

(ert-deftest agent-shell-help-menu-binds-question-mark-in-evil-normal-state ()
  (require 'evil)
  (should
   (eq (evil-lookup-key
        (evil-get-auxiliary-keymap agent-shell-mode-map 'normal)
        (kbd "?"))
       #'agent-shell-help-menu)))

(provide 'agent-shell-help-menu-test)
;;; agent-shell-help-menu-test.el ends here
