;;; ui.el --- frames, fonts, modeline, dashboard, theme -*- lexical-binding: t -*-
;;; Commentary:
;; User interface: frames, fonts, cnfonts, the custom modeline, dashboard,
;; popwin, themes and TTY tweaks.
;;; Code:


;; fix frame display issues
(setq frame-resize-pixelwise t)

;; smooth scrolling
(pixel-scroll-mode +1)
(when (fboundp 'pixel-scroll-precision-mode)
  (pixel-scroll-precision-mode +1))

;; Optional configurations for fine-tuning
(setq pixel-dead-time 0) ; Never revert to line-based scrolling behavior
(setq pixel-resolution-fine-flag t) ; Scroll by actual pixels
(setq mouse-wheel-scroll-amount '(1)) ; Distance to scroll per mouse wheel event
(setq mouse-wheel-progressive-speed nil) ; Disable progressive speed if it feels too fast

(set-fringe-mode 0)

(setq ring-bell-function 'ignore)

(add-to-list 'default-frame-alist '(fullscreen . maximized))

(blink-cursor-mode -1)

(setq blink-matching-paren nil)

(setq x-stretch-cursor nil)

(setq indicate-buffer-boundaries nil
      indicate-empty-lines nil)

(setq resize-mini-windows 'grow-only
      tooltip-resize-echo-area t)

(menu-bar-mode 0)
(tool-bar-mode 0)
(customize-set-variable 'scroll-bar-mode nil)
(customize-set-variable 'horizontal-scroll-bar-mode nil)

(add-hook 'prog-mode-hook 'display-line-numbers-mode)

(dolist (mode '(pdf-view-mode-hook
                term-mode-hook
                eshell-mode-hook
                vterm-mode-hook
                imenu-list-minor-mode-hook
                imenu-list-major-mode-hook))
  (add-hook mode (lambda () (display-line-numbers-mode -1))))
(setq-default display-line-numbers-type 't)

;; ------------------------------------------------------------------
;; TTY Configuration
;; ------------------------------------------------------------------

(when (not (display-graphic-p))
  ;; HACK for state-of-art emacs (30.1.05 maybe?)
  (when (featurep 'tty-child-frames)
    (add-hook 'tty-setup-hook #'tty-tip-mode))

  ;; Use OSC52 protocol, which is used by alacritty by default
  (defun +tty/copy-to-system-clipboard (text &optional push)
    (let ((encoded (base64-encode-string
                    (encode-coding-string text 'binary)
                    t)))
      (send-string-to-terminal (format "\e]52;c;%s\a" encoded))))

  (setq interprogram-cut-function '+tty/copy-to-system-clipboard)


  (xterm-mouse-mode 1)
  (setq x-stretch-cursor t)

  ;; Disable eldoc in terminal
  (eldoc-mode -1))

;; ------------------------------------------------------------------
;;; Modeline
;; ------------------------------------------------------------------

;; Place Evil's state tag after every right-aligned status segment.  The plain
;; `after' setting targets `mode-line-modes', which this custom mode line does
;; not contain, so anchor the tag explicitly to its final named segment.
;; (setopt evil-mode-line-format '(after . mode-line-end-spaces))
(setopt evil-mode-line-format 'nil)

;; turn on column-number on modeline
(column-number-mode 1)
;; (setopt mode-line-position-column-line-format '("%l:%c"))

;; remove trailing dashes
(setopt mode-line-end-spaces nil)
(setopt mode-line-front-space nil)

;; turn on size in bytes indicator on modeline
(size-indication-mode 1)

(require 'project)

(defface +ui/modeline-project-name
  '((t (:inherit font-lock-keyword-face :weight bold)))
  "Face used for the project name in the mode line."
  :group 'mode-line-faces)

(defface +ui/modeline-buffer-name
  '((t (:inherit mode-line-buffer-id :weight normal)))
  "Face used for the buffer name in the mode line."
  :group 'mode-line-faces)

(setopt project-mode-line t
        project-mode-line-face '+ui/modeline-project-name)

(defconst +ui/modeline-project-format-version 3
  "Version of the cached mode-line project segment format.")

(defvar-local +ui/modeline-project-cache-version nil
  "Format version of the cached mode-line project segment.")

(defvar-local +ui/modeline-project-cache-directory nil
  "Directory used to compute the cached mode-line project segment.")

(defvar-local +ui/modeline-project-cache nil
  "Cached project segment for the mode line.")

(defun +ui/modeline-project-segment ()
  "Return a cached project segment for the mode line.

The cache avoids project discovery during ordinary mode-line redisplay.
Use angle brackets for remote projects and square brackets for local ones."
  (unless (and (eq +ui/modeline-project-cache-version
                   +ui/modeline-project-format-version)
               (equal default-directory
                      +ui/modeline-project-cache-directory))
    (setq +ui/modeline-project-cache-version
          +ui/modeline-project-format-version
          +ui/modeline-project-cache-directory default-directory
          +ui/modeline-project-cache
          (when-let* ((segment (project-mode-line-format)))
            (let* ((name (if (and (> (length segment) 0)
                                  (eq (aref segment 0) ?\s))
                             (substring segment 1)
                           segment))
                   (remote (file-remote-p default-directory))
                   (label (concat (if remote "<" "[")
                                  name
                                  (if remote ">" "]"))))
              ;; `project-mode-line-format' applies the project face only to
              ;; NAME.  Override that single property across LABEL so both
              ;; delimiters use exactly the same face.
              (put-text-property 0 (length label)
                                 'face '+ui/modeline-project-name label)
              (concat " " label " ")))))
  +ui/modeline-project-cache)

(defvar-local +ui/modeline-buffer-identification-cache nil
  "Cached mode-line buffer identification keyed by buffer name.")

(defun +ui/modeline-buffer-identification ()
  "Return a cached, propertized buffer identifier for the mode line."
  (let ((name (buffer-name)))
    (if (equal name (car +ui/modeline-buffer-identification-cache))
        (cdr +ui/modeline-buffer-identification-cache)
      (let ((identification
             (propertize
              name
              'face '+ui/modeline-buffer-name
              'help-echo
              "Buffer name\nmouse-1: Previous buffer\nmouse-3: Next buffer"
              'mouse-face 'mode-line-highlight
              'local-map mode-line-buffer-identification-keymap)))
        (setq +ui/modeline-buffer-identification-cache
              (cons name identification))
        identification))))

;; mode-line format
(setopt mode-line-format
        (list
         "%e"
         'mode-line-front-space
         '(:eval (+ui/modeline-project-segment))
         '(:eval (+ui/modeline-buffer-identification))
         "   "
         'mode-line-position
         "   "
         '(:eval (if (region-active-p)
                     (format " (Sel: %d)" (abs (- (point) (mark)))) ""))
         'mode-line-format-right-align
         'mode-line-misc-info
         "   "
         'mode-name
         " (+"
         '(:eval (format "%d" (length local-minor-modes)))
         ")"
         'mode-line-end-spaces
         "   "
         )
        )

(use-package cnfonts
  :ensure t
  :custom
  (cnfonts-directory (expand-file-name "cnfonts" +emacs/repo-directory))
  (cnfonts-profiles '("default" "reading"))
  (cnfonts-personal-fontnames
   '(
     ("Maple Mono NL NF CN" "Maple Mono NF CN") ;; English
     ("Maple Mono NL NF CN" "Maple Mono NF CN") ;; Chinese
     nil  ;; Ext-B
     nil ;; Symbol
     nil ;; Others
     ))
  (cnfonts-use-face-font-rescale t)
  :config
  ;; NOTE you can use this to list all fonts
  ;; (cl-prettyprint (font-family-list))
  (cnfonts-mode 1))

(use-package dashboard
  :ensure t
  :custom
  (dashboard-banner-logo-title "It's possible to build a cabin with no foundations, but not a lasting building.")
  (dashboard-center-content t)
  (dashboard-vertically-center-content t)
  (dashboard-show-shortcuts nil)
  (dashboard-set-heading-icons nil)
  (dashboard-startup-banner 4) ; 4 means using 4.txt
  (dashboard-set-file-icons nil)
  (dashboard-items '(
                     ;; (agenda . 5)
                     (org-project . 5)
                     (elfeed . 5)
                     (recents  . 5)
                     ;; (projects  . 3)
                     ;; (bookmarks . 3)
                     ))
  (dashboard-projects-backend 'projectile)
  (dashboard-filter-agenda-entry 'dashboard-filter-agenda-by-todo)
  (dashboard-agenda-sort-strategy '(priority-up))
  :config
  (dashboard-setup-startup-hook)

  ;; HACK from https://github.com/emacs-dashboard/emacs-dashboard/issues/153#issuecomment-714406661
  (defvar my-banners-dir (concat +emacs/repo-directory "/data/"))
  (defun +ui/dashboard-install-banners ()
    "Copy all files under under banners directory to dashboard banners directory"
    (when (boundp 'dashboard-banners-directory)
      (copy-directory my-banners-dir dashboard-banners-directory nil nil t)))
  (+ui/dashboard-install-banners)

  (defun +ui/dashboard-window ()
    "Return a visible dashboard window."
    (get-buffer-window dashboard-buffer-name t))

  (defun +ui/dashboard-current-position (&optional window)
    "Return a logical dashboard position for WINDOW or the current point."
    (let ((point (if window (window-point window) (point))))
      (save-excursion
        (goto-char point)
        (let ((section (ignore-errors (dashboard--current-section))))
          (list :line (line-number-at-pos nil t)
                :column (current-column)
                :section section
                :section-line (when section
                                (dashboard--current-index section point)))))))

  (defun +ui/dashboard-restore-position (position &optional window)
    "Restore dashboard point from POSITION after the buffer is refreshed."
    (let ((line (max 1 (or (plist-get position :line) 1)))
          (column (or (plist-get position :column) 0))
          (section (plist-get position :section))
          (section-line (plist-get position :section-line)))
      (cond
       ((and section section-line)
        (unless (ignore-errors
                  (dashboard--goto-section section)
                  (forward-line section-line)
                  t)
          (goto-char (point-min))
          (forward-line (1- line))))
       (t
        (goto-char (point-min))
        (forward-line (1- line))))
      (move-to-column column)
      (when (window-live-p window)
        (set-window-point window (point))
        (with-selected-window window
          (recenter)))))

  (defun +ui/dashboard-open-keep-position-a (fn &rest args)
    "Run FN with ARGS while preserving point in an existing dashboard buffer."
    (let* ((window (+ui/dashboard-window))
           (buffer (and (window-live-p window) (window-buffer window)))
           (keep-position-p (and buffer
                                 (eq (buffer-local-value 'major-mode buffer)
                                     'dashboard-mode)))
           (position (when keep-position-p
                       (with-current-buffer buffer
                         (+ui/dashboard-current-position window)))))
      (prog1 (apply fn args)
        (when (and keep-position-p (buffer-live-p buffer))
          (with-current-buffer buffer
            (+ui/dashboard-restore-position position window))))))
  (advice-add 'dashboard-open :around #'+ui/dashboard-open-keep-position-a)

  ;; To disable shortcut "jump" indicators for each section, set
  (add-hook 'dashboard-after-initialize-hook (lambda () (dashboard-open)))
  (setq initial-buffer-choice (lambda () (dashboard-open))))

(use-package popwin
  :ensure t
  :after gptel
  :custom
  (popwin:special-display-config
   '(
     ;; emacs-builtin
     ("*xref*" :position bottom :stick t :dedicated t)
     ("*Messages*" :position bottom :stick t :dedicated t)
     ;; help
     ("*Multiple Choice Help*" :position bottom :stick t :dedicated t)
     (help-mode :position bottom :stick t :dedicated t)
     (helpful-mode :position bottom :stick t :dedicated t)
     ;; flycheck
     ("*Flycheck errors*" :position bottom :stick t :dedicated t)
     ;; llm-related
     ("*LLM response*" :position bottom :stick t :dedicated t)
     (agent-shell-mode :position right :stick t :dedicated t :width 0.5)
     ;; org-related
     ("*Org Select*" :position bottom :stick t :dedicated t)
     ("*Org Attach*" :position bottom :stick t :dedicated t)
     ("CAPTURE-inbox.org" :position bottom :stick t :dedicated t)
     (org-gtd-clarify-mode :position bottom :stick t :dedicated t)
     ;; (compilation-mode :position bottom :position bottom :stick t :dedicated t)
     ;; (comint-mode :position bottom :position bottom :stick t :dedicated t)
     ;; ("^\\*eshell\\*.*" :regexp t :position bottom :stick t :dedicated t)
     ;; (eat-mode :position bottom :stick t :dedicated t)
     )
   )
  :config
  (popwin-mode 1))

(use-package zenburn-theme
  :ensure t
  :defer t)

(use-package gruvbox-theme
  :ensure t
  :defer t)

;; Work around Gruvbox's stale Gnus face inheritance on Emacs 31.

(defconst +emacs/gruvbox-themes
  '(gruvbox
    gruvbox-dark-hard
    gruvbox-dark-medium
    gruvbox-dark-soft
    gruvbox-light-hard
    gruvbox-light-medium
    gruvbox-light-soft)
  "Gruvbox theme variants that share the same Gnus face definitions.")

(defun +emacs/replace-symbol-in-tree (tree from to)
  "Return TREE with every occurrence of symbol FROM replaced by TO."
  (cond
   ((eq tree from) to)
   ((consp tree)
    (cons (+emacs/replace-symbol-in-tree (car tree) from to)
          (+emacs/replace-symbol-in-tree (cdr tree) from to)))
   (t tree)))

(defun +emacs/fix-gruvbox-gnus-face-cycle-a (args)
  "Fix Gruvbox's stale Gnus face inheritance in `custom-theme-set-faces' ARGS."
  (let ((theme (car args)))
    (if (memq theme +emacs/gruvbox-themes)
        (cons theme
              (mapcar
               (lambda (face-spec)
                 (if (eq (car-safe face-spec) 'gnus-group-news-low-empty)
                     (+emacs/replace-symbol-in-tree
                      face-spec
                      'gnus-group-news-low
                      'gnus-group-mail-1-empty)
                   face-spec))
               (cdr args)))
      args)))

(advice-add 'custom-theme-set-faces
            :filter-args #'+emacs/fix-gruvbox-gnus-face-cycle-a)


(provide 'init-ui)
;;; ui.el ends here
