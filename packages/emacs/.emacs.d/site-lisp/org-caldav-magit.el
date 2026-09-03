;;; org-caldav-magit.el --- Org CalDAV adapter for Magit -*- lexical-binding: t; -*-
;;; Commentary:
;; Adds conflict-safe CalDAV status and operations to the Magit status buffer
;; for `+emacs/org-root-dir'.  Synchronization remains in init-caldav.
;;
;; Repository selection is based on the local working tree, not on a Git
;; remote, repository name, branch, or `.git' contents.  In the current Magit
;; context, `magit-toplevel' finds the working-tree root and `file-equal-p'
;; compares it with `+emacs/org-root-dir'.  Consequently, a nested directory
;; below that root and a symbolic-link spelling of the same directory match,
;; while an Org directory that is merely a subdirectory of another repository
;; does not.
;;
;; The status section is inserted only in `magit-status-mode' when that check
;; succeeds.  CalDAV fetch, pull, and push suffixes are installed in Magit's
;; transients globally, but executing any operation performs the same
;; repository check and requires the Org root status buffer to be open.
;;; Code:

(require 'cl-lib)
(require 'git-foreign-magit)
(require 'org)
(require 'seq)
(eval-and-compile
  (require 'magit-section)
  (require 'transient))
(require 'magit nil t)

(unless (fboundp '+notes/caldav--git-context)
  (error "Load `init-caldav' before `org-caldav-magit'"))

(declare-function org-caldav-event-etag "org-caldav" (event))
(declare-function org-caldav-event-md5 "org-caldav" (event))
(declare-function org-caldav-load-sync-state "org-caldav" ())
(declare-function org-caldav-sync-state-filename "org-caldav" (id))
(declare-function magit-add-section-hook "magit-section"
                  (hook function &optional at append local))
(declare-function magit-fetch-arguments "magit-fetch" ())
(declare-function magit-get-mode-buffer "magit-mode"
                  (mode &optional value frame))
(declare-function magit-pull-arguments "magit-pull" ())
(declare-function magit-push-arguments "magit-push" ())
(declare-function magit-refresh "magit-mode" ())
(declare-function magit-toplevel "magit-git" (&optional directory))

(defvar org-caldav-url nil)
(defvar +notes/caldav--last-verified-remote-etags :unknown)

(defvar-local +notes/caldav-status--remote-etags :unknown
  "Remote ETags cached in the current Magit status buffer.")

(defvar-local +notes/caldav-status--remote-current-p nil
  "Non-nil when the last remote refresh in this buffer succeeded.")

(defvar-local +notes/caldav-status--last-checked nil
  "Time of the last successful remote status refresh.")

(defvar-local +notes/caldav-status--remote-error nil
  "Error message from the most recent remote status refresh.")

(dolist (variable '(+notes/caldav-status--remote-etags
                    +notes/caldav-status--remote-current-p
                    +notes/caldav-status--last-checked
                    +notes/caldav-status--remote-error))
  (put variable 'permanent-local t))

(defclass +notes/caldav-magit-section (magit-section)
  ((type :initform 'caldav-magit))
  "Top-level CalDAV section in a Magit status buffer.")

(defclass +notes/caldav-magit-group-section (magit-section)
  ((type :initform 'caldav-status-group))
  "A group of similarly classified CalDAV items.")

(defclass +notes/caldav-magit-entry-section (magit-section)
  ((type :initform 'caldav-status-entry))
  "One CalDAV item in a status buffer.")

(cl-defmethod magit-section-ident-value
  ((section +notes/caldav-magit-entry-section))
  "Return a stable identity for a CalDAV entry SECTION."
  (let* ((entry (oref section value))
         (uid (plist-get entry :uid)))
    (if (and uid (not (equal uid "(assigned on push)")))
        uid
      (list (plist-get entry :file)
            (plist-get entry :title)))))

(defun +notes/caldav-status--component-changed-p
    (base-present base-value current-present current-value)
  "Return non-nil when a snapshot component changed from BASE to CURRENT.

BASE-PRESENT and CURRENT-PRESENT describe existence; BASE-VALUE and
CURRENT-VALUE contain the corresponding MD5 or ETag."
  (or (not (eq (and base-present t) (and current-present t)))
      (and base-present
           current-present
           (not (equal base-value current-value)))))

(defun +notes/caldav-status--local-state (base-present local-present)
  "Return the local change state from BASE-PRESENT and LOCAL-PRESENT."
  (cond
   ((not base-present) 'local-added)
   ((not local-present) 'local-deleted)
   (t 'local-modified)))

(defun +notes/caldav-status--remote-state (base-present remote-present)
  "Return the remote change state from BASE-PRESENT and REMOTE-PRESENT."
  (cond
   ((not base-present) 'remote-added)
   ((not remote-present) 'remote-deleted)
   (t 'remote-modified)))

(defun +notes/caldav-status--classify-entry
    (uid base local remote remote-known conflict-uids)
  "Classify UID using BASE, LOCAL, REMOTE, and CONFLICT-UIDS.

BASE is an org-caldav event, LOCAL is a status item plist, and REMOTE is
an (UID . ETAG) pair.  REMOTE-KNOWN distinguishes an empty collection
from one which has not been checked.  CONFLICT-UIDS names entries inside
unresolved Git conflict markers."
  (let* ((base-md5 (and base (org-caldav-event-md5 base)))
         (base-etag (and base (org-caldav-event-etag base)))
         (local-md5 (and local (plist-get local :md5)))
         (remote-etag (and remote (cdr remote)))
         (local-changed
          (+notes/caldav-status--component-changed-p
           base-md5 base-md5 local local-md5))
         (remote-changed
          (and remote-known
               (+notes/caldav-status--component-changed-p
                base-etag base-etag remote remote-etag)))
         state)
    (setq state
          (cond
           ((member uid conflict-uids) 'conflict)
           ((not remote-known)
            (if local-changed
                (+notes/caldav-status--local-state base-md5 local)
              'unchecked))
           ((and local-changed remote-changed) 'diverged)
           (remote-changed
            (+notes/caldav-status--remote-state base-etag remote))
           (local-changed
            (+notes/caldav-status--local-state base-md5 local))
           (t 'synced)))
    (list :uid uid
          :title (and local (plist-get local :title))
          :marker (and local (plist-get local :marker))
          :file (and local (plist-get local :file))
          :state state
          :base-md5 base-md5
          :local-md5 local-md5
          :base-etag base-etag
          :remote-etag remote-etag)))

(defun +notes/caldav-status--classify
    (base-events local-items remote-etags remote-known conflict-uids)
  "Return status entries from BASE-EVENTS, LOCAL-ITEMS, and REMOTE-ETAGS.

LOCAL-ITEMS is an alist from UID to local item plists.  REMOTE-KNOWN is
non-nil after a successful read-only refresh.  CONFLICT-UIDS lists entries
inside unresolved Git conflict markers."
  (let ((uids (delete-dups
               (append (mapcar #'car base-events)
                       (mapcar #'car local-items)
                       (mapcar #'car remote-etags)
                       (copy-sequence conflict-uids)))))
    (mapcar
     (lambda (uid)
       (+notes/caldav-status--classify-entry
        uid
        (assoc uid base-events)
        (cdr (assoc uid local-items))
        (assoc uid remote-etags)
        remote-known
        conflict-uids))
     (sort uids #'string-lessp))))

(defun +notes/caldav-status--saved-state ()
  "Return a plist describing the saved org-caldav baseline."
  (require 'org-caldav)
  (+notes/caldav-configure)
  (let* ((file (org-caldav-sync-state-filename org-caldav-calendar-id))
         (exists (file-exists-p file))
         org-caldav-event-list
         org-caldav-previous-files
         org-caldav-empty-calendar)
    (when exists
      (org-caldav-load-sync-state))
    (list :exists exists :events (copy-tree org-caldav-event-list))))

(defun +notes/caldav-status--scan-conflict-uids (files)
  "Return all Org IDs found inside conflict markers in FILES."
  (let (uids)
    (dolist (file files)
      (with-current-buffer (find-file-noselect file)
        (save-excursion
          (save-restriction
            (widen)
            (goto-char (point-min))
            (while (re-search-forward "^<<<<<<< " nil t)
              (let ((begin (point))
                    (end (and (re-search-forward "^>>>>>>> " nil t)
                              (line-beginning-position))))
                (when end
                  (save-restriction
                    (narrow-to-region begin end)
                    (goto-char (point-min))
                    (while (re-search-forward
                            "^[ \t]*:ID:[ \t]+\\([^ \t\r\n]+\\)"
                            nil t)
                      (push (match-string-no-properties 1) uids))))))))))
    (delete-dups (nreverse uids))))

(defun +notes/caldav-status--scan-local-file (file)
  "Return local CalDAV item plists found in Org FILE."
  (let (items)
    (with-current-buffer (find-file-noselect file)
      (unless (derived-mode-p 'org-mode)
        (error "CalDAV source is not in Org mode: %s" file))
      (save-excursion
        (save-restriction
          (widen)
          (goto-char (point-min))
          (while (re-search-forward org-outline-regexp-bol nil t)
            (goto-char (match-beginning 0))
            (when (+notes/caldav--leaf-action-item-p)
              (let* ((begin (org-entry-beginning-position))
                     (end (org-entry-end-position))
                     (uid (org-entry-get nil "ID"))
                     (title (org-get-heading t t t t)))
                (push (list :uid uid
                            :title title
                            :marker (copy-marker begin)
                            :file file
                            :md5 (and uid
                                      (md5 (buffer-substring-no-properties
                                            begin end))))
                      items)))
            (org-back-to-heading t)
            (forward-line 1)))))
    (nreverse items)))

(defun +notes/caldav-status--scan-local ()
  "Return local items, untracked tasks, duplicate IDs, and scan errors."
  (let (items untracked duplicates errors)
    (dolist (file (delete-dups (+notes/caldav-source-files)))
      (when (and (stringp file) (file-readable-p file))
        (condition-case err
            (dolist (item (+notes/caldav-status--scan-local-file file))
              (if-let* ((uid (plist-get item :uid)))
                  (if (assoc uid items)
                      (push uid duplicates)
                    (push (cons uid item) items))
                (push item untracked)))
          (error
           (push (cons file (error-message-string err)) errors)))))
    (list :items (nreverse items)
          :untracked (nreverse untracked)
          :duplicates (delete-dups (nreverse duplicates))
          :errors (nreverse errors))))

(defun +notes/caldav-status--collect-data ()
  "Collect the local, baseline, and cached remote status data."
  (let* ((baseline (+notes/caldav-status--saved-state))
         (local (+notes/caldav-status--scan-local))
         (git (+notes/caldav--git-status-data))
         (conflict-files (+notes/caldav--conflict-files))
         (conflict-uids
          (delete-dups
           (append (+notes/caldav-status--scan-conflict-uids conflict-files)
                   (plist-get local :duplicates))))
         (remote-known (not (eq +notes/caldav-status--remote-etags :unknown)))
         (remote (if remote-known +notes/caldav-status--remote-etags nil))
         (entries
          (+notes/caldav-status--classify
           (plist-get baseline :events)
           (plist-get local :items)
           remote
           remote-known
           conflict-uids)))
    (list :baseline-exists (plist-get baseline :exists)
          :git git
          :entries entries
          :untracked (plist-get local :untracked)
          :duplicates (plist-get local :duplicates)
          :scan-errors (plist-get local :errors)
          :conflict-files conflict-files
          :remote-known remote-known
          :remote-current +notes/caldav-status--remote-current-p)))

(defun +notes/caldav-status--entries-with-state (entries states)
  "Return ENTRIES whose state belongs to STATES."
  (seq-filter (lambda (entry)
                (memq (plist-get entry :state) states))
              entries))

(defun +notes/caldav-status--push-gate (data)
  "Return (LABEL FACE) describing whether normal push is safe for DATA."
  (let ((entries (plist-get data :entries))
        (git (plist-get data :git)))
    (cond
     ((+notes/caldav--modified-org-buffers)
      '("BLOCKED — save modified Org buffers" error))
     ((or (plist-get data :conflict-files)
          (plist-get data :duplicates))
      '("BLOCKED — resolve local conflicts" error))
     ((and (plist-member data :git)
           (not (plist-get git :clean)))
      '("BLOCKED — commit Git changes first" error))
     ((and (plist-get git :state)
           (not (plist-get git :push-ready)))
      '("BLOCKED — integrate the CalDAV Git snapshot" error))
     ((plist-get data :scan-errors)
      '("BLOCKED — local status scan failed" error))
     ((not (plist-get data :baseline-exists))
      '("BLOCKED — pull before the first push" warning))
     ((not (plist-get data :remote-current))
      '("GUARDED — remote will be checked before push" warning))
     ((+notes/caldav-status--entries-with-state
       entries '(remote-added remote-modified remote-deleted diverged))
      '("BLOCKED — remote changes require pull" error))
     (t '("READY — remote matches the saved baseline" success)))))

(defconst +notes/caldav-status--state-presentations
  '((conflict "conflict" error)
    (diverged "both changed" error)
    (remote-added "added remotely" warning)
    (remote-modified "changed remotely" warning)
    (remote-deleted "deleted remotely" warning)
    (local-added "added locally" success)
    (local-modified "changed locally" success)
    (local-deleted "deleted locally" success)
    (unchecked "remote unchecked" shadow)
    (synced "in sync" shadow))
  "Labels and faces used for CalDAV item states.")

(defun +notes/caldav-status--insert-group-heading (count title)
  "Insert an indented secondary heading for COUNT items named TITLE."
  (magit-insert-heading
    count
    (propertize (concat "  " title)
                'font-lock-face 'magit-section-secondary-heading)))

(defun +notes/caldav-status--insert-entry (entry)
  "Insert one status section for ENTRY."
  (let* ((state (plist-get entry :state))
         (presentation (assq state +notes/caldav-status--state-presentations))
         (label (nth 1 presentation))
         (face (nth 2 presentation))
         (uid (or (plist-get entry :uid) "(missing UID)"))
         (title (or (plist-get entry :title) "(no local copy)")))
    (magit-insert-section (+notes/caldav-magit-entry-section entry)
      (insert "    "
              (propertize (format "%-17s" label)
                          'face face 'font-lock-face face)
              title
              "  "
              (propertize uid 'face 'shadow 'font-lock-face 'shadow)
              "\n"))))

(defun +notes/caldav-status--insert-group
    (title entries states &optional hidden)
  "Insert TITLE containing ENTRIES matching STATES.

When HIDDEN is non-nil, initially collapse the section."
  (when-let* ((matching
               (+notes/caldav-status--entries-with-state entries states)))
    (magit-insert-section (+notes/caldav-magit-group-section states hidden)
      (+notes/caldav-status--insert-group-heading (length matching) title)
      (dolist (entry matching)
        (+notes/caldav-status--insert-entry entry))
      (insert "\n"))))

(defun +notes/caldav-status--insert-untracked (items)
  "Insert the local action ITEMS which do not yet have a CalDAV UID."
  (when items
    (magit-insert-section (+notes/caldav-magit-group-section 'untracked)
      (+notes/caldav-status--insert-group-heading
       (length items) "Untracked local tasks")
      (dolist (item items)
        (+notes/caldav-status--insert-entry
         (append item (list :uid "(assigned on push)"
                            :state 'local-added))))
      (insert "\n"))))

(defun +notes/caldav-status--insert-conflict-files (files)
  "Insert Org FILES containing unresolved conflict markers."
  (when files
    (magit-insert-section (+notes/caldav-magit-group-section 'conflict-files)
      (+notes/caldav-status--insert-group-heading
       (length files) "Conflict files")
      (dolist (file files)
        (insert "    "
                (propertize "unresolved       " 'face 'error)
                (file-relative-name file +emacs/org-root-dir)
                "\n"))
      (insert "\n"))))

(defun +notes/caldav-status--insert-scan-errors (errors)
  "Insert local scan ERRORS."
  (when errors
    (magit-insert-section (+notes/caldav-magit-group-section 'scan-errors)
      (+notes/caldav-status--insert-group-heading
       (length errors) "Local scan errors")
      (dolist (error errors)
        (insert "    "
                (propertize (file-relative-name
                             (car error) +emacs/org-root-dir)
                            'face 'error)
                ": " (cdr error) "\n"))
      (insert "\n"))))

(defun +notes/caldav-status--remote-label ()
  "Return a concise description of the current remote cache."
  (cond
   (+notes/caldav-status--remote-current-p
    (format "checked %s"
            (format-time-string "%Y-%m-%d %H:%M:%S"
                                +notes/caldav-status--last-checked)))
   (+notes/caldav-status--remote-error
    (format "refresh failed — %s" +notes/caldav-status--remote-error))
   ((not (eq +notes/caldav-status--remote-etags :unknown))
    "cached snapshot is stale")
   (t "unchecked")))

(defun +notes/caldav-magit--org-repo-p ()
  "Return non-nil when the current Magit context belongs to the Org repo."
  (and (stringp +emacs/org-root-dir)
       (when-let* ((repo (magit-toplevel)))
         (file-equal-p repo +emacs/org-root-dir))))

(defun +notes/caldav-magit--applicable-p ()
  "Return non-nil in the Magit status buffer for the Org root repo."
  (and (derived-mode-p 'magit-status-mode)
       (+notes/caldav-magit--org-repo-p)))

(defun +notes/caldav-magit--face-string (string face)
  "Return STRING propertized with FACE."
  (propertize string 'face face 'font-lock-face face))

(defun +notes/caldav-magit--heading-face ()
  "Return the face for the current CalDAV remote status."
  (cond
   (+notes/caldav-status--remote-error 'error)
   (+notes/caldav-status--remote-current-p 'magit-dimmed)
   (t 'warning)))

(defun +notes/caldav-magit--insert-data (data)
  "Insert CalDAV status DATA below the current section heading."
  (let* ((gate (+notes/caldav-status--push-gate data))
         (entries (plist-get data :entries))
         (git (plist-get data :git))
         (git-state (plist-get (plist-get git :state) :status))
         (presentation
          (git-foreign-magit-state-presentation git-state)))
    (insert "  Remote: "
            (format "%s/%s\n"
                    (or org-caldav-url "(not configured)")
                    (or org-caldav-calendar-id "(not configured)")))
    (insert "  Git remote: "
            (or (plist-get git :remote-name) "unregistered")
            " — "
            (+notes/caldav-magit--face-string
             (or (nth 1 presentation) "not initialized")
             (or (nth 2 presentation) 'warning))
            "\n")
    (insert "  Push: "
            (+notes/caldav-magit--face-string (car gate) (cadr gate))
            "\n\n")
    (+notes/caldav-status--insert-conflict-files
     (plist-get data :conflict-files))
    (+notes/caldav-status--insert-group
     "Unresolved item conflicts" entries '(conflict))
    (+notes/caldav-status--insert-group
     "Remote changes" entries
     '(remote-added remote-modified remote-deleted diverged))
    (+notes/caldav-status--insert-group
     "Local changes" entries
     '(local-added local-modified local-deleted))
    (+notes/caldav-status--insert-untracked
     (plist-get data :untracked))
    (+notes/caldav-status--insert-scan-errors
     (plist-get data :scan-errors))
    (+notes/caldav-status--insert-group
     "Remote unchecked" entries '(unchecked) t)
    (+notes/caldav-status--insert-group
     "In sync" entries '(synced) t)))

(defun +notes/caldav-magit-insert-status ()
  "Insert the CalDAV section into the Org root Magit status buffer."
  (when (+notes/caldav-magit--applicable-p)
    (+notes/caldav-configure)
    (condition-case err
        (let ((data (+notes/caldav-status--collect-data)))
          (magit-insert-section
              (+notes/caldav-magit-section +emacs/org-root-dir)
            (magit-insert-heading
              (concat
               (+notes/caldav-magit--face-string
                (format "CalDAV: %s (" org-caldav-calendar-id)
                'magit-section-heading)
               (+notes/caldav-magit--face-string
                (+notes/caldav-status--remote-label)
                (+notes/caldav-magit--heading-face))
               (+notes/caldav-magit--face-string
                ")" 'magit-section-heading)))
            (+notes/caldav-magit--insert-data data)))
      (error
       (magit-insert-section
           (+notes/caldav-magit-section +emacs/org-root-dir)
         (magit-insert-heading "CalDAV (status unavailable)")
         (insert "  "
                 (+notes/caldav-magit--face-string
                  (error-message-string err) 'error)
                 "\n\n"))))))

(defun +notes/caldav-magit--status-buffer ()
  "Return the Org root status buffer from an Org-repo Magit context."
  (when (+notes/caldav-magit--org-repo-p)
    (or (and (derived-mode-p 'magit-status-mode) (current-buffer))
        (let ((default-directory
               (file-name-as-directory +emacs/org-root-dir)))
          (magit-get-mode-buffer 'magit-status-mode)))))

(defun +notes/caldav-magit--require-status-buffer ()
  "Return the Org root Magit status buffer or signal a user error."
  (or (+notes/caldav-magit--status-buffer)
      (user-error "Open Magit status for %s first" +emacs/org-root-dir)))

(defun +notes/caldav-magit--refresh-buffer (buffer)
  "Refresh live Magit status BUFFER."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (+notes/caldav-magit--applicable-p)
        (magit-refresh)))))

(defun +notes/caldav-magit--accept-remote-etags (buffer remote-etags)
  "Cache verified REMOTE-ETAGS in BUFFER and refresh it once."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq +notes/caldav-status--remote-etags remote-etags
            +notes/caldav-status--remote-current-p t
            +notes/caldav-status--last-checked (current-time)
            +notes/caldav-status--remote-error nil)
      (magit-refresh))))

(defun +notes/caldav-magit--refresh-remote ()
  "Read remote CalDAV ETags and refresh the Org root Magit buffer.

This command never writes Org files or advances the org-caldav baseline."
  (let ((buffer (+notes/caldav-magit--require-status-buffer)))
    (with-current-buffer buffer
      (+notes/caldav-configure)
      (message "Checking CalDAV remote status...")
      (let ((org-caldav-empty-calendar nil))
        (condition-case err
            (progn
              (+notes/caldav-magit--accept-remote-etags
               buffer (+notes/caldav--fetch-remote-etags))
              (message "CalDAV remote status refreshed")
              t)
          (error
           (setq +notes/caldav-status--remote-current-p nil
                 +notes/caldav-status--remote-error
                 (error-message-string err))
           (magit-refresh)
           (message "CalDAV status refresh failed: %s"
                    +notes/caldav-status--remote-error)
           nil))))))

(defun +notes/caldav-magit--invalidate (buffer)
  "Invalidate cached CalDAV remote state in Magit BUFFER and refresh it."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq +notes/caldav-status--remote-etags :unknown
            +notes/caldav-status--remote-current-p nil
            +notes/caldav-status--last-checked nil
            +notes/caldav-status--remote-error nil)
      (+notes/caldav-magit--refresh-buffer buffer))))

(defun +notes/caldav-magit--run-sync (command &rest arguments)
  "Run CalDAV COMMAND with ARGUMENTS and refresh its Magit section.
Call COMMAND interactively when ARGUMENTS is empty."
  (let ((buffer (+notes/caldav-magit--require-status-buffer))
        completed)
    (unwind-protect
        (progn
          (if arguments
              (apply command arguments)
            (call-interactively command))
          (setq completed t))
      (unless completed
        (+notes/caldav-magit--invalidate buffer)))
    (when (and completed (buffer-live-p buffer))
      (with-current-buffer buffer
        (if (eq +notes/caldav--last-verified-remote-etags :unknown)
            (+notes/caldav-magit--refresh-remote)
          (+notes/caldav-magit--accept-remote-etags
           buffer +notes/caldav--last-verified-remote-etags))))))

(defun +notes/caldav-magit--operation-description ()
  "Return the transient description for the configured CalDAV calendar."
  (format "CalDAV: %s" +notes/caldav-calendar-id))

(defun +notes/caldav-magit--validate-fetch-args (args)
  "Reject Magit fetch ARGS unsupported by the CalDAV transport."
  (when args
    (user-error "CalDAV fetch does not support arguments; got: %s"
                (mapconcat #'identity args " "))))

(defun +notes/caldav-magit--pull-mode (args)
  "Return the CalDAV pull mode selected by Magit ARGS."
  (when-let* ((unsupported
               (seq-remove
                (lambda (arg) (equal arg "--ff-only"))
                args)))
    (user-error "Only --ff-only applies to CalDAV pull; got: %s"
                (mapconcat #'identity unsupported " ")))
  (if (member "--ff-only" args) 'ff-only 'normal))

(defun +notes/caldav-magit--push-mode (args)
  "Return the CalDAV push mode selected by Magit ARGS."
  (cond
   ((or (null args) (equal args '("--force-with-lease"))) 'normal)
   ((and (null (cdr args))
         (member (car args) '("-f" "--force")))
    'force)
   (t
    (user-error
     (concat "Only --force-with-lease and --force apply to CalDAV push; "
             "got: %s")
     (mapconcat #'identity args " ")))))

(transient-define-suffix +notes/caldav-magit-fetch (args)
  "Fetch the configured CalDAV calendar without merging."
  :description #'+notes/caldav-magit--operation-description
  (interactive (list (magit-fetch-arguments)))
  (+notes/caldav-magit--validate-fetch-args args)
  (+notes/caldav-magit--run-sync #'+notes/caldav-fetch))

(transient-define-suffix +notes/caldav-magit-pull (args)
  "Pull the configured CalDAV calendar."
  :description #'+notes/caldav-magit--operation-description
  (interactive (list (magit-pull-arguments)))
  (+notes/caldav-magit--run-sync
   #'+notes/caldav-pull
   (eq (+notes/caldav-magit--pull-mode args) 'ff-only)))

(transient-define-suffix +notes/caldav-magit-push (args)
  "Push the configured CalDAV calendar."
  :description #'+notes/caldav-magit--operation-description
  (interactive (list (magit-push-arguments)))
  (+notes/caldav-magit--run-sync
   (if (eq (+notes/caldav-magit--push-mode args) 'force)
       #'+notes/caldav-force-push
     #'+notes/caldav-push)))

(defvar +notes/caldav-magit--fetch-integration-installed nil)
(defvar +notes/caldav-magit--pull-integration-installed nil)
(defvar +notes/caldav-magit--push-integration-installed nil)

(defun +notes/caldav-magit--install-fetch-integration ()
  "Add the CalDAV action to `magit-fetch'."
  (unless +notes/caldav-magit--fetch-integration-installed
    (setq +notes/caldav-magit--fetch-integration-installed t)
    (transient-append-suffix
      'magit-fetch "e" '("c" +notes/caldav-magit-fetch))))

(defun +notes/caldav-magit--install-pull-integration ()
  "Add the CalDAV action to `magit-pull'."
  (unless +notes/caldav-magit--pull-integration-installed
    (setq +notes/caldav-magit--pull-integration-installed t)
    (transient-append-suffix
      'magit-pull "e" '("c" +notes/caldav-magit-pull))))

(defun +notes/caldav-magit--install-push-integration ()
  "Add the CalDAV action to `magit-push'."
  (unless +notes/caldav-magit--push-integration-installed
    (setq +notes/caldav-magit--push-integration-installed t)
    (transient-append-suffix
      'magit-push "e" '("c" +notes/caldav-magit-push))))

(defun +notes/caldav-magit-setup ()
  "Install CalDAV status and transient integrations into Magit."
  (unless (require 'magit nil t)
    (user-error "CalDAV Magit integration requires Magit"))
  (magit-add-section-hook
   'magit-status-sections-hook
   #'+notes/caldav-magit-insert-status
   'magit-insert-stashes
   nil)
  (with-eval-after-load 'magit-fetch
    (+notes/caldav-magit--install-fetch-integration))
  (with-eval-after-load 'magit-pull
    (+notes/caldav-magit--install-pull-integration))
  (with-eval-after-load 'magit-push
    (+notes/caldav-magit--install-push-integration)))

(provide 'org-caldav-magit)
;;; org-caldav-magit.el ends here
