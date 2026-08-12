;;; core-vars.el --- User-tunable variables -*- lexical-binding: t -*-
;;; Commentary:
;; Defines the `+emacs' customization group and the small set of user-tunable
;; variables shared across the configuration.  Concrete values are set in
;; `init.el'.
;;; Code:

(defgroup +emacs nil
  "Personal Emacs configuration."
  :group 'convenience
  :prefix "+emacs/")

(defcustom +emacs/repo-directory (expand-file-name "~/.emacs.d")
  "Path to the emacs.d configuration repository.
Derived from the Git-managed `init.el' location."
  :type 'directory
  :group '+emacs)

(defcustom +emacs/org-root-dir (expand-file-name "~/opt/org-root")
  "Path to the org-root folder."
  :type 'directory
  :group '+emacs)

(defcustom +emacs/proxy "127.0.0.1:10808"
  "HTTP/HTTPS proxy host:port used for URL access."
  :type 'string
  :group '+emacs)

(defcustom +emacs/theme 'zenburn
  "Theme loaded after the feature modules, or nil to load no theme."
  :type '(choice (const :tag "Do not load a theme" nil) symbol)
  :group '+emacs)

(defcustom +emacs/email-address nil
  "Primary email address used by the email module.
Set this in `init.el' when mail support is configured."
  :type '(choice (const :tag "Not configured" nil) string)
  :group '+emacs)

(defcustom +emacs/email-full-name nil
  "Full name used in messages sent by the email module.
Set this in `init.el' when mail support is configured."
  :type '(choice (const :tag "Not configured" nil) string)
  :group '+emacs)

(defcustom +emacs/email-maildir
  (expand-file-name "mail/outlook" (or (getenv "XDG_DATA_HOME") "~/.local/share"))
  "Local Maildir root used by mbsync and mu4e.
Set this in `init.el' when the machine uses a different local mail location."
  :type 'directory
  :group '+emacs)

(defcustom +emacs/mu4e-load-path nil
  "Optional directory containing the system-installed mu4e Lisp files.
Set this in `init.el' when mu4e is installed outside Emacs' default
`load-path'.  Use `+emacs/detect-mu4e-load-path' for automatic
detection based on the `mu' binary location."
  :type '(choice (const :tag "Use default load-path" nil) directory)
  :group '+emacs)

(defun +emacs/detect-mu4e-load-path ()
  "Auto-detect the mu4e Lisp directory from the `mu' binary location.
Returns nil when the mu binary is not found or no mu4e directory
exists at the expected location."
  (when-let* ((mu-bin (executable-find "mu")))
    (let* ((prefix (file-name-directory
                    (directory-file-name
                     (file-name-directory mu-bin))))
           (candidates
            (list (expand-file-name "share/emacs/site-lisp/mu/mu4e" prefix)
                  (expand-file-name "share/emacs/site-lisp/mu4e" prefix))))
      (seq-find #'file-directory-p candidates))))

(provide 'core-vars)
;;; core-vars.el ends here
