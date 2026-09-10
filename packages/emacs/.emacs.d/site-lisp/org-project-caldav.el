;;; org-project-caldav.el --- Background CalDAV for org-project -*- lexical-binding: t; -*-

;; Copyright (C) 2012-2017 Free Software Foundation, Inc.
;; Copyright (C) 2018-2024 David Engster
;; Copyright (C) 2026 Jamie Cui
;; Author: Jamie Cui <jamie.cui@outlook.com>
;; Description: Asynchronous CalDAV synchronization for org-project
;; Package-Requires: ((emacs "30.1"))
;; SPDX-License-Identifier: GPL-3.0-or-later
;;
;; This file is free software: you can redistribute it and/or modify it under
;; the terms of the GNU General Public License as published by the Free
;; Software Foundation, either version 3 of the License, or (at your option)
;; any later version.
;;
;; This file is distributed in the hope that it will be useful, but WITHOUT
;; ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
;; FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
;; more details.
;;
;; You should have received a copy of the GNU General Public License along
;; with GNU Emacs.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Synchronize active leaf tasks from every Org file below the shared
;; org-project-caldav directory through a local vdir.  The configured layout
;; keeps project files, the CalDAV inbox, and synchronization state together,
;; while org-journal remains outside this task root.  This package owns the
;; Org/VTODO projection and its three-way state; vdirsyncer owns all network
;; access and runs asynchronously.
;; The VTODO codec adapts conversion behavior from org-caldav under GPLv3+,
;; without loading or depending on the org-caldav package.  org-project remains
;; usable without CalDAV synchronization because loading and setup stay with
;; the caller.

;;; Code:

