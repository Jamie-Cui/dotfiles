;;; init-config-consult.el --- Consult extensions -*- lexical-binding: t -*-
;;; Commentary:
;; Group agenda headings by TODO state and annotate their scheduling dates.
;;; Code:

(require 'org)
(require 'org-agenda)

(defun consult-org--get-heading-time-info (marker)
  "Return the scheduled date or deadline of the heading at MARKER."
  (with-current-buffer (marker-buffer marker)
    (save-excursion
      (goto-char marker)
      (let ((scheduled (org-entry-get (point) "SCHEDULED"))
            (deadline (org-entry-get (point) "DEADLINE")))
        (cond
         (scheduled (concat " SCH: " (substring scheduled 1 -1)))
         (deadline (concat " DDL: " (substring deadline 1 -1)))
         (t ""))))))

(defun consult-org-agenda-by-todo-status-with-time (&optional match)
  "Select an agenda heading matching MATCH, grouped by TODO state.
Annotate dates and align priorities with a fixed-width placeholder."
  (unless org-agenda-files
    (user-error "No agenda files"))
  (let* ((cands (consult--slow-operation "Collecting agenda headings..."
                  (or (consult-org--headings t match 'agenda)
                      (user-error "No agenda headings"))))
         (my-annotate
          (lambda (cand)
            (pcase-let ((`(,_level ,todo ,prio . ,_)
                         (get-text-property 0 'consult-org--heading cand)))
              (let* ((priority-str
                      (if prio
                          (propertize (format " [#%c]" prio) 'face 'org-priority)
                        "     ")) ; 5 spaces = width of " [#A]"
                     (base-annot (concat (or todo "") priority-str))
                     (marker (get-text-property 0 'org-marker cand))
                     (time-info (consult-org--get-heading-time-info marker)))
                (consult--annotate-align
                 cand
                 (concat base-annot time-info)))))))
    (consult--read
     cands
     :prompt "Go to agenda heading (by TODO): "
     :category 'org-heading
     :sort nil
     :require-match t
     :history '(:input consult-org--history)
     :narrow (consult-org--narrow)
     :state (consult--jump-state)
     :annotate my-annotate
     :group (lambda (cand transform)
              (pcase-let ((`(,_level ,todo ,_prio . ,_)
                           (get-text-property 0 'consult-org--heading cand)))
                (if transform
                    (substring cand (string-match-p " " cand))
                  (or todo "[no TODO]"))))
     :lookup (apply-partially #'consult--lookup-prop 'org-marker))))

(with-eval-after-load 'consult
  (advice-add 'consult-org-agenda
              :override #'consult-org-agenda-by-todo-status-with-time))

(provide 'init-config-consult)
;;; init-config-consult.el ends here
