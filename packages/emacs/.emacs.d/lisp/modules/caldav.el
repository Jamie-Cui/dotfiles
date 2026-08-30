;;; caldav.el --- explicit conflict-safe Org CalDAV sync -*- lexical-binding: t; -*-
;;; Commentary:
;; Explicit pull, push, force-pull, and force-push semantics for the Org task
;; collection, including conflict markers and ETag concurrency protection.
;;; Code:

(require 'init-notes)
(require 'org-project)

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

(defvar +notes/caldav--pull-conflicts nil
  "UIDs for conflicts created by the current CalDAV pull.")

(defvar +notes/caldav--remote-etags :not-fetched
  "Remote ETags observed while updating the current CalDAV pull.")

(defvar +notes/caldav--force-remote-etags nil
  "Remote ETags fetched immediately before the current forced push.")

(defvar +notes/caldav--force-local-uids nil
  "UIDs exported from Org immediately before the current forced pull.")

(defvar +notes/caldav--write-etags nil
  "ETags returned by writes during the current CalDAV push.")

(defvar +notes/caldav--push-races nil
  "UIDs changed remotely while the current CalDAV push was running.")

(defvar org-caldav-files nil)
(defvar org-caldav-inbox nil)
(defvar org-caldav-event-list nil)
(defvar org-caldav-sync-result nil)
(defvar org-caldav-empty-calendar nil)
(defvar org-caldav-previous-files nil)
(defvar org-caldav-calendar-id nil)
(defvar org-caldav-uuid-extension ".ics")

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
  (setq org-caldav-inbox (+notes/caldav--inbox-target)
        org-caldav-files (+notes/caldav-source-files))
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
       (re-search-forward "^<<<<<<< LOCAL$" nil t)))
   (directory-files-recursively +emacs/org-root-dir "\\.org\\'")))

(defun +notes/caldav--assert-no-conflicts ()
  "Refuse to sync while CalDAV conflict markers remain."
  (when-let* ((files (+notes/caldav--conflict-files)))
    (user-error
     "Resolve CalDAV conflicts before syncing: %s"
     (mapconcat (lambda (file)
                  (file-relative-name file +emacs/org-root-dir))
                files ", "))))

