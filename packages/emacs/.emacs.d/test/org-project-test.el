;;; org-project-test.el --- Tests for central project Org workflow -*- lexical-binding: t; -*-

;;; Commentary:

;; Focused regression tests for immutable journal events, safe project file
;; updates, and TODO rendering.

;;; Code:

(require 'cl-lib)
(require 'ert)

(add-to-list 'load-path
             (expand-file-name "../site-lisp"
                               (file-name-directory
                                (or load-file-name buffer-file-name))))

(require 'org-project)

(ert-deftest org-project-journal-state-event-classifies-transitions ()
  (let ((org-done-keywords '("DONE" "KILL"))
        (org-not-done-keywords '("TODO" "WAIT")))
    (should (equal (+org-project--journal-state-event "DONE" "TODO")
                   "DONE"))
    (should (equal (+org-project--journal-state-event "KILL" "DONE")
                   "KILL"))
    (should (equal (+org-project--journal-state-event "TODO" "DONE")
                   "REOPENED"))
    (should-not (+org-project--journal-state-event "WAIT" "TODO"))
    (should-not (+org-project--journal-state-event nil "DONE"))))

(ert-deftest org-project-journal-event-entry-uses-immutable-schema ()
  (let* ((context '(:slug "demo" :file "/tmp/demo.org"))
         (entry (+org-project--journal-event-entry
                 "REOPENED" context "task-id" "Write tests"
                 "[2026-08-28 Fri 09:30]" "DONE" "TODO")))
    (dolist (text '("** REOPENED [demo] Write tests"
                    ":EVENT: REOPENED"
                    ":EVENT_AT: [2026-08-28 Fri 09:30]"
                    ":SOURCE_ID: task-id"
                    ":PROJECT: demo"
                    ":PROJECT_FILE: /tmp/demo.org"
                    ":PREVIOUS_STATE: DONE"
                    ":NEW_STATE: TODO"
                    "[[id:task-id][open project task]]"))
      (should (string-match-p (regexp-quote text) entry)))
    (dolist (legacy '("AUDIT_STATUS" "REVIEWED_AT"
                      "DONE_JOURNAL_LOGGED_AT"))
      (should-not (string-match-p legacy entry)))))

(ert-deftest org-project-write-journal-event-preserves-existing-history ()
  (let* ((time (encode-time 0 30 9 28 8 2026))
         (original (concat "* Friday, 28/08/2026\n"
                           ":PROPERTIES:\n"
                           ":CREATED: 20260828\n"
                           ":END:\n"
                           "** CAPTURED [demo] Old task\n"
                           ":PROPERTIES:\n"
                           ":EVENT: CAPTURED\n"
                           ":EVENT_AT: [2026-08-28 Fri 09:00]\n"
                           ":SOURCE_ID: old-id\n"
                           ":PROJECT: demo\n"
                           ":PROJECT_FILE: /tmp/demo.org\n"
                           ":END:\n"
                           "old event body\n"))
         (file (make-temp-file "org-project-journal-test-" nil ".org"
                               original))
         buffer)
    (unwind-protect
        (cl-progv '(features) (list (cons 'org-journal features))
          (cl-letf (((symbol-function 'org-journal--get-entry-path)
                     (lambda (&optional _time) file))
                    ((symbol-function 'org-journal-new-entry)
                     (lambda (&rest _args) nil)))
            (let ((org-mode-hook nil))
              (+org-project--write-journal-event
               "DONE" '(:slug "demo" :file "/tmp/demo.org")
               "new-id" "New task" "TODO" "DONE" time)))
          (setq buffer (find-buffer-visiting file))
          (with-temp-buffer
            (insert-file-contents file)
            (let ((contents (buffer-string)))
              (should (string-prefix-p original contents))
              (should (string-match-p
                       (regexp-quote "** DONE [demo] New task") contents))
              (should (string-match-p
                       (regexp-quote ":EVENT: DONE") contents)))))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (set-buffer-modified-p nil))
        (let ((kill-buffer-hook nil))
          (kill-buffer buffer)))
      (when (file-exists-p file)
        (delete-file file)))))

(ert-deftest org-project-state-journal-appends-reopen-and-recompletion ()
  (let ((+org-project-state-journal-log-enabled t)
        (org-done-keywords '("DONE" "KILL"))
        (org-not-done-keywords '("TODO" "WAIT"))
        events)
    (with-temp-buffer
      (let ((org-mode-hook nil))
        (org-mode))
      (setq buffer-file-name "/tmp/demo.org")
      (insert "* TODO Write tests\n")
      (goto-char (point-min))
      (cl-letf (((symbol-function '+org-project-file-p)
                 (lambda (&optional _file) t))
                ((symbol-function '+org-project-journal-file-p)
                 (lambda (&optional _file) nil))
                ((symbol-function '+org-project-in-archive-p)
                 (lambda (&optional _marker) nil))
                ((symbol-function 'org-id-get-create)
                 (lambda () "task-id"))
                ((symbol-function '+org-project--write-journal-event)
                 (lambda (&rest args) (push args events))))
        (dolist (transition '(("TODO" "DONE")
                              ("DONE" "TODO")
                              ("TODO" "DONE")))
          (cl-progv '(org-last-state org-state) transition
            (+org-project-log-state-to-journal-h)))))
    (should
     (equal (mapcar (lambda (args)
                      (list (nth 0 args) (nth 4 args) (nth 5 args)))
                    (nreverse events))
            '(("DONE" "TODO" "DONE")
              ("REOPENED" "DONE" "TODO")
              ("DONE" "TODO" "DONE"))))))

(ert-deftest org-project-journal-has-no-history-refresh-machinery ()
  (should-not (fboundp '+org-project-audit-refresh-entry))
  (should-not (fboundp '+org-project-audit-refresh-current-journal))
  (should-not (memq '+org-project--maybe-refresh-journal-audit-h
                    org-mode-hook)))

(ert-deftest org-project-save-buffer-no-hooks-saves-whole-narrowed-buffer ()
  (let ((file (make-temp-file "org-project-save-test-" nil ".txt"
                              "line one\nline two\nline three\n"))
        buffer
        before-save-ran
        after-save-ran)
    (unwind-protect
        (progn
          (setq buffer (find-file-noselect file))
          (with-current-buffer buffer
            (setq-local before-save-hook
                        (list (lambda () (setq before-save-ran t))))
            (setq-local after-save-hook
                        (list (lambda () (setq after-save-ran t))))
            (goto-char (point-min))
            (forward-line 1)
            (narrow-to-region (line-beginning-position)
                              (line-beginning-position 2))
            (delete-region (point-min) (point-max))
            (insert "changed second line\n")
            (+org-project--save-buffer-no-hooks)
            (should (buffer-narrowed-p)))
          (with-temp-buffer
            (insert-file-contents file)
            (should
             (equal (buffer-string)
                    "line one\nchanged second line\nline three\n")))
          (should-not before-save-ran)
          (should-not after-save-ran))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (set-buffer-modified-p nil))
        (kill-buffer buffer))
      (when (file-exists-p file)
        (delete-file file)))))

(ert-deftest org-project-scan-buffer-keeps-unsaved-edits-on-disk-change ()
  (let ((file (make-temp-file "org-project-scan-test-" nil ".txt"
                              "original contents\n"))
        buffer)
    (unwind-protect
        (progn
          (setq buffer (find-file-noselect file))
          (with-current-buffer buffer
            (goto-char (point-max))
            (insert "unsaved user text\n"))
          (with-temp-file file
            (insert "external disk contents changed\n"))
          (should (eq (+org-project--scan-buffer-for-file file) buffer))
          (with-current-buffer buffer
            (should (buffer-modified-p))
            (should
             (equal (buffer-string)
                    "original contents\nunsaved user text\n"))))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (set-buffer-modified-p nil))
        (kill-buffer buffer))
      (when (file-exists-p file)
        (delete-file file)))))

(ert-deftest org-project-deadline-face-compares-calendar-days ()
  (let ((now (encode-time 0 0 12 28 8 2026)))
    (cl-letf (((symbol-function 'current-time) (lambda () now)))
      (should
       (eq (+org-project--deadline-face "2026-08-27")
           'org-project-todo-list-deadline-overdue-face))
      (should
       (eq (+org-project--deadline-face "2026-08-28")
           'org-project-todo-list-deadline-soon-face))
      (should
       (eq (+org-project--deadline-face "2026-09-04")
           'org-project-todo-list-deadline-soon-face))
      (should
       (eq (+org-project--deadline-face "2026-09-05")
           'org-project-todo-list-deadline-face)))))

(provide 'org-project-test)
;;; org-project-test.el ends here
