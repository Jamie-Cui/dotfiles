;;; agent-skills-emacs.el --- Emacs helpers for skills -*- lexical-binding: t; -*-

;;; Commentary:
;; Fixed, scoped operations for inspecting and refreshing a live Emacs session.
;; Diagnostic helpers report metadata or bounded, allowlisted buffer excerpts.
;;; Code:

(require 'cl-lib)

(declare-function ert-select-tests "ert" (selector universe))
(declare-function ert-stats-completed-expected "ert" (cl-x))
(declare-function ert-stats-completed-unexpected "ert" (cl-x))
(declare-function ert-stats-skipped "ert" (cl-x))
(declare-function +org/use-default-cite-fontification-on-remote-h
                  "modules/lang/org" ())

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
         (tests (ert-select-tests pattern t))
         (results-buffer (get-buffer-create "*ERT*")))
    (with-current-buffer results-buffer
      (let ((inhibit-read-only t))
        (erase-buffer)))
    (if (null tests)
        (format "No ERT tests matched: %s" pattern)
      (let ((stats (ert-run-tests-batch pattern)))
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

(cl-defun agent-skills/buffer-directory-state (directory)
  "Report metadata for buffers whose working directory equals DIRECTORY.
Also report the focused buffer's working directory without visiting files."
  (let ((target (file-name-as-directory (expand-file-name directory))))
    (list :directory target
          :exists (file-directory-p target)
          :focused-directory
          (buffer-local-value 'default-directory
                              (window-buffer (selected-window)))
          :buffers
          (cl-loop for buffer in (buffer-list)
                   when (equal (buffer-local-value 'default-directory buffer)
                               target)
                   collect (with-current-buffer buffer
                             (list :name (buffer-name)
                                   :mode major-mode
                                   :file buffer-file-name))))))

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

(cl-defun agent-skills/revert-unmodified-file-buffer (path)
  "Revert the live buffer visiting PATH only when it has no unsaved changes.

Preserve the buffer's point as closely as the new file size permits.  Refuse to
revert modified buffers so external file updates cannot discard user edits."
  (let ((buffer (agent-skills--buffer-visiting-file path)))
    (if (not (buffer-live-p buffer))
        (format "No live buffer is visiting: %s" path)
      (with-current-buffer buffer
        (when (buffer-modified-p)
          (error "Refusing to revert modified buffer: %s" (buffer-name)))
        (let ((origin-line (line-number-at-pos))
              (origin-column (current-column)))
          (revert-buffer t t t)
          (goto-char (point-min))
          (forward-line (1- origin-line))
          (move-to-column origin-column)
          (format (concat "Buffer: %s\nFile: %s\nReverted: yes\n"
                          "Point: %d\nLine: %d\nSize: %d\nModified: %S")
                  (buffer-name)
                  buffer-file-name
                  (point)
                  (line-number-at-pos)
                  (buffer-size)
                  (buffer-modified-p)))))))

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

(declare-function image-mode-window-get "image-mode" (prop &optional window))
(declare-function +lang-c-cpp/auto-mode-setup-h "modules/lang/c-cpp" ())
(declare-function +lang-cmake/auto-mode-setup-h "modules/lang/cmake" ())
(defvar +emacs/repo-directory)

(defun agent-skills/pdf-language-state ()
  "Report viewer integration and PDF buffer metadata without document text."
  (list
   :features
   (mapcar (lambda (feature) (cons feature (featurep feature)))
           '(init-pdf init-lang-latex pdf-tools tex git-overleaf))
   :definitions
   (mapcar (lambda (symbol) (cons symbol (symbol-file symbol 'defun)))
           '(+latex/roll-setup +latex/pdf-tools-sync-view
             +prog/flycheck-c++20-h))
   :settings
   (mapcar (lambda (symbol)
             (cons symbol (if (boundp symbol) (symbol-value symbol) :unbound)))
           '(TeX-view-program-selection TeX-view-program-list
             TeX-source-correlate-start-server pdf-sync-forward-display-action
             pdf-sync-backward-search-method))
   :hook-counts
   (mapcar (lambda (entry)
             (cons (car entry)
                   (if (boundp (car entry))
                       (cl-count (cdr entry) (symbol-value (car entry)))
                     0)))
           '((pdf-view-mode-hook . +latex/roll-setup)
             (LaTeX-mode-hook . TeX-source-correlate-mode)
             (TeX-after-compilation-finished-functions
              . TeX-revert-document-buffer)))
   :advice-counts
   (mapcar (lambda (entry)
             (let ((count 0))
               (advice-mapc (lambda (fn _props)
                             (when (eq fn (cdr entry)) (cl-incf count)))
                           (car entry))
               (cons (car entry) count)))
           '((pdf-roll-pre-redisplay . +latex/roll-pre-redisplay-a)
             (ultra-scroll . +latex/roll-ultra-scroll-a)
             (ultra-scroll-mac . +latex/roll-ultra-scroll-a)))
   :pdf-buffers
   (cl-loop for buffer in (buffer-list)
            when (with-current-buffer buffer (derived-mode-p 'pdf-view-mode))
            collect
            (with-current-buffer buffer
              (list :name (buffer-name) :file buffer-file-name
                    :modified (buffer-modified-p)
                    :roll (bound-and-true-p pdf-view-roll-minor-mode)
                    :visible-pages
                    (mapcar (lambda (window)
                              (image-mode-window-get 'page window))
                            (get-buffer-window-list buffer nil t)))))))

(defun agent-skills/reload-language-viewer-modules ()
  "Reload the fixed language/viewer module set without replaying all of init.
Refuse unsaved module buffers.  Existing PDF buffers are not reverted, and
general editing, VC, package startup and after-init hooks are not replayed."
  (unless (and (boundp '+emacs/repo-directory)
               (stringp +emacs/repo-directory)
               (file-directory-p +emacs/repo-directory))
    (user-error "The managed Emacs configuration root is unavailable"))
  (let ((files
         (mapcar (lambda (name)
                   (expand-file-name (concat "lisp/modules/" name ".el")
                                     +emacs/repo-directory))
                 '("lang/c-cpp" "lang/rust" "lang/python" "lang/cmake"
                   "lang/latex" "pdf"))))
    (dolist (file files)
      (unless (file-readable-p file)
        (user-error "Module is not readable: %s" file))
      (when-let* ((buffer (get-file-buffer file)))
        (when (buffer-modified-p buffer)
          (user-error "Module has unsaved edits: %s" file))))
    (save-window-excursion
      (save-excursion
        (dolist (file files)
          (load file nil t t))
        (+lang-c-cpp/auto-mode-setup-h)
        (+lang-cmake/auto-mode-setup-h)))
    (agent-skills/pdf-language-state)))

(defun agent-skills/reload-files-module ()
  "Reload the managed files module and report the Dired home binding."
  (unless (and (boundp '+emacs/repo-directory)
               (stringp +emacs/repo-directory))
    (user-error "The managed Emacs configuration root is unavailable"))
  (let ((file (expand-file-name "lisp/modules/files.el"
                                +emacs/repo-directory)))
    (when-let* ((buffer (get-file-buffer file)))
      (when (buffer-modified-p buffer)
        (user-error "Module has unsaved edits: %s" file)))
    (save-window-excursion
      (save-excursion
        (load file nil t t))))
  (agent-skills/key-binding-state "~"))

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

(defun agent-skills/org-project-caldav-state ()
  "Report live CalDAV paths, task IDs and cycle state without credentials."
  (unless (featurep 'org-project-caldav)
    (error "Org project CalDAV is not loaded"))
  (let* ((files (org-project-caldav--source-files))
         (state (org-project-caldav--load-state))
         (index (org-project-caldav--active-task-index files)))
    (list
     :settings
     (mapcar (lambda (symbol)
               (cons symbol (and (boundp symbol) (symbol-value symbol))))
             '(+org-project-root-dir +org-projects-dir org-journal-dir
               org-journal-enable-agenda-integration org-agenda-files
               org-project-caldav-vdir-directory org-project-caldav-mode
               org-project-caldav--running org-project-caldav--last-error
               org-project-caldav--last-success org-project-caldav--last-result))
     :library (symbol-file 'org-project-caldav-sync 'defun)
     :sources files
     :modified-buffers
     (mapcar #'buffer-name (org-project-caldav--modified-source-buffers))
     :active-tasks index
     :previous-sources (plist-get state :source-files)
     :previous-tasks
     (mapcar (lambda (entry) (list (car entry) (nth 4 entry)))
             (plist-get state :entries))
     :vdir-uids (mapcar #'car (org-project-caldav--vdir-index)))))

(defun agent-skills/reload-org-project-caldav ()
  "Reload the CalDAV library while idle, preserving timers and sync state."
  (unless (featurep 'org-project-caldav)
    (error "Org project CalDAV is not loaded"))
  (when (bound-and-true-p org-project-caldav--running)
    (error "CalDAV synchronization is currently active"))
  (load (locate-library "org-project-caldav.el") nil t t)
  (list :library (symbol-file 'org-project-caldav-sync 'defun)
        :reloaded t))

(defun agent-skills/org-project-caldav-sync (approved-removals)
  "Reload CalDAV, back up local data, and sync APPROVED-REMOVALS once.
APPROVED-REMOVALS must exactly match the reviewed missing paths and task IDs.
Return the recovery directory and immediate cycle status."
  (when (bound-and-true-p org-project-caldav--running)
    (error "CalDAV synchronization is currently active"))
  (load (locate-library "org-project-caldav.el") nil t t)
  (org-project-caldav--assert-saved)
  (let* ((files (org-project-caldav--source-files))
         (actual (org-project-caldav--source-removals
                  (org-project-caldav--load-state) files
                  (org-project-caldav--active-task-index files t)))
         (backup (make-temp-file "org-project-caldav-recovery-" t)))
    (unless (equal approved-removals actual)
      (error "CalDAV removals changed since review: %S" actual))
    (copy-directory +org-project-root-dir
                    (expand-file-name "org" backup) nil nil t)
    (copy-directory org-project-caldav-vdir-directory
                    (expand-file-name "vdir" backup) nil nil t)
    (when (file-exists-p (org-project-caldav--legacy-state-file))
      (copy-file (org-project-caldav--legacy-state-file)
                 (expand-file-name "legacy-state.el" backup)))
    (org-project-caldav-sync approved-removals)
    (list :backup backup :status (org-project-caldav-status))))

(cl-defun agent-skills/migrate-org-project-data
    (legacy-root target-root duplicate-ids old-project-root)
  "Migrate legacy Org project data into TARGET-ROOT.

Copy the `projects' and `journal' directories below LEGACY-ROOT, remove from
the live CalDAV inbox the task subtrees named by DUPLICATE-IDS, rewrite
references below OLD-PROJECT-ROOT to the new projects directory, refresh Org
ID locations, and validate the resulting active-task inventory.  Refuse to
run while CalDAV synchronization is active or while the inbox has unsaved
changes."
  (require 'org)
  (require 'org-id)
  (require 'org-project-caldav)
  (dolist (directory (list legacy-root target-root old-project-root))
    (unless (and (stringp directory)
                 (file-name-absolute-p directory)
                 (not (file-remote-p directory)))
      (error "Expected an absolute local directory, got: %S" directory)))
  (unless (and (listp duplicate-ids)
               duplicate-ids
               (cl-every
                (lambda (id)
                  (and (stringp id)
                       (string-match-p
                        "\\`[[:xdigit:]]\\{8\\}\\(?:-[[:xdigit:]]+\\)\\{4\\}\\'"
                        id)))
                duplicate-ids))
    (error "Invalid duplicate Org ID list: %S" duplicate-ids))
  (let* ((legacy-projects (expand-file-name "projects" legacy-root))
         (legacy-journal (expand-file-name "journal" legacy-root))
         (target-projects +org-projects-dir)
         (target-journal (expand-file-name "journal" target-root))
         (inbox (expand-file-name "inbox.org" target-root))
         (source-project-files
          (and (file-directory-p legacy-projects)
               (directory-files legacy-projects t "\\.org\\'")))
         (source-journal-files
          (and (file-directory-p legacy-journal)
               (directory-files legacy-journal t "\\.org\\'")))
         (inbox-buffer (find-buffer-visiting inbox))
         (mode-was-enabled (bound-and-true-p org-project-caldav-mode))
         created-files
         inbox-original
         inbox-point
         removed-count
         active-count)
    (unless (and (file-directory-p legacy-projects)
                 (file-directory-p legacy-journal)
                 (= (length source-project-files) 9)
                 (= (length source-journal-files) 6))
      (error "Unexpected legacy layout: projects=%d journal=%d"
             (length source-project-files) (length source-journal-files)))
    (unless (and (file-directory-p target-root)
                 (file-equal-p target-root +org-project-root-dir)
                 (file-equal-p target-projects +org-projects-dir)
                 (file-readable-p inbox))
      (error "Target does not match the live org-project configuration"))
    (when (or (and (processp org-project-caldav--process)
                   (process-live-p org-project-caldav--process))
              org-project-caldav--running)
      (error "CalDAV synchronization is currently active"))
    (dolist (directory (list target-projects target-journal))
      (when (directory-files directory nil "\\.org\\'")
        (error "Target directory is not empty: %s" directory)))
    (unless (buffer-live-p inbox-buffer)
      (setq inbox-buffer (find-file-noselect inbox t)))
    (with-current-buffer inbox-buffer
      (when (buffer-modified-p)
        (error "Refusing to migrate with an unsaved inbox buffer"))
      (setq inbox-original (buffer-substring-no-properties
                            (point-min) (point-max))
            inbox-point (point)))
    (cl-labels
        ((scan-current-org-buffer
          (function)
          (save-excursion
            (save-restriction
              (widen)
              (goto-char (point-min))
              (while (re-search-forward org-outline-regexp-bol nil t)
                (goto-char (match-beginning 0))
                (funcall function)
                (forward-line 1)))))
         (id-count-in-files
          (id files)
          (let ((count 0))
            (dolist (file files count)
              (with-temp-buffer
                (insert-file-contents file)
                (let ((delay-mode-hooks t))
                  (org-mode))
                (scan-current-org-buffer
                 (lambda ()
                   (when (equal (org-entry-get nil "ID") id)
                     (setq count (1+ count)))))))))
         (rewrite-project-paths
          (file)
          (let ((old-absolute (directory-file-name old-project-root))
                (old-abbreviated
                 (directory-file-name
                  (abbreviate-file-name old-project-root)))
                (new-absolute (directory-file-name target-projects)))
            (with-temp-buffer
              (insert-file-contents file)
              (dolist (old (delete-dups
                            (list old-absolute old-abbreviated)))
                (goto-char (point-min))
                (while (search-forward old nil t)
                  (replace-match new-absolute t t)))
              (write-region (point-min) (point-max) file nil 'silent)))))
      (dolist (id duplicate-ids)
        (unless (= (id-count-in-files id source-project-files) 1)
          (error "Expected duplicate ID once in legacy projects: %s" id)))
      (with-current-buffer inbox-buffer
        (let ((inbox-id-counts (make-hash-table :test #'equal)))
          (scan-current-org-buffer
           (lambda ()
             (when-let* ((id (org-entry-get nil "ID"))
                         ((member id duplicate-ids)))
               (puthash id (1+ (gethash id inbox-id-counts 0))
                        inbox-id-counts))))
          (dolist (id duplicate-ids)
            (unless (= (gethash id inbox-id-counts 0) 1)
              (error "Expected duplicate ID once in current inbox: %s" id)))))
      (when mode-was-enabled
        (org-project-caldav-mode -1))
      (unwind-protect
          (condition-case err
              (progn
                (dolist (pair `((,source-project-files . ,target-projects)
                                (,source-journal-files . ,target-journal)))
                  (dolist (source (car pair))
                    (let ((target (expand-file-name
                                   (file-name-nondirectory source)
                                   (cdr pair))))
                      (copy-file source target nil t nil t)
                      (push target created-files)
                      (rewrite-project-paths target))))
                (with-current-buffer inbox-buffer
                  (let (positions)
                    (scan-current-org-buffer
                     (lambda ()
                       (when (member (org-entry-get nil "ID") duplicate-ids)
                         (push (point) positions))))
                    (dolist (position (sort positions #'>))
                      (goto-char position)
                      (let ((begin (line-beginning-position))
                            (end (save-excursion
                                   (org-end-of-subtree t t))))
                        (delete-region begin end)
                        (setq removed-count (1+ (or removed-count 0)))))
                    (goto-char (min inbox-point (point-max)))
                    (save-buffer)))
                (let ((org-caldav-save-buffers t)
                      (source-files (org-project-caldav--source-files)))
                  (dolist (file source-files)
                    (org-project-caldav--create-leaf-uids file))
                  (setq active-count
                        (length
                         (org-project-caldav--active-task-index source-files)))
                  (org-id-update-id-locations source-files))
                (when (and (boundp 'dashboard-buffer-name)
                           (get-buffer dashboard-buffer-name)
                           (fboundp 'dashboard-insert-startupify-lists))
                  (with-current-buffer (get-buffer dashboard-buffer-name)
                    (let ((origin (point)))
                      (dashboard-insert-startupify-lists t)
                      (goto-char (min origin (point-max))))))
                (format
                 (concat "Migrated projects=%d journal=%d; "
                         "moved-from-inbox=%d; active-tasks=%d")
                 (length source-project-files)
                 (length source-journal-files)
                 removed-count
                 active-count))
            (error
             (with-current-buffer inbox-buffer
               (let ((inhibit-read-only t))
                 (erase-buffer)
                 (insert inbox-original)
                 (goto-char (min inbox-point (point-max)))
                 (save-buffer)))
             (dolist (file created-files)
               (when (file-exists-p file)
                 (delete-file file)))
             (signal (car err) (cdr err))))
        (when mode-was-enabled
          (org-project-caldav-mode 1))))))

(defun agent-skills/org-babel-latex-state ()
  "Report the live LaTeX Babel configuration and required executables."
  (require 'ob-latex)
  (require 'ox-latex)
  (list :compiler org-latex-compiler
        :pdf-process org-latex-pdf-process
        :svg-process org-babel-latex-pdf-svg-process
        :protocol-defined
        (cl-some (lambda (entry)
                   (and (stringp entry)
                        (string-match-p
                         (regexp-quote "\\newenvironment{protocol}") entry)))
                 org-latex-packages-alist)
        :programs
        (mapcar (lambda (name) (cons name (executable-find name)))
                '("xelatex" "latexmk" "pdftocairo" "convert"))
        :svg-supported (image-type-available-p 'svg)))

(defun agent-skills/reload-org-latex-config ()
  "Reload only the managed Org LaTeX configuration section.
Refuse unsaved edits and leave the remaining Org module untouched."
  (unless (and (boundp '+emacs/repo-directory)
               (stringp +emacs/repo-directory))
    (user-error "The managed Emacs configuration root is unavailable"))
  (let ((file (expand-file-name "lisp/modules/lang/org.el"
                                +emacs/repo-directory)))
    (when-let* ((buffer (find-buffer-visiting file)))
      (when (buffer-modified-p buffer)
        (user-error "Org module has unsaved edits: %s" file)))
    (with-temp-buffer
      (insert-file-contents file)
      (goto-char (point-min))
      (unless (re-search-forward "^;;; org-latex$" nil t)
        (error "The Org LaTeX section is missing"))
      (let ((start (point)))
        (unless (re-search-forward "^;;; org-babel$" nil t)
          (error "The end of the Org LaTeX section is missing"))
        (eval-region start (match-beginning 0)))))
  (agent-skills/org-babel-latex-state))

(defun agent-skills/render-org-latex-block (path name)
  "Execute the named LaTeX block NAME in the live Org buffer visiting PATH.
Run the normal Org C-c C-c command and save the inserted result link.
Refuse unsaved edits and preserve point, narrowing, and window selection."
  (let ((buffer (agent-skills--buffer-visiting-file path)))
    (unless (buffer-live-p buffer)
      (user-error "No live buffer is visiting: %s" path))
    (with-current-buffer buffer
      (unless (derived-mode-p 'org-mode)
        (user-error "The target buffer is not in Org mode"))
      (when (buffer-modified-p)
        (user-error "The Org buffer has unsaved edits"))
      (save-window-excursion
        (save-excursion
          (save-restriction
            (widen)
            (goto-char (point-min))
            (org-babel-goto-named-src-block name)
            (let* ((info (org-babel-get-src-block-info))
                   (file (cdr (assq :file (nth 2 info)))))
              (unless (and (equal (car info) "latex")
                           (equal (nth 4 info) name)
                           (stringp file)
                           (member (file-name-extension file) '("svg" "png" "pdf")))
                (user-error "The named block must produce a LaTeX image"))
              (org-ctrl-c-ctrl-c)
              (unless (file-exists-p file)
                (error "LaTeX did not create the expected file: %s" file))
              (save-buffer)
              (list :block name :file (expand-file-name file)
                    :bytes (file-attribute-size (file-attributes file))))))))))

(defun agent-skills/org-image-preview-state (path image-path)
  "Inspect preview overlays for IMAGE-PATH in the live Org buffer at PATH.
Return bounded display metadata without image data or document contents."
  (let ((buffer (agent-skills--buffer-visiting-file path)))
    (unless (buffer-live-p buffer)
      (user-error "No live buffer is visiting: %s" path))
    (with-current-buffer buffer
      (save-excursion
        (save-restriction
          (widen)
          (goto-char (point-min))
          (unless (search-forward (concat "[[file:" image-path "]]" ) nil t)
            (user-error "The image link was not found"))
          (let ((beg (match-beginning 0)) (end (match-end 0)))
            (list
             :point (point) :link-bounds (cons beg end)
             :colors (list :background (face-background 'default nil t)
                           :highlight (face-background 'highlight nil t)
                           :mouse-face (get-char-property (+ beg 2) 'mouse-face))
             :settings
             (mapcar (lambda (name)
                       (cons name (if (boundp name) (symbol-value name) :unbound)))
                     '(org-appear-autolinks org-link-descriptive
                       org-fold-core-style org-fold-core--isearch-reveal-p
                       buffer-invisibility-spec cursor-sensor-mode))
             :text-properties
             (mapcar
              (lambda (pos)
                (list :pos pos :invisible (invisible-p pos)
                      :properties
                      (cl-loop for (key value) on (text-properties-at pos) by #'cddr
                               when (or (memq key '(invisible display cursor-sensor-functions))
                                        (string-match-p "fold" (symbol-name key)))
                               collect (cons key
                                             (if (and (eq key 'display)
                                                      (eq (car-safe value) 'image))
                                                 :image value)))))
              (list beg (+ beg 2) (1- end)))
             :overlays
             (mapcar
              (lambda (ov)
                (let ((display (overlay-get ov 'display)))
                  (list :bounds (cons (overlay-start ov) (overlay-end ov))
                        :image (and (eq (car-safe display) 'image)
                                    (list :type (plist-get (cdr display) :type)
                                          :file (plist-get (cdr display) :file)
                                          :width (plist-get (cdr display) :width)))
                        :display-kind (car-safe display)
                        :org-image (overlay-get ov 'org-image-overlay)
                        :xenops (overlay-get ov 'xenops-overlay-type)
                        :priority (overlay-get ov 'priority)
                        :invisible (overlay-get ov 'invisible)
                        :face (overlay-get ov 'face)
                        :window (and (overlay-get ov 'window) t)
                        :cursor-sensor (overlay-get ov 'cursor-sensor-functions))))
              (overlays-in beg end)))))))))

(defun agent-skills/passphrase-input-state ()
  "Report password input metadata and stack function names, never secrets.
Do not return minibuffer text, input events, stack arguments, or process
command arguments.  Anonymous functions are represented by their type."
  (let ((window (active-minibuffer-window))
        stack)
    (mapbacktrace
     (lambda (_evaluated function _arguments _flags)
       (push (if (symbolp function) function (type-of function)) stack)))
    (list
     :minibuffer-depth (minibuffer-depth)
     :recursion-depth (recursion-depth)
     :stack-functions (nreverse stack)
     :minibuffer
     (when (window-live-p window)
       (with-current-buffer (window-buffer window)
         (list
          :selected (eq window (selected-window))
          :mode major-mode
          :read-only buffer-read-only
          :password-mode (bound-and-true-p read-passwd-mode)
          :evil-state (bound-and-true-p evil-state)
          :overriding-local-map (not (null overriding-local-map))
          :overriding-terminal-local-map
          (not (null overriding-terminal-local-map))
          :global-map-matches (eq global-map (current-global-map))
          :bindings
          (mapcar
           (lambda (key)
             (let* ((sequence (kbd key))
                    (binding (key-binding sequence)))
               (list key
                     :effective (if (symbolp binding)
                                    binding (type-of binding))
                     :global (lookup-key (current-global-map) sequence)
                     :standard (lookup-key global-map sequence))))
           '("a" "RET" "C-g" "C-]"))
          :setup-hooks
          (agent-skills--symbol-hook-members 'minibuffer-setup-hook)
          :post-command-hooks
          (agent-skills--symbol-hook-members 'post-command-hook))))
     :pinentry-mode (bound-and-true-p epg-pinentry-mode)
     :gpg-processes
     (cl-loop for process in (process-list)
              when (string-match-p "\\(?:epg\\|gpg\\)" (process-name process))
              collect (list :name (process-name process)
                            :pid (process-id process)
                            :status (process-status process))))))

(declare-function org-project-caldav--cancel-timers "org-project-caldav" ())
(declare-function org-project-caldav-mode "org-project-caldav" (&optional arg))

(defun agent-skills--finish-caldav-input-recovery ()
  "Release the outer mouse reader after the CalDAV prompt was cancelled."
  (let ((stack (plist-get (agent-skills/passphrase-input-state)
                         :stack-functions)))
    (when (and (zerop (minibuffer-depth))
               (memq 'read-key stack)
               (memq 'evil-mouse-drag-track stack))
      (top-level))))

(defun agent-skills/finish-caldav-input-recovery ()
  "Pause automatic CalDAV sync and release a remaining Evil mouse reader."
  (org-project-caldav-mode -1)
  (run-at-time 0.1 nil #'agent-skills--finish-caldav-input-recovery)
  'mouse-reader-release-scheduled)

(defun agent-skills--abort-caldav-passphrase (window depth)
  "Abort the stuck password prompt in WINDOW at minibuffer DEPTH.
Recheck the stack so a later, unrelated prompt cannot be interrupted."
  (let ((state (agent-skills/passphrase-input-state)))
    (when (and (eq window (active-minibuffer-window))
               (= depth (minibuffer-depth))
               (memq 'read-passwd (plist-get state :stack-functions))
               (memq 'org-project-caldav--credentials
                     (plist-get state :stack-functions)))
      (abort-recursive-edit))))

(defun agent-skills/recover-caldav-passphrase ()
  "Restore input and cancel a CalDAV password prompt nested in `read-key'.
Pause CalDAV timers for this session before scheduling the prompt abort."
  (let* ((state (agent-skills/passphrase-input-state))
         (stack (plist-get state :stack-functions))
         (window (active-minibuffer-window)))
    (unless (and (window-live-p window)
                 (memq 'read-passwd stack)
                 (memq 'read-key stack)
                 (memq 'org-project-caldav--credentials stack))
      (user-error "No CalDAV password prompt is blocking read-key"))
    (org-project-caldav-mode -1)
    (use-global-map global-map)
    (setq overriding-local-map
          (buffer-local-value 'read-passwd-map (window-buffer window)))
    (run-at-time 0.1 nil #'agent-skills--abort-caldav-passphrase
                 window (minibuffer-depth))
    'input-restored-password-abort-scheduled))

(declare-function +notes/denote-menu-sort-by-modified-h "modules/notes" ())
(declare-function +notes/denote-menu-modified-date "modules/notes" (path))
(declare-function +emacs/read-passwd-with-input-maps-a "core-startup"
                  (function &rest args))

(defun agent-skills/reload-password-and-denote-input ()
  "Reload only the managed password and Denote date functions.
Refresh existing Denote menus without replaying startup or enabling timers.
Only the three fixed function definitions below are evaluated."
  (unless (zerop (minibuffer-depth))
    (user-error "Finish the active minibuffer before reloading input settings"))
  (let (definitions menus)
    (dolist (entry '(("lisp/core/core-startup.el"
                      +emacs/read-passwd-with-input-maps-a)
                     ("lisp/modules/notes.el"
                      +notes/denote-menu-modified-date
                      +notes/denote-menu-sort-by-modified-h)))
      (let* ((file (expand-file-name (car entry) +emacs/repo-directory))
             (buffer (find-buffer-visiting file))
             (remaining (copy-sequence (cdr entry))))
        (when (and buffer (buffer-modified-p buffer))
          (user-error "Configuration has unsaved edits: %s" file))
        (with-temp-buffer
          (insert-file-contents file)
          (emacs-lisp-mode)
          (goto-char (point-min))
          (while (progn (forward-comment (point-max)) (not (eobp)))
            (let ((form (read (current-buffer))))
              (when (and (eq (car-safe form) 'defun)
                         (memq (cadr form) remaining))
                (push form definitions)
                (setq remaining (delq (cadr form) remaining)))))
          (when remaining
            (user-error "Missing managed definitions: %S" remaining)))))
    (dolist (form (nreverse definitions))
      (eval form t))
    (advice-add 'read-passwd :around #'+emacs/read-passwd-with-input-maps-a)
    (advice-add 'denote-menu-date :override #'+notes/denote-menu-modified-date)
    (add-hook 'denote-menu-mode-hook #'+notes/denote-menu-sort-by-modified-h)
    (save-selected-window
      (dolist (buffer (buffer-list))
        (with-current-buffer buffer
          (when (derived-mode-p 'denote-menu-mode)
            (+notes/denote-menu-sort-by-modified-h)
            (tabulated-list-print t)
            (push (list :buffer (buffer-name)
                        :sort-key tabulated-list-sort-key
                        :date-column (aref tabulated-list-format 0))
                  menus)))))
    (list :password-advice
          (not (null (advice-member-p
                      #'+emacs/read-passwd-with-input-maps-a 'read-passwd)))
          :denote-menus (nreverse menus)
          :caldav-auto-sync (bound-and-true-p org-project-caldav-mode))))

(defun agent-skills/denote-menu-order-state ()
  "Verify rendered Denote date order without reading note contents."
  (cl-loop
   for buffer in (buffer-list)
   when (with-current-buffer buffer (derived-mode-p 'denote-menu-mode))
   collect
   (with-current-buffer buffer
     (save-excursion
       (goto-char (point-min))
       (let ((rows 0) (newest-first t) previous first-date last-date)
         (while (not (eobp))
           (when-let* ((entry (tabulated-list-get-entry)))
             (let ((date (substring-no-properties (car (aref entry 0)))))
               (unless first-date (setq first-date date))
               (when (and previous (string-lessp previous date))
                 (setq newest-first nil))
               (setq previous date last-date date)
               (cl-incf rows)))
           (forward-line 1))
         (list :buffer (buffer-name) :sort-key tabulated-list-sort-key
               :rows rows :newest-first newest-first
               :first-date first-date :last-date last-date))))))

(declare-function +org/protocol-block-p "org-latex-protocol" (element))
(declare-function +org/protocol-preview "org-latex-protocol" ())
(declare-function yas-load-directory "yasnippet" (top-level-dir &optional use-jit))

(defun agent-skills/reload-org-protocol-config ()
  "Reload protocol definitions and refresh fontification in live Org buffers."
  (unless (and (boundp '+emacs/repo-directory)
               (stringp +emacs/repo-directory))
    (user-error "The managed Emacs configuration root is unavailable"))
  (load (expand-file-name "site-lisp/org-latex-protocol.el"
                          +emacs/repo-directory) nil t t)
  (when (fboundp 'yas-load-directory)
    (yas-load-directory (expand-file-name "snippets" +emacs/repo-directory)))
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (derived-mode-p 'org-mode)
        (org-set-font-lock-defaults)
        (font-lock-refresh-defaults))))
  (list :loaded (featurep 'org-latex-protocol)
        :preview-command (commandp '+org/protocol-preview)))

(defun agent-skills/org-protocol-fontification-state (path)
  "Report protocol face metadata in the live Org buffer visiting PATH."
  (let ((buffer (agent-skills--buffer-visiting-file path)))
    (unless (buffer-live-p buffer)
      (user-error "No live buffer is visiting: %s" path))
    (with-current-buffer buffer
      (save-excursion
        (save-restriction
          (widen)
          (list :native-mode (org-src-get-lang-mode-if-bound "latex")
                :blocks
                (org-element-map (org-element-parse-buffer) 'special-block
                  (lambda (block)
                    (when (+org/protocol-block-p block)
                      (let ((begin (org-element-property :contents-begin block))
                            (end (org-element-property :contents-end block)))
                        (font-lock-ensure (org-element-property :begin block)
                                          (org-element-property :end block))
                        (list :name (org-element-property :name block)
                              :first-face (and begin (get-text-property begin 'face))
                              :command-face
                              (when (and begin end)
                                (goto-char begin)
                                (when (search-forward "\\textbf" end t)
                                  (get-text-property (1- (point)) 'face)))
                              :delimiter-syntax
                              (and end (get-text-property end 'syntax-table)))))))
                :modified (buffer-modified-p)))))))

(defun agent-skills/convert-latex-protocol-blocks (path names &optional apply)
  "Plan conversion of named LaTeX protocol blocks NAMES in live file PATH.
With APPLY, back up the saved buffer to a temporary file, convert and save it.
Refuse unsaved edits, unexpected wrappers or nonstandard result contents.
Preserve protocol bodies, point and narrowing; never evaluate Babel headers."
  (require 'org)
  (require 'ob-core)
  (let ((buffer (agent-skills--buffer-visiting-file path)))
    (unless (buffer-live-p buffer)
      (user-error "No live buffer is visiting: %s" path))
    (with-current-buffer buffer
      (unless (derived-mode-p 'org-mode)
        (user-error "The target buffer is not in Org mode"))
      (when (or (buffer-modified-p) (not (verify-visited-file-modtime buffer)))
        (user-error "The Org buffer must match its saved file"))
      (save-excursion
        (save-restriction
          (widen)
          (let (changes backup)
            (dolist (name names)
              (goto-char (point-min))
              (org-babel-goto-named-src-block name)
              (let* ((block (org-element-at-point))
                     (body (org-element-property :value block))
                     (begin (org-element-property :begin block))
                     (end (org-element-property :end block))
                     (prefix "\\begin{protocol}\n")
                     (suffix "\\end{protocol}\n")
                     (result (org-babel-where-is-src-block-result)))
                (unless (and (org-element-type-p block 'src-block)
                             (equal (org-element-property :language block) "latex")
                             (string-prefix-p prefix body)
                             (string-suffix-p suffix body))
                  (user-error "Unexpected LaTeX protocol wrapper: %s" name))
                (when result
                  (unless (and (>= result end)
                               (string-blank-p
                                (buffer-substring-no-properties end result)))
                    (user-error "Results are not adjacent to protocol: %s" name))
                  (goto-char result)
                  (forward-line 2)
                  (unless (equal
                           (string-trim
                            (buffer-substring-no-properties result (point)))
                           (format "#+RESULTS: %s\n[[file:img/%s.svg]]" name name))
                    (user-error "Unexpected protocol results: %s" name))
                  (setq end (point)))
                (push (list begin end
                            (concat "#+name: " name "\n#+begin_protocol\n"
                                    (substring body (length prefix)
                                               (- (length suffix)))
                                    "#+end_protocol\n")
                            name)
                      changes)))
            (when apply
              (setq backup (make-temp-file "org-protocol-before-" nil ".org"))
              (write-region (point-min) (point-max) backup nil 'silent)
              (setq changes (sort changes (lambda (a b) (> (car a) (car b)))))
              (atomic-change-group
                (dolist (change changes)
                  (goto-char (nth 0 change))
                  (delete-region (nth 0 change) (nth 1 change))
                  (insert (nth 2 change))))
              (save-buffer))
            (list :blocks names :count (length changes)
                  :applied (and apply t) :backup backup)))))))

(defun agent-skills/preview-org-protocol-blocks (path names)
  "Render named protocol blocks NAMES in the live buffer visiting PATH.
Return image metadata and lint counts without changing document text."
  (require 'org-latex-protocol)
  (require 'org-lint)
  (let ((buffer (agent-skills--buffer-visiting-file path)))
    (unless (buffer-live-p buffer)
      (user-error "No live buffer is visiting: %s" path))
    (with-current-buffer buffer
      (save-excursion
        (save-restriction
          (widen)
          (let* ((tree (org-element-parse-buffer))
                 (blocks (org-element-map tree 'special-block
                           (lambda (element)
                             (when (and (+org/protocol-block-p element)
                                        (member (org-element-property :name element)
                                                names))
                               element))))
                 images)
            (unless (= (length blocks) (length names))
              (user-error "The requested protocol blocks were not all found"))
            (dolist (block blocks)
              (goto-char (org-element-post-affiliated block))
              (let ((file (+org/protocol-preview)))
                (push (list :name (org-element-property :name block)
                            :file (expand-file-name file)
                            :bytes (file-attribute-size (file-attributes file)))
                      images)))
            (when (bound-and-true-p flycheck-mode)
              (flycheck-buffer))
            (list :images (nreverse images)
                  :header-warnings (length (org-lint-wrong-header-value tree))
                  :modified (buffer-modified-p))))))))

(provide 'agent-skills/emacs)
;;; agent-skills-emacs.el ends here
