;;; denote-menu-pin.el --- pinned rows for Denote Menu -*- lexical-binding: t -*-

;; Copyright (C) 2026 Jamie Cui - MIT License
;; Author: Jamie Cui <jamie.cui@outlook.com>
;; Package-Requires: ((emacs "30.1"))

;;; Commentary:

;; Persist pinned Denote identifiers outside note files, keep pinned rows at
;; the top of Denote Menu, and distinguish them with a background-only face.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'tabulated-list)

(declare-function denote-menu-update-entries "denote-menu" ())
(declare-function denote-retrieve-filename-identifier "denote" (file))
(defvar denote-menu-mode-map)

(defgroup denote-menu-pin nil
  "Pinned rows in Denote Menu."
  :group 'denote-menu)

(defcustom denote-menu-pin-state-file
  (locate-user-emacs-file "var/denote-menu-pins.el")
  "File used to persist pinned Denote identifiers."
  :type 'file
  :group 'denote-menu-pin)

(defface denote-menu-pin-row-face
  '((t (:inherit secondary-selection :extend t)))
  "Background face applied to pinned Denote Menu rows."
  :group 'denote-menu-pin)

(defvar denote-menu-pin--state nil
  "Cached list of pinned Denote identifiers.")

(defvar denote-menu-pin--state-loaded nil
  "Non-nil after `denote-menu-pin-state-file' has been read.")

(defun denote-menu-pin--valid-state-p (value)
  "Return non-nil when VALUE is a valid persisted pin list."
  (and (listp value)
       (cl-every (lambda (item)
                   (and (stringp item) (not (string-empty-p item))))
                 value)))

(defun denote-menu-pin--load-state (&optional force)
  "Return persisted pins, re-reading the state file when FORCE is non-nil."
  (when (or force (not denote-menu-pin--state-loaded))
    (setq denote-menu-pin--state
          (if (not (file-exists-p denote-menu-pin-state-file))
              nil
            (condition-case err
                (with-temp-buffer
                  (insert-file-contents denote-menu-pin-state-file)
                  (let ((read-eval nil)
                        (value (read (current-buffer))))
                    (unless (denote-menu-pin--valid-state-p value)
                      (error "Invalid pin state in %s"
                             denote-menu-pin-state-file))
                    value))
              (error
               (signal 'file-error
                       (list (format "Cannot read Denote Menu pin state: %s"
                                     (error-message-string err))
                             denote-menu-pin-state-file)))))
          denote-menu-pin--state-loaded t))
  denote-menu-pin--state)

(defun denote-menu-pin--save-state ()
  "Persist `denote-menu-pin--state' atomically."
  (let* ((directory (file-name-directory denote-menu-pin-state-file))
         temporary)
    (make-directory directory t)
    (unwind-protect
        (progn
          (setq temporary
                (make-temp-file
                 (expand-file-name ".denote-menu-pins-" directory)))
          (with-temp-file temporary
            (let ((print-length nil)
                  (print-level nil))
              (prin1 (sort (delete-dups
                            (copy-sequence denote-menu-pin--state))
                           #'string<)
                     (current-buffer)))
            (insert "\n"))
          (rename-file temporary denote-menu-pin-state-file t)
          (setq temporary nil))
      (when (and temporary (file-exists-p temporary))
        (delete-file temporary)))))

(defun denote-menu-pin--identifier-for-path (path)
  "Return the stable Denote Menu identifier for PATH."
  (let ((identifier (denote-retrieve-filename-identifier path))
        (extension (file-name-extension path)))
    (unless (and (stringp identifier) (not (string-empty-p identifier))
                 (stringp extension) (not (string-empty-p extension)))
      (error "Cannot derive a Denote Menu identifier from %s" path))
    (format "%s-%s" identifier extension)))

(defun denote-menu-pin-pinned-p (identifier)
  "Return non-nil when Denote Menu IDENTIFIER is pinned."
  (and (stringp identifier)
       (member identifier (denote-menu-pin--load-state))))

(defun denote-menu-pin--tag-cell (cell)
  "Return CELL carrying the pinned-row text property."
  (cond
   ((stringp cell)
    (propertize (copy-sequence cell) 'denote-menu-pin-pinned t))
   ((and (consp cell) (stringp (car cell)))
    (cons (propertize (copy-sequence (car cell))
                      'denote-menu-pin-pinned t)
          (cdr cell)))
   (t cell)))

(defun denote-menu-pin--path-to-entry-a (function path)
  "Mark pinned rows returned by FUNCTION for Denote file PATH."
  (let ((entry (funcall function path)))
    (if (not (denote-menu-pin-pinned-p
              (denote-menu-pin--identifier-for-path path)))
        entry
      (let ((columns (copy-sequence (cadr entry))))
        (dotimes (index (length columns))
          (aset columns index
                (denote-menu-pin--tag-cell (aref columns index))))
        (list (car entry) columns)))))

(defun denote-menu-pin--columns-pinned-p (columns)
  "Return non-nil when COLUMNS belong to a pinned row."
  (cl-some
   (lambda (column)
     (let ((text (if (stringp column) column (car-safe column))))
       (and (stringp text)
            (text-property-any
             0 (length text) 'denote-menu-pin-pinned t text))))
   (append columns nil)))

(defun denote-menu-pin--cell-text (entry index)
  "Return plain text from column INDEX of tabulated ENTRY."
  (let* ((cell (aref (cadr entry) index))
         (text (if (stringp cell) cell (car-safe cell))))
    (if (stringp text) (substring-no-properties text) "")))

(defun denote-menu-pin-sorter (left right)
  "Sort Denote Menu entries LEFT and RIGHT with pinned rows first."
  (let* ((descending (cdr tabulated-list-sort-key))
         (left-rank
          (if (denote-menu-pin--columns-pinned-p (cadr left)) 0 1))
         (right-rank
          (if (denote-menu-pin--columns-pinned-p (cadr right)) 0 1))
         (column-index
          (or (cl-position (car tabulated-list-sort-key)
                           tabulated-list-format :key #'car :test #'equal)
              0)))
    (if (/= left-rank right-rank)
        (if descending
            (> left-rank right-rank)
          (< left-rank right-rank))
      (string< (denote-menu-pin--cell-text left column-index)
               (denote-menu-pin--cell-text right column-index)))))

(defun denote-menu-pin--face-spec ()
  "Return a background-only face spec for a pinned row."
  (let ((background (face-background 'denote-menu-pin-row-face nil t)))
    (if (and (stringp background)
             (not (equal background "unspecified-bg")))
        `(:background ,background :extend t)
      '(:inverse-video t :extend t))))

(defun denote-menu-pin-print-entry (id columns)
  "Print Denote Menu entry ID with COLUMNS and pinned-row styling."
  (let ((begin (point))
        (pinned (denote-menu-pin--columns-pinned-p columns)))
    (tabulated-list-print-entry id columns)
    (when pinned
      (add-face-text-property begin (point) (denote-menu-pin--face-spec)))))

(defun denote-menu-pin-setup ()
  "Configure pin sorting and rendering in the current Denote Menu."
  (when (derived-mode-p 'denote-menu-mode)
    (setq-local tabulated-list-printer #'denote-menu-pin-print-entry)
    (when (> (length tabulated-list-format) 0)
      (let ((date-column (copy-sequence (aref tabulated-list-format 0))))
        (setf (nth 2 date-column) #'denote-menu-pin-sorter)
        (aset tabulated-list-format 0 date-column)))
    (tabulated-list-init-header)))

(defun denote-menu-pin--refresh ()
  "Rebuild the current Denote Menu without retaining stale paths."
  (setq tabulated-list-entries nil)
  (denote-menu-update-entries))

(defun denote-menu-pin--goto-id (identifier)
  "Move to the tabulated row matching IDENTIFIER, when present."
  (goto-char (point-min))
  (catch 'found
    (while (not (eobp))
      (when (equal (tabulated-list-get-id) identifier)
        (throw 'found t))
      (forward-line 1))
    nil))

;;;###autoload
(defun denote-menu-pin-toggle ()
  "Toggle whether the Denote Menu row at point is pinned to the top."
  (interactive)
  (unless (derived-mode-p 'denote-menu-mode)
    (user-error "Not in a Denote menu"))
  (let ((identifier (tabulated-list-get-id))
        pinned)
    (unless (stringp identifier)
      (user-error "No Denote note on this row"))
    (denote-menu-pin--load-state t)
    (setq pinned (not (member identifier denote-menu-pin--state)))
    (if pinned
        (push identifier denote-menu-pin--state)
      (setq denote-menu-pin--state
            (delete identifier denote-menu-pin--state)))
    (denote-menu-pin--save-state)
    (denote-menu-pin--refresh)
    (denote-menu-pin--goto-id identifier)
    (message (if pinned "Pinned to top" "Unpinned"))))

;;;###autoload
(defun denote-menu-pin-install ()
  "Install Denote Menu pin integration and refresh existing menus."
  (unless (featurep 'denote-menu)
    (user-error "Denote Menu is not loaded"))
  (unless (advice-member-p #'denote-menu-pin--path-to-entry-a
                           'denote-menu--path-to-entry)
    (advice-add 'denote-menu--path-to-entry :around
                #'denote-menu-pin--path-to-entry-a))
  (define-key denote-menu-mode-map (kbd "C-c C-p")
              #'denote-menu-pin-toggle)
  (add-hook 'denote-menu-mode-hook #'denote-menu-pin-setup t)
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (derived-mode-p 'denote-menu-mode)
        (denote-menu-pin-setup)
        (denote-menu-pin--refresh)))))

(provide 'denote-menu-pin)
;;; denote-menu-pin.el ends here
