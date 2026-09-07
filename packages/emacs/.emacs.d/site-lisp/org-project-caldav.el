;;; org-project-caldav.el --- Background CalDAV for org-project -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jamie Cui - MIT License
;; Author: Jamie Cui <jamie.cui@outlook.com>
;; Description: Asynchronous CalDAV synchronization for org-project
;; Package-Requires: ((emacs "30.1") (org-caldav "20260501.8"))

;;; Commentary:

;; Synchronize active leaf tasks from every Org file below the shared
;; caldav-tasks directory through a local vdir.  This covers both org-project
;; and org-journal without exporting terminal-state history or ordinary Org
;; prose.  org-caldav performs only local Org/iCalendar conversion;
;; vdirsyncer owns all network access and runs asynchronously.  This package
;; is loaded and configured by org-project after org-project has defined its
;; task model.

;;; Code:

(require 'auth-source)
(require 'cl-lib)
(require 'org-caldav)
(require 'seq)
(require 'subr-x)

(declare-function +org-project--action-item-p "org-project"
                  (&optional filter bucket))
(declare-function +org-project-file-p "org-project" (&optional file))
(declare-function +org-project-sync-agenda-files "org-project" ())

(defvar +org-project-root-dir)
(defvar +org-projects-dir)
(defvar org-agenda-files)
(defvar org-project-caldav-mode)

(defgroup org-project-caldav nil
  "Background CalDAV synchronization for org-project."
  :group '+org-project
  :prefix "org-project-caldav-")

(define-error 'org-project-caldav-coverage-error
  "CalDAV active-task coverage mismatch")

(defcustom org-project-caldav-pair-name "org_project_caldav"
  "Vdirsyncer pair used for project task synchronization."
  :type 'string
  :group 'org-project-caldav)

(defcustom org-project-caldav-config-file
  (expand-file-name "vdirsyncer/config"
                    (or (getenv "XDG_CONFIG_HOME") "~/.config"))
  "Path to the vdirsyncer configuration file."
  :type 'file
  :group 'org-project-caldav)

(defcustom org-project-caldav-vdir-directory
  (expand-file-name "org-project-caldav/org-tasks"
                    (or (getenv "XDG_DATA_HOME") "~/.local/share"))
  "Directory containing the local iCalendar vdir."
  :type 'directory
  :group 'org-project-caldav)

(defcustom org-project-caldav-auth-host "caldav.gw-api.xyz"
  "Host whose credentials are read through `auth-source'."
  :type 'string
  :group 'org-project-caldav)

(defcustom org-project-caldav-calendar-id "caldav-tasks"
  "Stable calendar identifier used by the local org-caldav state."
  :type 'string
  :group 'org-project-caldav)

(defcustom org-project-caldav-sync-interval 300
  "Seconds between background synchronization attempts."
  :type 'integer
  :group 'org-project-caldav)

(defcustom org-project-caldav-initial-delay 20
  "Seconds to wait before the first background synchronization."
  :type 'integer
  :group 'org-project-caldav)

(defcustom org-project-caldav-after-save-delay 8
  "Seconds to debounce synchronization after saving an Org file."
  :type 'integer
  :group 'org-project-caldav)

(defcustom org-project-caldav-auto-sync t
  "Whether `org-project-caldav-setup' enables background synchronization."
  :type 'boolean
  :group 'org-project-caldav)

(defcustom org-project-caldav-conflict-policy 'org-wins
  "Policy for simultaneous Org and CalDAV changes.

The only supported value is `org-wins'.  org-caldav applies the Org version
when both representations changed, and the vdirsyncer pair uses the matching
local-vdir-wins policy."
  :type '(const :tag "Org wins" org-wins)
  :group 'org-project-caldav)

(defvar org-project-caldav--process nil
  "Current vdirsyncer process, or nil.")

(defvar org-project-caldav--running nil
  "Non-nil while a complete pull, reconcile, and push cycle is active.")

(defvar org-project-caldav--pending nil
  "Non-nil when another synchronization was requested during a cycle.")

(defvar org-project-caldav--discovery-attempted nil
  "Non-nil after automatic discovery in the current cycle.")

(defvar org-project-caldav--periodic-timer nil
  "Timer used for periodic synchronization.")

(defvar org-project-caldav--save-timer nil
  "Debounce timer used after saving an Org file.")

(defvar org-project-caldav--reconciling nil
  "Non-nil while org-caldav is reconciling Org with the local vdir.")

(defvar org-project-caldav--last-success nil
  "Time of the most recent successful synchronization.")

(defvar org-project-caldav--last-error nil
  "Most recent synchronization error string, or nil.")

(defvar org-project-caldav--last-result nil
  "Copy of the most recent org-caldav result list.")

(defvar org-project-caldav--last-source-file-count nil
  "Number of Org source files checked by the latest reconciliation.")

(defvar org-project-caldav--last-active-task-count nil
  "Number of active tasks checked by the latest reconciliation.")

(defconst org-project-caldav--log-buffer "*org-project-caldav*"
  "Buffer containing vdirsyncer output and local reconciliation errors.")

(defun org-project-caldav--inbox-file ()
  "Return the Org file receiving tasks created by CalDAV clients."
  (expand-file-name "inbox.org" +org-project-root-dir))

(defun org-project-caldav--state-directory ()
  "Return the directory containing local CalDAV backups."
  (expand-file-name "org-project-caldav" user-emacs-directory))

(defun org-project-caldav--program ()
  "Return an executable vdirsyncer path or signal a user error."
  (or (executable-find "vdirsyncer")
      (seq-find #'file-executable-p
                '("/opt/homebrew/bin/vdirsyncer"
                  "/usr/local/bin/vdirsyncer"
                  "/usr/bin/vdirsyncer"))
      (user-error "Vdirsyncer is not installed or executable")))

(defun org-project-caldav--secret-string (secret)
  "Return a private copy of auth-source SECRET as a string."
  (let ((value (if (functionp secret) (funcall secret) secret)))
    (unless (and (stringp value) (not (string-empty-p value)))
      (user-error "CalDAV password from auth-source is empty"))
    (copy-sequence value)))

(defun org-project-caldav--credentials ()
  "Return the CalDAV username and password from `auth-source'."
  (let ((entry (car (auth-source-search
                     :host org-project-caldav-auth-host
                     :max 1
                     :require '(:user :secret)
                     :create nil))))
    (unless entry
      (user-error "No auth-source entry for %s"
                  org-project-caldav-auth-host))
    (let ((user (plist-get entry :user)))
      (unless (and (stringp user) (not (string-empty-p user)))
        (user-error "CalDAV username from auth-source is empty"))
      (cons user
            (org-project-caldav--secret-string
             (plist-get entry :secret))))))

(defun org-project-caldav--ensure-layout ()
  "Create local directories and the Org inbox required for synchronization."
  (make-directory org-project-caldav-vdir-directory t)
  (make-directory (org-project-caldav--state-directory) t)
  (make-directory +org-project-root-dir t)
  (make-directory +org-projects-dir t)
  (make-directory (expand-file-name "journal" +org-project-root-dir) t)
  (let ((inbox (org-project-caldav--inbox-file)))
    (unless (file-exists-p inbox)
      (write-region "" nil inbox nil 'silent))))

(defun org-project-caldav--source-files ()
  "Return every readable Org file below the shared task root.
Signal an error instead of silently omitting a discovered source file."
  (unless (file-directory-p +org-project-root-dir)
    (error "CalDAV task root is not a directory: %s"
           +org-project-root-dir))
  (let ((files (directory-files-recursively
                +org-project-root-dir "\\.org\\'")))
    (dolist (file files)
      (unless (file-regular-p file)
        (error "CalDAV source is not a regular file: %s" file))
      (unless (file-readable-p file)
        (error "CalDAV source is not readable: %s" file)))
    (sort (delete-dups (mapcar #'expand-file-name files)) #'string<)))

(defun org-project-caldav--modified-source-buffers ()
  "Return modified buffers visiting synchronized Org files."
  (let ((files (mapcar #'expand-file-name
                       (org-project-caldav--source-files))))
    (seq-filter
     (lambda (buffer)
       (with-current-buffer buffer
         (and buffer-file-name
              (buffer-modified-p)
              (member (expand-file-name buffer-file-name) files))))
     (buffer-list))))

(defun org-project-caldav--assert-saved ()
  "Signal a user error when a synchronized Org buffer is modified."
  (when-let* ((buffers (org-project-caldav--modified-source-buffers)))
    (user-error "Save Org buffers before CalDAV sync: %s"
                (mapconcat #'buffer-name buffers ", "))))

(defun org-project-caldav--leaf-action-item-p ()
  "Return non-nil when point is an org-project leaf action item."
  (+org-project--action-item-p
   nil
   (if (+org-project-file-p) 'project 'non-project)))

(defun org-project-caldav--create-leaf-uids (file &optional bell)
  "Create IDs for synchronized leaf action items in FILE.
When BELL is non-nil, report whether the file changed."
  (let (modified)
    (with-current-buffer (org-get-agenda-file-buffer file)
      (save-excursion
        (save-restriction
          (widen)
          (goto-char (point-min))
          (while (re-search-forward org-outline-regexp-bol nil t)
            (goto-char (match-beginning 0))
            (when (and (org-project-caldav--leaf-action-item-p)
                       (not (org-entry-get nil "ID")))
              (org-id-get-create)
              (setq modified t))
            (org-back-to-heading t)
            (forward-line 1))))
      (when (and modified org-caldav-save-buffers)
        (save-buffer)))
    (when (and bell modified)
      (message "CalDAV IDs created for leaf tasks in %s" file))))

(defun org-project-caldav--active-task-index (files)
  "Return validated active task UID and source pairs from FILES."
  (let ((seen (make-hash-table :test #'equal))
        index)
    (dolist (file files (nreverse index))
      (with-current-buffer (org-get-agenda-file-buffer file)
        (save-excursion
          (save-restriction
            (widen)
            (goto-char (point-min))
            (while (re-search-forward org-outline-regexp-bol nil t)
              (goto-char (match-beginning 0))
              (when (org-project-caldav--leaf-action-item-p)
                (let ((uid (org-entry-get nil "ID")))
                  (unless (and (stringp uid) (not (string-empty-p uid)))
                    (error "Active task has no UID in %s:%d"
                           file (line-number-at-pos)))
                  (when-let* ((previous (gethash uid seen)))
                    (error "Duplicate active task UID %s in %s and %s"
                           uid previous file))
                  (puthash uid file seen)
                  (push (cons uid file) index)))
              (org-back-to-heading t)
              (forward-line 1))))))))

(defun org-project-caldav--validate-coverage (files)
  "Require active Org tasks in FILES and local VTODOs to have equal UIDs."
  (let* ((source-index (org-project-caldav--active-task-index files))
         (source-uids (mapcar #'car source-index))
         (vdir-uids (mapcar #'car (org-project-caldav--vdir-index)))
         (missing (cl-set-difference source-uids vdir-uids :test #'string=))
         (extra (cl-set-difference vdir-uids source-uids :test #'string=)))
    (when (or missing extra)
      (signal
       'org-project-caldav-coverage-error
       (list
        (format "Missing VTODOs=%S extra VTODOs=%S" missing extra))))
    (setq org-project-caldav--last-source-file-count (length files)
          org-project-caldav--last-active-task-count (length source-uids))
    (org-project-caldav--append-log
     "Coverage verified: %d Org files, %d active tasks\n"
     org-project-caldav--last-source-file-count
     org-project-caldav--last-active-task-count)
    t))

(defun org-project-caldav--filter-export-buffer (backend)
  "Keep only org-project leaf tasks when exporting BACKEND."
  (when (and org-project-caldav--reconciling (eq backend 'icalendar))
    (let ((preamble
           (save-excursion
             (goto-char (point-min))
             (if (re-search-forward org-outline-regexp-bol nil t)
                 (buffer-substring-no-properties
                  (point-min) (match-beginning 0))
               (buffer-string))))
          entries)
      (save-excursion
        (goto-char (point-min))
        (while (re-search-forward org-outline-regexp-bol nil t)
          (goto-char (match-beginning 0))
          (when (org-project-caldav--leaf-action-item-p)
            (let* ((begin (line-beginning-position))
                   (end (save-excursion (org-end-of-subtree t t)))
                   (subtree (buffer-substring-no-properties begin end)))
              (push (replace-regexp-in-string "\\`\\*+" "*" subtree)
                    entries)))
          (forward-line 1)))
      (erase-buffer)
      (insert preamble)
      (dolist (entry (nreverse entries))
        (unless (or (bobp) (bolp))
          (insert "\n"))
        (insert entry)
        (unless (bolp)
          (insert "\n"))))))

(defun org-project-caldav--vdir-files ()
  "Return regular iCalendar files in the configured local vdir."
  (when (file-directory-p org-project-caldav-vdir-directory)
    (seq-filter
     #'file-regular-p
     (directory-files org-project-caldav-vdir-directory t "\\.ics\\'"))))

(defun org-project-caldav--buffer-uid ()
  "Return the logical org-caldav UID from the current iCalendar buffer."
  (save-excursion
    (goto-char (point-min))
    (unless (re-search-forward "^BEGIN:VTODO\r?$" nil t)
      (error "ICalendar item does not contain a VTODO"))
    (goto-char (point-min))
    (org-caldav-get-uid)))

(defun org-project-caldav--file-metadata (file)
  "Return a UID, hash, and FILE list for one vdir FILE."
  (with-temp-buffer
    (insert-file-contents file)
    (list (org-project-caldav--buffer-uid)
          (secure-hash 'sha256 (current-buffer))
          file)))

(defun org-project-caldav--vdir-index ()
  "Return validated metadata for every item in the local vdir."
  (let (index)
    (dolist (file (org-project-caldav--vdir-files) (nreverse index))
      (condition-case err
          (let* ((metadata (org-project-caldav--file-metadata file))
                 (uid (car metadata)))
            (when (assoc-string uid index)
              (error "Duplicate VTODO UID %s" uid))
            (push metadata index))
        (error
         (error "Invalid vdir item %s: %s"
                file (error-message-string err)))))))

(defun org-project-caldav--check-vdir ()
  "Validate the local vdir and update org-caldav's empty flag."
  (org-project-caldav--ensure-layout)
  (setq org-caldav-empty-calendar
        (null (org-project-caldav--vdir-index)))
  t)

(defun org-project-caldav--event-etags ()
  "Return org-caldav-style UID and content-hash pairs for the local vdir."
  (mapcar (lambda (metadata)
            (cons (nth 0 metadata) (nth 1 metadata)))
          (org-project-caldav--vdir-index)))

(defun org-project-caldav--event-file (uid)
  "Return the vdir file containing UID, or nil."
  (nth 2 (assoc-string uid (org-project-caldav--vdir-index))))

(defun org-project-caldav--get-event (uid &optional _with-headers)
  "Return a temporary buffer containing the vdir item for UID."
  (let ((file (org-project-caldav--event-file uid)))
    (unless file
      (error "No local vdir item for UID %s" uid))
    (let ((buffer (get-buffer-create " *org-project-caldav-event*")))
      (with-current-buffer buffer
        (let ((inhibit-read-only t))
          (widen)
          (erase-buffer)
          (insert-file-contents file)
          (goto-char (point-min))
          (while (re-search-forward "\r$" nil t)
            (replace-match "" nil nil))
          (goto-char (point-min))
          (while (re-search-forward "\n[ \t]" nil t)
            (replace-match "" nil nil))
          (goto-char (point-min))))
      buffer)))

(defun org-project-caldav--atomic-write (file text)
  "Atomically write TEXT to FILE."
  (let ((temporary (make-temp-file
                    (expand-file-name ".org-project-caldav-"
                                      (file-name-directory file)))))
    (unwind-protect
        (progn
          (write-region text nil temporary nil 'silent)
          (rename-file temporary file t)
          (setq temporary nil))
      (when (and temporary (file-exists-p temporary))
        (delete-file temporary)))))

(defun org-project-caldav--put-event (buffer)
  "Write the narrowed VTODO in BUFFER into the local vdir."
  (let (event uid file)
    (with-current-buffer buffer
      (setq event (buffer-substring-no-properties (point-min) (point-max)))
      (setq uid (org-project-caldav--buffer-uid)))
    (setq file
          (or (org-project-caldav--event-file uid)
              (expand-file-name
               (concat (secure-hash 'sha256 uid) ".ics")
               org-project-caldav-vdir-directory)))
    (org-project-caldav--atomic-write
     file
     (concat "BEGIN:VCALENDAR\r\n"
             "VERSION:2.0\r\n"
             "PRODID:-//org-project-caldav//EN\r\n"
             event
             (unless (string-suffix-p "\n" event) "\r\n")
             "END:VCALENDAR\r\n"))
    (setq org-caldav-empty-calendar nil)
    t))

(defun org-project-caldav--delete-event (uid)
  "Delete the local vdir item for UID."
  (let ((file (org-project-caldav--event-file uid)))
    (when file
      (delete-file file))
    t))

(defun org-project-caldav--reconcile ()
  "Reconcile saved Org tasks with the local vdir and return a result list."
  (org-project-caldav--ensure-layout)
  (org-project-caldav--assert-saved)
  (unless (eq org-project-caldav-conflict-policy 'org-wins)
    (error "Unsupported CalDAV conflict policy: %S"
           org-project-caldav-conflict-policy))
  (let* ((inbox (org-project-caldav--inbox-file))
         (source-files (org-project-caldav--source-files))
         (files (remove inbox source-files))
         (original-create-uid (symbol-function 'org-caldav-create-uid))
         (org-project-caldav--reconciling t)
         (org-export-before-parsing-functions
          (cons #'org-project-caldav--filter-export-buffer
                (remove #'org-project-caldav--filter-export-buffer
                        org-export-before-parsing-functions)))
         (org-caldav-url "local-vdir")
         (org-caldav-calendar-id org-project-caldav-calendar-id)
         (org-caldav-files files)
         (org-caldav-inbox inbox)
         (org-caldav-calendars nil)
         (org-caldav-save-directory user-emacs-directory)
         (org-caldav-backup-file
          (expand-file-name "backup.org"
                            (org-project-caldav--state-directory)))
         (org-caldav-sync-direction 'twoway)
         (org-caldav-sync-todo t)
         (org-caldav-delete-org-entries 'always)
         (org-caldav-delete-calendar-entries 'always)
         (org-caldav-resume-aborted 'never)
         (org-caldav-show-sync-results nil)
         (org-caldav-save-buffers t)
         (org-caldav-retry-attempts 1)
         (org-caldav-debug-level 0)
         (org-caldav-sync-changes-to-org 'title-and-timestamp)
         (org-caldav-todo-percent-states
          '((0 "TODO") (25 "WAIT") (50 "PROJ") (100 "DONE")))
         (org-icalendar-timezone "Asia/Shanghai")
         (org-icalendar-include-todo 'all)
         (org-caldav-event-list nil)
         (org-caldav-previous-files nil)
         (org-caldav-sync-result nil)
         (org-caldav-empty-calendar nil))
    (cl-letf (((symbol-function 'org-caldav-create-uid)
               (lambda (file &optional bell)
                 (if org-project-caldav--reconciling
                     (org-project-caldav--create-leaf-uids file bell)
                   (funcall original-create-uid file bell))))
              ((symbol-function 'org-caldav-check-connection)
               #'org-project-caldav--check-vdir)
              ((symbol-function 'org-caldav-get-event-etag-list)
               #'org-project-caldav--event-etags)
              ((symbol-function 'org-caldav-get-event)
               #'org-project-caldav--get-event)
              ((symbol-function 'org-caldav-put-event)
               #'org-project-caldav--put-event)
              ((symbol-function 'org-caldav-delete-event)
               #'org-project-caldav--delete-event))
      (dolist (file source-files)
        (org-project-caldav--create-leaf-uids file))
      (org-project-caldav--active-task-index source-files)
      (org-caldav-sync)
      (condition-case nil
          (org-project-caldav--validate-coverage
           (org-project-caldav--source-files))
        (org-project-caldav-coverage-error
         (org-project-caldav--append-log
          "Active task set changed during pull; reconciling once more\n")
         (org-caldav-sync)
         (org-project-caldav--validate-coverage
          (org-project-caldav--source-files)))))
    (copy-tree org-caldav-sync-result)))

(defun org-project-caldav--command (stage)
  "Return the vdirsyncer command for synchronization STAGE."
  (unless (file-readable-p org-project-caldav-config-file)
    (user-error "Vdirsyncer config is not readable: %s"
                org-project-caldav-config-file))
  (list (org-project-caldav--program)
        "--config" org-project-caldav-config-file
        (if (eq stage 'discover) "discover" "sync")
        org-project-caldav-pair-name))

(defun org-project-caldav--append-log (format-string &rest arguments)
  "Append FORMAT-STRING and ARGUMENTS to the synchronization log."
  (with-current-buffer (get-buffer-create org-project-caldav--log-buffer)
    (let ((inhibit-read-only t))
      (goto-char (point-max))
      (insert (apply #'format format-string arguments)))))

(defun org-project-caldav--record-failure (message)
  "Finish the current cycle with failure MESSAGE."
  (setq org-project-caldav--process nil
        org-project-caldav--running nil
        org-project-caldav--pending nil
        org-project-caldav--discovery-attempted nil)
  (org-project-caldav--append-log "\n%s\n" message)
  (unless (equal message org-project-caldav--last-error)
    (display-warning 'org-project-caldav message :warning))
  (setq org-project-caldav--last-error message))

(defun org-project-caldav--finish-success ()
  "Record a successful complete synchronization cycle."
  (let ((rerun org-project-caldav--pending))
    (setq org-project-caldav--process nil
          org-project-caldav--running nil
          org-project-caldav--pending nil
          org-project-caldav--discovery-attempted nil
          org-project-caldav--last-success (current-time)
          org-project-caldav--last-error nil)
    (org-project-caldav--append-log
     "Completed at %s\n" (format-time-string "%F %T"))
    (when rerun
      (run-at-time 0 nil #'org-project-caldav-sync))))

(defun org-project-caldav--discovery-required-p ()
  "Return non-nil when the current log requests vdirsyncer discovery."
  (with-current-buffer (get-buffer-create org-project-caldav--log-buffer)
    (save-excursion
      (goto-char (point-min))
      (re-search-forward
       "\\(?:Please run.*vdirsyncer discover\\|Detected change in config\\)"
       nil t))))

(defun org-project-caldav--handle-process-exit (process stage)
  "Handle completion of vdirsyncer PROCESS for STAGE."
  (when (eq process org-project-caldav--process)
    (setq org-project-caldav--process nil)
    (if (and (eq (process-status process) 'exit)
             (zerop (process-exit-status process)))
        (pcase stage
          ('discover (org-project-caldav--start-vdirsyncer 'pull))
          ('pull
           (condition-case err
               (progn
                 (setq org-project-caldav--last-result
                       (org-project-caldav--reconcile))
                 (org-project-caldav--start-vdirsyncer 'push))
             (error
              (org-project-caldav--record-failure
               (format "Local CalDAV reconciliation failed: %s"
                       (error-message-string err))))))
          ('push (org-project-caldav--finish-success))
          (_ (org-project-caldav--record-failure
              (format "Unknown CalDAV process stage: %S" stage))))
      (if (and (eq stage 'pull)
               (not org-project-caldav--discovery-attempted)
               (org-project-caldav--discovery-required-p))
          (progn
            (setq org-project-caldav--discovery-attempted t)
            (org-project-caldav--start-vdirsyncer 'discover))
        (org-project-caldav--record-failure
         (format "Vdirsyncer %s failed with status %s; see %s"
                 stage (process-exit-status process)
                 org-project-caldav--log-buffer))))))

(defun org-project-caldav--sentinel (process _event)
  "Dispatch terminal status changes for vdirsyncer PROCESS."
  (when (memq (process-status process) '(exit signal))
    (let ((stage (process-get process 'org-project-caldav-stage)))
      (run-at-time 0 nil
                   #'org-project-caldav--handle-process-exit process stage))))

(defun org-project-caldav--start-vdirsyncer (stage)
  "Start asynchronous vdirsyncer STAGE using auth-source credentials."
  (let* ((credentials (org-project-caldav--credentials))
         (username (car credentials))
         (password (cdr credentials))
         (process-environment (copy-sequence process-environment))
         (buffer (get-buffer-create org-project-caldav--log-buffer)))
    (unwind-protect
        (progn
          (setenv "ORG_PROJECT_CALDAV_USERNAME" username)
          (setenv "ORG_PROJECT_CALDAV_PASSWORD" password)
          (when (eq stage 'pull)
            (with-current-buffer buffer
              (let ((inhibit-read-only t))
                (erase-buffer))))
          (org-project-caldav--append-log
           "%s vdirsyncer %s\n"
           (format-time-string "%F %T") stage)
          (let ((process
                 (make-process
                  :name (format "org-project-caldav-%s" stage)
                  :buffer buffer
                  :command (org-project-caldav--command stage)
                  :connection-type 'pipe
                  :noquery t
                  :sentinel #'org-project-caldav--sentinel)))
            (process-put process 'org-project-caldav-stage stage)
            (setq org-project-caldav--process process)))
      (clear-string password))))

;;;###autoload
(defun org-project-caldav-sync ()
  "Request an asynchronous CalDAV synchronization cycle."
  (interactive)
  (if org-project-caldav--running
      (progn
        (setq org-project-caldav--pending t)
        (when (called-interactively-p 'interactive)
          (message "CalDAV sync already running; queued one more cycle")))
    (condition-case err
        (progn
          (org-project-caldav--ensure-layout)
          (let ((modified (org-project-caldav--modified-source-buffers)))
            (if modified
                (progn
                  (setq org-project-caldav--last-error
                        (format "Waiting for saved Org buffers: %s"
                                (mapconcat #'buffer-name modified ", ")))
                  (when (called-interactively-p 'interactive)
                    (user-error "%s" org-project-caldav--last-error)))
              (setq org-project-caldav--running t
                    org-project-caldav--pending nil
                    org-project-caldav--discovery-attempted nil)
              (org-project-caldav--start-vdirsyncer 'pull)
              (when (called-interactively-p 'interactive)
                (message "CalDAV sync started in the background")))))
      (error
       (org-project-caldav--record-failure
        (format "Could not start CalDAV sync: %s"
                (error-message-string err)))
       (when (called-interactively-p 'interactive)
         (signal (car err) (cdr err)))))))

;;;###autoload
(defun org-project-caldav-status ()
  "Report current background synchronization status."
  (interactive)
  (message
   "CalDAV: %s; files %s; active tasks %s; last success %s%s"
   (cond (org-project-caldav--process
          (symbol-name
           (process-get org-project-caldav--process
                        'org-project-caldav-stage)))
         (org-project-caldav--running "reconciling")
         (t "idle"))
   (or org-project-caldav--last-source-file-count "unknown")
   (or org-project-caldav--last-active-task-count "unknown")
   (if org-project-caldav--last-success
       (format-time-string "%F %T" org-project-caldav--last-success)
     "never")
   (if org-project-caldav--last-error
       (format "; %s" org-project-caldav--last-error)
     "")))

(defun org-project-caldav--managed-org-buffer-p ()
  "Return non-nil when the current buffer should trigger synchronization."
  (and buffer-file-name
       (derived-mode-p 'org-mode)
       (file-in-directory-p
        (expand-file-name buffer-file-name)
        (file-name-as-directory (expand-file-name +org-project-root-dir)))))

(defun org-project-caldav--after-save-h ()
  "Debounce a synchronization after saving managed Org data."
  (when (and org-project-caldav-mode
             (not org-project-caldav--reconciling)
             (org-project-caldav--managed-org-buffer-p))
    (when (timerp org-project-caldav--save-timer)
      (cancel-timer org-project-caldav--save-timer))
    (setq org-project-caldav--save-timer
          (run-at-time org-project-caldav-after-save-delay nil
                       #'org-project-caldav-sync))))

(defun org-project-caldav--cancel-timers ()
  "Cancel all timers owned by org-project-caldav."
  (dolist (timer (list org-project-caldav--periodic-timer
                       org-project-caldav--save-timer))
    (when (timerp timer)
      (cancel-timer timer)))
  (setq org-project-caldav--periodic-timer nil
        org-project-caldav--save-timer nil))

;;;###autoload
(define-minor-mode org-project-caldav-mode
  "Synchronize org-project tasks with CalDAV in the background."
  :global t
  :group 'org-project-caldav
  (org-project-caldav--cancel-timers)
  (if org-project-caldav-mode
      (progn
        (add-hook 'after-save-hook #'org-project-caldav--after-save-h)
        (setq org-project-caldav--periodic-timer
              (run-at-time org-project-caldav-initial-delay
                           org-project-caldav-sync-interval
                           #'org-project-caldav-sync)))
    (remove-hook 'after-save-hook #'org-project-caldav--after-save-h)
    (setq org-project-caldav--pending nil)))

(defun org-project-caldav--remove-legacy-hooks ()
  "Remove hooks and advice installed by the retired CalDAV module."
  (remove-hook 'org-export-before-parsing-functions
               (intern "+notes/caldav--filter-export-buffer"))
  (dolist (entry
           '((org-caldav-create-uid . +notes/caldav--create-leaf-uids-a)
             (org-caldav-sync . +notes/caldav--sync-project-todos-a)
             (org-caldav-get-event-etag-list
              . +notes/caldav--capture-remote-etags-a)
             (org-caldav-update-eventdb-from-cal
              . +notes/caldav--reconcile-pull-state-a)
             (org-caldav-update-eventdb-from-org
              . +notes/caldav--force-push-eventdb-a)
             (org-caldav-url-retrieve-synchronously
              . +notes/caldav--conditional-request-a)
             (org-caldav-update-events-in-cal
              . +notes/caldav--verify-written-etags-a)
             (org-caldav-delete-event . +notes/caldav--delete-event-a)))
    (advice-remove (car entry) (cdr entry)))
  (when (boundp 'magit-status-sections-hook)
    (remove-hook 'magit-status-sections-hook
                 (intern "+notes/caldav-magit-insert-status"))))

;;;###autoload
(defun org-project-caldav-setup ()
  "Integrate background CalDAV synchronization with org-project."
  (org-project-caldav--remove-legacy-hooks)
  (+org-project-sync-agenda-files)
  (add-to-list 'org-agenda-files (org-project-caldav--inbox-file) t)
  (when (and org-project-caldav-auto-sync (not noninteractive)
             (not org-project-caldav-mode))
    (org-project-caldav-mode 1)))

(provide 'org-project-caldav)
;;; org-project-caldav.el ends here
