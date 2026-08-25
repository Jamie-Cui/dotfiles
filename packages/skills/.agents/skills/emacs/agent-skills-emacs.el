;;; agent-skills-emacs.el --- Emacs helpers for skills -*- lexical-binding: t; -*-

(require 'cl-lib)

(declare-function ert-select-tests "ert" (selector universe))
(declare-function ert-test-name "ert" (cl-x))
(declare-function ert-stats-completed-expected "ert" (cl-x))
(declare-function ert-stats-completed-unexpected "ert" (cl-x))
(declare-function ert-stats-skipped "ert" (cl-x))
(declare-function +org/use-default-cite-fontification-on-remote-h "init-org" ())

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

(defun agent-skills--buffer-visiting-file (path)
  "Return the live buffer visiting PATH without contacting PATH's host."
  (unless (and (stringp path)
               (> (length path) 0)
               (<= (length path) 4096))
    (error "Invalid file path: %S" path))
  (cl-find-if
   (lambda (buffer)
     (with-current-buffer buffer
       (equal buffer-file-name path)))
   (buffer-list)))

(defun agent-skills--symbol-hook-members (hook)
  "Return the named functions in HOOK's current buffer-local value."
  (let ((value (and (boundp hook) (symbol-value hook))))
    (mapcar #'symbol-name
            (cl-remove-if-not
             (lambda (member)
               (and (symbolp member) (not (eq member t))))
             (if (listp value) value (list value))))))

(cl-defun agent-skills/file-buffer-state (path)
  "Return read-only runtime metadata for the live buffer visiting PATH.

This does not visit PATH, switch windows, or expose buffer text."
  (let ((buffer (agent-skills--buffer-visiting-file path)))
    (if (not (buffer-live-p buffer))
        (format "No live buffer is visiting: %s" path)
      (with-current-buffer buffer
        (let* ((windows (get-buffer-window-list buffer nil t))
               (mode-flags
                (mapcar
                 (lambda (mode)
                   (cons mode (and (boundp mode) (symbol-value mode))))
                 '(evil-local-mode
                   visual-line-mode
                   font-lock-mode
                   org-indent-mode
                   org-appear-mode
                   pangu-spacing-mode
                   xenops-mode
                   cursor-sensor-mode
                   smartparens-mode
                   flycheck-mode
                   eldoc-mode
                   eldoc-box-hover-at-point-mode)))
               (overlays (overlays-in (point-min) (point-max)))
               (pangu-overlays
                (cl-count-if
                 (lambda (overlay)
                   (overlay-get overlay 'pangu-spacing-overlay))
                 overlays))
               (xenops-overlays
                (cl-count-if
                 (lambda (overlay)
                   (overlay-get overlay 'xenops-overlay-type))
                 overlays)))
          (format (concat
                   "Buffer: %s\nMode: %s\nFile: %s\n"
                   "Point: %d\nLine: %d\nColumn: %d\n"
                   "Size: %d\nModified: %S\nNarrowed: %S\n"
                   "Displayed windows: %d\nMode flags: %S\n"
                   "Org/runtime options: %S\n"
                   "Overlays: total=%d pangu=%d xenops=%d\n"
                   "pre-command-hook: %S\npost-command-hook: %S\n"
                   "window-scroll-functions: %S\n"
                   "pre-redisplay-functions: %S\n"
                   "jit-lock-functions: %S")
                  (buffer-name)
                  major-mode
                  buffer-file-name
                  (point)
                  (line-number-at-pos)
                  (current-column)
                  (buffer-size)
                  (buffer-modified-p)
                  (buffer-narrowed-p)
                  (length windows)
                  mode-flags
                  (mapcar
                   (lambda (option)
                     (cons option
                           (and (boundp option) (symbol-value option))))
                   '(org-element-use-cache
                     org-hide-emphasis-markers
                     org-startup-with-inline-images
                     pangu-spacing-real-insert-separtor
                     word-wrap-by-category
                     flycheck-checker))
                  (length overlays)
                  pangu-overlays
                  xenops-overlays
                  (agent-skills--symbol-hook-members 'pre-command-hook)
                  (agent-skills--symbol-hook-members 'post-command-hook)
                  (agent-skills--symbol-hook-members 'window-scroll-functions)
                  (agent-skills--symbol-hook-members 'pre-redisplay-functions)
                  (agent-skills--symbol-hook-members 'jit-lock-functions)))))))

(cl-defun agent-skills/file-buffer-key-binding-state (path key)
  "Report the effective bindings for KEY in the live buffer visiting PATH."
  (unless (and (stringp key)
               (> (length key) 0)
               (<= (length key) 64))
    (error "Invalid key description: %S" key))
  (let ((buffer (agent-skills--buffer-visiting-file path))
        (sequence (kbd key)))
    (if (not (buffer-live-p buffer))
        (format "No live buffer is visiting: %s" path)
      (with-current-buffer buffer
        (format (concat "Buffer: %s\nMode: %s\nKey: %s\n"
                        "Effective: %S\nLocal: %S\nGlobal: %S")
                (buffer-name)
                major-mode
                (key-description sequence)
                (key-binding sequence)
                (local-key-binding sequence)
                (global-key-binding sequence))))))

(cl-defun agent-skills/org-file-buffer-parser-timings (path &optional iterations)
  "Time fixed Org point-context readers in the live buffer visiting PATH.

ITERATIONS defaults to 20 and is capped at 100.  This helper does not execute
interactive commands, switch windows, or expose buffer text."
  (let ((buffer (agent-skills--buffer-visiting-file path))
        (iterations (or iterations 20)))
    (unless (and (integerp iterations) (> iterations 0) (<= iterations 100))
      (error "Invalid iteration count: %S" iterations))
    (if (not (buffer-live-p buffer))
        (format "No live buffer is visiting: %s" path)
      (with-current-buffer buffer
        (unless (derived-mode-p 'org-mode)
          (error "Buffer is not in Org mode: %s" (buffer-name)))
        (require 'benchmark)
        (let (results)
          (dolist (function '(org-element-context
                              org-appear--current-elem
                              fn/xenops-math-inline-editing-element))
            (when (fboundp function)
              (let ((timing
                     (benchmark-run iterations
                       (save-excursion (funcall function)))))
                (push (cons function timing) results))))
          (format "Buffer: %s\nPoint: %d\nIterations: %d\nTimings: %S"
                  (buffer-name) (point) iterations (nreverse results)))))))

(cl-defun agent-skills/org-file-buffer-citation-state (path &optional iterations)
  "Report and time Basic Org citation metadata for the buffer visiting PATH.

ITERATIONS defaults to 3 and is capped at 10.  The bibliography is checked
read-only through Org's normal Basic citation path; bibliography contents are
not returned."
  (let ((buffer (agent-skills--buffer-visiting-file path))
        (iterations (or iterations 3)))
    (unless (and (integerp iterations) (> iterations 0) (<= iterations 10))
      (error "Invalid iteration count: %S" iterations))
    (if (not (buffer-live-p buffer))
        (format "No live buffer is visiting: %s" path)
      (with-current-buffer buffer
        (unless (derived-mode-p 'org-mode)
          (error "Buffer is not in Org mode: %s" (buffer-name)))
        (require 'benchmark)
        (require 'oc)
        (let* ((files (org-cite-list-bibliography-files))
               (file-state
                (mapcar
                 (lambda (file)
                   (let ((resolved (expand-file-name file default-directory)))
                     (list
                      :file file
                      :resolved resolved
                      :remote (and (file-remote-p resolved) t)
                      :truename
                      (benchmark-run iterations (file-truename resolved))
                      :readable
                      (benchmark-run iterations (file-readable-p resolved))
                      :changed-check
                      (benchmark-run iterations (file-has-changed-p resolved)))))
                 files))
               (timing
                (when (and (eq org-cite-activate-processor 'basic)
                           (require 'oc-basic nil t))
                  (benchmark-run iterations
                    (org-cite-basic--parse-bibliography)))))
          (format (concat "Buffer: %s\nActivate processor: %S\n"
                          "Bibliography files: %S\nIterations: %d\n"
                          "Basic parse/check timing: %S")
                  (buffer-name)
                  org-cite-activate-processor
                  file-state
                  iterations
                  timing))))))

(cl-defun agent-skills/apply-remote-org-cite-fontification (path)
  "Apply the configured lightweight citation activation to remote Org PATH.

The live buffer must already visit PATH.  This preserves point and buffer text;
it only updates the buffer-local activation processor and flushes fontification
so the new setting is used on the next redisplay."
  (let ((buffer (agent-skills--buffer-visiting-file path)))
    (if (not (buffer-live-p buffer))
        (format "No live buffer is visiting: %s" path)
      (with-current-buffer buffer
        (unless (derived-mode-p 'org-mode)
          (error "Buffer is not in Org mode: %s" (buffer-name)))
        (unless (file-remote-p (or buffer-file-name default-directory))
          (error "Buffer is not remote: %s" (buffer-name)))
        (unless (fboundp '+org/use-default-cite-fontification-on-remote-h)
          (error "Remote Org citation configuration is not loaded"))
        (let ((origin (point))
              (modified (buffer-modified-p)))
          (+org/use-default-cite-fontification-on-remote-h)
          (when (and font-lock-mode (fboundp 'font-lock-flush))
            (font-lock-flush))
          (format (concat "Buffer: %s\nPoint preserved: %S\n"
                          "Modified preserved: %S\n"
                          "org-cite-activate-processor=%S")
                  (buffer-name)
                  (= origin (point))
                  (eq modified (buffer-modified-p))
                  org-cite-activate-processor))))))

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

(cl-defun agent-skills/key-binding-state (key)
  "Report the effective, local, and global bindings for KEY.

KEY must be a textual key description accepted by `kbd'.  The lookup is
read-only and runs in the buffer shown in the selected window."
  (unless (and (stringp key)
               (> (length key) 0)
               (<= (length key) 64))
    (error "Invalid key description: %S" key))
  (let* ((sequence (kbd key))
         (buffer (window-buffer (selected-window))))
    (with-current-buffer buffer
      (format (concat "Buffer: %s\nMode: %s\nKey: %s\n"
                      "Effective: %S\nLocal: %S\nGlobal: %S\n"
                      "general-override-mode: %S\n"
                      "general-override-map: %S")
              (buffer-name)
              major-mode
              (key-description sequence)
              (key-binding sequence)
              (local-key-binding sequence)
              (global-key-binding sequence)
              (and (boundp 'general-override-mode)
                   general-override-mode)
              (and (boundp 'general-override-mode-map)
                   (lookup-key general-override-mode-map sequence))))))

(provide 'agent-skills/emacs)
