;;; caldav-test.el --- Tests for explicit safe CalDAV sync -*- lexical-binding: t; -*-

;;; Commentary:
;; Offline tests for normal and forced snapshot semantics.  No CalDAV server
;; is contacted.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'org-caldav)
(require 'org-project)

(defconst caldav-test--org-root
  (make-temp-file "caldav-test-org-" t)
  "Temporary Org root used while loading the CalDAV module.")

(defvar +emacs/org-root-dir nil)
(setq +emacs/org-root-dir caldav-test--org-root)
(provide 'init-notes)
(load (expand-file-name "lisp/modules/caldav.el"
                        (getenv "DOTFILES_EMACS_TEST_REPO"))
      nil t)
(defun caldav-test--event (uid etag &optional status)
  "Return a test event for UID, ETAG, and optional STATUS."
  (list uid "md5" etag nil (or status 'synced)))

(defun caldav-test--local-item (uid md5 &optional title)
  "Return a local test item for UID, MD5, and optional TITLE."
  (cons uid (list :uid uid :md5 md5 :title (or title uid))))

(defun caldav-test--transient-command (prefix key)
  "Return the command bound to KEY in transient PREFIX."
  (plist-get (cdr (transient-get-suffix prefix key)) :command))

(defun caldav-test--git (repo &rest args)
  "Run Git ARGS in REPO and return trimmed output."
  (let ((default-directory repo))
    (with-temp-buffer
      (let ((status (apply #'process-file "git" nil (current-buffer) nil args)))
        (unless (zerop status)
          (error "Git failed: %s" (buffer-string)))
        (string-trim-right (buffer-string))))))

(defun caldav-test--git-repo ()
  "Create and return a temporary Git repository."
  (let ((repo (make-temp-file "caldav-git-test." t)))
    (caldav-test--git repo "init" "--quiet")
    (caldav-test--git repo "config" "user.name" "CalDAV Test")
    (caldav-test--git repo "config" "user.email" "caldav@example.test")
    repo))

(defun caldav-test--write (repo file text)
  "Write TEXT to FILE below REPO."
  (let ((path (expand-file-name file repo)))
    (make-directory (file-name-directory path) t)
    (write-region text nil path nil 'silent)))

(defun caldav-test--commit (repo message)
  "Commit REPO with MESSAGE and return HEAD."
  (caldav-test--git repo "add" "--all")
  (caldav-test--git repo "commit" "--quiet" "-m" message)
  (caldav-test--git repo "rev-parse" "HEAD"))

(defun caldav-test--read (repo file)
  "Return FILE contents below REPO."
  (with-temp-buffer
    (insert-file-contents (expand-file-name file repo))
    (buffer-string)))

(ert-deftest caldav-git-snapshot-pull-creates-a-real-merge-conflict ()
  (let* ((repo (caldav-test--git-repo))
         (+emacs/org-root-dir repo))
    (unwind-protect
        (progn
          (caldav-test--write repo "tasks.org" "base\n")
          (let* ((base (caldav-test--commit repo "base"))
                 (context (+notes/caldav--git-context)))
            (git-foreign-register-remote
             context +notes/caldav-git-remote-name)
            (git-foreign-set-base-ref context base)
            (git-foreign-set-remote-ref context base)
            (caldav-test--write repo "tasks.org" "local\n")
            (caldav-test--commit repo "local")
            (let ((remote
                   (cl-letf
                       (((symbol-function '+notes/caldav--run-remote-pull)
                         (lambda ()
                           (caldav-test--write
                            repo "tasks.org" "remote\n"))))
                     (+notes/caldav--capture-remote-snapshot context))))
              (should (equal (caldav-test--read repo "tasks.org") "local\n"))
              (should (string-empty-p
                       (+notes/caldav--git-worktree-status context)))
              (should
               (eq (git-foreign-apply-pull
                    context (git-foreign-read-state context remote))
                   'conflict))
              (should (string-match-p
                       "UU tasks.org"
                       (+notes/caldav--git-worktree-status context)))
              (let ((contents (caldav-test--read repo "tasks.org")))
                (should (string-match-p "^<<<<<<< HEAD$" contents))
                (should (string-match-p "^>>>>>>> " contents))))))
      (delete-directory repo t))))

(ert-deftest caldav-git-snapshot-starts-from-latest-remote-ref ()
  (let* ((repo (caldav-test--git-repo))
         (snapshot (make-temp-file "caldav-previous-remote." t))
         (state-file (make-temp-file "caldav-remote-state."))
         (+emacs/org-root-dir repo)
         saw-previous-remote)
    (unwind-protect
        (progn
          (caldav-test--write repo "tasks.org" "base\n")
          (let* ((base (caldav-test--commit repo "base"))
                 (context (+notes/caldav--git-context)))
            (git-foreign-set-base-ref context base)
            (caldav-test--write snapshot "tasks.org" "remote-old\n")
            (let ((previous-remote
                   (git-foreign-commit-directory
                    context snapshot base "previous remote")))
              (git-foreign-set-remote-ref context previous-remote)
              (caldav-test--write repo "tasks.org" "local\n")
              (let ((local (caldav-test--commit repo "local")))
                (cl-letf
                    (((symbol-function 'org-caldav-sync-state-filename)
                      (lambda (_id) state-file))
                     ((symbol-function '+notes/caldav--run-remote-pull)
                      (lambda ()
                        (setq saw-previous-remote
                              (equal (caldav-test--read repo "tasks.org")
                                     "remote-old\n"))
                        (caldav-test--write
                         repo "tasks.org" "remote-new\n"))))
                  (+notes/caldav--capture-remote-snapshot context))
                (should saw-previous-remote)
                (should (equal (git-foreign-rev-parse context "HEAD") local))
                (should (equal (caldav-test--read repo "tasks.org")
                               "local\n"))))))
      (when (file-exists-p state-file)
        (delete-file state-file))
      (delete-directory snapshot t)
      (delete-directory repo t))))

(ert-deftest caldav-git-unchanged-snapshot-reuses-remote-commit ()
  (let* ((repo (caldav-test--git-repo))
         (state-file (make-temp-file "caldav-unchanged-state."))
         (+emacs/org-root-dir repo))
    (unwind-protect
        (progn
          (caldav-test--write repo "tasks.org" "unchanged\n")
          (let* ((base (caldav-test--commit repo "base"))
                 (context (+notes/caldav--git-context)))
            (git-foreign-set-base-ref context base)
            (git-foreign-set-remote-ref context base)
            (cl-letf
                (((symbol-function 'org-caldav-sync-state-filename)
                  (lambda (_id) state-file))
                 ((symbol-function '+notes/caldav--run-remote-pull) #'ignore))
              (should
               (equal (+notes/caldav--capture-remote-snapshot context)
                      base)))
            (should (equal (git-foreign-rev-parse context "HEAD") base))
            (should
             (equal
              (git-foreign-rev-parse
               context (git-foreign-remote-ref context))
              base))))
      (when (file-exists-p state-file)
        (delete-file state-file))
      (delete-directory repo t))))

(ert-deftest caldav-fetch-preserves-local-state-and-ff-only-refuses-divergence ()
  (let* ((repo (caldav-test--git-repo))
         (remote-tree (make-temp-file "caldav-remote-tree." t))
         (+emacs/org-root-dir repo))
    (unwind-protect
        (progn
          (caldav-test--write repo "tasks.org" "base\n")
          (let* ((base (caldav-test--commit repo "base"))
                 (context (+notes/caldav--git-context)))
            (git-foreign-register-remote
             context +notes/caldav-git-remote-name)
            (git-foreign-set-base-ref context base)
            (git-foreign-set-remote-ref context base)
            (caldav-test--write repo "tasks.org" "local\n")
            (let* ((local (caldav-test--commit repo "local"))
                   (_ (caldav-test--write
                       remote-tree "tasks.org" "remote\n"))
                   (remote
                    (git-foreign-commit-directory
                     context remote-tree base "remote")))
              (cl-letf
                  (((symbol-function
                     '+notes/caldav--capture-remote-snapshot)
                    (lambda (sync-context)
                      (git-foreign-set-remote-ref sync-context remote)
                      remote)))
                (should (equal (+notes/caldav-fetch) remote))
                (should (equal (git-foreign-rev-parse context "HEAD") local))
                (should (equal
                         (git-foreign-rev-parse
                          context (git-foreign-base-ref context))
                         base))
                (should (equal
                         (git-foreign-rev-parse
                          context (git-foreign-remote-ref context))
                         remote))
                (should (equal
                         (caldav-test--read repo "tasks.org") "local\n"))
                (should-error (+notes/caldav-pull t) :type 'user-error)
                (should (equal
                         (git-foreign-rev-parse context "HEAD") local))
                (should-not
                 (git-foreign-rev-parse-noerror context "MERGE_HEAD"))))))
      (delete-directory remote-tree t)
      (delete-directory repo t))))

(ert-deftest caldav-git-does-not-recreate-a-removed-logical-remote ()
  (let* ((repo (caldav-test--git-repo))
         (+emacs/org-root-dir repo))
    (unwind-protect
        (progn
          (caldav-test--write repo "tasks.org" "base\n")
          (let* ((base (caldav-test--commit repo "base"))
                 (context (+notes/caldav--git-context)))
            (git-foreign-register-remote
             context +notes/caldav-git-remote-name)
            (git-foreign-set-base-ref context base)
            (git-foreign-set-remote-ref context base)
            (caldav-test--git
             repo "remote" "remove" +notes/caldav-git-remote-name)
            (should-error (+notes/caldav--ensure-git-state context)
                          :type 'user-error)
            (should-not (git-foreign-remote-name context))))
      (delete-directory repo t))))

(ert-deftest caldav-git-snapshot-failure-rolls-back-worktree-and-state ()
  (let* ((repo (caldav-test--git-repo))
         (+emacs/org-root-dir repo)
         (state-file (make-temp-file "caldav-git-state.")))
    (unwind-protect
        (progn
          (caldav-test--write repo "tasks.org" "base\n")
          (let* ((base (caldav-test--commit repo "base"))
                 (context (+notes/caldav--git-context)))
            (git-foreign-set-base-ref context base)
            (git-foreign-set-remote-ref context base)
            (caldav-test--write repo "tasks.org" "local\n")
            (caldav-test--commit repo "local")
            (write-region "old-state\n" nil state-file nil 'silent)
            (cl-letf
                (((symbol-function 'org-caldav-sync-state-filename)
                  (lambda (_id) state-file))
                 ((symbol-function '+notes/caldav--run-remote-pull)
                  (lambda ()
                    (caldav-test--write repo "tasks.org" "remote\n")
                    (write-region
                     "new-state\n" nil state-file nil 'silent)
                    (error "Simulated remote failure"))))
              (should-error
               (+notes/caldav--capture-remote-snapshot context)
               :type 'error))
            (should (equal (caldav-test--read repo "tasks.org") "local\n"))
            (should (string-empty-p
                     (+notes/caldav--git-worktree-status context)))
            (with-temp-buffer
              (insert-file-contents state-file)
              (should (equal (buffer-string) "old-state\n")))))
      (when (file-exists-p state-file)
        (delete-file state-file))
      (delete-directory repo t))))

(ert-deftest caldav-local-event-inventory-always-includes-inbox ()
  (let* ((inbox (expand-file-name "inbox.org" caldav-test--org-root))
         (source (expand-file-name "source.org" caldav-test--org-root))
         (org-caldav-inbox inbox)
         (org-caldav-files (list source))
         exported-files)
    (cl-letf (((symbol-function 'org-caldav-generate-ics)
               (lambda ()
                 (setq exported-files (copy-sequence org-caldav-files))
                 (let ((buffer (generate-new-buffer " *caldav-uids*")))
                   (with-current-buffer buffer
                     (insert "BEGIN:VCALENDAR\r\n"
                             "BEGIN:VTODO\r\n"
                             "UID:inbox-uid\r\n"
                             "END:VTODO\r\n"
                             "END:VCALENDAR\r\n"))
                   buffer))))
      (should (equal (+notes/caldav--local-event-uids) '("inbox-uid")))
      (should (member inbox exported-files))
      (should (member source exported-files)))))

(ert-deftest caldav-incremental-pull-skips-complete-local-inventory ()
  (let ((prepared 0)
        force-value
        synced)
    (cl-letf (((symbol-function '+notes/caldav--prepare-project-files)
               (lambda () (cl-incf prepared)))
              ((symbol-function '+notes/caldav--local-event-uids)
               (lambda () (ert-fail "Incremental pull exported local UIDs")))
              ((symbol-function 'org-caldav-sync)
               (lambda ()
                 (setq force-value +notes/caldav--force-pulling
                       synced t)))
              ((symbol-function '+notes/caldav--sync-errors)
               (lambda () nil))
              ((symbol-function '+notes/caldav--finish-remote-pull)
               (lambda () '(("uid" . "etag")))))
      (should (equal (+notes/caldav--run-remote-pull)
                     '(("uid" . "etag"))))
      (should (= prepared 1))
      (should synced)
      (should-not force-value))))

(ert-deftest caldav-git-rejects-an-uncommitted-worktree ()
  (let* ((repo (caldav-test--git-repo))
         (+emacs/org-root-dir repo))
    (unwind-protect
        (progn
          (caldav-test--write repo "tasks.org" "base\n")
          (caldav-test--commit repo "base")
          (caldav-test--write repo "tasks.org" "dirty\n")
          (should-error
           (+notes/caldav--assert-clean-git-worktree
            (+notes/caldav--git-context))
           :type 'user-error))
      (delete-directory repo t))))

(ert-deftest caldav-magit-installs-fetch-pull-and-push-transient-suffixes ()
  (require 'magit-fetch)
  (require 'magit-pull)
  (require 'magit-push)
  (let* ((sections (default-value 'magit-status-sections-hook))
         (tail (memq #'+notes/caldav-magit-insert-status sections)))
    (should tail)
    (should (eq (cadr tail) #'magit-insert-stashes)))
  (dolist (binding '((magit-fetch "c" +notes/caldav-magit-fetch)
                     (magit-pull "c" +notes/caldav-magit-pull)
                     (magit-push "c" +notes/caldav-magit-push)))
    (should (eq (caldav-test--transient-command
                 (nth 0 binding) (nth 1 binding))
                (nth 2 binding)))))

(ert-deftest caldav-configuration-initializes-connection-values-explicitly ()
  (let (org-caldav-url org-caldav-calendar-id)
    (+notes/caldav-configure)
    (should (equal org-caldav-url +notes/caldav-url))
    (should (equal org-caldav-calendar-id +notes/caldav-calendar-id))))

(ert-deftest caldav-status-classifies-three-way-changes ()
  (let* ((base (mapcar (lambda (uid)
                         (list uid (concat "md5-" uid)
                               (concat "etag-" uid) nil 'synced))
                       '("synced" "local-modified" "remote-modified"
                         "diverged" "local-deleted" "remote-deleted"
                         "conflict")))
         (local (list
                 (caldav-test--local-item "synced" "md5-synced")
                 (caldav-test--local-item "local-modified" "new-local")
                 (caldav-test--local-item
                  "remote-modified" "md5-remote-modified")
                 (caldav-test--local-item "diverged" "new-local")
                 (caldav-test--local-item
                  "remote-deleted" "md5-remote-deleted")
                 (caldav-test--local-item "conflict" "md5-conflict")
                 (caldav-test--local-item "local-added" "new-local")))
         (remote '(("synced" . "etag-synced")
                   ("local-modified" . "etag-local-modified")
                   ("remote-modified" . "new-remote")
                   ("diverged" . "new-remote")
                   ("local-deleted" . "etag-local-deleted")
                   ("conflict" . "etag-conflict")
                   ("remote-added" . "new-remote")))
         (entries (+notes/caldav-status--classify
                   base local remote t '("conflict")))
         (states (mapcar (lambda (entry)
                           (cons (plist-get entry :uid)
                                 (plist-get entry :state)))
                         entries)))
    (dolist (expected '(("synced" . synced)
                        ("local-modified" . local-modified)
                        ("remote-modified" . remote-modified)
                        ("diverged" . diverged)
                        ("local-deleted" . local-deleted)
                        ("remote-deleted" . remote-deleted)
                        ("conflict" . conflict)
                        ("local-added" . local-added)
                        ("remote-added" . remote-added)))
      (should (eq (alist-get (car expected) states nil nil #'equal)
                  (cdr expected))))))

(ert-deftest caldav-status-keeps-remote-unknown-separate-from-empty ()
  (let* ((base (list (list "same" "md5-same" "etag-same" nil 'synced)
                     (list "changed" "md5-old" "etag-old" nil 'synced)))
         (local (list (caldav-test--local-item "same" "md5-same")
                      (caldav-test--local-item "changed" "md5-new")))
         (entries (+notes/caldav-status--classify base local nil nil nil)))
    (should (eq (plist-get (seq-find
                            (lambda (entry)
                              (equal (plist-get entry :uid) "same"))
                            entries)
                           :state)
                'unchecked))
    (should (eq (plist-get (seq-find
                            (lambda (entry)
                              (equal (plist-get entry :uid) "changed"))
                            entries)
                           :state)
                'local-modified))))

(ert-deftest caldav-magit-sections-have-no-custom-keymaps ()
  (dolist (class '(+notes/caldav-magit-section
                   +notes/caldav-magit-group-section
                   +notes/caldav-magit-entry-section))
    (should-not (oref (make-instance class) keymap))))

(ert-deftest caldav-magit-applies-only-to-the-org-root-status-buffer ()
  (let ((other-root (make-temp-file "caldav-other-repo-" t)))
    (unwind-protect
        (with-temp-buffer
          (setq major-mode 'magit-status-mode)
          (cl-letf (((symbol-function 'magit-toplevel)
                     (lambda (&optional _directory)
                       caldav-test--org-root)))
            (should (+notes/caldav-magit--applicable-p)))
          (cl-letf (((symbol-function 'magit-toplevel)
                     (lambda (&optional _directory) other-root)))
            (should-not (+notes/caldav-magit--applicable-p))))
      (delete-directory other-root t))))

(ert-deftest caldav-magit-does-not-target-org-status-from-another-repo ()
  (let ((other-root (make-temp-file "caldav-other-repo-" t))
        consulted)
    (unwind-protect
        (with-temp-buffer
          (setq major-mode 'magit-status-mode)
          (cl-letf (((symbol-function 'magit-toplevel)
                     (lambda (&optional _directory) other-root))
                    ((symbol-function 'magit-get-mode-buffer)
                     (lambda (&rest _arguments)
                       (setq consulted t))))
            (should-not (+notes/caldav-magit--status-buffer))
            (should-not consulted)))
      (delete-directory other-root t))))

(ert-deftest caldav-status-push-gate-blocks-remote-drift ()
  (cl-letf (((symbol-function '+notes/caldav--modified-org-buffers)
             (lambda () nil)))
    (let ((gate (+notes/caldav-status--push-gate
                 '(:baseline-exists t
                   :remote-current t
                   :entries ((:uid "uid" :state remote-modified))))))
      (should (string-prefix-p "BLOCKED" (car gate)))
      (should (eq (cadr gate) 'error)))
    (let ((gate (+notes/caldav-status--push-gate
                 '(:baseline-exists t
                   :remote-current t
                   :entries ((:uid "uid" :state local-modified))))))
      (should (string-prefix-p "READY" (car gate)))
      (should (eq (cadr gate) 'success)))
    (let ((gate (+notes/caldav-status--push-gate
                 '(:baseline-exists t
                   :remote-current nil
                   :entries ((:uid "uid" :state local-modified))))))
      (should (string-prefix-p "GUARDED" (car gate)))
      (should (eq (cadr gate) 'warning)))
    (let ((gate (+notes/caldav-status--push-gate
                 '(:baseline-exists t
                   :git (:clean nil)
                   :remote-current t
                   :entries nil))))
      (should (string-prefix-p "BLOCKED — commit Git" (car gate)))
      (should (eq (cadr gate) 'error)))))

(ert-deftest caldav-magit-inserts-status-into-the-magit-section-tree ()
  (let ((org-caldav-calendar-id "test-calendar")
        (org-caldav-url nil)
        (+notes/caldav-status--remote-etags '(("remote" . "etag-new")))
        (+notes/caldav-status--remote-current-p t)
        (+notes/caldav-status--last-checked (current-time)))
    (with-temp-buffer
      (magit-section-mode)
      (let ((inhibit-read-only t))
        (cl-letf (((symbol-function '+notes/caldav-magit--applicable-p)
                   (lambda () t))
                  ((symbol-function '+notes/caldav-configure) #'ignore)
                  ((symbol-function '+notes/caldav-status--collect-data)
                   (lambda ()
                     '(:baseline-exists t
                       :remote-current t
                       :entries ((:uid "remote"
                                  :title nil
                                  :state remote-added)))))
                  ((symbol-function '+notes/caldav--modified-org-buffers)
                   (lambda () nil)))
          (magit-insert-section (magit-section)
            (+notes/caldav-magit-insert-status))))
      (should magit-root-section)
      (let ((section (car (oref magit-root-section children))))
        (should (object-of-class-p section '+notes/caldav-magit-section))
        (should (object-of-class-p
                 (car (oref section children))
                 '+notes/caldav-magit-group-section)))
      (should (string-match-p "CalDAV: test-calendar" (buffer-string)))
      (should (string-match-p "Remote: (not configured)/test-calendar"
                              (buffer-string)))
      (should (string-match-p
               "Git remote: unregistered — not initialized"
               (buffer-string)))
      (should (string-match-p "^  Remote changes" (buffer-string)))
      (should-not (string-match-p "^Remote changes" (buffer-string)))
      (should (string-match-p "^    added remotely" (buffer-string)))
      (goto-char (point-min))
      (re-search-forward "^  Remote changes")
      (should (eq (get-text-property (match-beginning 0) 'font-lock-face)
                  'magit-section-secondary-heading)))))

(ert-deftest caldav-magit-interprets-native-sync-arguments ()
  (should-not (+notes/caldav-magit--validate-fetch-args nil))
  (should-error (+notes/caldav-magit--validate-fetch-args '("--force"))
                :type 'user-error)
  (should (eq (+notes/caldav-magit--pull-mode nil) 'normal))
  (should (eq (+notes/caldav-magit--pull-mode '("--ff-only")) 'ff-only))
  (should-error (+notes/caldav-magit--pull-mode '("--force"))
                :type 'user-error)
  (should-error (+notes/caldav-magit--pull-mode '("--autostash"))
                :type 'user-error)
  (should (eq (+notes/caldav-magit--push-mode nil) 'normal))
  (should (eq (+notes/caldav-magit--push-mode
               '("--force-with-lease"))
              'normal))
  (should (eq (+notes/caldav-magit--push-mode '("--force")) 'force))
  (should-error (+notes/caldav-magit--push-mode '("--dry-run"))
                :type 'user-error))

(ert-deftest caldav-magit-dispatches-native-transients-to-safe-commands ()
  (let (commands)
    (cl-letf (((symbol-function '+notes/caldav-magit--run-sync)
               (lambda (command &rest arguments)
                 (push (cons command arguments) commands))))
      (+notes/caldav-magit-fetch nil)
      (+notes/caldav-magit-pull nil)
      (+notes/caldav-magit-pull '("--ff-only"))
      (+notes/caldav-magit-push '("--force-with-lease"))
      (+notes/caldav-magit-push '("-f")))
    (should (equal (nreverse commands)
                   '((+notes/caldav-fetch)
                     (+notes/caldav-pull nil)
                     (+notes/caldav-pull t)
                     (+notes/caldav-push)
                     (+notes/caldav-force-push))))))

(ert-deftest caldav-magit-refreshes-remote-without-running-a-sync ()
  (let (refreshed)
    (with-temp-buffer
      (cl-letf (((symbol-function '+notes/caldav-magit--require-status-buffer)
                 (lambda () (current-buffer)))
                ((symbol-function '+notes/caldav-configure) #'ignore)
                ((symbol-function '+notes/caldav--fetch-remote-etags)
                 (lambda () '(("uid" . "etag"))))
                ((symbol-function 'magit-refresh)
                 (lambda () (setq refreshed t))))
        (should (+notes/caldav-magit--refresh-remote))
        (should refreshed)
        (should +notes/caldav-status--remote-current-p)
        (should (equal +notes/caldav-status--remote-etags
                       '(("uid" . "etag"))))
        (should +notes/caldav-status--last-checked)
        (should-not +notes/caldav-status--remote-error)))))

(ert-deftest caldav-magit-invalidates-after-a-failed-sync ()
  (let (invalidated refreshed)
    (with-temp-buffer
      (cl-letf (((symbol-function 'caldav-test--failing-sync)
                 (lambda ()
                   (interactive)
                   (error "Simulated sync failure")))
                ((symbol-function '+notes/caldav-magit--require-status-buffer)
                 (lambda () (current-buffer)))
                ((symbol-function '+notes/caldav-magit--invalidate)
                 (lambda (_buffer) (setq invalidated t)))
                ((symbol-function '+notes/caldav-magit--refresh-remote)
                 (lambda () (setq refreshed t))))
        (should-error
         (+notes/caldav-magit--run-sync #'caldav-test--failing-sync)
         :type 'error)))
    (should invalidated)
    (should-not refreshed)))

(ert-deftest caldav-magit-reuses-sync-etags-and-refreshes-once ()
  (let ((+notes/caldav--last-verified-remote-etags
         '(("uid" . "etag")))
        (refresh-count 0)
        fetched)
    (with-temp-buffer
      (cl-letf (((symbol-function '+notes/caldav-magit--require-status-buffer)
                 (lambda () (current-buffer)))
                ((symbol-function 'caldav-test--successful-sync) #'ignore)
                ((symbol-function '+notes/caldav--fetch-remote-etags)
                 (lambda () (setq fetched t)))
                ((symbol-function 'magit-refresh)
                 (lambda () (cl-incf refresh-count))))
        (+notes/caldav-magit--run-sync #'caldav-test--successful-sync)
        (should (= refresh-count 1))
        (should-not fetched)
        (should +notes/caldav-status--remote-current-p)
        (should (equal +notes/caldav-status--remote-etags
                       '(("uid" . "etag"))))))))

(ert-deftest caldav-normal-pull-classifies-remote-snapshot ()
  (let ((org-caldav-event-list
         (list (caldav-test--event "same" "etag-1")
               (caldav-test--event "changed" "etag-old")
               (caldav-test--event "deleted" "etag-deleted")))
        (+notes/caldav--pulling t)
        (+notes/caldav--force-pulling nil)
        (+notes/caldav--remote-etags
         '(("same" . "etag-1")
           ("changed" . "etag-new")
           ("new" . "etag-new-item"))))
    (+notes/caldav--reconcile-pull-state-a
     (lambda ()
       (setq org-caldav-event-list
             (append org-caldav-event-list
                     (list (caldav-test--event "new" "etag-new-item"
                                                'new-in-cal))))))
    (should (eq (org-caldav-event-status
                 (assoc "same" org-caldav-event-list))
                'synced))
    (should (eq (org-caldav-event-status
                 (assoc "changed" org-caldav-event-list))
                'changed-in-cal))
    (should (eq (org-caldav-event-status
                 (assoc "deleted" org-caldav-event-list))
                'deleted-in-cal))
    (should (eq (org-caldav-event-status
                 (assoc "new" org-caldav-event-list))
                'new-in-cal))))

(ert-deftest caldav-force-pull-makes-remote-the-complete-snapshot ()
  (let ((org-caldav-event-list
         (list (caldav-test--event "both" "etag-old")
               (caldav-test--event "remote-only" "etag-remote")
               (caldav-test--event "stale" nil)))
        (+notes/caldav--pulling t)
        (+notes/caldav--force-pulling t)
        (+notes/caldav--force-local-uids '("both" "local-only"))
        (+notes/caldav--remote-etags
         '(("both" . "etag-current")
           ("remote-only" . "etag-remote"))))
    (+notes/caldav--reconcile-pull-state-a (lambda () nil))
    (should (eq (org-caldav-event-status
                 (assoc "both" org-caldav-event-list))
                'changed-in-cal))
    (should (eq (org-caldav-event-status
                 (assoc "remote-only" org-caldav-event-list))
                'new-in-cal))
    (should (eq (org-caldav-event-status
                 (assoc "local-only" org-caldav-event-list))
                'deleted-in-cal))
    (should-not (assoc "stale" org-caldav-event-list))))

(ert-deftest caldav-force-push-makes-local-the-complete-snapshot ()
  (let ((org-caldav-event-list
         (list (caldav-test--event "both" "etag-old")
               (caldav-test--event "stale" "etag-stale")))
        (+notes/caldav--force-pushing t)
        (+notes/caldav--force-remote-etags
         '(("both" . "etag-current")
           ("remote-only" . "etag-remote")))
        (ics (generate-new-buffer " *caldav-force-ics*")))
    (unwind-protect
        (progn
          (with-current-buffer ics
            (insert "BEGIN:VCALENDAR\r\n"
                    "BEGIN:VTODO\r\nUID:both\r\nEND:VTODO\r\n"
                    "BEGIN:VTODO\r\nUID:local-only\r\nEND:VTODO\r\n"
                    "END:VCALENDAR\r\n"))
          (+notes/caldav--force-push-eventdb-a
           (lambda (_buffer)
             (setq org-caldav-event-list
                   (append org-caldav-event-list
                           (list (caldav-test--event "local-only" nil
                                                      'new-in-org)))))
           ics)
          (should (eq (org-caldav-event-status
                       (assoc "both" org-caldav-event-list))
                      'changed-in-org))
          (should (eq (org-caldav-event-status
                       (assoc "local-only" org-caldav-event-list))
                      'new-in-org))
          (should (eq (org-caldav-event-status
                       (assoc "remote-only" org-caldav-event-list))
                      'deleted-in-org))
          (should (eq (org-caldav-event-status
                       (assoc "stale" org-caldav-event-list))
                      'deleted-in-org)))
      (kill-buffer ics))))

(ert-deftest caldav-force-push-uses-current-remote-etag ()
  (let ((org-caldav-event-list
         (list (caldav-test--event "uid" "etag-stale")))
        (+notes/caldav--pushing t)
        (+notes/caldav--force-pushing t)
        (+notes/caldav--force-remote-etags '(("uid" . "etag-current")))
        (+notes/caldav--write-etags nil)
        captured-headers
        (response (generate-new-buffer " *caldav-force-put*")))
    (unwind-protect
        (progn
          (with-current-buffer response
            (insert "HTTP/1.1 204 No Content\r\nETag: \"etag-written\"\r\n\r\n"))
          (+notes/caldav--conditional-request-a
           (lambda (_url _method _data headers)
             (setq captured-headers headers)
             response)
           "https://example.invalid/uid.ics"
           "PUT" "BEGIN:VTODO\r\nUID:uid\r\nEND:VTODO\r\n" nil)
          (should (member '("If-Match" . "\"etag-current\"")
                          captured-headers))
          (should (equal +notes/caldav--write-etags
                         '(("uid" . "etag-written")))))
      (kill-buffer response))))

(ert-deftest caldav-request-uid-matches-the-complete-url-component ()
  (let ((org-caldav-event-list
         (list (caldav-test--event "short" "etag-short")
               (caldav-test--event "prefix-short-suffix" "etag-long")))
        (org-caldav-uuid-extension ".ics"))
    (should
     (equal
      (+notes/caldav--request-uid
       "https://example.invalid/prefix-short-suffix.ics" nil)
      "prefix-short-suffix"))))

(ert-deftest caldav-force-push-detects-non-local-remote-item ()
  (let ((org-caldav-event-list
         (list (caldav-test--event "local" "etag-local")))
        (+notes/caldav--pushing t)
        (+notes/caldav--force-pushing t)
        (+notes/caldav--write-etags nil)
        (+notes/caldav--push-races nil))
    (cl-letf (((symbol-function 'org-caldav-get-event-etag-list)
               (lambda ()
                 '(("local" . "etag-local")
                   ("raced" . "etag-raced")))))
      (+notes/caldav--verify-written-etags-a (lambda () nil)))
    (should (equal +notes/caldav--push-races '("raced")))))

(ert-deftest caldav-saved-state-drift-detects-a-pull-race ()
  (let ((state-file (make-temp-file "caldav-state-")))
    (unwind-protect
        (cl-letf (((symbol-function 'org-caldav-sync-state-filename)
                   (lambda (_id) state-file))
                  ((symbol-function 'org-caldav-load-sync-state)
                   (lambda ()
                     (setq org-caldav-event-list
                           (list (caldav-test--event "uid" "etag-before")))))
                  ((symbol-function '+notes/caldav--fetch-remote-etags)
                   (lambda () '(("uid" . "etag-during-pull")))))
          (should (equal (+notes/caldav--saved-state-drift) '("uid"))))
      (delete-file state-file))))

(provide 'caldav-test)
;;; caldav-test.el ends here
