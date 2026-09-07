;;; llm.el --- LLM and agent integrations -*- lexical-binding: t -*-
;;; Commentary:
;; LLM and agent integrations: agent-switch, gptel, agent-shell and Magent.
;;; Code:

(require 'cl-lib)
(require 'subr-x)

;; -----------------------------------------------------------
;; DONE llm
;;
;; agent-switch
;; agent-shell
;; gptel
;; magent-magit
;; -----------------------------------------------------------

;; (use-package agent-switch
;;   :vc (:url "https://github.com/Jamie-Cui/agent-switch.el" :rev "main")
;;   :ensure t
;;   :commands agent-switch)

(use-package agent-shell
  :ensure t
  :demand t
  :custom
  (shell-maker-prompt-before-killing-buffer nil) ; do not prompt for save when quit buffer
  (agent-shell-session-restore-verbosity 'last) ; render only last turn
  (agent-shell-transcript-file-path-function nil) ; do not generate transcript
  (agent-shell-display-action 'display-buffer-other-window)
  ;; the following configs make ui clean
  (agent-shell-show-welcome-message nil)
  (agent-shell-header-style 'text)
  (agent-shell-show-config-icons nil)
  (agent-shell-thought-process-expand-by-default nil)
  (agent-shell-tool-use-expand-by-default nil)
  (agent-shell-tool-use-group-expand-by-default nil)
  (agent-shell-user-message-expand-by-default nil)
  :config
  ;; Agent Shell prompts are edited as prose: RET inserts a newline in insert
  ;; state and submits from normal state.  Bind its child map so other
  ;; Shell Maker consumers keep the global Evil Collection policy.
  (let ((evil-collection-binding-overrides
         '((repl-submit  :state normal)
           (repl-newline :state insert))))
    (evil-collection-bind 'agent-shell-mode-map
                          'repl-submit #'shell-maker-submit
                          'repl-newline #'newline))

  (defun +agent-shell/bind-return-in-action-keymap-a (map)
    "Bind GUI <return> in agent-shell action keymaps."
    (when (keymapp map)
      (when-let* ((action (lookup-key map (kbd "RET"))))
        (define-key map (kbd "<return>") action)))
    map)

  (defun +agent-shell/focus-input (shell-buffer)
    "Move point in visible SHELL-BUFFER to the current input's beginning."
    (when-let* ((window (get-buffer-window shell-buffer t)))
      (set-window-point
       window
       (with-current-buffer shell-buffer
         (let ((prompt-end
                (and (boundp 'comint-last-prompt)
                     (cdr-safe (symbol-value 'comint-last-prompt)))))
           (if (and (markerp prompt-end)
                    (marker-position prompt-end))
               (marker-position prompt-end)
             (point-max)))))))

  (defun +agent-shell/focus-input-after-display-a (shell-buffer)
    "Move point to the input after displaying SHELL-BUFFER."
    (+agent-shell/focus-input shell-buffer))

  (defun +agent-shell/focus-input-after-insert-a (&rest args)
    "Move point after a focused insertion described by ARGS."
    (unless (plist-get args :no-focus)
      (when (derived-mode-p 'agent-shell-mode)
        (+agent-shell/focus-input (current-buffer)))))

  (defun +agent-shell/focus-input-when-initialized-h ()
    "Move point after this agent shell finishes initializing."
    (let ((shell-buffer (current-buffer))
          subscription)
      (setq subscription
            (agent-shell-subscribe-to
             :shell-buffer shell-buffer
             :event 'init-finished
             :on-event
             (lambda (_event)
               (+agent-shell/focus-input shell-buffer)
               (agent-shell-unsubscribe :subscription subscription))))))

  (advice-remove 'agent-shell--display-buffer
                 #'+agent-shell/focus-input-after-display-a)
  (advice-add 'agent-shell--display-buffer
              :after #'+agent-shell/focus-input-after-display-a)
  (advice-remove 'agent-shell--insert-to-shell-buffer
                 #'+agent-shell/focus-input-after-insert-a)
  (advice-add 'agent-shell--insert-to-shell-buffer
              :after #'+agent-shell/focus-input-after-insert-a)
  (remove-hook 'agent-shell-mode-hook
               #'+agent-shell/focus-input-when-prompt-ready-h)
  (add-hook 'agent-shell-mode-hook
            #'+agent-shell/focus-input-when-initialized-h)

  (with-eval-after-load 'agent-shell-ui
    (advice-remove 'agent-shell-ui-make-action-keymap
                   #'+agent-shell/bind-return-in-action-keymap-a)
    (advice-add 'agent-shell-ui-make-action-keymap
                :filter-return #'+agent-shell/bind-return-in-action-keymap-a))

  ;; HACK using sssaicode api key

  ;; (defun +agent-shell/sss-api-key ()
  ;;   "Return the SSS API key used by Codex."
  ;;   (or (getenv "SSS_API_KEY")
  ;;       (user-error
  ;;        "SSS_API_KEY is not available in Emacs; restart Emacs or run `exec-path-from-shell-copy-env'")))

  ;; (with-eval-after-load 'agent-shell-openai
  ;;   (setq agent-shell-openai-authentication
  ;;         (agent-shell-openai-make-authentication
  ;;          :api-key #'+agent-shell/sss-api-key)
  ;;         agent-shell-openai-codex-acp-command
  ;;         '("codex-acp"
  ;;           "-c" "model_provider=\"sss\""
  ;;           "-c" "preferred_auth_method=\"apikey\"")))
  )

(use-package agent-shell-permission-transient
  :vc (:url "https://github.com/Jamie-Cui/agent-shell-permission-transient"
            :rev "main")
  :ensure t
  :after agent-shell
  :demand t
  :bind (:map agent-shell-mode-map
              ("C-c C-p" . agent-shell-permission-transient-menu))
  :config
  (agent-shell-permission-transient-mode +1))

(use-package agent-shell-help-menu
  :load-path (lambda () +emacs/site-lisp-directory)
  :after (agent-shell agent-shell-permission-transient)
  :demand t)

(use-package gptel
  :ensure t
  :custom
  (gptel-rewrite-default-action 'merge)
  (gptel-default-mode 'org-mode)
  (gptel-org-branching-context t)
  (gptel-log-level 'info)
  (gptel-proxy +emacs/proxy)
  ;; re-bind key
  :bind (:map gptel-mode-map
              ("C-c C-c" . #'gptel-send)
              ("C-c RET" . #'gptel-menu))
  :config
  ;; Display gptel buffers outside the current window.
  (setq gptel-display-buffer-action
        '((display-buffer-reuse-window
           display-buffer-use-some-window
           display-buffer-pop-up-window)
          (inhibit-same-window . t)))

  ;; set context
  (setf (alist-get 'org-mode gptel-prompt-prefix-alist) "=@Jamie=\n")
  (setf (alist-get 'org-mode gptel-response-prefix-alist) "=@AI=\n")

  ;; set hook
  (add-hook 'gptel-mode-hook
            (lambda () (insert "* Default Context\n=@Jamie=")))

  ;; (defun +llm/remove-headings (beg end)
  ;;   (when (derived-mode-p 'org-mode)
  ;;     (save-excursion
  ;;       (goto-char beg)
  ;;       (while (re-search-forward org-heading-regexp end t)
  ;;         (forward-line 0)
  ;;         (delete-char (1+ (length (match-string 1))))
  ;;         (insert-and-inherit "*")
  ;;         (end-of-line)
  ;;         (skip-chars-backward " \t\r")
  ;;         (insert-and-inherit "*")))))

  ;; (add-hook 'gptel-post-response-functions #'+llm/remove-headings)

  ;; -----------------------------------------------------------
  ;; PlantUML Beautification (using gptel-rewrite)
  ;; -----------------------------------------------------------

  ;;   (defvar +llm/beautify-plantuml-directive
  ;;     "You are a PlantUML expert. Beautify and improve the PlantUML diagram while preserving its semantic meaning. Improve layout, add appropriate styling/colors, organize elements logically, add skinparams for professional appearance. Return ONLY the improved PlantUML code without any explanations or markdown formatting."
  ;;     "Rewrite directive for PlantUML beautification.")

  ;;   (defun +llm/beautify-plantuml ()
  ;;     "Beautify PlantUML source block at point using gptel-rewrite.
  ;; This selects the PlantUML code region and invokes gptel's rewrite
  ;; functionality, allowing you to diff/ediff/merge the changes."
  ;;     (interactive)
  ;;     (require 'gptel-rewrite)
  ;;     ;; 1. Validate we're in org-mode
  ;;     (unless (derived-mode-p 'org-mode)
  ;;       (user-error "Not in org-mode"))

  ;;     ;; 2. Validate we're in a PlantUML source block
  ;;     (let* ((info (org-babel-get-src-block-info))
  ;;            (lang (car info)))
  ;;       (unless info
  ;;         (user-error "Not in a source block"))
  ;;       (unless (string= lang "plantuml")
  ;;         (user-error "Not in a PlantUML block (current: %s)" lang))

  ;;       ;; 3. Select the code region
  ;;       (let ((code-start (save-excursion
  ;;                           (org-babel-goto-src-block-head)
  ;;                           (forward-line 1)
  ;;                           (point)))
  ;;             (code-end (save-excursion
  ;;                         (org-babel-goto-src-block-head)
  ;;                         (re-search-forward "^[ \t]*#\\+end_src")
  ;;                         (match-beginning 0))))
  ;;         ;; 4. Set region and invoke gptel-rewrite
  ;;         (goto-char code-start)
  ;;         (push-mark code-end t t)
  ;;         (let ((gptel--rewrite-directive +llm/beautify-plantuml-directive))
  ;;           (gptel--suffix-rewrite)))))
  )

(use-package magent
  :vc (:url "https://github.com/Jamie-Cui/magent"
            :rev "master"
            :lisp-dir "lisp")
  :ensure t
  :after (agent-shell gptel)
  :demand t
  :custom
  ;; (magent-bypass-permission t)
  (magent-default-effort 'xhigh)
  (magent-include-reasoning 'ignore)
  :config
  (add-to-list 'magent-skill-directories
               (expand-file-name "~/.agents/skills") t)
  (magent-agent-shell-ensure-config))

(use-package magent-magit
  :load-path (lambda () (concat +emacs/repo-directory "/site-lisp/"))
  :after magent
  :demand t
  :config
  (magent-magit-register)
  (magent-magit-install))

(use-package magent-profile-memory
  :load-path (lambda () (concat +emacs/repo-directory "/site-lisp/"))
  :after magent
  :demand t
  :config
  (magent-profile-memory-register))

(use-package magent-submit-pr
  :load-path (lambda () (concat +emacs/repo-directory "/site-lisp/"))
  :after magent
  :demand t
  :config
  (magent-submit-pr-register))

(use-package magent-repo-summary-action
  :load-path (lambda () (concat +emacs/repo-directory "/site-lisp/"))
  :after magent
  :demand t
  :config
  (magent-repo-summary-register))


(provide 'init-llm)
;;; llm.el ends here
