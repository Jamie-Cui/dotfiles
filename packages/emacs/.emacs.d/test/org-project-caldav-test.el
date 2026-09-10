;;; org-project-caldav-test.el --- Tests for org-project CalDAV -*- lexical-binding: t; -*-

;;; Commentary:

;; Offline tests for the local Org/vdir bridge.  No CalDAV server is contacted.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'org-project)
(require 'org-project-caldav)

(defconst org-project-caldav-test--vtodo
  (concat "BEGIN:VCALENDAR\r\n"
          "VERSION:2.0\r\n"
          "BEGIN:VTODO\r\n"
          "UID:TODO-task-1\r\n"
          "SUMMARY:Test task\r\n"
          "STATUS:NEEDS-ACTION\r\n"
          "PERCENT-COMPLETE:0\r\n"
          "END:VTODO\r\n"
          "END:VCALENDAR\r\n")
  "Minimal VTODO used by local bridge tests.")

(defun org-project-caldav-test--kill-buffers-below (directory)
  "Kill file buffers visiting files below DIRECTORY."
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (and buffer-file-name
                 (file-in-directory-p buffer-file-name directory))
        (set-buffer-modified-p nil)
        (kill-buffer buffer)))))

(ert-deftest org-project-load-does-not-load-org-project-caldav ()
  "Keep CalDAV synchronization an optional org-project integration."
  (let ((isolated-features
         (delq 'org-project-caldav
               (delq 'org-project (copy-sequence features)))))
    (cl-progv '(features) (list isolated-features)
      (should-not (featurep 'org-project-caldav))
      (load (expand-file-name
             "org-project.el"
             (file-name-directory (locate-library "org-project")))
            nil t)
      (should (featurep 'org-project))
      (should-not (featurep 'org-project-caldav)))))

(ert-deftest org-project-caldav-setup-hides-standalone-sync-command ()
  "Hide a stale standalone sync autoload without loading its package."
  (let ((saved-plist (copy-sequence (symbol-plist 'org-caldav-sync)))
        (saved-function (and (fboundp 'org-caldav-sync)
                             (symbol-function 'org-caldav-sync)))
        (org-agenda-files nil)
        (org-project-caldav-auto-sync nil))
    (unwind-protect
        (progn
          (unless (fboundp 'org-caldav-sync)
            (fset 'org-caldav-sync
                  (lambda () (interactive))))
          (cl-letf (((symbol-function '+org-project-sync-agenda-files)
                     #'ignore))
            (org-project-caldav-setup)
            (should (commandp 'org-caldav-sync))
            (should-not (featurep 'org-caldav))
            (should-not
             (command-completion-default-include-p
              'org-caldav-sync (current-buffer)))))
      (setplist 'org-caldav-sync saved-plist)
      (if saved-function
          (fset 'org-caldav-sync saved-function)
        (fmakunbound 'org-caldav-sync)))))

(ert-deftest org-project-caldav-indexes-vtodo-by-logical-uid ()
  (let ((directory (make-temp-file "org-project-caldav-vdir-" t)))
    (unwind-protect
        (let* ((org-project-caldav-vdir-directory directory)
               (file (expand-file-name "opaque-name.ics" directory)))
          (write-region org-project-caldav-test--vtodo nil file nil 'silent)
          (let ((metadata (car (org-project-caldav--vdir-index))))
            (should (equal (nth 0 metadata) "task-1"))
            (should (equal (nth 2 metadata) file))
            (should (stringp (nth 1 metadata)))))
      (delete-directory directory t))))

(ert-deftest org-project-caldav-vtodo-codec-unfolds-and-decodes-fields ()
  "Decode folded CRLF input without relying on org-caldav."
  (with-temp-buffer
    (insert "BEGIN:VCALENDAR\r\n"
            "VERSION:2.0\r\n"
            "BEGIN:VTODO\r\n"
            "UID:TODO-codec-1\r\n"
            "SUMMARY:Codec test\r\n"
            "DESCRIPTION:Line one\\n\r\n"
            " line two\r\n"
            "LOCATION:Office\r\n"
            "CATEGORIES:work,deep focus\r\n"
            "PRIORITY:1\r\n"
            "PERCENT-COMPLETE:25\r\n"
            "DTSTART;TZID=Asia/Shanghai:20260908T091500\r\n"
            "DUE;VALUE=DATE:20260909\r\n"
            "RRULE:FREQ=WEEKLY;INTERVAL=2\r\n"
            "SEQUENCE:3\r\n"
            "END:VTODO\r\n"
            "END:VCALENDAR\r\n")
    (let ((record (org-project-caldav-vtodo-parse-buffer)))
      (should (equal (plist-get record :uid) "codec-1"))
      (should (equal (plist-get record :summary) "Codec test"))
      (should (equal (plist-get record :description)
                     "Line one\n line two"))
      (should (equal (plist-get record :location) "Office"))
      (should (equal (plist-get record :categories)
                     '("work" "deep-focus")))
      (should (equal (plist-get record :priority) "1"))
      (should (equal (plist-get record :percent) "25"))
      (should (equal (plist-get record :scheduled-time) "09:15"))
      (should (equal (plist-get record :due-time) nil))
      (should (= (plist-get record :sequence) 3)))))

(ert-deftest org-project-caldav-put-updates-existing-vdir-item ()
  (let ((directory (make-temp-file "org-project-caldav-vdir-" t)))
    (unwind-protect
        (let ((org-project-caldav-vdir-directory directory))
          (with-temp-buffer
            (insert "BEGIN:VTODO\r\n"
                    "UID:TODO-task-1\r\n"
                    "SUMMARY:First\r\n"
                    "END:VTODO\r\n")
            (org-project-caldav--put-vtodo "task-1" (buffer-string)))
          (let ((file (org-project-caldav--event-file "task-1")))
            (should file)
            (with-temp-buffer
              (insert-file-contents file)
              (should (search-forward "SEQUENCE:0" nil t)))
            (with-temp-buffer
              (insert "BEGIN:VTODO\r\n"
                      "UID:TODO-task-1\r\n"
                      "SUMMARY:Second\r\n"
                      "END:VTODO\r\n")
              (org-project-caldav--put-vtodo "task-1" (buffer-string)))
            (should (= (length (org-project-caldav--vdir-files)) 1))
            (should (equal (org-project-caldav--event-file "task-1") file))
            (with-temp-buffer
              (insert-file-contents file)
              (should (search-forward "SUMMARY:Second" nil t))
              (goto-char (point-min))
              (should (search-forward "SEQUENCE:1" nil t)))))
      (delete-directory directory t))))

(ert-deftest org-project-caldav-state-reader-does-not-evaluate-input ()
  "Reject reader evaluation syntax without running its payload."
  (let* ((emacs-directory (file-name-as-directory
                           (make-temp-file
                            "org-project-caldav-emacs-" t)))
         (user-emacs-directory emacs-directory)
         (+org-project-root-dir emacs-directory)
         (state-directory (org-project-caldav--state-directory))
         (state-file (org-project-caldav--state-file))
         (marker (expand-file-name "reader-evaluated" emacs-directory)))
    (unwind-protect
        (progn
          (make-directory state-directory t)
          (write-region
           (format "#.(progn (write-region \"unsafe\" nil %S) nil)\n"
                   marker)
           nil state-file nil 'silent)
          (should-error (org-project-caldav--load-state)
                        :type 'org-project-caldav-state-error)
          (should-not (file-exists-p marker)))
      (delete-directory emacs-directory t))))

(ert-deftest org-project-caldav-loads-legacy-state-as-data ()
  "Migrate the retired org-caldav state shape without loading its package."
  (let* ((emacs-directory (file-name-as-directory
                           (make-temp-file
                            "org-project-caldav-emacs-" t)))
         (user-emacs-directory emacs-directory)
         (+org-project-root-dir emacs-directory)
         (source-file (expand-file-name "legacy.org" emacs-directory))
         (legacy-file (org-project-caldav--legacy-state-file)))
    (unwind-protect
        (progn
          (write-region
           (format
            (concat ";; retired state\n"
                    "(setq org-caldav-event-list\n"
                    "'((\"legacy-1\" \"org-hash\" \"etag\" 4 synced)))\n"
                    "(setq org-caldav-previous-files '%S)\n")
            (list source-file))
           nil legacy-file nil 'silent)
          (let ((state (org-project-caldav--load-state)))
            (should (equal (plist-get state :source-files)
                           (list source-file)))
            (should (equal (plist-get state :entries)
                           '(("legacy-1" "org-hash" "etag" 4 nil))))
            (should-not (featurep 'org-caldav))))
      (delete-directory emacs-directory t))))

(ert-deftest org-project-caldav-reconcile-rolls-back-org-on-state-failure ()
  "Keep committed Org, vdir, and state data when state writing fails."
  (let* ((root (make-temp-file "org-project-caldav-rollback-" t))
         (projects (expand-file-name "project-files" root))
         (project-file (expand-file-name "demo.org" projects))
         (vdir (expand-file-name "vdir" root))
         (emacs-directory (file-name-as-directory
                           (make-temp-file
                            "org-project-caldav-emacs-" t)))
         (+org-project-root-dir root)
         (+org-projects-dir projects)
         (org-project-caldav-vdir-directory vdir)
         (+org-project-state-journal-log-enabled nil)
         (user-emacs-directory emacs-directory)
         (org-id-locations-file (expand-file-name ".org-id-locations" root))
         (org-mode-hook nil))
    (unwind-protect
        (progn
          (make-directory projects t)
          (write-region
           (concat "* Project\n"
                   "** TODO Original title\n"
                   ":PROPERTIES:\n:ID: rollback-1\n:END:\n")
           nil project-file nil 'silent)
          (org-project-caldav--reconcile)
          (let ((event-file (org-project-caldav--event-file "rollback-1")))
            (with-temp-buffer
              (insert-file-contents event-file)
              (goto-char (point-min))
              (should (search-forward "SUMMARY:Original title" nil t))
              (replace-match "SUMMARY:Remote title" t t)
              (write-region nil nil event-file nil 'silent))
            (let ((org-before (with-temp-buffer
                                (insert-file-contents project-file)
                                (buffer-string)))
                  (vdir-before (with-temp-buffer
                                 (insert-file-contents event-file)
                                 (buffer-string)))
                  (state-before
                   (with-temp-buffer
                     (insert-file-contents
                      (org-project-caldav--state-file))
                     (buffer-string))))
              (cl-letf (((symbol-function
                          'org-project-caldav--write-state-temp)
                         (lambda (_state)
                           (error "Injected state failure"))))
                (should-error (org-project-caldav--reconcile)))
              (should (equal org-before
                             (with-temp-buffer
                               (insert-file-contents project-file)
                               (buffer-string))))
              (should (equal vdir-before
                             (with-temp-buffer
                               (insert-file-contents event-file)
                               (buffer-string))))
              (should (equal state-before
                             (with-temp-buffer
                               (insert-file-contents
                                (org-project-caldav--state-file))
                               (buffer-string)))))))
      (org-project-caldav-test--kill-buffers-below root)
      (delete-directory root t)
      (delete-directory emacs-directory t))))

(ert-deftest org-project-caldav-discovers-every-org-file-below-task-root ()
  (let* ((root (make-temp-file "org-project-caldav-sources-" t))
         (projects (expand-file-name "project-files" root))
         (journal (expand-file-name "journal" root))
         (nested (expand-file-name "nested" journal))
         (vdir (expand-file-name "vdir" root))
         (emacs-directory (file-name-as-directory
                           (make-temp-file
                            "org-project-caldav-emacs-" t)))
         (+org-project-root-dir root)
         (+org-projects-dir projects)
         (org-project-caldav-vdir-directory vdir)
         (user-emacs-directory emacs-directory))
    (unwind-protect
        (progn
          (make-directory projects t)
          (make-directory nested t)
          (write-region "* Project\n" nil
                        (expand-file-name "demo.org" projects) nil 'silent)
          (write-region "* Journal\n" nil
                        (expand-file-name "20260901.org" journal) nil 'silent)
          (write-region "* Nested\n" nil
                        (expand-file-name "extra.org" nested) nil 'silent)
          (org-project-caldav--ensure-layout)
          (should
           (equal
            (mapcar (lambda (file) (file-relative-name file root))
                    (org-project-caldav--source-files))
            '("inbox.org"
              "journal/20260901.org"
              "journal/nested/extra.org"
              "project-files/demo.org"))))
      (org-project-caldav-test--kill-buffers-below root)
      (delete-directory root t)
      (delete-directory emacs-directory t))))

(ert-deftest org-project-caldav-layout-does-not-create-a-journal-directory ()
  (let* ((root (make-temp-file "org-project-caldav-layout-" t))
         (projects (expand-file-name "project-files" root))
         (vdir (expand-file-name "vdir" root))
         (emacs-directory (file-name-as-directory
                           (make-temp-file
                            "org-project-caldav-emacs-" t)))
         (+org-project-root-dir root)
         (+org-projects-dir projects)
         (org-project-caldav-vdir-directory vdir)
         (user-emacs-directory emacs-directory))
    (unwind-protect
        (progn
          (org-project-caldav--ensure-layout)
          (should (file-equal-p (org-project-caldav--state-directory) root))
          (should (file-directory-p projects))
          (should (file-exists-p (expand-file-name "inbox.org" root)))
          (should-not (file-exists-p (expand-file-name "journal" root))))
      (org-project-caldav-test--kill-buffers-below root)
      (delete-directory root t)
      (delete-directory emacs-directory t))))

(ert-deftest org-project-caldav-indexes-only-active-leaf-tasks ()
  (let* ((root (make-temp-file "org-project-caldav-scope-" t))
         (projects (expand-file-name "project-files" root))
         (journal (expand-file-name "journal" root))
         (project-file (expand-file-name "demo.org" projects))
         (journal-file (expand-file-name "20260901.org" journal))
         (+org-project-root-dir root)
         (+org-projects-dir projects)
         (org-mode-hook nil))
    (unwind-protect
        (progn
          (make-directory projects t)
          (make-directory journal t)
          (write-region
           (concat "#+TODO: TODO WAIT PROJ | DONE KILL CAPTURED MOVED\n"
                   "* Project\n"
                   "** PROJ Container\n"
                   "*** TODO Project action\n"
                   ":PROPERTIES:\n:ID: project-active\n:END:\n"
                   "** DONE Project history\n"
                   ":PROPERTIES:\n:ID: project-done\n:END:\n")
           nil project-file nil 'silent)
          (write-region
           (concat "#+TODO: TODO WAIT PROJ | DONE KILL CAPTURED MOVED\n"
                   "* Journal\n"
                   "** WAIT Journal action\n"
                   ":PROPERTIES:\n:ID: journal-active\n:END:\n"
                   "** MOVED Journal history\n"
                   ":PROPERTIES:\n:ID: journal-moved\n:END:\n")
           nil journal-file nil 'silent)
          (should
           (equal
            (sort (mapcar #'car
                          (org-project-caldav--active-task-index
                           (list project-file journal-file)))
                  #'string<)
            '("journal-active" "project-active"))))
      (org-project-caldav-test--kill-buffers-below root)
      (delete-directory root t))))

(ert-deftest org-project-caldav-coverage-fails-closed-on-missing-vtodo ()
  (let* ((root (make-temp-file "org-project-caldav-coverage-" t))
         (projects (expand-file-name "project-files" root))
         (project-file (expand-file-name "demo.org" projects))
         (vdir (expand-file-name "vdir" root))
         (+org-project-root-dir root)
         (+org-projects-dir projects)
         (org-project-caldav-vdir-directory vdir)
         (org-mode-hook nil))
    (unwind-protect
        (progn
          (make-directory projects t)
          (make-directory vdir t)
          (write-region
           (concat "* Project\n"
                   "** TODO Covered task\n"
                   ":PROPERTIES:\n:ID: coverage-1\n:END:\n")
           nil project-file nil 'silent)
          (should-error
           (org-project-caldav--validate-coverage (list project-file)))
          (write-region
           (replace-regexp-in-string "task-1" "coverage-1"
                                     org-project-caldav-test--vtodo)
           nil (expand-file-name "opaque.ics" vdir) nil 'silent)
          (should
           (org-project-caldav--validate-coverage (list project-file)))
          (should (= org-project-caldav--last-source-file-count 1))
          (should (= org-project-caldav--last-active-task-count 1)))
      (org-project-caldav-test--kill-buffers-below root)
      (delete-directory root t))))

(ert-deftest org-project-caldav-local-reconcile-round-trip ()
  (let* ((root (make-temp-file "org-project-caldav-org-" t))
         (projects (expand-file-name "project-files" root))
         (project-file (expand-file-name "demo.org" projects))
         (journal (expand-file-name "journal" root))
         (journal-file (expand-file-name "20260901.org" journal))
         (vdir (expand-file-name "vdir" root))
         (emacs-directory (file-name-as-directory
                           (make-temp-file
                            "org-project-caldav-emacs-" t)))
         (+org-project-root-dir root)
         (+org-projects-dir projects)
         (org-project-caldav-vdir-directory vdir)
         (org-agenda-files (list project-file))
         (+org-project-state-journal-log-enabled nil)
         (user-emacs-directory emacs-directory)
         (org-id-locations-file (expand-file-name ".org-id-locations" root))
         (org-mode-hook nil))
    (unwind-protect
        (progn
          (make-directory projects t)
          (make-directory journal t)
          (write-region
           (concat "#+title: Demo\n"
                   "* Project\n"
                   "** TODO Local title\n"
                   ":PROPERTIES:\n"
                   ":ID: task-1\n"
                   ":END:\n")
           nil project-file nil 'silent)
          (write-region
           (concat "* Journal\n"
                   "** TODO Journal title\n"
                   ":PROPERTIES:\n"
                   ":ID: journal-1\n"
                   ":END:\n"
                   "** DONE Journal history\n"
                   ":PROPERTIES:\n"
                   ":ID: journal-done\n"
                   ":END:\n")
           nil journal-file nil 'silent)
          (org-project-caldav--reconcile)
          (should (= (length (org-project-caldav--vdir-files)) 2))
          (should (org-project-caldav--event-file "journal-1"))
          (should-not (org-project-caldav--event-file "journal-done"))
          (let ((event-file (org-project-caldav--event-file "task-1")))
            (should event-file)
            (with-temp-buffer
              (insert-file-contents event-file)
              (goto-char (point-min))
              (should (search-forward "SUMMARY:Local title" nil t))
              (goto-char (point-min))
              (unless (search-forward "SUMMARY:Local title" nil t)
                (ert-fail "Exported VTODO has no summary"))
              (replace-match "SUMMARY:Remote title" t t)
              (write-region nil nil event-file nil 'silent)))
          (org-project-caldav--reconcile)
          (with-temp-buffer
            (insert-file-contents project-file)
            (should (search-forward "** TODO Remote title" nil t))
            (goto-char (point-min))
            (should (re-search-forward ":ID:[ \t]+task-1$" nil t)))
          (with-current-buffer (find-file-noselect project-file)
            (goto-char (point-min))
            (should (search-forward "Remote title" nil t))
            (replace-match "Org conflict winner" t t)
            (save-buffer))
          (let ((event-file (org-project-caldav--event-file "task-1")))
            (with-temp-buffer
              (insert-file-contents event-file)
              (goto-char (point-min))
              (should (search-forward "SUMMARY:Remote title" nil t))
              (replace-match "SUMMARY:Remote conflict loser" t t)
              (write-region nil nil event-file nil 'silent)))
          (org-project-caldav--reconcile)
          (with-temp-buffer
            (insert-file-contents project-file)
            (should (search-forward "** TODO Org conflict winner" nil t)))
          (with-temp-buffer
            (insert-file-contents
             (org-project-caldav--event-file "task-1"))
            (should (search-forward "SUMMARY:Org conflict winner" nil t)))
          (let ((event-file (org-project-caldav--event-file "task-1")))
            (with-temp-buffer
              (insert-file-contents event-file)
              (goto-char (point-min))
              (should (search-forward "STATUS:NEEDS-ACTION" nil t))
              (replace-match "STATUS:COMPLETED" t t)
              (goto-char (point-min))
              (should (search-forward "PERCENT-COMPLETE:0" nil t))
              (replace-match "PERCENT-COMPLETE:100" t t)
              (write-region nil nil event-file nil 'silent)))
          (org-project-caldav--reconcile)
          (with-temp-buffer
            (insert-file-contents project-file)
            (should (search-forward "** DONE Org conflict winner" nil t)))
          (should-not (org-project-caldav--event-file "task-1")))
      (org-project-caldav-test--kill-buffers-below root)
      (delete-directory root t)
      (delete-directory emacs-directory t))))

(ert-deftest org-project-caldav-command-selects-only-configured-pair ()
  (let ((config (make-temp-file "org-project-caldav-config-"))
        (org-project-caldav-pair-name "test_pair"))
    (unwind-protect
        (let ((org-project-caldav-config-file config))
          (cl-letf (((symbol-function 'org-project-caldav--program)
                     (lambda () "/usr/bin/vdirsyncer")))
            (should
             (equal (org-project-caldav--command 'pre-sync)
                    (list "/usr/bin/vdirsyncer" "--config" config
                          "sync" "test_pair")))
            (should
             (equal (org-project-caldav--command 'post-sync)
                    (list "/usr/bin/vdirsyncer" "--config" config
                          "sync" "test_pair")))
            (should
             (equal (org-project-caldav--command 'discover)
                    (list "/usr/bin/vdirsyncer" "--config" config
                          "discover" "test_pair")))))
      (delete-file config))))

(ert-deftest org-project-caldav-process-starts-from-missing-buffer-directory ()
  "Start every sync stage in the vdir despite a stale buffer directory."
  (let* ((root (make-temp-file "org-project-caldav-process-" t))
         (org-project-caldav-vdir-directory (expand-file-name "vdir" root))
         (missing (file-name-as-directory (expand-file-name "removed" root)))
         (pwd-program (executable-find "pwd"))
         (buffer (generate-new-buffer " *org-project-caldav-test*"))
         (org-project-caldav--log-buffer (buffer-name buffer))
         (org-project-caldav--process nil))
    (unwind-protect
        (progn
          (should pwd-program)
          (make-directory org-project-caldav-vdir-directory)
          (with-current-buffer buffer
            (setq default-directory missing))
          (cl-letf (((symbol-function 'org-project-caldav--credentials)
                     (lambda () (cons "test-user" (copy-sequence "test-secret"))))
                    ((symbol-function 'org-project-caldav--command)
                     (lambda (_stage) (list pwd-program)))
                    ((symbol-function 'org-project-caldav--sentinel) #'ignore))
            (dolist (stage '(pre-sync discover post-sync))
              (with-current-buffer buffer
                (erase-buffer)
                (insert (make-string org-project-caldav--log-history-limit ?x)
                        "\nOld failure: Please run vdirsyncer discover\n"))
              (let ((default-directory missing))
                (org-project-caldav--start-vdirsyncer stage)
                (should (equal default-directory missing)))
              (with-timeout (5 (ert-fail "CalDAV test process timed out"))
                (while (process-live-p org-project-caldav--process)
                  (accept-process-output org-project-caldav--process 0.1)))
              (should (= (process-exit-status org-project-caldav--process) 0))
              (should (eq (process-get org-project-caldav--process
                                       'org-project-caldav-stage)
                          stage))
              ;; Keep the previous failure for diagnosis without letting it
              ;; request discovery for the new process.
              (should-not (org-project-caldav--discovery-required-p
                           org-project-caldav--process))
              (with-current-buffer buffer
                (when (eq stage 'pre-sync)
                  (should (= (1- (process-get org-project-caldav--process
                                             'org-project-caldav-log-start))
                             org-project-caldav--log-history-limit)))
                (goto-char (point-min))
                (should (search-forward "Old failure:" nil t))
                (goto-char (point-max))
                (forward-line -1)
                (should (file-equal-p
                         (string-trim
                          (buffer-substring-no-properties (point) (point-max)))
                         org-project-caldav-vdir-directory))
                (goto-char (point-max))
                (insert "Detected change in config\n"))
              (should (org-project-caldav--discovery-required-p
                       org-project-caldav--process)))))
      (when (process-live-p org-project-caldav--process)
        (delete-process org-project-caldav--process))
      (kill-buffer buffer)
      (delete-directory root t))))

(ert-deftest org-project-caldav-empty-projects-asks-before-creating-default ()
  (let* ((root (make-temp-file "org-project-caldav-empty-" t))
         (+org-project-root-dir root)
         (+org-projects-dir (expand-file-name "project-files" root))
         (org-project-caldav-vdir-directory (expand-file-name "vdir" root))
         (user-emacs-directory (file-name-as-directory root))
         (org-agenda-files nil)
         (org-mode-hook nil)
         (org-project-caldav--running nil)
         (org-project-caldav--pending nil)
         (org-project-caldav--last-error nil)
         (org-project-caldav--approved-removals nil)
         (default (expand-file-name "default.org" +org-projects-dir))
         answer prompts stages)
    (unwind-protect
        (cl-letf (((symbol-function 'y-or-n-p)
                   (lambda (prompt)
                     (should org-project-caldav--running)
                     (push prompt prompts) answer))
                  ((symbol-function 'display-warning)
                   (lambda (&rest _) (ert-fail "Unexpected warning popup")))
                  ((symbol-function 'org-project-caldav--start-vdirsyncer)
                   (lambda (stage) (push stage stages))))
          ;; Background runs wait without asking or creating a project.
          (org-project-caldav-sync)
          (should-not prompts)
          (should-not stages)
          (should-not (file-exists-p default))
          (should (string-match-p "No project Org files"
                                  org-project-caldav--last-error))
          ;; Saying no preserves that waiting state.
          (let ((noninteractive nil))
            (call-interactively #'org-project-caldav-sync))
          (should (= (length prompts) 1))
          (should-not stages)
          (should-not (file-exists-p default))
          ;; Accepting creates a real project skeleton before network work.
          (setq answer t)
          (let ((noninteractive nil))
            (call-interactively #'org-project-caldav-sync))
          (should (= (length prompts) 2))
          (should (equal stages '(pre-sync)))
          (should (file-exists-p default))
          (with-temp-buffer
            (insert-file-contents default)
            (should (search-forward "* Inbox" nil t)))
          (should-not (file-directory-p (expand-file-name "journal" root))))
      (org-project-caldav-test--kill-buffers-below root)
      (delete-directory root t))))

(ert-deftest org-project-caldav-removals-need-exact-cycle-approval ()
  (let* ((root (make-temp-file "org-project-caldav-approval-" t))
         (+org-project-root-dir root)
         (+org-projects-dir (expand-file-name "project-files" root))
         (org-project-caldav-vdir-directory (expand-file-name "vdir" root))
         (user-emacs-directory (file-name-as-directory root))
         (org-id-locations-file (expand-file-name "ids" root))
         (org-agenda-files nil)
         (org-mode-hook nil)
         (org-project-caldav--running nil)
         (org-project-caldav--pending nil)
         (org-project-caldav--last-error nil)
         (org-project-caldav--approved-removals nil)
         (missing (expand-file-name "old/project.org" root))
         (state (list :version 1 :calendar-id org-project-caldav-calendar-id
                      :source-files (list missing)
                      :entries (list (list "task-1" "old-org" "old-cal" 0 missing))))
         answer prompts stages)
    (unwind-protect
        (progn
          (org-project-caldav--ensure-layout)
          (+org-project-ensure-default)
          (rename-file (org-project-caldav--write-state-temp state)
                       (org-project-caldav--state-file))
          (write-region org-project-caldav-test--vtodo nil
                        (expand-file-name "opaque.ics"
                                          org-project-caldav-vdir-directory)
                        nil 'silent)
          (cl-letf (((symbol-function 'yes-or-no-p)
                     (lambda (prompt)
                       (should org-project-caldav--running)
                       (push prompt prompts) answer))
                    ((symbol-function 'display-warning)
                     (lambda (&rest _) (ert-fail "Unexpected warning popup")))
                    ((symbol-function 'org-project-caldav--start-vdirsyncer)
                     (lambda (stage) (push stage stages))))
            (org-project-caldav-sync)
            (should-not prompts)
            (should-not stages)
            (should (org-project-caldav--event-file "task-1"))
            (let ((noninteractive nil))
              (call-interactively #'org-project-caldav-sync))
            (should (= (length prompts) 1))
            (should-not stages)
            (should-not org-project-caldav--approved-removals)
            ;; Quitting the minibuffer also releases the cycle.
            (cl-letf (((symbol-function 'yes-or-no-p)
                       (lambda (&rest _) (signal 'quit nil))))
              (let ((noninteractive nil))
                (call-interactively #'org-project-caldav-sync)))
            (should-not org-project-caldav--running)
            (should-not org-project-caldav--approved-removals)
            (setq answer t)
            (let ((noninteractive nil))
              (call-interactively #'org-project-caldav-sync))
            (should (equal stages '(pre-sync)))
            (should (equal org-project-caldav--approved-removals
                           (list :files (list missing) :uids '("task-1"))))
            ;; A new disappearance while network work runs is not approved.
            (should-error
             (org-project-caldav--assert-source-removal-safe
              (list :source-files (list missing)
                    :entries '(("task-1") ("another-task")))
              (org-project-caldav--source-files) nil)
             :type 'org-project-caldav-confirmation-required)
            ;; The reviewed removal can commit and clears the old baseline.
            (org-project-caldav--reconcile)
            (should-not (org-project-caldav--event-file "task-1"))
            (should-not (plist-get (org-project-caldav--load-state) :entries))
            (org-project-caldav--finish-success)
            (should-not org-project-caldav--approved-removals)
            (should-not org-project-caldav--last-error)
            (org-project-caldav-sync)
            (should-not org-project-caldav--approved-removals)
            (should (= (length prompts) 2))))
      (org-project-caldav-test--kill-buffers-below root)
      (delete-directory root t))))

(ert-deftest org-project-caldav-preflight-does-not-assign-task-ids ()
  (with-temp-buffer
    (org-mode)
    (insert "* TODO New task\n")
    (cl-letf (((symbol-function 'org-get-agenda-file-buffer)
               (lambda (_file) (current-buffer))))
      (should-not (org-project-caldav--active-task-index '("new.org") t))
      (should-error (org-project-caldav--active-task-index '("new.org")))
      (should-not (org-entry-get nil "ID")))))

(ert-deftest org-project-caldav-detects-unsaved-missing-source ()
  (let* ((root (make-temp-file "org-project-caldav-unsaved-" t))
         (+org-project-root-dir root)
         (file (expand-file-name "default.org" root)))
    (unwind-protect
        (with-temp-buffer
          (setq buffer-file-name file)
          (insert "* TODO Unsaved task\n")
          (should-not (file-exists-p file))
          (should (memq (current-buffer)
                        (org-project-caldav--modified-source-buffers))))
      (delete-directory root t))))

(provide 'org-project-caldav-test)
;;; org-project-caldav-test.el ends here
