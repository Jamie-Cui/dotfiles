;;; agent-skills-emacs.el --- Emacs helpers for skills -*- lexical-binding: t; -*-

(require 'cl-lib)

(declare-function ert-select-tests "ert" (selector universe))
(declare-function ert-test-name "ert" (cl-x))
(declare-function ert-stats-completed-expected "ert" (cl-x))
(declare-function ert-stats-completed-unexpected "ert" (cl-x))
(declare-function ert-stats-skipped "ert" (cl-x))

(defconst agent-skills--allowed-special-buffers
  '("*Messages*" "*Warnings*" "*Backtrace*" "*Compile-Log*" "*ERT*"
    "*magent*" "*magent-log*")
  "Special buffers that may be inspected through `agent-skills/special-buffer'.")

(defun agent-skills--readable-buffer-string (buffer limit)
  "Return up to LIMIT characters from BUFFER, capped at 4000."
  (with-current-buffer buffer
    (let ((max-chars (min (or limit 3000) 4000)))
      (buffer-substring-no-properties
       (point-min)
       (min (point-max) (+ (point-min) max-chars))))))

(cl-defun agent-skills/list-functions (prefix)
  "Return a list of interactive function names matching PREFIX."
  (let (result)
    (mapatoms
     (lambda (sym)
       (when (and (fboundp sym)
                  (commandp sym)
                  (string-prefix-p prefix (symbol-name sym)))
         (push (symbol-name sym) result))))
    (sort result #'string<)))

(cl-defun agent-skills/describe-function (name)
  "Return the docstring and argument list for function NAME."
  (let ((sym (intern-soft name)))
    (unless (and sym (fboundp sym))
      (error "Function %s is not defined" name))
    (let ((arglist (help-function-arglist sym t))
          (docstring (documentation sym t)))
      (format "(%s %s)\n\n%s"
              name
              (if arglist (mapconcat #'symbol-name arglist " ") "")
              (or docstring "No documentation available.")))))

(cl-defun agent-skills/byte-compile-file (path)
  "Byte-compile PATH and return warnings and status."
  (let* ((target (expand-file-name path))
         (log-buffer (get-buffer-create "*Compile-Log*")))
    (with-current-buffer log-buffer
      (let ((inhibit-read-only t))
        (erase-buffer)))
    (byte-compile-file target)
    (let ((log-output
           (if (buffer-live-p log-buffer)
               (agent-skills--readable-buffer-string log-buffer 4000)
             "")))
      (format "Byte-compiled: %s\n%s"
              target
              (if (equal log-output "")
                  "Compile log is empty."
                log-output)))))

(cl-defun agent-skills/run-ert (selector)
  "Run ERT tests matching SELECTOR regexp or prefix."
  (require 'ert)
  (let* ((pattern (or selector ""))
         (tests
          (ert-select-tests
           (lambda (test)
             (string-match-p pattern (symbol-name (ert-test-name test))))
           t))
         (results-buffer (get-buffer-create "*ERT*")))
    (with-current-buffer results-buffer
      (let ((inhibit-read-only t))
        (erase-buffer)))
    (if (null tests)
        (format "No ERT tests matched: %s" pattern)
      (let ((stats (ert-run-tests-batch tests)))
        (format "ERT selector: %s\nPassed: %d\nFailed: %d\nSkipped: %d"
                pattern
                (ert-stats-completed-expected stats)
                (ert-stats-completed-unexpected stats)
                (ert-stats-skipped stats))))))

(cl-defun agent-skills/current-buffer-state ()
  "Return metadata for the user's focused buffer without buffer text."
  (let ((buf (window-buffer (selected-window))))
    (with-current-buffer buf
      (let ((name (buffer-name))
            (mode (symbol-name major-mode))
            (point (point))
            (line (line-number-at-pos))
            (column (current-column))
            (file (or buffer-file-name ""))
            (narrowed (buffer-narrowed-p))
            (region-active (use-region-p)))
        (format "Buffer: %s\nMode: %s\nFile: %s\nPoint: %d\nLine: %d\nColumn: %d\nNarrowed: %S\nRegion active: %S"
                name mode file point line column narrowed region-active)))))

(cl-defun agent-skills/buffer-count ()
  "Return the number of live buffers without exposing their contents."
  (length (buffer-list)))

(cl-defun agent-skills/special-buffer (name &optional limit)
  "Return a bounded excerpt of an allowlisted special buffer NAME."
  (unless (member name agent-skills--allowed-special-buffers)
    (error "Buffer is not in the special-buffer allowlist: %s" name))
  (let ((buffer (get-buffer name)))
    (if (not (buffer-live-p buffer))
        (format "Buffer not found: %s" name)
      (format "Buffer: %s\n---\n%s"
              name
              (agent-skills--readable-buffer-string buffer limit)))))

(cl-defun agent-skills/toggle-debug-on-error (&optional value)
  "Set `debug-on-error' to VALUE and report the result."
  (setq debug-on-error (if (null value) (not debug-on-error) value))
  (format "debug-on-error=%S" debug-on-error))

(cl-defun agent-skills/toggle-debug-on-quit (&optional value)
  "Set `debug-on-quit' to VALUE and report the result."
  (setq debug-on-quit (if (null value) (not debug-on-quit) value))
  (format "debug-on-quit=%S" debug-on-quit))

(cl-defun agent-skills/configure-url-proxy (proxy)
  "Configure Emacs URL access to use HTTP/HTTPS PROXY and report the result."
  (unless (and (stringp proxy)
               (string-match-p
                "\\`[[:alnum:]._-]+:[[:digit:]]+\\'" proxy))
    (error "Invalid proxy host and port: %S" proxy))
  (require 'url-vars)
  (dolist (scheme '("http" "https"))
    (setf (alist-get scheme url-proxy-services nil nil #'string=) proxy))
  (format "Configured HTTP/HTTPS proxy: %s" proxy))

(cl-defun agent-skills/package-refresh-contents ()
  "Refresh package archive metadata and report the available package count."
  (require 'package)
  (package-refresh-contents)
  (format "Refreshed package archives; available packages: %d"
          (length package-archive-contents)))

(cl-defun agent-skills/package-install (names)
  "Install packages named by the list of strings NAMES and report their state."
  (require 'package)
  (dolist (name names)
    (unless (and (stringp name)
                 (string-match-p "\\`[[:alnum:]-]+\\'" name))
      (error "Invalid package name: %S" name))
    (package-install (intern name)))
  (mapconcat
   (lambda (name)
     (format "%s=%s" name
             (if (package-installed-p (intern name)) "installed" "missing")))
   names "\n"))

(cl-defun agent-skills/package-reinstall (names)
  "Reinstall packages named by the list of strings NAMES and report their state."
  (require 'package)
  (dolist (name names)
    (unless (and (stringp name)
                 (string-match-p "\\`[[:alnum:]-]+\\'" name))
      (error "Invalid package name: %S" name))
    (package-reinstall (intern name)))
  (mapconcat
   (lambda (name)
     (format "%s=%s" name
             (if (package-installed-p (intern name)) "installed" "missing")))
   names "\n"))

(cl-defun agent-skills/reload-user-init ()
  "Reload `user-init-file' and report the loaded path."
  (unless (and user-init-file (file-readable-p user-init-file))
    (error "User init file is not readable: %S" user-init-file))
  (load user-init-file nil nil t)
  (format "Reloaded user init: %s" user-init-file))

(cl-defun agent-skills/feature-state (feature-name)
  "Report whether FEATURE-NAME is loaded."
  (let* ((sym (intern-soft feature-name))
         (loaded (and sym (featurep sym))))
    (format "feature=%s loaded=%S" feature-name loaded)))

(cl-defun agent-skills/symbol-state (name)
  "Report function and variable state for symbol NAME without raw values."
  (let* ((sym (intern-soft name))
         (fbound (and sym (fboundp sym)))
         (bound (and sym (boundp sym)))
         (value-type (if bound (type-of (symbol-value sym)) :unbound)))
    (format "symbol=%s exists=%S fboundp=%S boundp=%S value-type=%S"
            name (not (null sym)) fbound bound value-type)))

(provide 'agent-skills/emacs)
