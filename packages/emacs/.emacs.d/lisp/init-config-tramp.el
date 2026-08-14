;;; init-config-tramp.el --- TRAMP configuration -*- lexical-binding: t -*-
;;; Commentary:
;;; Code:

(require 'subr-x)
(require 'tramp)

(setopt enable-remote-dir-locals t)
(setopt tramp-use-file-attributes nil)
(setopt remote-file-name-inhibit-cache nil)
(setopt remote-file-name-inhibit-auto-save t)
(setopt remote-file-name-inhibit-auto-save-visited t)

(setq vc-ignore-dir-regexp (format "%s\\|%s" vc-ignore-dir-regexp tramp-file-name-regexp))

;; Improve tramp speed.
;; see: https://coredumped.dev/2025/06/18/making-tramp-go-brrrr./
(setopt tramp-allow-unsafe-temporary-files t ; do not warn me, please
        remote-file-name-inhibit-locks t
        tramp-use-scp-direct-remote-copying t)

(connection-local-set-profile-variables
 'remote-direct-async-process
 '((tramp-direct-async-process . t)))

(connection-local-set-profiles
 '(:application tramp :protocol "ssh")
 'remote-direct-async-process)

(with-eval-after-load 'tramp
  (with-eval-after-load 'compile
    (remove-hook 'compilation-mode-hook #'tramp-compile-disable-ssh-controlmaster-options)))

;; forgot why I add this ...
(setopt tramp-pipe-stty-settings "")

;; this improves magit efficiency
(unless (featurep :system 'windows)
  (setopt tramp-default-method "ssh")) ; faster than the default scp

;; allow asyn in tramp
(setopt tramp-async-enabled t)

;; PERF: Calls over TRAMP are expensive, so reduce the number of calls by more
;; aggressively caching some common data. Inspired by
;; https://coredumped.dev/2025/06/18/making-tramp-go-brrrr.
(defun +tramp--memoize (key cache fn &rest args)
  "Memoize a value if the key is a remote path."
  (if (and key (file-remote-p key))
      (if-let* ((current (assoc key (symbol-value cache))))
          (cdr current)
        (let ((current (apply fn args)))
          (set cache (cons (cons key current) (symbol-value cache)))
          current))
    (apply fn args)))

;;;###package magit
(declare-function magit-process-git "magit-process" (destination &rest args))
(defvar magit-git-debug)

(defvar +tramp--magit-toplevel-cache nil)
(defun +tramp--memoized-magit-toplevel-a (orig &optional directory)
  (+tramp--memoize (or directory default-directory)
                   '+tramp--magit-toplevel-cache orig directory))

(with-eval-after-load 'magit
  (advice-add #'magit-toplevel :around #'+tramp--memoized-magit-toplevel-a))

;; Magit renders the staged and unstaged sections with `magit--git-wash'.
;; That function asks the private `magit--git-insert' helper to preserve the
;; complete stderr output, so Magit creates a local `magit-stderr*' file and
;; passes it to the synchronous `process-file' call.  TRAMP cannot connect a
;; remote process' stderr directly to that local file.  It first redirects
;; stderr to `/tmp/tramp.*' on the remote host and then copies the file back.
;; A status refresh normally renders both diff sections, so even a clean
;; repository incurs two blocking transfers and reports messages such as:
;;
;;   Renaming /ssh:host:/tmp/tramp.* to /local/tmp/magit-stderr*...done
;;
;; `tramp-direct-async-process' does not help here because this refresh path is
;; synchronous.  For a remote status buffer, use the documented (t t) process
;; destination instead, which mixes stderr into stdout without a temporary
;; file.  A successful `git diff' normally writes nothing to stderr, leaving
;; Magit's diff parser unchanged.  On failure, remove the mixed process output
;; and return it as the error string that `magit--git-wash' expects.
;;
;; Keep the workaround narrow: local repositories, non-status Magit buffers,
;; non-`full' error handling, and `magit-git-debug' all retain upstream
;; behavior.  This advises a private Magit function and should be reviewed
;; after upgrades that change `magit--git-insert'.
(defun +tramp--magit-remote-git-insert-a (orig return-error &rest args)
  "Avoid local stderr-file transfers while refreshing remote Magit status.
ORIG, RETURN-ERROR, and ARGS are the arguments of `magit--git-insert'."
  (if (and (eq return-error 'full)
           (derived-mode-p 'magit-status-mode)
           (file-remote-p default-directory)
           (not magit-git-debug))
      (let* ((beg (point))
             (args (flatten-tree args))
             (exit (apply #'magit-process-git (list t t) args)))
        (if (zerop exit)
            exit
          (let ((error-output
                 (buffer-substring-no-properties beg (point))))
            (delete-region beg (point))
            (if (string-empty-p error-output)
                exit
              error-output))))
    (apply orig return-error args)))

(with-eval-after-load 'magit-git
  (advice-add #'magit--git-insert :around
              #'+tramp--magit-remote-git-insert-a))

;;;###package project
(defvar +tramp--project-current-cache nil)
(defun +tramp--memoized-project-current (fn &optional prompt directory)
  (+tramp--memoize (or directory
                       project-current-directory-override
                       default-directory)
                   '+tramp--project-current-cache fn prompt directory))

(advice-add #'project-current :around #'+tramp--memoized-project-current)

;;;###package vc-git
(defvar +tramp--vc-git-root-cache nil)
(defun +tramp--memoized-vc-git-root-a (fn file)
  (let ((value
         (+tramp--memoize (file-name-directory file)
                          '+tramp--vc-git-root-cache fn file)))
    ;; sometimes vc-git-root returns nil even when there is a root there
    (unless (cdar +tramp--vc-git-root-cache)
      (setq +tramp--vc-git-root-cache (cdr +tramp--vc-git-root-cache)))
    value))

(with-eval-after-load 'vc-git
  (advice-add #'vc-git-root :around #'+tramp--memoized-vc-git-root-a))

(provide 'init-config-tramp)
;;; init-config-tramp.el ends here
