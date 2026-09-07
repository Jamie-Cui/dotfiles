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

(ert-deftest org-project-caldav-is-required-by-org-project ()
  (should (featurep 'org-project-caldav)))

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

(ert-deftest org-project-caldav-put-updates-existing-vdir-item ()
  (let ((directory (make-temp-file "org-project-caldav-vdir-" t)))
    (unwind-protect
        (let ((org-project-caldav-vdir-directory directory))
          (with-temp-buffer
            (insert "BEGIN:VTODO\r\n"
                    "UID:TODO-task-1\r\n"
                    "SUMMARY:First\r\n"
                    "END:VTODO\r\n")
            (org-project-caldav--put-event (current-buffer)))
          (let ((file (org-project-caldav--event-file "task-1")))
            (should file)
            (with-temp-buffer
              (insert "BEGIN:VTODO\r\n"
                      "UID:TODO-task-1\r\n"
                      "SUMMARY:Second\r\n"
                      "END:VTODO\r\n")
              (org-project-caldav--put-event (current-buffer)))
            (should (= (length (org-project-caldav--vdir-files)) 1))
            (should (equal (org-project-caldav--event-file "task-1") file))
            (with-temp-buffer
              (insert-file-contents file)
              (should (search-forward "SUMMARY:Second" nil t)))))
      (delete-directory directory t))))

(ert-deftest org-project-caldav-discovers-every-org-file-below-task-root ()
  (let* ((root (make-temp-file "org-project-caldav-sources-" t))
         (projects (expand-file-name "projects" root))
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
              "projects/demo.org"))))
      (org-project-caldav-test--kill-buffers-below root)
      (delete-directory root t)
      (delete-directory emacs-directory t))))

(ert-deftest org-project-caldav-indexes-only-active-leaf-tasks ()
  (let* ((root (make-temp-file "org-project-caldav-scope-" t))
         (projects (expand-file-name "projects" root))
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
         (projects (expand-file-name "projects" root))
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
         (projects (expand-file-name "projects" root))
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
             (equal (org-project-caldav--command 'pull)
                    (list "/usr/bin/vdirsyncer" "--config" config
                          "sync" "test_pair")))
            (should
             (equal (org-project-caldav--command 'discover)
                    (list "/usr/bin/vdirsyncer" "--config" config
                          "discover" "test_pair")))))
      (delete-file config))))

(provide 'org-project-caldav-test)
;;; org-project-caldav-test.el ends here
