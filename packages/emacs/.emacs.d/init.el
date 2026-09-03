;;; init.el --- Configuration manifest -*- lexical-binding: t -*-
;;; Commentary:
;; Entry point for the Stow-managed configuration.  Loads the core layer, then
;; the feature modules via `+emacs/load-modules'.
;;; Code:

;; Prefer managed source changes even when an ignored .elc is stale.
(setq load-prefer-newer t)

;; Keep Customize-generated settings out of the tracked init.el.
(setq custom-file (expand-file-name "custom.el" user-emacs-directory))

;; --- Bootstrap: locate the repository and the core layer. ---
(let ((repo (file-name-directory
             (file-truename (or load-file-name buffer-file-name
                                (expand-file-name "init.el"))))))
  (add-to-list 'load-path (expand-file-name "lisp" repo))
  (add-to-list 'load-path (expand-file-name "lisp/core" repo))
  (setq +emacs/repo-directory (directory-file-name repo)))

;; --- Core layer (fixed order). ---
(require 'core-vars)

;; --- User settings ---------------------------------------------------------
(setopt +emacs/org-root-dir (expand-file-name "~/opt/org-root")
        +emacs/proxy "127.0.0.1:10808"
        +emacs/theme 'gruvbox)

;; Mail identity; the mu4e path is auto-detected from the mu binary.
(setopt +emacs/email-address "jamie.cui@outlook.com"
        +emacs/email-full-name "Jamie Cui"
        +emacs/email-maildir (expand-file-name "~/.local/share/mail/outlook")
        +emacs/mu4e-load-path (+emacs/detect-mu4e-load-path))

;; If you use an Apple keyboard, map the Super key to Meta.
;; (setq x-super-keysym 'meta)

;; Load the package manager so we can configure its archives.
(require 'package)

;; Configure ELPA archives before any package operations.
(setq package-archives
      '(("gnu"    . "https://elpa.gnu.org/packages/")
        ("nongnu" . "https://elpa.nongnu.org/nongnu/")
        ("melpa"  . "https://melpa.org/packages/")))

;; If the official package hosts are slow:
;; (setq package-archives
;;       '(("gnu"    . "https://mirrors.tuna.tsinghua.edu.cn/elpa/gnu/")
;;         ("nongnu" . "https://mirrors.tuna.tsinghua.edu.cn/elpa/nongnu/")
;;         ("melpa"  . "https://mirrors.tuna.tsinghua.edu.cn/elpa/melpa/")))

(require 'core-paths)
(require 'core-startup)
(require 'core-package)
(require 'core-loader)
(require 'core-util)

;; --- Module manifest -------------------------------------------------------
;; Evil and its config provide commands and helpers used by feature modules at
;; load time, so they load before the manifest.  `keys' loads last so every
;; module command it binds is already defined.
(require 'init-config-evil)

(+emacs/load-modules
 '("os"
   "ui"
   "editor"
   "completion"
   "files"
   "project"
   "vc"
   "prog"
   "lang/lean"
   "lang/protobuf"
   "lang/meson"
   "lang/cmake"
   "lang/bazel"
   "lang/markdown"
   "org"
   "notes"
   "caldav"
   "bibliography"
   "latex"
   "reading"
   ;; "email"
   "llm"
   "llm-config"
   "input"
   "keys"))

;; Loading happens after packages so generated forms can reference package
;; variables safely.
(when (file-readable-p custom-file)
  (load custom-file nil 'nomessage))

(when +emacs/theme
  (load-theme +emacs/theme t))

;;; init.el ends here
