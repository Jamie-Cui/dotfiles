;;; org-done-journal.el --- Record Org completions in journal -*- lexical-binding: t -*-

;;; Commentary:
;; Global completion logging for file-backed Org buffers.  Records are snapshots
;; of the title and source link, not copies of the task body.  Journal entries
;; themselves are excluded.  Configure exclusion predicates for other workflows
;; that already log completions; this library does not depend on org-project.

;;; Code:

(require 'org)
(require 'org-id)

(declare-function org-journal-new-entry "org-journal" (prefix &optional time no-timestamp))
(declare-function org-journal--get-entry-path "org-journal" (&optional time))
(defvar org-journal-dir)
(defvar org-journal-find-file-fn)
(defvar org-journal-carryover-items)
(defvar org-state)
(defvar org-last-state)
(defvar +org-done-journal-mode)

(defgroup +org-done-journal nil
  "Record completed Org tasks in the current journal day."
  :group 'org)

(defcustom +org-done-journal-exclude-functions nil
  "Predicates that exclude the current task from completion logging.
Each function is called without arguments at the source heading."
  :type 'hook
  :group '+org-done-journal)

(defvar +org-done-journal--writing nil
  "Non-nil while a completion record is being written.")

(defun +org-done-journal--append (title source-id source-file time)
  "Append TITLE, SOURCE-ID and SOURCE-FILE to the journal day for TIME."
  (require 'org-journal)
  ;; Keep the org-journal private path API confined to this writer.
  (let ((file (org-journal--get-entry-path time))
        (date (format-time-string "%Y%m%d" time))
        (org-journal-find-file-fn #'find-file)
        ;; Recording a completion must not move unfinished tasks between days.
        (org-journal-carryover-items nil))
    (save-window-excursion
      (with-current-buffer (find-file-noselect file)
        (save-excursion
          (save-restriction
            (widen)
            (org-journal-new-entry t time)
            (widen)
            (goto-char (point-min))
            (let (day)
              (org-map-entries
               (lambda ()
                 (when (and (= (org-outline-level) 1)
                            (equal (org-entry-get nil "CREATED") date))
                   (setq day (point)))) nil nil)
              (unless day
                (error "No journal day heading for %s" date))
              (goto-char day))
            (org-end-of-subtree t t)
            (atomic-change-group
              (unless (bolp) (insert "\n"))
              (insert (format "** DONE %s\n" title))
              (org-back-to-heading t)
              (org-entry-put nil "EVENT_AT" (format-time-string "[%Y-%m-%d %a %H:%M]" time))
              (org-entry-put nil "SOURCE_ID" source-id)
              (org-entry-put nil "SOURCE_FILE" source-file)
              (org-entry-put nil "SOURCE_LINK"
                             (format "[[id:%s][Original task]]" source-id)))
            (save-buffer)))))))

(defun +org-done-journal-log-h ()
  "Record a transition to DONE, excluding journal and configured tasks."
  (when (and +org-done-journal-mode
             (not +org-done-journal--writing)
             (derived-mode-p 'org-mode)
             buffer-file-name
             (equal (bound-and-true-p org-state) "DONE")
             (not (equal (bound-and-true-p org-last-state) "DONE")))
    ;; A failed journal write must not undo the source transition.  Report all
    ;; failures at this hook isolation boundary rather than silently losing them.
    (condition-case err
        (save-excursion
          (org-back-to-heading t)
          (unless (run-hook-with-args-until-success
                   '+org-done-journal-exclude-functions)
            (require 'org-journal)
            (unless (file-in-directory-p buffer-file-name org-journal-dir)
              (let ((+org-done-journal--writing t))
                (+org-done-journal--append
                 (org-get-heading t t t t) (org-id-get-create)
                 (expand-file-name buffer-file-name) (current-time))))))
      (error (display-warning 'org-done-journal
                              (format "Cannot record completed task: %s"
                                      (error-message-string err)))))))

;;;###autoload
(define-minor-mode +org-done-journal-mode
  "Globally record completed Org tasks in today's journal.
Source tasks remain unsaved until the user saves them; journal records are
saved immediately.  Reopening a task does not remove earlier records."
  :global t
  :group '+org-done-journal
  (if +org-done-journal-mode
      (add-hook 'org-after-todo-state-change-hook #'+org-done-journal-log-h)
    (remove-hook 'org-after-todo-state-change-hook #'+org-done-journal-log-h)))

(provide 'org-done-journal)
;;; org-done-journal.el ends here
