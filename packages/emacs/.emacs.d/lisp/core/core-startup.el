;;; core-startup.el --- Startup tuning and workarounds -*- lexical-binding: t -*-
;;; Commentary:
;; Emacs version gate, startup performance restoration, proxy application,
;; process tuning, version workarounds, and session side-effects (compression,
;; server).
;;; Code:

(require 'core-vars)

;; Require a modern Emacs.
(let ((minver "30.1"))
  (when (version< emacs-version minver)
    (error "Your Emacs is too old -- this config requires v%s or higher" minver)))

;; Faster subprocess (e.g. LSP) reads.  Default is 4KB, too small for LSP.
(setq read-process-output-max (* 1024 1024)) ; 1MB

;; Let EasyPG collect passphrases through Emacs instead of relying on an
;; external Pinentry with a usable TTY.  This keeps GUI and daemon sessions
;; working after gpg-agent's passphrase cache expires.
(require 'epg)
(require 'epa-file)
(setopt epg-pinentry-mode 'loopback)

;; Never fall back to plaintext credential files.  EasyPG decrypts this source
;; through GnuPG when an auth-source consumer requests a secret.
(require 'auth-source)
(setopt auth-sources '("~/.authinfo.gpg"))

;; Quiet down development-time warning noise.
(setopt warning-suppress-log-types '((files)))
(setq byte-compile-warnings '(not lexical))
;; Silently report native-comp warnings/errors (handled by the deny-list below).
(setopt native-comp-async-report-warnings-errors 'silent)

;; `early-init.el' raises the GC ceiling and clears `file-name-handler-alist'.
;; When early-init did not run (e.g. `emacs -q --load init.el') the `defvar'
;; below captures the live value as a safe fallback so the restore is correct.
(defvar +emacs/initial-file-name-handler-alist file-name-handler-alist
  "Value of `file-name-handler-alist' before startup tuning.")

(defun +emacs/restore-startup-settings-h ()
  "Reset GC and file-handler settings to normal post-startup values."
  ;; Magent and TRAMP keep a large live heap; collect less frequently so
  ;; interactive work does not repeatedly pay for a full-heap scan.
  (setq gc-cons-threshold (* 128 1024 1024) ; 128 MiB
        gc-cons-percentage 0.2
        file-name-handler-alist +emacs/initial-file-name-handler-alist)
  ;; Install this only after restoring the handlers cleared by `early-init.el'.
  (epa-file-enable))

(add-hook 'emacs-startup-hook #'+emacs/restore-startup-settings-h)

;; Load the URL variables before applying the proxy.  At startup the URL stack
;; is normally still unloaded, so guarding this with `boundp' silently skipped
;; the proxy and made package.el attempt a direct connection.
(require 'url-vars)

(defconst +emacs/proxy-environment-variables
  '("http_proxy" "https_proxy" "ftp_proxy" "all_proxy"
    "HTTP_PROXY" "HTTPS_PROXY" "FTP_PROXY" "ALL_PROXY")
  "Environment variables managed by the Emacs proxy commands.")

(defun +emacs/setenv-globally (variable value)
  "Set environment VARIABLE to VALUE throughout the Emacs session.
Update the top-level environment used by ordinary buffers as well as
copies already made buffer-local by modes such as Eshell."
  (let ((process-environment
         (copy-sequence (default-toplevel-value 'process-environment))))
    (setenv variable value)
    (set-default-toplevel-value 'process-environment process-environment))
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (local-variable-p 'process-environment)
        (setenv variable value)))))

(defun +emacs/set-proxy (&optional proxy)
  "Enable PROXY for Emacs URL access and future subprocesses.
PROXY defaults to `+emacs/proxy' and should have the form host:port."
  (interactive)
  (setq proxy (or proxy +emacs/proxy))
  (dolist (scheme '("http" "https" "ftp"))
    (setf (alist-get scheme url-proxy-services nil nil #'string=) proxy))
  (let ((proxy-url (concat "http://" proxy)))
    (dolist (variable +emacs/proxy-environment-variables)
      (+emacs/setenv-globally variable proxy-url)))
  ;; Gptel uses its own proxy setting instead of `url-proxy-services'.
  (when (boundp 'gptel-proxy)
    (set 'gptel-proxy proxy))
  (when (called-interactively-p 'interactive)
    (message "Emacs proxy enabled: %s" proxy)))

(defun +emacs/unset-proxy ()
  "Disable the proxy for Emacs URL access and future subprocesses."
  (interactive)
  (dolist (scheme '("http" "https" "ftp"))
    (setq url-proxy-services
          (assoc-delete-all scheme url-proxy-services)))
  (dolist (variable +emacs/proxy-environment-variables)
    (+emacs/setenv-globally variable nil))
  (when (boundp 'gptel-proxy)
    (set 'gptel-proxy nil))
  (when (called-interactively-p 'interactive)
    (message "Emacs proxy disabled")))

(+emacs/set-proxy)

;; Work around an Emacs 30.2+ native-comp regression in built-in Org.
(defvar native-comp-jit-compilation-deny-list nil)
(dolist (regexp '(".*org-element.*" ".*org-macs.*"))
  (add-to-list 'native-comp-jit-compilation-deny-list regexp))

;; Org 9.8.5 bytecode can call this version check as a runtime function under
;; Emacs 31 snapshots, although Org defines it as a macro.
(with-eval-after-load 'org-macs
  (when (macrop 'org-assert-version)
    (defalias 'org-assert-version #'ignore)))

;; Keep `auto-compression-mode' robust across reloads.
(auto-compression-mode 0)
(auto-compression-mode 1)

;; Start the Emacs server for emacsclient (interactive sessions only).
(require 'server)
(unless (or noninteractive (server-running-p))
  (server-start))

(provide 'core-startup)
;;; core-startup.el ends here
