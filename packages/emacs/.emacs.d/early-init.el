;;; early-init.el --- Early initialization -*- lexical-binding: t -*-
;;; Commentary:
;; Loaded before the package system and the first frame.  Only settings that
;; must take effect this early belong here; everything else lives in the core
;; layer and modules.  Performance values raised here are restored in
;; `core-startup'.
;;; Code:

;; Raise the GC ceiling during startup; restored on `emacs-startup-hook'.
(setq gc-cons-threshold most-positive-fixnum
      gc-cons-percentage 0.6)

;; Skip the file-name handler machinery during startup I/O.
(defvar +emacs/initial-file-name-handler-alist file-name-handler-alist)
(setq file-name-handler-alist nil)

;; We initialize package.el explicitly in `core-package'.
(setq package-enable-at-startup nil)

;; Prefer newer source over stale byte-code.
(setq load-prefer-newer t)

;; Disable UI chrome before the first frame to avoid flicker.
(push '(menu-bar-lines . 0) default-frame-alist)
(push '(tool-bar-lines . 0) default-frame-alist)
(push '(vertical-scroll-bars) default-frame-alist)
(setq menu-bar-mode nil
      tool-bar-mode nil
      scroll-bar-mode nil)

;; Host-specific settings that must run before the first frame belong here.
(let ((local-file (expand-file-name "early-local.el" user-emacs-directory)))
  (when (file-readable-p local-file)
    (load local-file nil 'nomessage)))

;; undecorated frame
(add-to-list 'default-frame-alist '(undecorated . t))

;;; early-init.el ends here
