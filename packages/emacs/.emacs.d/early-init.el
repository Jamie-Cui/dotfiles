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

;; undecorated frame
(add-to-list 'default-frame-alist '(undecorated . t))

;; Native compilation can start while package.el bootstraps, before the OS
;; module imports the login-shell environment.  Give GUI Emacs access to the
;; Homebrew GCC driver early enough for libgccjit to invoke it.
(when (eq system-type 'darwin)
  (let ((homebrew-bin
         (cond
          ((file-directory-p "/opt/homebrew/bin") "/opt/homebrew/bin")
          ((file-directory-p "/usr/local/bin") "/usr/local/bin"))))
    (when homebrew-bin
      (unless (member homebrew-bin exec-path)
        (push homebrew-bin exec-path))
      (let ((path (getenv "PATH")))
        (unless (member homebrew-bin
                        (split-string (or path "") path-separator t))
          (setenv "PATH"
                  (if (and path (> (length path) 0))
                      (concat homebrew-bin path-separator path)
                    homebrew-bin)))))))

;; Apple Silicon macOS with Homebrew: help libgccjit find GCC's private
;; runtime libraries when Emacs is launched from Finder or Spotlight.
;; (let* ((gcc-bin-dir "/opt/homebrew/opt/gcc/bin")
;;        (gcc (and (file-directory-p gcc-bin-dir)
;;                  (car (directory-files
;;                        gcc-bin-dir t "\\`gcc-[0-9]+\\'"))))
;;        (libemutls (and gcc
;;                       (car (process-lines
;;                             gcc "-print-file-name=libemutls_w.a")))))
;;   (when (and libemutls (file-readable-p libemutls))
;;     (setq native-comp-driver-options
;;           (list "-Wl,-w"
;;                 (concat "-L" (file-name-directory libemutls))))))

;;; early-init.el ends here