(defun +notes/caldav--resolve-conflicts (side)
  "Resolve every CalDAV conflict marker by choosing SIDE.

SIDE must be `local' or `remote'."
  (unless (memq side '(local remote))
    (error "Unknown CalDAV conflict side: %S" side))
  (dolist (file (+notes/caldav--conflict-files))
    (with-current-buffer (find-file-noselect file)
      (save-excursion
        (save-restriction
          (widen)
          (goto-char (point-min))
          (while (re-search-forward "^<<<<<<< LOCAL$" nil t)
            (let ((block-begin (line-beginning-position))
                  (local-begin (progn (forward-line 1) (point))))
              (unless (re-search-forward "^=======$" nil t)
                (error "Malformed CalDAV conflict in %s" file))
              (let ((local-end (line-beginning-position))
                    (remote-begin (progn (forward-line 1) (point))))
                (unless (re-search-forward "^>>>>>>> CALDAV$" nil t)
                  (error "Malformed CalDAV conflict in %s" file))
                (let* ((remote-end (line-beginning-position))
                       (block-end (progn (forward-line 1) (point)))
                       (chosen
                        (buffer-substring-no-properties
                         (if (eq side 'local) local-begin remote-begin)
                         (if (eq side 'local) local-end remote-end))))
                  (delete-region block-begin block-end)
                  (goto-char block-begin)
                  (insert chosen)))))))
      (when (buffer-modified-p)
        (save-buffer))))
  (+notes/caldav--assert-no-conflicts))

(defun +notes/caldav--entry-snapshot (uid)
  "Return UID's current Org subtree and MD5, or nil if it is absent."
  (when-let* ((marker (org-id-find uid t)))
    (with-current-buffer (marker-buffer marker)
      (save-excursion
        (goto-char marker)
        (org-back-to-heading t)
        (let* ((begin (org-entry-beginning-position))
               (end (org-entry-end-position))
               (text (buffer-substring-no-properties begin end)))
          (list :text text :md5 (md5 text)))))))

(defun +notes/caldav--format-conflict (local remote)
  "Return a Git-style conflict containing LOCAL and REMOTE subtrees."
  (concat "<<<<<<< LOCAL\n"
          (or local "")
          (unless (or (null local) (string-suffix-p "\n" local)) "\n")
          "=======\n"
          (or remote "")
          (unless (or (null remote) (string-suffix-p "\n" remote)) "\n")
          ">>>>>>> CALDAV\n"))

(defun +notes/caldav--replace-entry-with-conflict (uid local remote)
  "Replace UID's entry with a conflict between LOCAL and REMOTE."
  (let ((marker (org-id-find uid t)))
    (unless marker
      (error "Could not find CalDAV conflict entry %s" uid))
    (with-current-buffer (marker-buffer marker)
      (save-excursion
        (goto-char marker)
        (org-back-to-heading t)
        (delete-region (org-entry-beginning-position)
                       (org-entry-end-position))
        (insert (+notes/caldav--format-conflict local remote))
        (save-buffer)))))

(defun +notes/caldav--collect-pull-conflicts ()
  "Collect every external remote change as a manual conflict.

This runs after org-caldav has compared remote ETags but before it changes Org
files.  Cases which org-caldav cannot represent directly are converted into an
update which can subsequently be wrapped in conflict markers."
  (let (conflicts remove-events)
    (dolist (event org-caldav-event-list)
      (let* ((uid (car event))
             (status (org-caldav-event-status event))
             (snapshot (+notes/caldav--entry-snapshot uid))
             (local (plist-get snapshot :text)))
        (pcase status
          ('changed-in-cal
           ;; If the entry was deleted locally, import the remote version so
           ;; the conflict can have an empty LOCAL side.
           (unless snapshot
             (org-caldav-event-set-status event 'new-in-cal))
           (push (list :event event :uid uid :local local :deleted nil)
                 conflicts))
          ('new-in-cal
           ;; A remote UID collision must update the existing local entry
           ;; temporarily; otherwise org-caldav would create a duplicate ID.
           (when snapshot
             (org-caldav-event-set-status event 'changed-in-cal))
           (push (list :event event :uid uid :local local :deleted nil)
                 conflicts))
          ('deleted-in-cal
           (if snapshot
               (progn
                 ;; Keep the local side instead of letting org-caldav delete it.
                 (org-caldav-event-set-status event 'ignored)
                 (push (list :event event :uid uid :local local :deleted t)
                       conflicts))
             ;; Both sides already lack the entry, so no choice remains for the
             ;; user to resolve and the stale state can simply disappear.
             (push event remove-events))))))
    (dolist (event remove-events)
      (setq org-caldav-event-list (delq event org-caldav-event-list)))
    (nreverse conflicts)))

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
  (let ((+notes/caldav--syncing t)
        buffer file)
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
  (org-caldav-check-connection)
  (+notes/caldav--normalize-etag-list
   (org-caldav-get-event-etag-list)))

(defun +notes/caldav--capture-remote-etags-a (fn &rest args)
  "Record the ETag list returned by FN during an explicit pull."
  (let ((result (apply fn args)))
    (when +notes/caldav--pulling
      (setq +notes/caldav--remote-etags
            (+notes/caldav--normalize-etag-list result)))
    result))

(defun +notes/caldav--reconcile-pull-state-a (fn &rest args)
  "Make FN classify pull changes against the saved remote baseline.

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
          (dolist (event org-caldav-event-list)
            (let* ((uid (car event))
                   (saved (assoc uid baseline))
                   (remote (assoc uid +notes/caldav--remote-etags))
                   (saved-etag (and saved (org-caldav-event-etag saved))))
              (cond
               ((and remote (not saved))
                (org-caldav-event-set-etag event (cdr remote))
                (org-caldav-event-set-status event 'new-in-cal))
               ((and remote (not saved-etag))
                ;; The saved baseline represented absence, so this is a new
                ;; external version even though an old state entry remains.
                (org-caldav-event-set-etag event (cdr remote))
                (org-caldav-event-set-status event 'new-in-cal))
               ((and remote (not (equal (cdr remote) saved-etag)))
                (org-caldav-event-set-etag event (cdr remote))
                (org-caldav-event-set-status event 'changed-in-cal))
               (remote
                (org-caldav-event-set-status event 'synced))
               (saved-etag
                (org-caldav-event-set-status event 'deleted-in-cal))
               (t
                (org-caldav-event-set-status event 'synced))))))))))

(defun +notes/caldav--update-events-in-org-a (fn &rest args)
  "Around advice for FN which preserves all remote changes as conflicts."
  (if (or (not +notes/caldav--pulling)
          +notes/caldav--force-pulling)
      (apply fn args)
    (let ((conflicts (+notes/caldav--collect-pull-conflicts)))
      (prog1 (apply fn args)
        (dolist (conflict conflicts)
          (let* ((event (plist-get conflict :event))
                 (uid (plist-get conflict :uid))
                 (local (plist-get conflict :local))
                 (deleted (plist-get conflict :deleted))
                 (remote (unless deleted
                           (plist-get (+notes/caldav--entry-snapshot uid)
                                      :text))))
            (+notes/caldav--replace-entry-with-conflict uid local remote)
            (when deleted
              ;; Nil is now the remote baseline.  Choosing LOCAL will make a
              ;; later push recreate the entry; choosing CALDAV removes it.
              (org-caldav-event-set-md5 event nil)
              (org-caldav-event-set-etag event nil)
              (org-caldav-event-set-status event 'synced))
            (push uid +notes/caldav--pull-conflicts)))))))

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

(defun +notes/caldav--saved-state-drift ()
  "Return remote UIDs which differ from the saved CalDAV state."
  (let ((state-file
         (org-caldav-sync-state-filename org-caldav-calendar-id)))
    (unless (file-exists-p state-file)
      (user-error "Pull CalDAV before the first push"))
    (let (org-caldav-event-list
          org-caldav-previous-files
          org-caldav-empty-calendar)
      (org-caldav-load-sync-state)
      (+notes/caldav--remote-drift
       org-caldav-event-list
       (+notes/caldav--fetch-remote-etags)))))

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
  "Add CalDAV precondition headers to writes made by FN."
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
  "Around advice for FN which detects remote writes racing with a push."
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
  "Make a failed deletion by FN abort the current push."
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

(defun +notes/caldav-pull ()
  "Pull CalDAV into Org, representing every remote change as a conflict."
  (interactive)
  (require 'org-caldav)
  (+notes/caldav--assert-org-buffers-saved)
  (+notes/caldav--assert-no-conflicts)
  (let ((+notes/caldav--pulling t)
        (+notes/caldav--pull-conflicts nil)
        (+notes/caldav--remote-etags :not-fetched)
        (org-caldav-sync-direction 'cal->org)
        (org-caldav-delete-org-entries 'never)
        (org-caldav-resume-aborted 'never))
    (org-caldav-sync)
    (when (+notes/caldav--sync-errors)
      (org-caldav-display-sync-results)
      (user-error "CalDAV pull finished with errors; inspect the results"))
    (if +notes/caldav--pull-conflicts
        (message
         "CalDAV pull created %d conflict(s); resolve markers before push"
         (length +notes/caldav--pull-conflicts))
      (message "CalDAV pull complete; no remote changes"))))

(defun +notes/caldav-push ()
  "Push Org to CalDAV only if the remote still matches the last pull."
  (interactive)
  (require 'org-caldav)
  (+notes/caldav--assert-org-buffers-saved)
  (+notes/caldav--assert-no-conflicts)
  (+notes/caldav--prepare-project-files)
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
    (message "CalDAV push complete")))

(defun +notes/caldav-force-pull ()
  "Replace every local CalDAV-managed task with the remote snapshot.

This is destructive: remote entries win, remote deletions delete their local
counterparts, and local-only CalDAV tasks are deleted.  Existing conflict
markers are resolved by choosing their CALDAV side."
  (interactive)
  (require 'org-caldav)
  (+notes/caldav--assert-org-buffers-saved)
  (unless (yes-or-no-p
           "FORCE PULL: replace/delete local CalDAV tasks to match remote? ")
    (user-error "Forced CalDAV pull cancelled"))
  (+notes/caldav--resolve-conflicts 'remote)
  (+notes/caldav--prepare-project-files)
  (let ((local-uids (+notes/caldav--local-event-uids)))
    ;; UID creation during the snapshot export may have changed ID locations.
    (+notes/caldav--prepare-project-files)
    (let ((+notes/caldav--pulling t)
          (+notes/caldav--force-pulling t)
          (+notes/caldav--force-local-uids local-uids)
          (+notes/caldav--pull-conflicts nil)
          (+notes/caldav--remote-etags :not-fetched)
          (org-caldav-sync-direction 'cal->org)
          (org-caldav-delete-org-entries 'always)
          (org-caldav-resume-aborted 'never))
      (org-caldav-sync)
      (when (+notes/caldav--sync-errors)
        (org-caldav-display-sync-results)
        (user-error
         "Forced CalDAV pull finished with errors; inspect the results"))
      (let ((drift (+notes/caldav--saved-state-drift)))
        (when drift
          (user-error
           "CalDAV changed during forced pull (%s); retry the forced pull"
           (mapconcat #'identity drift ", "))))
      (message "Forced CalDAV pull complete; local snapshot matches remote"))))

(defun +notes/caldav-force-push ()
  "Replace the remote CalDAV collection with the local task snapshot.

This is destructive: local entries win and remote-only entries are deleted.
Existing conflict markers are resolved by choosing their LOCAL side."
  (interactive)
  (require 'org-caldav)
  (+notes/caldav--assert-org-buffers-saved)
  (unless (yes-or-no-p
           "FORCE PUSH: replace/delete remote CalDAV entries to match local? ")
    (user-error "Forced CalDAV push cancelled"))
  (+notes/caldav--resolve-conflicts 'local)
  (+notes/caldav--prepare-project-files)
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
      (message "Forced CalDAV push complete; remote snapshot matches local"))))

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
  :custom
  ;; Emacs's URL library resolves Basic Auth credentials through auth-source.
  (org-caldav-url "https://jamie@gw-api.xyz:443/dav/jamie")
  (org-caldav-calendar-id "org-tasks")
  (org-caldav-inbox +notes/caldav-inbox-file)
  ;; The actual list is refreshed immediately before every sync.
  (org-caldav-files nil)
  (org-icalendar-timezone "Asia/Shanghai")
  (org-icalendar-include-todo 'all)
  (org-caldav-sync-todo t)
  ;; Explicit commands dynamically bind this to the requested direction.
  (org-caldav-sync-direction 'cal->org)
  (org-caldav-show-sync-results nil)
  :config
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
  (unless (advice-member-p #'+notes/caldav--update-events-in-org-a
                           'org-caldav-update-events-in-org)
    (advice-add 'org-caldav-update-events-in-org
                :around
                #'+notes/caldav--update-events-in-org-a))
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

(provide 'init-caldav)
;;; caldav.el ends here
