;;; consult-agent-shell.el --- Switch Agent Shell buffers with Consult -*- lexical-binding: t; -*-

;;; Commentary:
;; A dedicated Consult source for live Agent Shell buffers.

;;; Code:

(require 'agent-shell)
(require 'consult)

(defvar consult-source-agent-shell
  `(:name "Agent Shell"
    :category buffer
    :face consult-buffer
    :history buffer-name-history
    :state ,#'consult--buffer-state
    :items ,(lambda ()
              (mapcar #'consult--buffer-pair (agent-shell-buffers))))
  "Agent Shell buffer source for `consult-agent-shell'.")

;;;###autoload
(defun consult-agent-shell ()
  "Switch to an existing Agent Shell buffer with Consult."
  (interactive)
  (unless (agent-shell-buffers)
    (user-error "No Agent Shell buffers"))
  (consult--multi (list consult-source-agent-shell)
                  :require-match t
                  :prompt "Switch to Agent Shell: "
                  :history 'consult--buffer-history
                  :sort nil))

(provide 'consult-agent-shell)
;;; consult-agent-shell.el ends here
