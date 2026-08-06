;;; init.el --- Configuration manifest -*- lexical-binding: t -*-
;;; Commentary:
;; Entry point for the Stow-managed configuration.  Loads the core layer, then
;; the feature modules via `+emacs/load-modules'.  Machine-local settings live
;; in the untracked ~/.emacs.d/local.el.
;;; Code:

;; --- Bootstrap: locate the repository and the core layer. ---
(let ((repo (file-name-directory
             (file-truename (or load-file-name buffer-file-name
                                (expand-file-name "init.el"))))))
  (add-to-list 'load-path (expand-file-name "lisp" repo))
  (add-to-list 'load-path (expand-file-name "lisp/core" repo))
  (setq +emacs/repo-directory (directory-file-name repo)))

;; --- Core layer (fixed order). ---
(require 'core-vars)

;; Defaults may be overridden by the untracked machine-local file before the
;; package system and feature modules initialize.
(setq custom-file (expand-file-name "custom.el" user-emacs-directory))
(require 'package)
(setq package-archives
      '(("gnu"    . "https://elpa.gnu.org/packages/")
        ("nongnu" . "https://elpa.nongnu.org/nongnu/")
        ("melpa"  . "https://melpa.org/packages/")))
(let ((local-file (expand-file-name "local.el" user-emacs-directory)))
  (when (file-readable-p local-file)
    (load local-file nil 'nomessage)))

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
   "bibliography"
   "latex"
   "reading"
   "email"
   "llm"
   "input"
   "keys"))

;; Loading happens after packages so generated forms can reference package
;; variables safely.
(when (file-readable-p custom-file)
  (load custom-file nil 'nomessage))

(when +emacs/theme
  (load-theme +emacs/theme t))

;;; init.el ends here