(require 'auth-source)
(require 'cl-lib)
(require 'org-id)
(require 'org-project-caldav-vtodo)
(require 'ox-icalendar)
(require 'seq)
(require 'subr-x)

(declare-function +org-project--action-item-p "org-project"
                  (&optional filter bucket))
(declare-function +org-project-file-p "org-project" (&optional file))
(declare-function +org-project-sync-agenda-files "org-project" ())
(declare-function +org-project-known-files "org-project" ())
(declare-function +org-project-ensure-default "org-project" ())

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

(define-error 'org-project-caldav-state-error
  "Invalid org-project-caldav state")

(define-error 'org-project-caldav-confirmation-required
  "CalDAV sync needs confirmation" 'user-error)

(defconst org-project-caldav--state-version 1
  "Current on-disk synchronization state version.")

(defconst org-project-caldav--todo-percent-states
  '((0 . "TODO") (25 . "WAIT") (50 . "PROJ") (100 . "DONE"))
  "Mapping from VTODO completion percentages to Org TODO states.")

(defconst org-project-caldav--todo-priorities
  '((0) (1 . "A") (5 . "B") (9 . "C"))
  "Mapping from iCalendar numeric priorities to Org priority strings.")

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
  "Stable calendar identifier used to migrate and identify local state."
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

The only supported value is `org-wins'.  The local reconciler applies the Org
version when both representations changed, and the vdirsyncer pair uses the
matching local-vdir-wins policy."
  :type '(const :tag "Org wins" org-wins)
  :group 'org-project-caldav)

(defvar org-project-caldav--process nil
  "Current vdirsyncer process, or nil.")

(defvar org-project-caldav--running nil
  "Non-nil while a complete pre-sync, reconcile, and post-sync cycle is active.")

(defvar org-project-caldav--pending nil
  "Non-nil when another synchronization was requested during a cycle.")

(defvar org-project-caldav--approved-removals nil
  "Exact missing source paths and task UIDs approved for the current cycle.")

(defvar org-project-caldav--discovery-attempted nil
  "Non-nil after automatic discovery in the current cycle.")

(defvar org-project-caldav--periodic-timer nil
  "Timer used for periodic synchronization.")

(defvar org-project-caldav--save-timer nil
  "Debounce timer used after saving an Org file.")

(defvar org-project-caldav--reconciling nil
  "Non-nil while reconciling Org with the local vdir.")

(defvar org-project-caldav--last-success nil
  "Time of the most recent successful synchronization.")

(defvar org-project-caldav--last-error nil
  "Most recent synchronization error string, or nil.")

(defvar org-project-caldav--last-result nil
  "Copy of the most recent local reconciliation result list.")

(defvar org-project-caldav--last-source-file-count nil
  "Number of Org source files checked by the latest reconciliation.")

(defvar org-project-caldav--last-active-task-count nil
  "Number of active tasks checked by the latest reconciliation.")

(defconst org-project-caldav--log-buffer "*org-project-caldav*"
  "Buffer containing vdirsyncer output and local reconciliation errors.")

(defconst org-project-caldav--log-history-limit 65536
  "Maximum characters of previous output retained when starting pre-sync.")

(defun org-project-caldav--inbox-file ()
  "Return the Org file receiving tasks created by CalDAV clients."
  (expand-file-name "inbox.org" +org-project-root-dir))

(defun org-project-caldav--state-directory ()
  "Return the directory containing local synchronization state."
  +org-project-root-dir)

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
  (make-directory +org-project-root-dir t)
  (make-directory +org-projects-dir t)
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
  "Return modified source buffers, including Org files not yet on disk."
  (let ((files (mapcar #'expand-file-name
                       (org-project-caldav--source-files))))
    (seq-filter
     (lambda (buffer)
       (with-current-buffer buffer
         (and buffer-file-name
              (buffer-modified-p)
              (or (member (expand-file-name buffer-file-name) files)
                  (and (string-suffix-p ".org" buffer-file-name)
                       (equal (file-remote-p buffer-file-name)
                              (file-remote-p +org-project-root-dir))
                       (file-in-directory-p buffer-file-name
                                            +org-project-root-dir))))))
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
      (when modified
        (save-buffer)))
    (when (and bell modified)
      (message "CalDAV IDs created for leaf tasks in %s" file))))

(defun org-project-caldav--active-task-index (files &optional allow-unassigned)
  "Return validated active task UID and source pairs from FILES.
With ALLOW-UNASSIGNED, omit tasks without IDs during read-only preflight."
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
                  (unless (or allow-unassigned
                              (and (stringp uid) (not (string-empty-p uid))))
                    (error "Active task has no UID in %s:%d"
                           file (line-number-at-pos)))
                  (when (and uid (not (string-empty-p uid)))
                    (when-let* ((previous (gethash uid seen)))
                      (error "Duplicate active task UID %s in %s and %s"
                             uid previous file))
                    (puthash uid file seen)
                    (push (cons uid file) index))))
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
  "Return the logical UID from the current iCalendar buffer."
  (save-excursion
    (goto-char (point-min))
    (unless (re-search-forward "^BEGIN:VTODO\r?$" nil t)
      (error "ICalendar item does not contain a VTODO"))
    (let ((begin (point))
          (end (and (re-search-forward "^END:VTODO\r?$" nil t)
                    (line-beginning-position))))
      (unless end
        (error "ICalendar item contains an unterminated VTODO"))
      (goto-char begin)
      (unless (re-search-forward "^UID:\\s-*\\(.+\\)\\s-*$" end t)
        (error "ICalendar VTODO does not contain a UID"))
      (let ((uid (match-string 1)))
        (while (progn
                 (forward-line)
                 (and (< (point) end)
                      (looking-at "[ \t]\\(.+\\)\\s-*$")))
          (setq uid (concat uid (match-string 1))))
        (org-project-caldav-vtodo-normalize-uid uid)))))

(defun org-project-caldav--file-metadata (file)
  "Return UID, hash, FILE, and decoded data for one vdir FILE."
  (with-temp-buffer
    (insert-file-contents file)
    (let ((uid (org-project-caldav--buffer-uid))
          (record (org-project-caldav-vtodo-parse-buffer)))
      (unless (equal uid (plist-get record :uid))
        (error "VTODO UID parser disagreement in %s" file))
      (list uid (secure-hash 'sha256 (current-buffer)) file record))))

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

(defun org-project-caldav--event-file (uid &optional index)
  "Return the vdir file containing UID, or nil.
Use INDEX instead of scanning the vdir when it is non-nil."
  (nth 2 (assoc-string uid (or index (org-project-caldav--vdir-index)))))

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

(defun org-project-caldav--state-file ()
  "Return the native synchronization state file."
  (expand-file-name "state.el" (org-project-caldav--state-directory)))

(defun org-project-caldav--legacy-state-file ()
  "Return the state file used by the retired org-caldav integration."
  (expand-file-name
   (format "org-caldav-%s.el"
           (substring (md5 org-project-caldav-calendar-id) 1 8))
   user-emacs-directory))

(defun org-project-caldav--read-data-file (file)
  "Read and return exactly one Lisp data object from FILE."
  (condition-case err
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        (let ((read-eval nil))
          (let ((object (read (current-buffer))))
            (skip-chars-forward " \t\r\n")
            (unless (eobp)
              (signal 'org-project-caldav-state-error
                      (list (format "Trailing data in state file %s" file))))
            object)))
    ((end-of-file invalid-read-syntax)
     (signal 'org-project-caldav-state-error
             (list (format "Could not parse state file %s: %s"
                           file (error-message-string err)))))))

(defun org-project-caldav--valid-state-entry-p (entry)
  "Return non-nil when ENTRY has the native state-entry shape."
  (and (proper-list-p entry)
       (= (length entry) 5)
       (stringp (nth 0 entry))
       (not (string-empty-p (nth 0 entry)))
       (or (null (nth 1 entry)) (stringp (nth 1 entry)))
       (or (null (nth 2 entry)) (stringp (nth 2 entry)))
       (or (null (nth 3 entry))
           (and (integerp (nth 3 entry)) (>= (nth 3 entry) 0)))
       (or (null (nth 4 entry))
           (and (stringp (nth 4 entry))
                (file-name-absolute-p (nth 4 entry))))))

(defun org-project-caldav--validate-state (state file)
  "Validate and return native STATE read from FILE."
  (unless (and (proper-list-p state)
               (equal (plist-get state :version)
                      org-project-caldav--state-version)
               (equal (plist-get state :calendar-id)
                      org-project-caldav-calendar-id)
               (listp (plist-get state :source-files))
               (cl-every
                (lambda (source)
                  (and (stringp source) (file-name-absolute-p source)))
                (plist-get state :source-files))
               (listp (plist-get state :entries))
               (cl-every #'org-project-caldav--valid-state-entry-p
                         (plist-get state :entries)))
    (signal 'org-project-caldav-state-error
            (list (format "Invalid synchronization state in %s" file))))
  (let ((seen (make-hash-table :test #'equal)))
    (dolist (entry (plist-get state :entries))
      (when (gethash (car entry) seen)
        (signal 'org-project-caldav-state-error
                (list (format "Duplicate state UID %s in %s"
                              (car entry) file))))
      (puthash (car entry) t seen)))
  state)

(defun org-project-caldav--read-legacy-state (file)
  "Read legacy org-caldav state from FILE without evaluating it."
  (condition-case err
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        (let ((read-eval nil)
              entries
              source-files)
          (while (progn
                   (skip-chars-forward " \t\r\n")
                   (not (eobp)))
            (pcase (read (current-buffer))
              (`(setq org-caldav-event-list (quote ,value))
               (setq entries value))
              (`(setq org-caldav-previous-files (quote ,value))
               (setq source-files value))
              (form
               (signal 'org-project-caldav-state-error
                       (list (format "Unexpected legacy state form: %S"
                                     form))))))
          (unless (and (listp entries)
                       (cl-every
                        (lambda (entry)
                          (and (proper-list-p entry)
                               (>= (length entry) 5)
                               (stringp (nth 0 entry))
                               (or (null (nth 1 entry))
                                   (stringp (nth 1 entry)))
                               (or (null (nth 2 entry))
                                   (stringp (nth 2 entry)))
                               (or (null (nth 3 entry))
                                   (and (integerp (nth 3 entry))
                                        (>= (nth 3 entry) 0)))))
                        entries)
                       (listp source-files)
                       (cl-every #'stringp source-files))
            (signal 'org-project-caldav-state-error
                    (list (format "Invalid legacy state in %s" file))))
          (list
           :version org-project-caldav--state-version
           :calendar-id org-project-caldav-calendar-id
           :source-files (mapcar #'expand-file-name source-files)
           :entries
           (mapcar
            (lambda (entry)
              (list (nth 0 entry) (nth 1 entry) (nth 2 entry)
                    (nth 3 entry) nil))
            entries))))
    ((end-of-file invalid-read-syntax)
     (signal 'org-project-caldav-state-error
             (list (format "Could not parse legacy state %s: %s"
                           file (error-message-string err)))))))

(defun org-project-caldav--load-state ()
  "Load native state, migrate legacy state in memory, or return empty state."
  (let ((native (org-project-caldav--state-file))
        (legacy (org-project-caldav--legacy-state-file)))
    (cond
     ((file-exists-p native)
      (org-project-caldav--validate-state
       (org-project-caldav--read-data-file native) native))
     ((file-exists-p legacy)
      (org-project-caldav--append-log
       "Migrating synchronization state from %s\n" legacy)
      (org-project-caldav--read-legacy-state legacy))
     (t
      (list :version org-project-caldav--state-version
            :calendar-id org-project-caldav-calendar-id
            :source-files nil
            :entries nil)))))

(defun org-project-caldav--write-state-temp (state)
  "Write STATE beside its destination and return the temporary file."
  (make-directory (org-project-caldav--state-directory) t)
  (let ((temporary
         (make-temp-file
          (expand-file-name ".state-" (org-project-caldav--state-directory)))))
    (condition-case err
        (progn
          (with-temp-buffer
            (let ((print-length nil)
                  (print-level nil))
              (prin1 state (current-buffer)))
            (insert "\n")
            (write-region nil nil temporary nil 'silent))
          temporary)
      (error
       (when (file-exists-p temporary)
         (delete-file temporary))
       (signal (car err) (cdr err))))))

(defun org-project-caldav--replace-vtodo-line
    (vtodo property replacement)
  "Replace PROPERTY and its folded continuation in VTODO with REPLACEMENT.
REPLACEMENT is a complete unfolded property line, or nil to remove it."
  (with-temp-buffer
    (insert (replace-regexp-in-string "\r\n?" "\n" vtodo))
    (goto-char (point-min))
    (let ((case-fold-search t)
          (regexp (format "^%s\\(?:;[^:\n]*\\)?:" (regexp-quote property))))
      (when (re-search-forward regexp nil t)
        (let ((begin (line-beginning-position)))
          (forward-line 1)
          (while (looking-at "[ \t]")
            (forward-line 1))
          (delete-region begin (point))))
      (when replacement
        (goto-char (point-min))
        (unless (re-search-forward
                 (if (string-equal property "UID")
                     "^BEGIN:VTODO$"
                   "^UID\\(?:;[^:\n]*\\)?:.*$")
                 nil t)
          (error "Cannot insert %s into malformed VTODO" property))
        (forward-line 1)
        (insert replacement "\n")))
    (buffer-string)))

(defun org-project-caldav--put-vtodo
    (uid vtodo &optional index previous-sequence)
  "Write VTODO for UID into the current vdir.
INDEX is the current vdir index.  PREVIOUS-SEQUENCE is used after deletion."
  (let* ((metadata (assoc-string uid (or index
                                         (org-project-caldav--vdir-index))))
         (file (or (nth 2 metadata)
                   (expand-file-name
                    (concat (secure-hash 'sha256 uid) ".ics")
                    org-project-caldav-vdir-directory)))
         (current-sequence
          (and metadata (plist-get (nth 3 metadata) :sequence)))
         (sequence (if (or current-sequence previous-sequence)
                       (1+ (max (or current-sequence 0)
                                (or previous-sequence 0)))
                     0))
         (event (org-project-caldav--replace-vtodo-line
                 vtodo "SEQUENCE" (format "SEQUENCE:%d" sequence)))
         (crlf-event (replace-regexp-in-string "\r?\n" "\r\n" event)))
    (org-project-caldav--atomic-write
     file
     (concat "BEGIN:VCALENDAR\r\n"
             "VERSION:2.0\r\n"
             "PRODID:-//org-project-caldav//EN\r\n"
             crlf-event
             (unless (string-suffix-p "\r\n" crlf-event) "\r\n")
             "END:VCALENDAR\r\n"))
    t))

(defun org-project-caldav--delete-event (uid &optional index)
  "Delete the local vdir item for UID."
  (let ((file (org-project-caldav--event-file uid index)))
    (when file
      (delete-file file))
    t))

(defun org-project-caldav--extract-vtodos ()
  "Return every complete VTODO string in the current buffer."
  (let (events)
    (goto-char (point-min))
    (while (re-search-forward "^BEGIN:VTODO\r?$" nil t)
      (let ((begin (line-beginning-position)))
        (unless (re-search-forward "^END:VTODO\r?$" nil t)
          (signal 'org-project-caldav-vtodo-error
                  (list "Unterminated VTODO in exported calendar")))
        (forward-line 1)
        (push (buffer-substring-no-properties begin (point)) events)))
    (nreverse events)))

(defun org-project-caldav--org-entry-marker (uid file)
  "Return a marker for UID in FILE, or signal an error."
  (or (org-id-find-id-in-file uid file t)
      (error "Could not find UID %s in %s" uid file)))

(defun org-project-caldav--org-entry-hash (uid file)
  "Return the content hash of Org entry UID in FILE."
  (let ((marker (org-project-caldav--org-entry-marker uid file)))
    (unwind-protect
        (with-current-buffer (marker-buffer marker)
          (save-excursion
            (goto-char marker)
            (md5 (buffer-substring-no-properties
                  (org-entry-beginning-position)
                  (org-entry-end-position)))))
      (set-marker marker nil))))

(defun org-project-caldav--todo-percent (state)
  "Return the configured completion percentage for Org TODO STATE."
  (or (car (rassoc state org-project-caldav--todo-percent-states))
      (error "Unsupported Org TODO state for CalDAV: %S" state)))

(defun org-project-caldav--ical-priority-at-point ()
  "Return the iCalendar priority for the Org heading at point."
  (if-let* ((priority (org-element-property
                       :priority (org-element-at-point))))
      (floor (- 9 (* 8.0 (/ (float (- org-priority-lowest priority))
                             (- org-priority-lowest
                                org-priority-highest)))))
    0))

(defun org-project-caldav--export-metadata (uid file)
  "Return export metadata for Org entry UID in FILE."
  (let ((marker (org-project-caldav--org-entry-marker uid file)))
    (unwind-protect
        (with-current-buffer (marker-buffer marker)
          (save-excursion
            (goto-char marker)
            (let* ((entry (org-element-at-point))
                   (state (org-get-todo-state))
                   (percent (org-project-caldav--todo-percent state)))
              (list :percent percent
                    :status (cond ((= percent 0) "NEEDS-ACTION")
                                  ((= percent 100) "COMPLETED")
                                  (t "IN-PROCESS"))
                    :priority (org-project-caldav--ical-priority-at-point)
                    :scheduled (org-entry-get nil "SCHEDULED")
                    :closed (org-element-property :closed entry)))))
      (set-marker marker nil))))

(defun org-project-caldav--strip-rrule-until (vtodo)
  "Remove the unsupported UNTIL clause from VTODO's RRULE."
  (with-temp-buffer
    (insert vtodo)
    (goto-char (point-min))
    (when (re-search-forward "^RRULE:\\([^\r\n]+\\)" nil t)
      (replace-match
       (string-join
        (seq-remove
         (lambda (clause) (string-prefix-p "UNTIL=" clause))
         (split-string (match-string 1) ";" t))
        ";")
       nil nil nil 1))
    (buffer-string)))

(defun org-project-caldav--cleanup-exported-description (vtodo)
  "Remove a leading exported Org timestamp from VTODO descriptions."
  (with-temp-buffer
    (insert vtodo)
    (goto-char (point-min))
    (when (re-search-forward
           (concat "^DESCRIPTION:\\(\\s-*"
                   org-ts-regexp
                   "\\(?:–" org-ts-regexp
                   "\\)?\\(?:\\\\n\\\\n\\)?\\)")
           nil t)
      (replace-match "" nil nil nil 1))
    (buffer-string)))

(defun org-project-caldav--normalize-exported-vtodo (vtodo uid file)
  "Normalize exported VTODO for Org entry UID in FILE."
  (let* ((metadata (org-project-caldav--export-metadata uid file))
         (percent (plist-get metadata :percent))
         (event (org-project-caldav--replace-vtodo-line
                 vtodo "UID" (concat "UID:" uid))))
    (setq event
          (org-project-caldav--replace-vtodo-line
           event "STATUS" (concat "STATUS:" (plist-get metadata :status))))
    (setq event
          (org-project-caldav--replace-vtodo-line
           event "PERCENT-COMPLETE"
           (format "PERCENT-COMPLETE:%d" percent)))
    (setq event
          (org-project-caldav--replace-vtodo-line
           event "PRIORITY"
           (format "PRIORITY:%d" (plist-get metadata :priority))))
    (unless (plist-get metadata :scheduled)
      (setq event
            (org-project-caldav--replace-vtodo-line event "DTSTART" nil)))
    (setq event
          (org-project-caldav--replace-vtodo-line
           event "COMPLETED"
           (when-let* ((closed (plist-get metadata :closed)))
             (org-icalendar-convert-timestamp closed "COMPLETED"))))
    (setq event (org-project-caldav--strip-rrule-until event))
    (setq event (org-project-caldav--cleanup-exported-description event))
    (when org-icalendar-timezone
      (setq event
            (replace-regexp-in-string
             (regexp-quote (upcase org-icalendar-timezone))
             org-icalendar-timezone event t t)))
    (setq event
          (replace-regexp-in-string
           "^CATEGORIES:[ \t]*\r?\n" "" event))
    event))

(defun org-project-caldav--generate-vtodos (files)
  "Export active leaf tasks from FILES as an alist keyed by UID."
  (let ((temporary (make-temp-file "org-project-caldav-export-" nil ".ics"))
        events)
    (unwind-protect
        (let ((org-icalendar-combined-agenda-file temporary)
              (org-icalendar-store-UID nil)
              (org-icalendar-include-bbdb-anniversaries nil)
              (org-icalendar-include-todo 'all)
              (org-icalendar-todo-unscheduled-start nil)
              (org-icalendar-timezone "Asia/Shanghai")
              (org-icalendar-date-time-format ";TZID=%Z:%Y%m%dT%H%M%S")
              (org-icalendar-categories '(local-tags))
              (org-project-caldav--reconciling t)
              (org-export-before-parsing-functions
               (cons #'org-project-caldav--filter-export-buffer
                     (remove #'org-project-caldav--filter-export-buffer
                             org-export-before-parsing-functions))))
          (apply #'org-icalendar--combine-files files)
          (with-temp-buffer
            (insert-file-contents temporary)
            (dolist (event (org-project-caldav--extract-vtodos))
              (let ((uid (with-temp-buffer
                           (insert event)
                           (org-project-caldav--buffer-uid))))
                (when (assoc-string uid events)
                  (error "Duplicate exported VTODO UID %s" uid))
                (push (cons uid event) events)))))
      (when (file-exists-p temporary)
        (delete-file temporary)))
    (nreverse events)))

(defun org-project-caldav--org-item-index (files)
  "Return UID, source, hash, and normalized VTODO entries from FILES."
  (let* ((active (org-project-caldav--active-task-index files))
         (exported (org-project-caldav--generate-vtodos files))
         index)
    (dolist (entry active)
      (let* ((uid (car entry))
             (file (cdr entry))
             (raw (cdr (assoc-string uid exported))))
        (unless raw
          (error "Org exporter omitted active task UID %s" uid))
        (push (list uid file
                    (org-project-caldav--org-entry-hash uid file)
                    (org-project-caldav--normalize-exported-vtodo
                     raw uid file))
              index)))
    (unless (= (length active) (length exported))
      (error "Org exporter produced unexpected VTODO entries"))
    (nreverse index)))

(defun org-project-caldav--todo-state-for-percent (percent)
  "Return the Org TODO state corresponding to VTODO PERCENT."
  (let ((number (string-to-number (or percent "0")))
        state)
    (dolist (entry org-project-caldav--todo-percent-states state)
      (when (>= number (car entry))
        (setq state (cdr entry))))))

(defun org-project-caldav--org-priority-for-vtodo (priority)
  "Return the Org priority string corresponding to VTODO PRIORITY."
  (let ((number (string-to-number (or priority "0")))
        result)
    (dolist (entry org-project-caldav--todo-priorities result)
      (when (>= number (car entry))
        (setq result (cdr entry))))))

(defun org-project-caldav--set-planning-from-vtodo (record)
  "Set planning timestamps on the heading at point from VTODO RECORD."
  (let ((scheduled
         (org-project-caldav-vtodo-org-time
          (plist-get record :scheduled-date)
          (plist-get record :scheduled-time)
          (plist-get record :rrule)))
        (deadline
         (org-project-caldav-vtodo-org-time
          (plist-get record :due-date)
          (plist-get record :due-time)
          (plist-get record :rrule)))
        (completed
         (org-project-caldav-vtodo-org-time
          (plist-get record :completed-date)
          (plist-get record :completed-time))))
    (if scheduled
        (org-schedule nil scheduled)
      (when (org-entry-get nil "SCHEDULED")
        (org-schedule '(4))))
    (if deadline
        (org-deadline nil deadline)
      (when (org-entry-get nil "DEADLINE")
        (org-deadline '(4))))
    (when completed
      (org-add-planning-info 'closed completed))))

(defun org-project-caldav--apply-vtodo-to-heading (record)
  "Apply synchronized fields from VTODO RECORD to the heading at point."
  (let ((state (org-project-caldav--todo-state-for-percent
                (plist-get record :percent)))
        (priority (org-project-caldav--org-priority-for-vtodo
                   (plist-get record :priority)))
        (location (plist-get record :location)))
    (unless state
      (error "VTODO has no supported completion state"))
    (org-edit-headline (plist-get record :summary))
    (unless (equal (org-get-todo-state) state)
      (org-todo state))
    (if priority
        (org-priority (string-to-char priority))
      (when (org-element-property :priority (org-element-at-point))
        (org-priority 'remove)))
    (org-set-tags (plist-get record :categories))
    (if (string-empty-p location)
        (org-delete-property "LOCATION")
      (org-set-property
       "LOCATION"
       (replace-regexp-in-string "[\r\n]+" ", " location)))
    (org-project-caldav--set-planning-from-vtodo record)))

(defun org-project-caldav--insert-description (description)
  "Insert non-empty VTODO DESCRIPTION below the current Org metadata."
  (when (not (string-empty-p description))
    (org-end-of-meta-data t)
    (unless (bolp)
      (insert "\n"))
    (let ((begin (point)))
      (insert description)
      (unless (bolp)
        (insert "\n"))
      (org-indent-region begin (point)))))

(defun org-project-caldav--insert-vtodo-into-org (record)
  "Insert VTODO RECORD as a new top-level task in the CalDAV inbox."
  (let ((inbox (org-project-caldav--inbox-file)))
    (with-current-buffer (find-file-noselect inbox)
      (org-with-wide-buffer
       (goto-char (point-max))
       (unless (bolp)
         (insert "\n"))
       (insert "* TODO " (plist-get record :summary) "\n")
       (forward-line -1)
       (org-set-property "ID" (plist-get record :uid))
       (org-project-caldav--apply-vtodo-to-heading record)
       (org-project-caldav--insert-description
        (plist-get record :description))
       (save-buffer)))
    inbox))

(defun org-project-caldav--update-org-from-vtodo (record file)
  "Update the Org entry in FILE from VTODO RECORD."
  (let ((marker (org-project-caldav--org-entry-marker
                 (plist-get record :uid) file)))
    (unwind-protect
        (with-current-buffer (marker-buffer marker)
          (org-with-wide-buffer
           (goto-char marker)
           (org-project-caldav--apply-vtodo-to-heading record)
           (save-buffer)))
      (set-marker marker nil))))

(defun org-project-caldav--delete-org-entry (uid file)
  "Delete Org entry UID from FILE."
  (let ((marker (org-project-caldav--org-entry-marker uid file)))
    (unwind-protect
        (with-current-buffer (marker-buffer marker)
          (org-with-wide-buffer
           (goto-char marker)
           (delete-region (org-entry-beginning-position)
                          (org-entry-end-position))
           (save-buffer)))
      (set-marker marker nil))))

(defun org-project-caldav--source-removals (state source-files org-index)
  "Return missing files and UIDs from STATE, SOURCE-FILES and ORG-INDEX.
Return nil unless both source files and previously synchronized tasks vanished."
  (let ((missing-files
         (cl-set-difference (plist-get state :source-files) source-files
                            :test #'file-equal-p))
        (current-uids (mapcar #'car org-index))
        missing-uids)
    (dolist (entry (plist-get state :entries))
      (unless (member (car entry) current-uids)
        (push (car entry) missing-uids)))
    (when (and missing-files missing-uids)
      (list :files (sort (mapcar #'substring-no-properties missing-files)
                         #'string<)
            :uids (sort (mapcar #'substring-no-properties missing-uids)
                        #'string<)))))

(defun org-project-caldav--assert-source-removal-safe
    (state source-files org-index)
  "Reject unapproved removal using STATE, SOURCE-FILES and ORG-INDEX."
  (when-let* ((removals (org-project-caldav--source-removals
                        state source-files org-index)))
    (unless (equal removals org-project-caldav--approved-removals)
      (signal 'org-project-caldav-confirmation-required
              (list (format
                     (concat "%d missing source files and %d removed task UIDs; "
                             "run M-x org-project-caldav-sync to confirm")
                     (length (plist-get removals :files))
                     (length (plist-get removals :uids))))))))

(defun org-project-caldav--prepare-sources (interactivep approved-removals)
  "Check sources before sync, returning this cycle's approved removals.
INTERACTIVEP allows minibuffer confirmation.  APPROVED-REMOVALS may supply
an exact, previously reviewed `org-project-caldav--source-removals' result."
  (unless (+org-project-known-files)
    (unless (and interactivep
                 (y-or-n-p
                  (format "No project Org files in %s; create default.org? "
                          (abbreviate-file-name +org-projects-dir))))
      (signal 'org-project-caldav-confirmation-required
              '("No project Org files; run M-x org-project-caldav-sync to create default.org")))
    (+org-project-ensure-default))
  (org-project-caldav--assert-saved)
  (let* ((files (org-project-caldav--source-files))
         (removals (org-project-caldav--source-removals
                    (org-project-caldav--load-state) files
                    (org-project-caldav--active-task-index files t))))
    (when removals
      (unless (or (equal removals approved-removals)
                  (and interactivep
                       (yes-or-no-p
                        (format
                         (concat "Sources missing: %s; accept removal of %d "
                                 "task UIDs (also deletes any matching CalDAV tasks)? ")
                         (mapconcat #'abbreviate-file-name
                                    (plist-get removals :files) ", ")
                         (length (plist-get removals :uids))))))
        (signal 'org-project-caldav-confirmation-required
                '("Source removals not approved; run M-x org-project-caldav-sync to confirm")))
      removals)))

(defun org-project-caldav--state-entry (uid state)
  "Return UID entry from STATE, or nil."
  (assoc-string uid (plist-get state :entries)))

(defun org-project-caldav--record-result (uid status action results)
  "Add UID, STATUS, and ACTION to RESULTS and return the new list."
  (cons (list org-project-caldav-calendar-id uid status action) results))

(defun org-project-caldav--apply-three-way-entry
    (uid previous org-item vdir-item results)
  "Reconcile UID across PREVIOUS, ORG-ITEM, and VDIR-ITEM.
Return the updated RESULTS list."
  (let ((org-changed
         (and previous
              (not (equal (and org-item (nth 2 org-item))
                          (nth 1 previous)))))
        (vdir-changed
         (and previous
              (not (equal (and vdir-item (nth 1 vdir-item))
                          (nth 2 previous)))))
        (previous-sequence (and previous (nth 3 previous))))
    (cond
     ((null previous)
      (cond
       ((and org-item vdir-item)
        (org-project-caldav--put-vtodo
         uid (nth 3 org-item) nil
         (plist-get (nth 3 vdir-item) :sequence))
        (org-project-caldav--record-result
         uid 'new-in-org 'org->cal results))
       (org-item
        (org-project-caldav--put-vtodo uid (nth 3 org-item))
        (org-project-caldav--record-result
         uid 'new-in-org 'org->cal results))
       (vdir-item
        (org-project-caldav--insert-vtodo-into-org (nth 3 vdir-item))
        (org-project-caldav--record-result
         uid 'new-in-cal 'cal->org results))
       (t results)))
     ((and org-item vdir-item)
      (cond
       (org-changed
        (org-project-caldav--put-vtodo
         uid (nth 3 org-item) nil previous-sequence)
        (org-project-caldav--record-result
         uid 'changed-in-org 'org->cal results))
       (vdir-changed
        (org-project-caldav--update-org-from-vtodo
         (nth 3 vdir-item) (nth 1 org-item))
        (org-project-caldav--record-result
         uid 'changed-in-cal 'cal->org results))
       (t results)))
     (org-item
      (if org-changed
          (progn
            (org-project-caldav--put-vtodo
             uid (nth 3 org-item) nil previous-sequence)
            (org-project-caldav--record-result
             uid 'changed-in-org 'org->cal results))
        (org-project-caldav--delete-org-entry uid (nth 1 org-item))
        (org-project-caldav--record-result
         uid 'deleted-in-cal 'removed-from-org results)))
     (vdir-item
      (org-project-caldav--delete-event uid)
      (org-project-caldav--record-result
       uid (if vdir-changed 'changed-in-cal 'deleted-in-org)
       'removed-from-cal results))
     (t results))))

(defun org-project-caldav--finalize-projection (source-files previous-state)
  "Make the staged vdir UID set equal active tasks in SOURCE-FILES.
Return the new native state, using PREVIOUS-STATE for sequence recovery."
  (let* ((org-index (org-project-caldav--org-item-index source-files))
         (vdir-index (org-project-caldav--vdir-index))
         (org-uids (mapcar #'car org-index))
         (vdir-uids (mapcar #'car vdir-index)))
    (dolist (uid (cl-set-difference vdir-uids org-uids :test #'string=))
      (org-project-caldav--delete-event uid vdir-index))
    (dolist (uid (cl-set-difference org-uids vdir-uids :test #'string=))
      (let ((org-item (assoc-string uid org-index))
            (previous (org-project-caldav--state-entry uid previous-state)))
        (org-project-caldav--put-vtodo
         uid (nth 3 org-item) vdir-index (and previous (nth 3 previous)))))
    (org-project-caldav--validate-coverage source-files)
    (setq vdir-index (org-project-caldav--vdir-index))
    (list
     :version org-project-caldav--state-version
     :calendar-id org-project-caldav-calendar-id
     :source-files (copy-sequence source-files)
     :entries
     (mapcar
      (lambda (org-item)
        (let* ((uid (car org-item))
               (vdir-item (assoc-string uid vdir-index)))
          (list uid (nth 2 org-item) (nth 1 vdir-item)
                (plist-get (nth 3 vdir-item) :sequence)
                (nth 1 org-item))))
      org-index))))

(defun org-project-caldav--reconcile-staged (source-files)
  "Reconcile SOURCE-FILES with the currently bound staging vdir."
  (let* ((state (org-project-caldav--load-state))
         (org-index (org-project-caldav--org-item-index source-files))
         (vdir-index (org-project-caldav--vdir-index))
         (uids (sort (delete-dups
                      (append (mapcar #'car (plist-get state :entries))
                              (mapcar #'car org-index)
                              (mapcar #'car vdir-index)))
                     #'string<))
         results)
    (org-project-caldav--assert-source-removal-safe
     state source-files org-index)
    (dolist (uid uids)
      (setq results
            (org-project-caldav--apply-three-way-entry
             uid
             (org-project-caldav--state-entry uid state)
             (assoc-string uid org-index)
             (assoc-string uid vdir-index)
             results)))
    (list :result (nreverse results)
          :state (org-project-caldav--finalize-projection
                  source-files state))))

(defun org-project-caldav--copy-vdir (source destination)
  "Copy the committed vdir from SOURCE into staging DESTINATION."
  (dolist (path (directory-files source t directory-files-no-dot-files-regexp))
    (cond
     ((file-regular-p path)
      (copy-file path (expand-file-name (file-name-nondirectory path)
                                        destination)
                 nil t nil t))
     ((file-directory-p path)
      (error "Unexpected directory in CalDAV vdir: %s" path)))))

(defun org-project-caldav--snapshot-source-files (files)
  "Return restorable snapshots for Org FILES."
  (mapcar
   (lambda (file)
     (let ((buffer (find-buffer-visiting file)))
       (list file
             (with-temp-buffer
               (insert-file-contents file)
               (buffer-string))
             buffer
             (and buffer (with-current-buffer buffer (point))))))
   files))

(defun org-project-caldav--restore-source-files (snapshots)
  "Restore Org file SNAPSHOTS after a failed reconciliation."
  (dolist (snapshot snapshots)
    (condition-case cleanup-error
        (let ((file (nth 0 snapshot))
              (text (nth 1 snapshot))
              (buffer (or (nth 2 snapshot)
                          (find-buffer-visiting (nth 0 snapshot))))
              (point-position (nth 3 snapshot)))
          (org-project-caldav--atomic-write file text)
          (when (buffer-live-p buffer)
            (with-current-buffer buffer
              (set-visited-file-modtime)
              (let ((inhibit-read-only t))
                (save-restriction
                  (widen)
                  (erase-buffer)
                  (insert text)
                  (goto-char (min (or point-position 1) (point-max)))
                  (set-buffer-modified-p nil)
                  (set-visited-file-modtime))))))
      (error
       (org-project-caldav--append-log
        "Org rollback failed: %s\n"
        (error-message-string cleanup-error))))))

(defun org-project-caldav--promote-vdir (staging)
  "Replace the committed vdir with STAGING and return its backup path."
  (let* ((live (directory-file-name org-project-caldav-vdir-directory))
         (parent (file-name-directory live))
         (backup (make-temp-name
                  (expand-file-name ".org-project-caldav-backup-" parent))))
    (rename-file live backup)
    (condition-case primary-error
        (progn
          (rename-file staging live)
          backup)
      (error
       (condition-case cleanup-error
           (rename-file backup live)
         (error
          (org-project-caldav--append-log
           "Vdir promotion rollback failed: %s\n"
           (error-message-string cleanup-error))))
       (signal (car primary-error) (cdr primary-error))))))

(defun org-project-caldav--rollback-promoted-vdir (backup)
  "Restore committed vdir BACKUP after a later transaction failure."
  (let* ((live (directory-file-name org-project-caldav-vdir-directory))
         (parent (file-name-directory live))
         (failed (make-temp-name
                  (expand-file-name ".org-project-caldav-failed-" parent))))
    (rename-file live failed)
    (condition-case primary-error
        (progn
          (rename-file backup live)
          (delete-directory failed t))
      (error
       (condition-case cleanup-error
           (rename-file failed live)
         (error
          (org-project-caldav--append-log
           "Vdir rollback recovery failed: %s\n"
           (error-message-string cleanup-error))))
       (signal (car primary-error) (cdr primary-error))))))

(defun org-project-caldav--cleanup-temporary-path (path)
  "Delete temporary PATH while keeping cleanup failure visible in the log."
  (when (and path (file-exists-p path))
    (condition-case cleanup-error
        (if (file-directory-p path)
            (delete-directory path t)
          (delete-file path))
      (error
       (org-project-caldav--append-log
        "Temporary cleanup failed for %s: %s\n"
        path (error-message-string cleanup-error))))))

(defun org-project-caldav--reconcile ()
  "Transactionally reconcile saved Org tasks with the committed local vdir."
  (org-project-caldav--ensure-layout)
  (org-project-caldav--assert-saved)
  (unless (eq org-project-caldav-conflict-policy 'org-wins)
    (error "Unsupported CalDAV conflict policy: %S"
           org-project-caldav-conflict-policy))
  (let* ((source-files (org-project-caldav--source-files))
         (snapshots (org-project-caldav--snapshot-source-files source-files))
         staging
         state-temporary
         backup
         promoted
         payload)
    (condition-case primary-error
        (progn
          (dolist (file source-files)
            (org-project-caldav--create-leaf-uids file))
          (setq source-files (org-project-caldav--source-files))
          (org-id-update-id-locations source-files)
          (let ((parent
                 (file-name-directory
                  (directory-file-name
                   org-project-caldav-vdir-directory))))
            (setq staging
                  (make-temp-file
                   (expand-file-name
                    ".org-project-caldav-stage-" parent)
                   t)))
          (org-project-caldav--copy-vdir
           org-project-caldav-vdir-directory staging)
          (let ((org-project-caldav-vdir-directory staging)
                (org-project-caldav--reconciling t))
            (setq payload
                  (org-project-caldav--reconcile-staged source-files)
                  state-temporary
                  (org-project-caldav--write-state-temp
                   (plist-get payload :state))))
          (setq backup (org-project-caldav--promote-vdir staging)
                promoted t
                staging nil)
          (rename-file state-temporary (org-project-caldav--state-file) t)
          (setq state-temporary nil)
          (org-project-caldav--cleanup-temporary-path backup)
          (setq backup nil)
          (plist-get payload :result))
      (error
       (when (and promoted backup (file-exists-p backup))
         (condition-case cleanup-error
             (org-project-caldav--rollback-promoted-vdir backup)
           (error
            (org-project-caldav--append-log
             "Committed vdir rollback failed: %s\n"
             (error-message-string cleanup-error)))))
       (org-project-caldav--restore-source-files snapshots)
       (org-project-caldav--cleanup-temporary-path staging)
       (org-project-caldav--cleanup-temporary-path state-temporary)
       (signal (car primary-error) (cdr primary-error))))))

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

(defun org-project-caldav--record-failure (message &optional needs-confirmation)
  "Log failure MESSAGE and finish the current cycle without a notification.
With NEEDS-CONFIRMATION, mark the log entry as waiting for user action."
  (setq org-project-caldav--process nil
        org-project-caldav--running nil
        org-project-caldav--pending nil
        org-project-caldav--discovery-attempted nil
        org-project-caldav--approved-removals nil)
  (org-project-caldav--append-log
   "\n%s%s\n" (if needs-confirmation "CalDAV waiting: " "") message)
  (setq org-project-caldav--last-error message))

(defun org-project-caldav--finish-success ()
  "Record a successful complete synchronization cycle."
  (let ((rerun org-project-caldav--pending))
    (setq org-project-caldav--process nil
          org-project-caldav--running nil
          org-project-caldav--pending nil
          org-project-caldav--discovery-attempted nil
          org-project-caldav--approved-removals nil
          org-project-caldav--last-success (current-time)
          org-project-caldav--last-error nil)
    (org-project-caldav--append-log
     "Completed at %s\n" (format-time-string "%F %T"))
    (when rerun
      (run-at-time 0 nil #'org-project-caldav-sync))))

(defun org-project-caldav--discovery-required-p (process)
  "Return non-nil when PROCESS output requests vdirsyncer discovery."
  (let ((buffer (process-buffer process)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (save-excursion
          ;; A process started before this library was reloaded has no boundary.
          (goto-char (or (process-get process 'org-project-caldav-log-start)
                         (point-min)))
          (re-search-forward
           "\\(?:Please run.*vdirsyncer discover\\|Detected change in config\\)"
           nil t))))))

(defun org-project-caldav--handle-process-exit (process stage)
  "Handle completion of vdirsyncer PROCESS for STAGE."
  (when (eq process org-project-caldav--process)
    (setq org-project-caldav--process nil)
    (if (and (eq (process-status process) 'exit)
             (zerop (process-exit-status process)))
        (pcase stage
          ('discover (org-project-caldav--start-vdirsyncer 'pre-sync))
          ('pre-sync
           (condition-case err
               (progn
                 (setq org-project-caldav--last-result
                       (org-project-caldav--reconcile))
                 (org-project-caldav--start-vdirsyncer 'post-sync))
             (org-project-caldav-confirmation-required
              (org-project-caldav--record-failure
               (error-message-string err) t))
             (error
              (org-project-caldav--record-failure
               (format "Local CalDAV reconciliation failed: %s"
                       (error-message-string err))))))
          ('post-sync (org-project-caldav--finish-success))
          (_ (org-project-caldav--record-failure
              (format "Unknown CalDAV process stage: %S" stage))))
      (if (and (eq stage 'pre-sync)
               (not org-project-caldav--discovery-attempted)
               (org-project-caldav--discovery-required-p process))
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
  ;; Timers can run in buffers whose project directory was moved or deleted.
  (let* ((default-directory
          (file-name-as-directory
           (expand-file-name org-project-caldav-vdir-directory)))
         (credentials (org-project-caldav--credentials))
         (username (car credentials))
         (password (cdr credentials))
         (process-environment (copy-sequence process-environment))
         (buffer (get-buffer-create org-project-caldav--log-buffer))
         log-start)
    (unwind-protect
        (progn
          (setenv "ORG_PROJECT_CALDAV_USERNAME" username)
          (setenv "ORG_PROJECT_CALDAV_PASSWORD" password)
          (when (eq stage 'pre-sync)
            (with-current-buffer buffer
              (let ((inhibit-read-only t))
                (delete-region
                 (point-min)
                 (max (point-min)
                      (- (point-max) org-project-caldav--log-history-limit))))))
          (setq log-start (with-current-buffer buffer (point-max)))
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
            (process-put process 'org-project-caldav-log-start log-start)
            (setq org-project-caldav--process process)))
      (clear-string password))))

;;;###autoload
(defun org-project-caldav-sync (&optional approved-removals)
  "Request an asynchronous CalDAV synchronization cycle.
Interactively, confirm creating a default project when no project files exist,
and confirm missing sources that also removed task UIDs.  Background requests
wait for manual confirmation without opening the minibuffer or a warning.
Programmatic APPROVED-REMOVALS must be the exact reviewed result from
`org-project-caldav--source-removals'; approval expires with this cycle."
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
              ;; Reserve the cycle before a prompt can dispatch other timers.
              (setq org-project-caldav--running t
                    org-project-caldav--pending nil
                    org-project-caldav--discovery-attempted nil
                    org-project-caldav--approved-removals nil)
              (setq org-project-caldav--approved-removals
                    (org-project-caldav--prepare-sources
                     (called-interactively-p 'interactive) approved-removals))
              (org-project-caldav--start-vdirsyncer 'pre-sync)
              (when (called-interactively-p 'interactive)
                (message "CalDAV sync started in the background")))))
      (org-project-caldav-confirmation-required
       (org-project-caldav--record-failure (error-message-string err) t))
      (quit
       (org-project-caldav--record-failure "Synchronization cancelled" t))
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

;;;###autoload
(defun org-project-caldav-setup ()
  "Integrate background CalDAV synchronization with org-project."
  ;; An earlier configuration may have left this autoload installed.  Hiding
  ;; it does not load or depend on the retired package.
  (function-put 'org-caldav-sync 'completion-predicate #'ignore)
  (+org-project-sync-agenda-files)
  (add-to-list 'org-agenda-files (org-project-caldav--inbox-file) t)
  (when (and org-project-caldav-auto-sync (not noninteractive)
             (not org-project-caldav-mode))
    (org-project-caldav-mode 1)))

(provide 'org-project-caldav)
;;; org-project-caldav.el ends here
