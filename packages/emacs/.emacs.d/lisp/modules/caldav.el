;;; caldav.el --- explicit conflict-safe Org CalDAV sync -*- lexical-binding: t; -*-
;;; Commentary:
;; Explicit pull, push, force-pull, and force-push semantics for the Org task
;; collection, including Git merges and ETag concurrency protection.
;;; Code:

(require 'git-foreign)
(require 'init-notes)
(require 'org-project)

;; The Emacs URL library resolves both the login and password through
;; `auth-source' after the server's Basic Auth challenge.
(defconst +notes/caldav-url "https://caldav.gw-api.xyz/jamie"
  "Base URL of the task CalDAV collection.")

(defconst +notes/caldav-calendar-id "org-tasks"
  "Calendar ID of the task CalDAV collection.")

(defconst +notes/caldav-git-remote-name "caldav"
  "Logical Git remote name for the task CalDAV collection.")

(defconst +notes/caldav-git-base-ref "refs/git-foreign/caldav/base"
  "Git ref storing the last integrated CalDAV snapshot.")

(defconst +notes/caldav-git-remote-ref "refs/git-foreign/caldav/remote"
  "Git ref storing the latest complete CalDAV snapshot.")

(defconst +notes/caldav-git-backup-ref-prefix
  "refs/git-foreign/caldav/backups"
  "Git ref prefix for CalDAV safety backups.")

(defconst +notes/caldav-inbox-file
  (expand-file-name "caldav-inbox.org" +emacs/org-root-dir)
  "Org file receiving tasks created through CalDAV clients.")

(defconst +notes/caldav-tasks-file
  (expand-file-name "caldav-tasks.org" +emacs/org-root-dir)
  "Legacy Org file containing tasks exported through CalDAV.")

(defvar +notes/caldav--syncing nil
  "Non-nil while syncing the project TODO view through CalDAV.")

(defvar +notes/caldav--pulling nil
  "Non-nil while pulling changes from CalDAV.")

(defvar +notes/caldav--pushing nil
  "Non-nil while pushing changes to CalDAV.")

(defvar +notes/caldav--force-pulling nil
  "Non-nil while replacing local CalDAV tasks from the remote snapshot.")

(defvar +notes/caldav--force-pushing nil
  "Non-nil while replacing the remote calendar from the local snapshot.")

(defvar +notes/caldav--remote-etags :not-fetched
  "Remote ETags observed while updating the current CalDAV pull.")

(defvar +notes/caldav--last-verified-remote-etags :unknown
  "Remote ETags verified by the most recent successful explicit sync.")

(defvar +notes/caldav--force-remote-etags nil
  "Remote ETags fetched immediately before the current forced push.")

(defvar +notes/caldav--force-local-uids nil
  "UIDs exported from Org immediately before the current forced pull.")

(defvar +notes/caldav--write-etags nil
  "ETags returned by writes during the current CalDAV push.")

(defvar +notes/caldav--push-races nil
  "UIDs changed remotely while the current CalDAV push was running.")

(defvar +notes/caldav--snapshotting nil
  "Non-nil while projecting a complete CalDAV snapshot into Git.")

(defvar org-caldav-files nil)
(defvar org-caldav-inbox nil)
(defvar org-caldav-url nil)
(defvar org-caldav-backup-file nil)
(defvar org-caldav-event-list nil)
(defvar org-caldav-sync-result nil)
(defvar org-caldav-empty-calendar nil)
(defvar org-caldav-previous-files nil)
(defvar org-caldav-calendar-id nil)
(defvar org-caldav-uuid-extension ".ics")
(defvar org-id--locations-checksum nil)
(defvar org-id-extra-files nil)
(defvar org-id-files nil)
(defvar org-id-locations nil)
(defvar org-id-locations-file nil)
(defvar org-id-search-archives nil)
(defvar org-journal-dir nil)

(declare-function org-journal--get-entry-path "org-journal" (&optional time))
(declare-function org-journal--search-forward-created
                  "org-journal" (date &optional bound noerror count))
(declare-function org-caldav-check-connection "org-caldav" ())
(declare-function org-caldav-delete-event "org-caldav" (uid))
(declare-function org-caldav-display-sync-results "org-caldav" ())
(declare-function org-caldav-event-etag "org-caldav" (event))
(declare-function org-caldav-event-md5 "org-caldav" (event))
(declare-function org-caldav-event-set-etag "org-caldav" (event etag))
(declare-function org-caldav-event-set-md5 "org-caldav" (event md5sum))
(declare-function org-caldav-event-set-status "org-caldav" (event status))
(declare-function org-caldav-event-status "org-caldav" (event))
(declare-function org-caldav-get-event-etag-list "org-caldav" ())
(declare-function org-caldav-get-uid "org-caldav" ())
(declare-function org-caldav-generate-ics "org-caldav" ())
(declare-function org-caldav-inbox-file "org-caldav" (inbox))
(declare-function org-caldav-load-sync-state "org-caldav" ())
(declare-function org-caldav-sync "org-caldav" ())
(declare-function org-caldav-sync-state-filename "org-caldav" (id))
(declare-function git-foreign-materialize-commit
                  "git-foreign" (context revision))
(declare-function org-id-find "org-id" (id &optional markerp))

(defun +notes/caldav-configure ()
  "Apply this configuration's explicit org-caldav settings."
  (setq org-caldav-url +notes/caldav-url
        org-caldav-calendar-id +notes/caldav-calendar-id
        org-caldav-inbox +notes/caldav-inbox-file
        ;; The actual list is refreshed immediately before every sync.
        org-caldav-files nil
        org-icalendar-timezone "Asia/Shanghai"
        org-icalendar-include-todo 'all
        org-caldav-sync-todo t
        org-caldav-sync-direction 'cal->org
        org-caldav-show-sync-results nil))

(defun +notes/caldav-ensure-files ()
  "Create dedicated CalDAV Org files and add them to the agenda."
  (make-directory +emacs/org-root-dir t)
  (dolist (file (list +notes/caldav-inbox-file
                      +notes/caldav-tasks-file))
    (unless (file-exists-p file)
      (with-temp-file file))
    (add-to-list 'org-agenda-files file t)))

(defun +notes/caldav-source-files ()
  "Return the Org files backing `org-project-todo-list'."
  (+org-project-sync-agenda-files)
  (+org-agenda-prune-files)
  (delete-dups
   (append (+org-project--agenda-non-project-files)
           (+org-project-known-files))))

(defun +notes/caldav--journal-inbox-target ()
  "Return today's journal heading as an `org-caldav-inbox' target."
  (require 'org-journal)
  (let* ((time (current-time))
         (decoded (decode-time time))
         (date (list (nth 4 decoded) (nth 3 decoded) (nth 5 decoded)))
         (file (org-journal--get-entry-path time))
         (buffer (find-file-noselect file))
         heading)
    (with-current-buffer buffer
      (save-excursion
        (save-restriction
          (widen)
          ;; A prefix creates today's date heading without a time entry.
          (org-journal-new-entry t time)
          (goto-char (point-min))
          (unless (org-journal--search-forward-created date nil t)
            (error "Could not find today's journal heading in %s" file))
          (org-back-to-heading t)
          (setq heading (org-get-heading t t t t))
          (when (buffer-modified-p)
            (save-buffer)))))
    (list 'file+headline file heading)))

(defun +notes/caldav--inbox-target ()
  "Return the journal inbox target, falling back to a dedicated file."
  (condition-case err
      (+notes/caldav--journal-inbox-target)
    (error
     (display-warning
      'org-caldav
      (format "Could not prepare journal inbox; using %s: %s"
              +notes/caldav-inbox-file
              (error-message-string err)))
     +notes/caldav-inbox-file)))

(defun +notes/caldav--prepare-project-files ()
  "Prepare the inbox and project files used by `org-caldav'."
  (let ((source-files (+notes/caldav-source-files)))
    (setq org-caldav-inbox (if +notes/caldav--snapshotting
                               +notes/caldav-inbox-file
                             (+notes/caldav--inbox-target))
          org-caldav-files
          (if +notes/caldav--snapshotting
              (seq-filter #'file-readable-p source-files)
            source-files)))
  ;; org-caldav only refreshes IDs before an Org-to-CalDAV sync.  A pull also
  ;; needs current markers so remote changes land in their source files.
  (org-id-update-id-locations
   (delete-dups
    (cons (org-caldav-inbox-file org-caldav-inbox)
          org-caldav-files))))

(defun +notes/caldav--modified-org-buffers ()
  "Return modified file buffers below `+emacs/org-root-dir'."
  (let ((root (file-name-as-directory
               (file-truename +emacs/org-root-dir))))
    (seq-filter
     (lambda (buffer)
       (with-current-buffer buffer
         (and buffer-file-name
              (buffer-modified-p)
              (file-in-directory-p (file-truename buffer-file-name) root))))
     (buffer-list))))

(defun +notes/caldav--assert-org-buffers-saved ()
  "Refuse to sync while an Org file buffer has unsaved changes."
  (when-let* ((buffers (+notes/caldav--modified-org-buffers)))
    (user-error
     "Save Org buffers before CalDAV sync: %s"
     (mapconcat #'buffer-name buffers ", "))))

(defun +notes/caldav--conflict-files ()
  "Return Org files containing unresolved CalDAV conflict markers."
  (seq-filter
   (lambda (file)
     (with-temp-buffer
       (insert-file-contents file)
       (re-search-forward "^<<<<<<< " nil t)))
   (directory-files-recursively +emacs/org-root-dir "\\.org\\'")))

(defun +notes/caldav--assert-no-conflicts ()
  "Refuse to sync while CalDAV conflict markers remain."
  (when-let* ((files (+notes/caldav--conflict-files)))
    (user-error
     "Resolve CalDAV conflicts before syncing: %s"
     (mapconcat (lambda (file)
                  (file-relative-name file +emacs/org-root-dir))
                files ", "))))

(defun +notes/caldav--git-context ()
  "Return the foreign Git context for the Org repository."
  (let* ((repo (directory-file-name
                (file-truename +emacs/org-root-dir)))
         (context
          (git-foreign-make-context
           :repo repo
           :label "CalDAV"
           :remote-marker-suffix "gitForeignCalendarId"
           :remote-marker-value +notes/caldav-calendar-id
           :base-ref +notes/caldav-git-base-ref
           :remote-ref +notes/caldav-git-remote-ref
           :backup-ref-prefix +notes/caldav-git-backup-ref-prefix
           :identity-name "CalDAV Snapshot"
           :identity-email "caldav@local"))
         (toplevel
          (git-foreign-output-noerror
           context "rev-parse" "--show-toplevel")))
    (unless (and toplevel (file-equal-p repo toplevel))
      (user-error "Org root is not a Git repository: %s" repo))
    context))

(defun +notes/caldav--git-worktree-status (context)
  "Return porcelain worktree status for foreign CONTEXT."
  (git-foreign-output
   context "status" "--porcelain=v1" "--untracked-files=all"))

(defun +notes/caldav--assert-clean-git-worktree (context)
  "Require a clean, merge-free worktree for foreign CONTEXT."
  (when (git-foreign-rev-parse-noerror context "MERGE_HEAD")
    (user-error "Complete or abort the current Git merge before CalDAV sync"))
  (let ((status (+notes/caldav--git-worktree-status context)))
    (unless (string-empty-p status)
      (user-error
       "Commit or discard Git changes before CalDAV sync:\n%s"
       status))))

(defun +notes/caldav--ensure-git-state
    (context &optional allow-without-sync-state)
  "Validate the logical remote and initialize refs for foreign CONTEXT.
When ALLOW-WITHOUT-SYNC-STATE is non-nil, permit an explicit forced operation
to establish the first baseline."
  (let ((base (git-foreign-rev-parse-noerror
               context (git-foreign-base-ref context)))
        (remote-name (git-foreign-remote-name context)))
    (when (and base (not remote-name))
      (user-error
       (concat "The CalDAV logical remote was removed; run "
               "`+notes/caldav-register-remote' to restore it")))
    (unless remote-name
      (git-foreign-register-remote context +notes/caldav-git-remote-name))
    ;; Reapply the skip flags after a user-visible `git remote rename'.
    (when remote-name
      (git-foreign-register-remote context remote-name))
    (unless base
      (let ((state-file
             (org-caldav-sync-state-filename org-caldav-calendar-id)))
        (unless (or allow-without-sync-state (file-exists-p state-file))
          (user-error
           "Run a forced CalDAV pull or push before initializing Git state")))
      (let ((head (git-foreign-rev-parse context "HEAD")))
        (git-foreign-set-base-ref context head)
        (git-foreign-set-remote-ref context head)))
    (when (and base
               (not (git-foreign-rev-parse-noerror
                     context (git-foreign-remote-ref context))))
      (git-foreign-set-remote-ref context base)))
  context)

(defun +notes/caldav-register-remote (&optional name)
  "Register the branchless CalDAV logical remote as NAME.
NAME defaults to `+notes/caldav-git-remote-name'."
  (interactive)
  (let ((remote
         (git-foreign-register-remote
          (+notes/caldav--git-context)
          (or name +notes/caldav-git-remote-name))))
    (message "Registered CalDAV logical remote `%s'" remote)
    remote))

(defun +notes/caldav--file-buffers-below (directory)
  "Return live file buffers below DIRECTORY."
  (let ((root (file-name-as-directory (file-truename directory))))
    (seq-filter
     (lambda (buffer)
       (and (buffer-live-p buffer)
            (with-current-buffer buffer
              (and buffer-file-name
                   (file-in-directory-p
                    (expand-file-name buffer-file-name)
                    root)))))
     (buffer-list))))

(defun +notes/caldav--org-buffers-below (function directory &rest arguments)
  "Call FUNCTION with ARGUMENTS and keep Org file buffers below DIRECTORY."
  (let ((root (file-name-as-directory (file-truename directory))))
    (seq-filter
     (lambda (buffer)
       (and (buffer-live-p buffer)
            (with-current-buffer buffer
              (and buffer-file-name
                   (file-in-directory-p
                    (expand-file-name buffer-file-name)
                    root)))))
     (apply function arguments))))

(defun +notes/caldav--repo-file-buffers ()
  "Return live file buffers below the Org Git repository."
  (+notes/caldav--file-buffers-below +emacs/org-root-dir))

(defun +notes/caldav--discard-file-buffers-below (directory)
  "Kill disposable file buffers below temporary DIRECTORY."
  (dolist (buffer (+notes/caldav--file-buffers-below directory))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (set-buffer-modified-p nil))
      (kill-buffer buffer))))

(defun +notes/caldav--revert-repo-buffers (buffers)
  "Revert unmodified repository BUFFERS after an external Git change."
  (dolist (buffer buffers)
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when (buffer-modified-p)
          (error "Repository buffer became modified during CalDAV sync: %s"
                 (buffer-name buffer)))
        (if (and buffer-file-name (file-exists-p buffer-file-name))
            (revert-buffer t t t)
          (kill-buffer buffer))))))

(defun +notes/caldav--sync-state-backup ()
  "Return a recoverable backup of the current org-caldav state."
  (let* ((state-file
          (org-caldav-sync-state-filename org-caldav-calendar-id))
         (exists (file-exists-p state-file))
         (backup (and exists (make-temp-file "caldav-state."))))
    (when backup
      (copy-file state-file backup t))
    (list :state-file state-file :existed exists :backup backup)))

(defun +notes/caldav--restore-sync-state (backup)
  "Restore org-caldav state from BACKUP."
  (let ((state-file (plist-get backup :state-file))
        (existed (plist-get backup :existed))
        (backup-file (plist-get backup :backup)))
    (if existed
        (copy-file backup-file state-file t)
      (when (file-exists-p state-file)
        (delete-file state-file)))))

(defun +notes/caldav--delete-state-backup (backup)
  "Delete the temporary state BACKUP, reporting cleanup failures."
  (when-let* ((file (plist-get backup :backup)))
    (condition-case err
        (when (file-exists-p file)
          (delete-file file))
      (error
       (display-warning
        'org-caldav
        (format "Could not remove CalDAV state backup %s: %s"
                file (error-message-string err)))))))

(defun +notes/caldav--run-remote-pull (&optional force)
  "Update the projected worktree from CalDAV.
When FORCE is non-nil, make the remote collection the complete snapshot."
  (+notes/caldav--prepare-project-files)
  (let ((local-uids (and force (+notes/caldav--local-event-uids))))
    (when force
      ;; UID creation during the inventory can make ID locations stale.
      (+notes/caldav--prepare-project-files))
    (let ((+notes/caldav--pulling t)
          (+notes/caldav--force-pulling force)
          (+notes/caldav--force-local-uids local-uids)
          (+notes/caldav--remote-etags :not-fetched)
          (org-caldav-sync-direction 'cal->org)
          (org-caldav-delete-org-entries 'always)
          (org-caldav-resume-aborted 'never))
      (org-caldav-sync)
      (when (+notes/caldav--sync-errors)
        (org-caldav-display-sync-results)
        (user-error "CalDAV pull finished with errors; inspect the results"))
      (+notes/caldav--finish-remote-pull))))

(defun +notes/caldav--snapshot-agenda-files
    (files repository snapshot)
  "Rebase agenda FILES below REPOSITORY into SNAPSHOT."
  (let ((repository (file-name-as-directory (expand-file-name repository))))
    (delq nil
          (mapcar
           (lambda (file)
             (when (stringp file)
               (let ((file (expand-file-name file)))
                 (when (file-in-directory-p file repository)
                   (expand-file-name
                    (file-relative-name file repository)
                    snapshot)))))
           files))))

(defun +notes/caldav--rebase-files (files source destination)
  "Rebase FILES below SOURCE onto DESTINATION.
Files outside SOURCE are preserved so org-caldav can still detect a genuinely
removed sync source."
  (let ((source (file-name-as-directory (expand-file-name source))))
    (mapcar
     (lambda (file)
       (if (and (stringp file)
                (file-in-directory-p (expand-file-name file) source))
           (expand-file-name (file-relative-name file source) destination)
         file))
     files)))

(defun +notes/caldav--load-snapshot-sync-state
    (function repository snapshot)
  "Call FUNCTION and rebase its saved file list from REPOSITORY to SNAPSHOT."
  (funcall function)
  (setq org-caldav-previous-files
        (+notes/caldav--rebase-files
         org-caldav-previous-files repository snapshot)))

(defun +notes/caldav--save-snapshot-sync-state
    (function snapshot repository)
  "Call FUNCTION while rebasing SNAPSHOT file paths onto REPOSITORY."
  (let ((org-caldav-files
         (+notes/caldav--rebase-files
          org-caldav-files snapshot repository)))
    (funcall function)))

(defun +notes/caldav--capture-remote-snapshot (context)
  "Capture a complete remote CalDAV commit for foreign CONTEXT.
The projection runs in a temporary directory materialized from the previous
remote commit, so the local branch, index, worktree, and live buffers are never
changed."
  (let* ((base (git-foreign-rev-parse
                context (git-foreign-base-ref context)))
         (parent (or (git-foreign-rev-parse-noerror
                      context (git-foreign-remote-ref context))
                     base))
         (state-backup (+notes/caldav--sync-state-backup))
         snapshot
         id-locations-file
         remote-commit
         primary-error)
    (condition-case err
        (progn
          (setq snapshot (git-foreign-materialize-commit context parent)
                id-locations-file
                (concat (directory-file-name snapshot) ".org-id-locations"))
          (let* ((repository (git-foreign-context-repo context))
                 (+emacs/org-root-dir snapshot)
                 (+org-project-root-dir snapshot)
                 (+org-projects-dir (expand-file-name "projects" snapshot))
                 (+notes/caldav-inbox-file
                  (expand-file-name "caldav-inbox.org" snapshot))
                 (+notes/caldav-tasks-file
                  (expand-file-name "caldav-tasks.org" snapshot))
                 (org-journal-dir (expand-file-name "journal" snapshot))
                 (org-agenda-files
                  (+notes/caldav--snapshot-agenda-files
                   org-agenda-files repository snapshot))
                 (org-caldav-files nil)
                 (org-caldav-inbox +notes/caldav-inbox-file)
                 (org-caldav-backup-file nil)
                 (org-id-locations-file id-locations-file)
                 (org-id-locations nil)
                 (org-id-extra-files nil)
                 (org-id-files nil)
                 (org-id--locations-checksum nil)
                 (org-id-search-archives nil)
                 (+notes/caldav--snapshotting t))
            ;; `org-id-update-id-locations' normally includes every live Org
            ;; buffer.  Hide the real worktree here so duplicate IDs across
            ;; the real and materialized trees cannot leak into resolution.
            (let ((org-buffer-list-function
                   (symbol-function 'org-buffer-list))
                  (load-sync-state-function
                   (symbol-function 'org-caldav-load-sync-state))
                  (save-sync-state-function
                   (symbol-function 'org-caldav-save-sync-state)))
              (cl-letf (((symbol-function 'org-buffer-list)
                         (lambda (&rest arguments)
                           (apply #'+notes/caldav--org-buffers-below
                                  org-buffer-list-function
                                  snapshot
                                  arguments)))
                        ((symbol-function 'org-caldav-load-sync-state)
                         (lambda ()
                           (+notes/caldav--load-snapshot-sync-state
                            load-sync-state-function repository snapshot)))
                        ((symbol-function 'org-caldav-save-sync-state)
                         (lambda ()
                           (+notes/caldav--save-snapshot-sync-state
                            save-sync-state-function snapshot repository))))
                (+notes/caldav--run-remote-pull))))
          (setq remote-commit
                (git-foreign-commit-directory
                 context
                 snapshot
                 parent
                 (format "caldav: remote snapshot %s"
                         (format-time-string "%Y-%m-%d %H:%M:%S")))))
      (error (setq primary-error err)))
    (condition-case err
        (when snapshot
          (+notes/caldav--discard-file-buffers-below snapshot)
          (delete-directory snapshot t))
      (error
       (if primary-error
           (display-warning
            'org-caldav
            (format "CalDAV snapshot cleanup failed: %s"
                    (error-message-string err)))
         (setq primary-error err))))
    (condition-case err
        (when (and id-locations-file
                   (file-exists-p id-locations-file))
          (delete-file id-locations-file))
      (error
       (if primary-error
           (display-warning
            'org-caldav
            (format "CalDAV Org ID cleanup failed: %s"
                    (error-message-string err)))
         (setq primary-error err))))
    (when primary-error
      (condition-case err
          (+notes/caldav--restore-sync-state state-backup)
        (file-error
         (display-warning
          'org-caldav
          (format "CalDAV state rollback failed: %s"
                  (error-message-string err)))))
      (+notes/caldav--delete-state-backup state-backup)
      (signal (car primary-error) (cdr primary-error)))
    (+notes/caldav--delete-state-backup state-backup)
    (git-foreign-set-remote-ref context remote-commit)
    remote-commit))

(defun +notes/caldav--mark-head-synchronized (context)
  "Mark HEAD as the synchronized state for foreign CONTEXT."
  (git-foreign-set-base-ref context "HEAD")
  (git-foreign-set-remote-ref context "HEAD"))

(defun +notes/caldav--remote-integrated-p (context)
  "Return non-nil when foreign CONTEXT is safe for a normal push."
  (let* ((state (git-foreign-read-state context))
         (status (plist-get state :status))
         (remote (plist-get state :remote-commit)))
    (or (memq status '(in-sync head-matches-remote remote-matches-base))
        (git-foreign-output-noerror
         context "merge-base" "--is-ancestor" remote "HEAD"))))

(defun +notes/caldav--git-status-data ()
  "Return non-mutating Git status data for the CalDAV adapter."
  (let* ((context (+notes/caldav--git-context))
         (base (git-foreign-rev-parse-noerror
                context (git-foreign-base-ref context)))
         (remote (git-foreign-rev-parse-noerror
                  context (git-foreign-remote-ref context)))
         (state (and base remote (git-foreign-read-state context))))
    (list :remote-name (git-foreign-remote-name context)
          :clean (string-empty-p
                  (+notes/caldav--git-worktree-status context))
          :state state
          :push-ready (and state
                           (+notes/caldav--remote-integrated-p context)))))

(defun +notes/caldav--managed-merge-p (context)
  "Return non-nil when CONTEXT is merging its CalDAV snapshot."
  (when-let* ((merge-head
               (git-foreign-rev-parse-noerror context "MERGE_HEAD"))
              (remote
               (git-foreign-rev-parse-noerror
                context (git-foreign-remote-ref context))))
    (equal merge-head remote)))

(defun +notes/caldav--abort-managed-merge (context)
  "Abort an active CalDAV merge for foreign CONTEXT."
  (when (git-foreign-rev-parse-noerror context "MERGE_HEAD")
    (unless (+notes/caldav--managed-merge-p context)
      (user-error "The active Git merge does not belong to CalDAV"))
    (git-foreign-output context "merge" "--abort")
    (+notes/caldav--revert-repo-buffers
     (+notes/caldav--repo-file-buffers))))

(defun +notes/caldav--commit-forced-pull (context)
  "Commit forced-pull changes and synchronize foreign CONTEXT."
  (unless (string-empty-p (+notes/caldav--git-worktree-status context))
    (git-foreign-output context "add" "--all")
    (git-foreign-output
     context "commit" "-m" "caldav: force pull remote snapshot"))
  (+notes/caldav--mark-head-synchronized context))

(defun +notes/caldav--ics-uids (buffer)
  "Return all event UIDs contained in iCalendar BUFFER."
  (with-current-buffer buffer
    (save-excursion
      (save-restriction
        (widen)
        (goto-char (point-min))
        (let (uids)
          (while (re-search-forward "^BEGIN:\\(?:VEVENT\\|VTODO\\)\r?$" nil t)
            (push (org-caldav-get-uid) uids))
          (delete-dups (nreverse uids)))))))

(defun +notes/caldav--local-event-uids ()
  "Export and return the UIDs in the local CalDAV task snapshot."
  (let* ((inbox (org-caldav-inbox-file org-caldav-inbox))
         ;; `org-caldav' excludes the inbox from a cal->org export.  A complete
         ;; local inventory must include it regardless of synchronization
         ;; direction, or existing remote tasks are reinserted as new entries.
         (org-caldav-files
          (delete-dups
           (if inbox (cons inbox org-caldav-files) org-caldav-files)))
         (+notes/caldav--syncing t)
         buffer
         file)
    (unwind-protect
        (progn
          (setq buffer (org-caldav-generate-ics)
                file (buffer-file-name buffer))
          (+notes/caldav--ics-uids buffer))
      (when (buffer-live-p buffer)
        (kill-buffer buffer))
      (when (and file (file-exists-p file))
        (delete-file file)))))

(defun +notes/caldav--normalize-etag-list (result)
  "Normalize RESULT returned by `org-caldav-get-event-etag-list'."
  (if (eq result 'empty) nil result))

(defun +notes/caldav--fetch-remote-etags ()
  "Return the current remote CalDAV ETag list after checking connectivity."
  (+notes/caldav-configure)
  (org-caldav-check-connection)
  (+notes/caldav--read-remote-etags))

(defun +notes/caldav--read-remote-etags ()
  "Return remote CalDAV ETags without a redundant connection probe."
  (+notes/caldav--normalize-etag-list
   (org-caldav-get-event-etag-list)))

(defun +notes/caldav--capture-remote-etags-a (fn &rest args)
  "Record the ETag list returned by FN with ARGS during an explicit pull."
  (let ((result (apply fn args)))
    (when +notes/caldav--pulling
      (setq +notes/caldav--remote-etags
            (+notes/caldav--normalize-etag-list result)))
    result))

(defun +notes/caldav--reconcile-pull-state-a (fn &rest args)
  "Make FN with ARGS classify pull changes against the saved remote baseline.

Pure `cal->org' mode does not scan Org first, so org-caldav cannot otherwise
distinguish an unchanged event from a local deletion or detect a remote
deletion."
  (let ((baseline (copy-tree org-caldav-event-list)))
    (prog1 (apply fn args)
      (when +notes/caldav--pulling
        (when (eq +notes/caldav--remote-etags :not-fetched)
          (error "CalDAV pull did not obtain a remote ETag list"))
        (if +notes/caldav--force-pulling
            (let (remove-events)
              ;; org-caldav's pull-only path knows nothing about local-only
              ;; entries, so add them to the database as remote deletions.
              (dolist (uid +notes/caldav--force-local-uids)
                (unless (assoc uid org-caldav-event-list)
                  (setq org-caldav-event-list
                        (append org-caldav-event-list
                                (list (list uid nil nil nil nil))))))
              (dolist (event org-caldav-event-list)
                (let* ((uid (car event))
                       (local (member uid +notes/caldav--force-local-uids))
                       (remote (assoc uid +notes/caldav--remote-etags)))
                  (cond
                   (remote
                    (org-caldav-event-set-etag event (cdr remote))
                    (org-caldav-event-set-status
                     event (if local 'changed-in-cal 'new-in-cal)))
                   (local
                    (org-caldav-event-set-status event 'deleted-in-cal))
                   (t
                    (push event remove-events)))))
              (dolist (event remove-events)
                (setq org-caldav-event-list
                      (delq event org-caldav-event-list))))
          (let (remove-events)
            (dolist (event org-caldav-event-list)
              (let* ((uid (car event))
                     (saved (assoc uid baseline))
                     (remote (assoc uid +notes/caldav--remote-etags))
                     (saved-etag (and saved (org-caldav-event-etag saved)))
                     (local (and saved-etag (org-id-find uid))))
                (cond
                 ((and remote (not saved))
                  (org-caldav-event-set-etag event (cdr remote))
                  (org-caldav-event-set-status event 'new-in-cal))
                 ((and remote (not saved-etag))
                  ;; The saved baseline represented absence, so this is a new
                  ;; external version even though an old state entry remains.
                  (org-caldav-event-set-etag event (cdr remote))
                  (org-caldav-event-set-status event 'new-in-cal))
                 ((and remote (not local))
                  ;; A saved UID without a local entry is remote-only now.
                  ;; Import it instead of trying to update a missing heading.
                  (org-caldav-event-set-etag event (cdr remote))
                  (org-caldav-event-set-status event 'new-in-cal))
                 ((and remote (not (equal (cdr remote) saved-etag)))
                  (org-caldav-event-set-etag event (cdr remote))
                  (org-caldav-event-set-status event 'changed-in-cal))
                 (remote
                  (org-caldav-event-set-status event 'synced))
                 (local
                  (org-caldav-event-set-status event 'deleted-in-cal))
                 (saved-etag
                  ;; The UID disappeared on both sides.  Keeping it as a
                  ;; remote deletion would make org-caldav call `org-id-goto'
                  ;; for an entry which no longer exists.
                  (push event remove-events))
                 (t
                  (org-caldav-event-set-status event 'synced)))))
            (dolist (event remove-events)
              (setq org-caldav-event-list
                    (delq event org-caldav-event-list)))))))))

(defun +notes/caldav--remote-drift (state remote)
  "Return UIDs whose REMOTE ETags differ from saved STATE."
  (let (drift)
    (dolist (remote-event remote)
      (let ((saved (assoc (car remote-event) state)))
        (unless (and saved
                     (equal (cdr remote-event)
                            (org-caldav-event-etag saved)))
          (push (car remote-event) drift))))
    (dolist (saved state)
      (when (and (org-caldav-event-etag saved)
                 (not (assoc (car saved) remote)))
        (push (car saved) drift)))
    (delete-dups (nreverse drift))))

(defun +notes/caldav--assert-remote-current ()
  "Refuse a push if CalDAV changed since the last pull."
  (let ((drift (+notes/caldav--saved-state-drift)))
    (when drift
      (user-error
       "CalDAV changed since the last pull (%s); pull before pushing"
       (mapconcat #'identity drift ", ")))))

(defun +notes/caldav--saved-state-drift-against (remote)
  "Return UIDs where REMOTE differs from the saved CalDAV state."
  (let ((state-file
         (org-caldav-sync-state-filename org-caldav-calendar-id)))
    (unless (file-exists-p state-file)
      (user-error "Pull CalDAV before the first push"))
    (let (org-caldav-event-list
          org-caldav-previous-files
          org-caldav-empty-calendar)
      (org-caldav-load-sync-state)
      (+notes/caldav--remote-drift
       org-caldav-event-list remote))))

(defun +notes/caldav--saved-state-drift ()
  "Return remote UIDs which differ from the saved CalDAV state."
  (+notes/caldav--saved-state-drift-against
   (+notes/caldav--fetch-remote-etags)))

(defun +notes/caldav--finish-remote-pull ()
  "Verify the completed pull and publish its final remote ETags."
  (let ((remote-etags (+notes/caldav--read-remote-etags)))
    (when-let* ((drift
                 (+notes/caldav--saved-state-drift-against remote-etags)))
      (user-error
       "CalDAV changed during pull (%s); retry the pull"
       (mapconcat #'identity drift ", ")))
    (setq +notes/caldav--last-verified-remote-etags remote-etags)
    remote-etags))

(defun +notes/caldav--request-uid (url data)
  "Return the event UID represented by request URL or DATA."
  (or (when (and data
                 (string-match
                  "\\(?:\\`\\|[\r\n]\\)UID:\\([^\r\n]+\\)" data))
        (match-string 1 data))
      (let ((decoded-url (url-unhex-string url)))
        (car (seq-find
              (lambda (event)
                (string-match-p
                 (concat "/" (regexp-quote (car event))
                         (regexp-quote org-caldav-uuid-extension)
                         "\\(?:[?#]\\|\\'\\)")
                 decoded-url))
              org-caldav-event-list)))))

(defun +notes/caldav--response-etag (response)
  "Return a normalized ETag from HTTP RESPONSE, or nil if absent."
  (when (buffer-live-p response)
    (with-current-buffer response
      (save-excursion
        (goto-char (point-min))
        (when (re-search-forward
               "^ETag:[ \t]*\\(?:W/\\)?\"?\\([^\"\r\n]+\\)\"?[ \t]*\r?$"
               nil t)
          (string-trim (match-string-no-properties 1)))))))

(defun +notes/caldav--conditional-request-a
    (fn url &optional request-method request-data extra-headers)
  "Add CalDAV preconditions to FN's URL request.
REQUEST-METHOD, REQUEST-DATA, and EXTRA-HEADERS are the corresponding
`org-caldav-url-retrieve-synchronously' arguments."
  (if (not (and +notes/caldav--pushing
                (member request-method '("PUT" "DELETE"))))
      (funcall fn url request-method request-data extra-headers)
    (let* ((uid (+notes/caldav--request-uid url request-data))
           (event (and uid (assoc uid org-caldav-event-list)))
           (etag (if +notes/caldav--force-pushing
                     (cdr (assoc uid +notes/caldav--force-remote-etags))
                   (and event (org-caldav-event-etag event))))
           (precondition
            (cond
             (etag (cons "If-Match" (format "\"%s\"" etag)))
             ((equal request-method "PUT")
              (cons "If-None-Match" "*")))))
      (unless uid
        (error "Could not identify CalDAV %s request" request-method))
      (let ((response
             (funcall fn url request-method request-data
                      (if precondition
                          (cons precondition extra-headers)
                        extra-headers))))
        (when (equal request-method "PUT")
          (let ((response-etag (+notes/caldav--response-etag response)))
            ;; Without the ETag of the version we just wrote, a later
            ;; PROPFIND could mistake a concurrent remote edit for our PUT.
            ;; Abort before org-caldav saves such an unsafe baseline.
            (unless response-etag
              (error "CalDAV PUT for %s returned no ETag; pull before retrying"
                     uid))
            (setf (alist-get uid +notes/caldav--write-etags
                             nil nil #'equal)
                  response-etag)))
        ;; org-caldav validates PUT responses itself, but its DELETE path does
        ;; not inspect HTTP status codes.
        (when (and precondition (equal request-method "DELETE"))
          (unless (buffer-live-p response)
            (error "CalDAV returned no response for DELETE %s" uid))
          (with-current-buffer response
            (goto-char (point-min))
            (unless (looking-at "HTTP.*2[0-9][0-9]")
              (error "CalDAV rejected conditional DELETE for %s" uid))))
        response))))

(defun +notes/caldav--verify-written-etags-a (fn &rest args)
  "Call FN with ARGS and detect remote writes racing with a push."
  (prog1 (apply fn args)
    (when +notes/caldav--pushing
      (dolist (written +notes/caldav--write-etags)
        (when-let* ((event (assoc (car written) org-caldav-event-list)))
          (unless (equal (cdr written) (org-caldav-event-etag event))
            ;; Preserve the ETag returned by our conditional PUT.  The next
            ;; pull will then see the later remote ETag as an external change.
            (org-caldav-event-set-etag event (cdr written))
            (push (car written) +notes/caldav--push-races))))
      (when +notes/caldav--force-pushing
        (setq +notes/caldav--push-races
              (delete-dups
               (append
                (+notes/caldav--remote-drift
                 org-caldav-event-list
                 (+notes/caldav--normalize-etag-list
                  (org-caldav-get-event-etag-list)))
                +notes/caldav--push-races)))))))

(defun +notes/caldav--force-push-eventdb-a (fn buffer)
  "Make FN treat local BUFFER as the complete forced-push snapshot."
  (if (not +notes/caldav--force-pushing)
      (funcall fn buffer)
    ;; Include every remote-only object so org-caldav deletes it after finding
    ;; no matching UID in the local export.
    (dolist (remote +notes/caldav--force-remote-etags)
      (unless (assoc (car remote) org-caldav-event-list)
        (setq org-caldav-event-list
              (append org-caldav-event-list
                      (list (list (car remote) nil (cdr remote) nil nil))))))
    (prog1 (funcall fn buffer)
      (let ((local-uids (+notes/caldav--ics-uids buffer)))
        (dolist (event org-caldav-event-list)
          (let ((uid (car event)))
            (org-caldav-event-set-status
             event
             (cond
              ((and (member uid local-uids)
                    (assoc uid +notes/caldav--force-remote-etags))
               'changed-in-org)
              ((member uid local-uids)
               'new-in-org)
              (t
               'deleted-in-org)))))))))

(defun +notes/caldav--delete-event-a (fn uid)
  "Make a failed deletion of UID by FN abort the current push."
  (let ((deleted (funcall fn uid)))
    (when (and +notes/caldav--pushing (not deleted))
      (error "CalDAV deletion failed for %s; pull and retry" uid))
    deleted))

(defun +notes/caldav--sync-errors ()
  "Return errors reported by the last org-caldav sync."
  (seq-filter
   (lambda (result)
     (string-prefix-p "error:"
                      (symbol-name (or (nth 3 result) 'unknown))))
   org-caldav-sync-result))

(defun +notes/caldav-fetch ()
  "Fetch a complete CalDAV snapshot without merging it into HEAD."
  (interactive)
  (require 'org-caldav)
  (+notes/caldav-configure)
  (setq +notes/caldav--last-verified-remote-etags :unknown)
  (let ((context (+notes/caldav--git-context)))
    (+notes/caldav--ensure-git-state context)
    (let* ((remote-commit
            (+notes/caldav--capture-remote-snapshot context))
           (state (git-foreign-read-state context remote-commit)))
      (message "Fetched CalDAV snapshot: %s"
               (plist-get state :status))
      remote-commit)))

(defun +notes/caldav-pull (&optional ff-only)
  "Pull CalDAV through a complete snapshot and a real Git merge.
When FF-ONLY is non-nil, fetch the snapshot but refuse a three-way merge."
  (interactive)
  (require 'org-caldav)
  (+notes/caldav-configure)
  (setq +notes/caldav--last-verified-remote-etags :unknown)
  (+notes/caldav--assert-org-buffers-saved)
  (+notes/caldav--assert-no-conflicts)
  (let ((context (+notes/caldav--git-context)))
    (+notes/caldav--assert-clean-git-worktree context)
    (+notes/caldav--ensure-git-state context)
    (let* ((remote-commit
            (+notes/caldav--capture-remote-snapshot context))
           (state (git-foreign-read-state context remote-commit))
           (status (plist-get state :status)))
      (when (and ff-only (eq status 'diverged))
        (user-error
         "CalDAV pull is not a fast-forward; fetched snapshot was not merged"))
      (let ((result (git-foreign-apply-pull context state)))
        (+notes/caldav--revert-repo-buffers
         (+notes/caldav--repo-file-buffers))
        (pcase result
          ('in-sync
           (message "CalDAV is already in sync"))
          ('matching
           (+notes/caldav--mark-head-synchronized context)
           (message "Local and CalDAV content already match"))
          ('no-remote-changes
           (message "No remote CalDAV changes to pull"))
          ('fast-forward
           (message "Pulled CalDAV changes with a Git fast-forward"))
          ('merged
           (message "Pulled CalDAV changes with a Git merge"))
          ('conflict
           (message
            (concat
             "CalDAV created a Git merge conflict; resolve it in Magit "
             "and commit"))))
        result))))

(defun +notes/caldav-push ()
  "Push Org to CalDAV only if the remote still matches the last pull."
  (interactive)
  (require 'org-caldav)
  (+notes/caldav-configure)
  (setq +notes/caldav--last-verified-remote-etags :unknown)
  (+notes/caldav--assert-no-conflicts)
  (let ((+notes/caldav--snapshotting t))
    (+notes/caldav--prepare-project-files)
    (+notes/caldav--local-event-uids)
    (+notes/caldav--prepare-project-files)
    (+notes/caldav--assert-org-buffers-saved)
    (let ((context (+notes/caldav--git-context)))
      (+notes/caldav--assert-clean-git-worktree context)
      (+notes/caldav--ensure-git-state context)
      (unless (+notes/caldav--remote-integrated-p context)
        (user-error
         "The latest CalDAV snapshot is not integrated; pull before pushing"))
      (+notes/caldav--assert-remote-current)
      (let ((+notes/caldav--pushing t)
            (+notes/caldav--write-etags nil)
            (+notes/caldav--push-races nil)
            (org-caldav-sync-direction 'org->cal)
            (org-caldav-resume-aborted 'never))
        (org-caldav-sync)
        (when (+notes/caldav--sync-errors)
          (org-caldav-display-sync-results)
          (user-error "CalDAV push finished with errors; pull before retrying"))
        (when +notes/caldav--push-races
          (user-error
           "CalDAV changed during push (%s); pull and resolve before pushing again"
           (mapconcat #'identity +notes/caldav--push-races ", ")))
        (+notes/caldav--mark-head-synchronized context)
        (message "CalDAV push complete")))))

(defun +notes/caldav-force-pull ()
  "Replace every local CalDAV-managed task with the remote snapshot.

This is destructive: remote entries win, remote deletions delete their local
counterparts, and local-only CalDAV tasks are deleted.  The resulting clean
snapshot is committed to the current Git branch."
  (interactive)
  (require 'org-caldav)
  (+notes/caldav-configure)
  (setq +notes/caldav--last-verified-remote-etags :unknown)
  (+notes/caldav--assert-org-buffers-saved)
  (unless (yes-or-no-p
           "FORCE PULL: replace/delete local CalDAV tasks to match remote? ")
    (user-error "Forced CalDAV pull cancelled"))
  (let ((context (+notes/caldav--git-context)))
    (+notes/caldav--abort-managed-merge context)
    (+notes/caldav--assert-clean-git-worktree context)
    (+notes/caldav--ensure-git-state context t)
    (let ((+notes/caldav--snapshotting t))
      (+notes/caldav--run-remote-pull t))
    (+notes/caldav--commit-forced-pull context)
    (message "Forced CalDAV pull committed the complete remote snapshot")))

(defun +notes/caldav-force-push ()
  "Replace the remote CalDAV collection with the local task snapshot.

This is destructive: local entries win and remote-only entries are deleted.
An active CalDAV merge is aborted before the local committed snapshot wins."
  (interactive)
  (require 'org-caldav)
  (+notes/caldav-configure)
  (setq +notes/caldav--last-verified-remote-etags :unknown)
  (+notes/caldav--assert-org-buffers-saved)
  (unless (yes-or-no-p
           "FORCE PUSH: replace/delete remote CalDAV entries to match local? ")
    (user-error "Forced CalDAV push cancelled"))
  (let ((context (+notes/caldav--git-context)))
    (+notes/caldav--abort-managed-merge context)
    (let ((+notes/caldav--snapshotting t))
      (+notes/caldav--prepare-project-files)
      (+notes/caldav--local-event-uids)
      (+notes/caldav--prepare-project-files)
      (+notes/caldav--assert-org-buffers-saved)
      (+notes/caldav--assert-clean-git-worktree context)
      (+notes/caldav--ensure-git-state context t)
      (let ((remote-etags (+notes/caldav--fetch-remote-etags)))
        (let ((+notes/caldav--pushing t)
              (+notes/caldav--force-pushing t)
              (+notes/caldav--force-remote-etags remote-etags)
              (+notes/caldav--write-etags nil)
              (+notes/caldav--push-races nil)
              (org-caldav-sync-direction 'org->cal)
              (org-caldav-delete-calendar-entries 'always)
              (org-caldav-resume-aborted 'never))
          (org-caldav-sync)
          (when (+notes/caldav--sync-errors)
            (org-caldav-display-sync-results)
            (user-error
             "Forced CalDAV push finished with errors; pull before retrying"))
          (when +notes/caldav--push-races
            (user-error
             "CalDAV changed during forced push (%s); retry after inspecting it"
             (mapconcat #'identity +notes/caldav--push-races ", ")))
          (+notes/caldav--mark-head-synchronized context)
          (message
           "Forced CalDAV push complete; remote snapshot matches HEAD"))))))

(defun +notes/caldav--leaf-action-item-p ()
  "Return non-nil when point is shown by `org-project-todo-list'."
  (+org-project--action-item-p
   nil
   (if (+org-project-file-p) 'project 'non-project)))

(defun +notes/caldav--create-leaf-uids-a (fn file &optional bell)
  "Create CalDAV UIDs only for leaf action items, or call FN normally.
FILE and BELL are the arguments accepted by `org-caldav-create-uid'."
  (if (not +notes/caldav--syncing)
      (funcall fn file bell)
    (let (modified)
      (save-excursion
        (save-restriction
          (widen)
          (goto-char (point-min))
          (while (re-search-forward org-outline-regexp-bol nil t)
            (goto-char (match-beginning 0))
            (when (and (+notes/caldav--leaf-action-item-p)
                       (not (org-entry-get nil "ID")))
              (org-id-get-create)
              (setq modified t))
            (org-back-to-heading t)
            (forward-line 1))))
      (when (and bell modified)
        (message "CalDAV IDs created for leaf tasks in %s" file)))))

(defun +notes/caldav--filter-export-buffer (backend)
  "Keep only project TODO leaf items when exporting BACKEND through CalDAV."
  (when (and +notes/caldav--syncing (eq backend 'icalendar))
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
          (when (+notes/caldav--leaf-action-item-p)
            (let* ((begin (line-beginning-position))
                   (end (save-excursion (org-end-of-subtree t t)))
                   (subtree (buffer-substring-no-properties begin end)))
              ;; Each exported leaf is independent of its source hierarchy.
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

(defun +notes/caldav--sync-project-todos-a (fn &rest args)
  "Call FN with ARGS using the files backing `org-project-todo-list'."
  (unless (or +notes/caldav--pulling +notes/caldav--pushing)
    (user-error "Use `+notes/caldav-pull' or `+notes/caldav-push'"))
  (let ((+notes/caldav--syncing t))
    (+notes/caldav--prepare-project-files)
    (apply fn args)))

(use-package org-caldav
  :ensure t
  :commands org-caldav-sync
  :init
  (+notes/caldav-ensure-files)
  ;; Do not rely on deferred `:custom' initialization for connection values.
  (+notes/caldav-configure)
  :config
  ;; Reloading this module in a long-lived Emacs must also remove the retired
  ;; advice which used to manufacture textual LOCAL/CALDAV conflict blocks.
  (advice-remove 'org-caldav-update-events-in-org
                 (intern "+notes/caldav--update-events-in-org-a"))
  (add-hook 'org-export-before-parsing-functions
            #'+notes/caldav--filter-export-buffer)
  (unless (advice-member-p #'+notes/caldav--create-leaf-uids-a
                           'org-caldav-create-uid)
    (advice-add 'org-caldav-create-uid
                :around
                #'+notes/caldav--create-leaf-uids-a))
  (unless (advice-member-p #'+notes/caldav--sync-project-todos-a
                           'org-caldav-sync)
    (advice-add 'org-caldav-sync
                :around
                #'+notes/caldav--sync-project-todos-a))
  (unless (advice-member-p #'+notes/caldav--capture-remote-etags-a
                           'org-caldav-get-event-etag-list)
    (advice-add 'org-caldav-get-event-etag-list
                :around
                #'+notes/caldav--capture-remote-etags-a))
  (unless (advice-member-p #'+notes/caldav--reconcile-pull-state-a
                           'org-caldav-update-eventdb-from-cal)
    (advice-add 'org-caldav-update-eventdb-from-cal
                :around
                #'+notes/caldav--reconcile-pull-state-a))
  (unless (advice-member-p #'+notes/caldav--force-push-eventdb-a
                           'org-caldav-update-eventdb-from-org)
    (advice-add 'org-caldav-update-eventdb-from-org
                :around
                #'+notes/caldav--force-push-eventdb-a))
  (unless (advice-member-p #'+notes/caldav--conditional-request-a
                           'org-caldav-url-retrieve-synchronously)
    (advice-add 'org-caldav-url-retrieve-synchronously
                :around
                #'+notes/caldav--conditional-request-a))
  (unless (advice-member-p #'+notes/caldav--verify-written-etags-a
                           'org-caldav-update-events-in-cal)
    (advice-add 'org-caldav-update-events-in-cal
                :around
                #'+notes/caldav--verify-written-etags-a))
  (unless (advice-member-p #'+notes/caldav--delete-event-a
                           'org-caldav-delete-event)
    (advice-add 'org-caldav-delete-event
                :around
                #'+notes/caldav--delete-event-a)))

(load "org-caldav-magit" nil t)
(+notes/caldav-magit-setup)

(provide 'init-caldav)
;;; caldav.el ends here
