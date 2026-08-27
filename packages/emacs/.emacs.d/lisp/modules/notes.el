;;; notes.el --- personal knowledge base on top of Org -*- lexical-binding: t -*-
;;; Commentary:
;; Personal knowledge base on top of Org: org-project, journal, roam, Denote,
;; agenda hygiene and consult integration.
;;; Code:


(add-to-list 'load-path (expand-file-name "site-lisp" +emacs/repo-directory))
(setq +org-project-root-dir +emacs/org-root-dir)
(require 'org-project)
(require 'dashboard-org-project)
(dashboard-org-project-setup)

;; -----------------------------------------------------------
;; DONE hack: filter out sync-conflict and *-beorg
;; -----------------------------------------------------------

(defgroup +org-agenda nil
  "Local agenda hygiene helpers."
  :group 'org)

(defcustom +org-agenda-ignored-file-regexps
  '("\\.sync-conflict-[^/]*\\.org\\'"
    "/[^/]+-beorg\\.org\\'")
  "Regexps for agenda files that should be ignored locally."
  :type '(repeat string)
  :group '+org-agenda)

(defun +org-agenda-ignored-file-p (file)
  "Return non-nil when FILE should be excluded from `org-agenda-files'."
  (when (stringp file)
    (let ((path (expand-file-name file))
          ignored)
      (dolist (regexp +org-agenda-ignored-file-regexps ignored)
        (when (string-match-p regexp path)
          (setq ignored t))))))

(defun +org-agenda-prune-files (&optional files)
  "Remove ignored entries from FILES or `org-agenda-files'."
  (interactive)
  (let* ((targets (or files org-agenda-files))
         (normalized (delete-dups
                      (delq nil
                            (mapcar (lambda (file)
                                      (when (stringp file)
                                        (expand-file-name file)))
                                    (copy-sequence targets)))))
         (filtered (delq nil
                         (mapcar (lambda (file)
                                   (unless (+org-agenda-ignored-file-p file)
                                     file))
                                 normalized))))
    (when (or (null files)
              (called-interactively-p 'interactive))
      (setq org-agenda-files filtered))
    filtered))

(defun +org-agenda--prune-after-journal-update (&rest _)
  "Keep generated journal side files out of `org-agenda-files'."
  (+org-agenda-prune-files))

(use-package org-journal
  :ensure t
  :custom
  (org-journal-dir (concat +emacs/org-root-dir "/journal"))
  (org-journal-find-file-fn 'find-file)
  (org-journal-file-format "%Y%m%d.org")
  (org-journal-file-type 'monthly)
  (org-journal-carryover-items "TODO=\"TODO\"|TODO=\"WAIT\"|TODO=\"PROJ\"")
  (org-journal-enable-agenda-integration t)
  :config
  (add-to-list 'org-agenda-files org-journal-dir)
  (+org-project-sync-agenda-files)
  (+org-agenda-prune-files)
  (advice-add 'org-journal--update-org-agenda-files
              :after
              #'+org-agenda--prune-after-journal-update))

(defconst +notes/caldav-inbox-file
  (expand-file-name "caldav-inbox.org" +emacs/org-root-dir)
  "Org file receiving tasks created through CalDAV clients.")

(defconst +notes/caldav-tasks-file
  (expand-file-name "caldav-tasks.org" +emacs/org-root-dir)
  "Legacy Org file containing tasks exported through CalDAV.")

(defvar +notes/caldav--syncing nil
  "Non-nil while syncing the project TODO view through CalDAV.")

(defvar org-caldav-files nil)
(defvar org-caldav-inbox nil)

(declare-function org-journal--get-entry-path "org-journal" (&optional time))

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
         (file (org-journal--get-entry-path time))
         (buffer (find-file-noselect file))
         heading)
    (with-current-buffer buffer
      (save-excursion
        (save-restriction
          (widen)
          ;; A prefix creates today's date heading without a time entry.
          (org-journal-new-entry t time)
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
  (let ((+notes/caldav--syncing t))
    (setq org-caldav-inbox (+notes/caldav--inbox-target)
          org-caldav-files (+notes/caldav-source-files))
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
  (org-caldav-sync-direction 'twoway)
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
                #'+notes/caldav--sync-project-todos-a)))

(defvar-local +notes/denote--syncing-file-name nil
  "Non-nil while synchronizing a Denote file name after saving.")

(declare-function denote-menu-get-path-by-id "denote-menu" (id file-type))
(declare-function denote-menu-update-entries "denote-menu" ())

(defun +notes/denote-sync-file-name-after-save-h ()
  "Synchronize the current Denote file name with its front matter."
  (when (and (not +notes/denote--syncing-file-name)
             buffer-file-name
             (denote-file-is-in-denote-directory-p buffer-file-name)
             (denote-file-has-denoted-filename-p buffer-file-name))
    (let ((+notes/denote--syncing-file-name t)
          (denote-rename-confirmations nil)
          (denote-save-buffers t))
      (condition-case err
          (denote-rename-file-using-front-matter buffer-file-name)
        (error
         (display-warning
          'denote
          (format "Could not synchronize `%s': %s"
                  (file-name-nondirectory buffer-file-name)
                  (error-message-string err))
          :warning))))))

(defun +notes/denote-menu-file-at-point ()
  "Return the Denote file represented by the menu row at point."
  (unless (derived-mode-p 'denote-menu-mode)
    (user-error "Not in a Denote menu"))
  (let* ((entry-id (tabulated-list-get-id))
         (parts (and (stringp entry-id) (split-string entry-id "-")))
         (identifier (car parts))
         (file-type (cadr parts))
         (file (and identifier
                    file-type
                    (denote-menu-get-path-by-id identifier file-type))))
    (unless (and file (file-exists-p file))
      (user-error "No Denote file on this row"))
    file))

(defun +notes/denote-menu-refresh ()
  "Refresh the current Denote menu without retaining stale paths."
  (setq tabulated-list-entries nil)
  (denote-menu-update-entries))

(defun +notes/denote-menu-rename-title ()
  "Rename the Denote file title represented by the menu row at point."
  (interactive)
  (let* ((file (+notes/denote-menu-file-at-point))
         (existing-buffer (find-buffer-visiting file))
         (note-buffer (or existing-buffer (find-file-noselect file))))
    (when (and existing-buffer (buffer-modified-p existing-buffer))
      (user-error "Save the note before renaming it"))
    (unwind-protect
        (with-current-buffer note-buffer
          (let ((+notes/denote--syncing-file-name t)
                (denote-save-buffers t))
            (call-interactively #'denote-rename-file-title)))
      (when (and (not existing-buffer)
                 (buffer-live-p note-buffer)
                 (not (buffer-modified-p note-buffer)))
        (kill-buffer note-buffer))))
  (+notes/denote-menu-refresh))

(defun +notes/denote-menu-new ()
  "Create a Denote note and refresh the menu that launched the command."
  (interactive)
  (let ((menu-buffer (current-buffer)))
    (call-interactively #'denote)
    (when (buffer-live-p menu-buffer)
      (with-current-buffer menu-buffer
        (+notes/denote-menu-refresh)))))

(defun +notes/denote-menu-archive ()
  "Archive the Denote file represented by the menu row at point."
  (interactive)
  (let* ((file (+notes/denote-menu-file-at-point))
         (root (seq-find (lambda (directory)
                           (file-in-directory-p file directory))
                         (denote-directories)))
         (relative-file (and root (file-relative-name file root)))
         (archive-root (and root (expand-file-name "archive" root)))
         (destination (and archive-root
                           relative-file
                           (expand-file-name relative-file archive-root)))
         (note-buffer (find-buffer-visiting file)))
    (unless root
      (user-error "The note is outside `denote-directory'"))
    (when (and note-buffer (buffer-modified-p note-buffer))
      (user-error "Save the note before archiving it"))
    (when (file-exists-p destination)
      (user-error "Archive destination already exists: %s" destination))
    (when (yes-or-no-p
           (format "Archive `%s'? " (file-name-nondirectory file)))
      (make-directory (file-name-directory destination) t)
      (rename-file file destination)
      (when note-buffer
        (with-current-buffer note-buffer
          (set-visited-file-name destination t)
          (set-buffer-modified-p nil)))
      (denote-update-dired-buffers)
      (+notes/denote-menu-refresh)
      (message "Archived to %s" destination))))

(defun +notes/denote-menu-delete ()
  "Delete the Denote file represented by the menu row at point."
  (interactive)
  (let* ((file (+notes/denote-menu-file-at-point))
         (note-buffer (find-buffer-visiting file)))
    (when (and note-buffer (buffer-modified-p note-buffer))
      (user-error "Save the note before deleting it"))
    (when (yes-or-no-p
           (format "Delete `%s'? " (file-name-nondirectory file)))
      (when note-buffer
        (kill-buffer note-buffer))
      (delete-file file)
      (denote-update-dired-buffers)
      (+notes/denote-menu-refresh)
      (message "Deleted %s" file))))

(use-package denote
  :ensure t
  :demand t
  :custom
  (denote-directory
   (list (+emacs/org-subdir "denote")
         (+emacs/org-subdir "projects")))
  (denote-file-type 'org)
  (denote-prompts '(title keywords))
  (denote-save-buffers nil)
  (denote-rename-confirmations '(rewrite-front-matter modify-file-name))
  (denote-excluded-directories-regexp
   "\\`\\(?:archive\\|img\\|sty\\)\\'")
  (denote-excluded-files-regexp
   "\\(?:\\.sync-conflict-[^/]*\\.org\\'\\|/[^/]+-beorg\\.org\\'\\)")
  (denote-dired-directories
   (list (+emacs/org-subdir "denote")
         (+emacs/org-subdir "projects")))
  (denote-dired-directories-include-subdirectories t)
  :hook
  (dired-mode . denote-dired-mode-in-directories)
  :config
  (denote-rename-buffer-mode +1)
  (add-hook 'after-save-hook #'+notes/denote-sync-file-name-after-save-h))

(use-package denote-menu
  :ensure t
  :custom
  (denote-menu-title-column-width 50)
  :commands (denote-menu-list-notes list-denotes)
  :bind
  (:map denote-menu-mode-map
        ("C-c C-r" . +notes/denote-menu-rename-title)
        ("C-c C-n" . +notes/denote-menu-new)
        ("C-c C-a" . +notes/denote-menu-archive)
        ("C-c C-d" . +notes/denote-menu-delete))
  :config
  (evil-define-key 'normal denote-menu-mode-map
    (kbd "R") #'+notes/denote-menu-rename-title
    (kbd "N") #'+notes/denote-menu-new
    (kbd "A") #'+notes/denote-menu-archive
    (kbd "D") #'+notes/denote-menu-delete))

(use-package consult-denote
  :ensure t
  :after (denote consult)
  :config
  (consult-denote-mode +1))

(use-package org-roam
  :ensure t
  :after evil
  :custom
  (org-roam-directory (+emacs/org-subdir "roam"))
  :config
  ;; 例如改成只用时间戳：
  (setq org-roam-capture-templates
        '(("d" "default" plain "%?"
           :target (file+head "%<%Y-%m-%dt%H%M>.org" "#+title: ${title}\n")
           :unnarrowed t)))

  ;; If you're using a vertical completion framework, you might want
  ;; a more informative completion interface
  (setq org-roam-node-display-template
        (format "${title:50}%s"
                (propertize "${tags:25}" 'face 'org-tag)))
  (require 'org-roam-db)
  (org-roam-db-autosync-mode +1)
  ;; If using org-roam-protocol
  (require 'org-roam-protocol)

  ;; NOTE Make org-roam case insensitve
  ;; from: https://emacs.stackexchange.com/a/77296
  (defun +org-roam/case-insensitive-org-roam-node-read (orig-fn &rest args)
    (let ((completion-ignore-case t))
      (apply orig-fn args)))
  (advice-add 'org-roam-node-read :around #'+org-roam/case-insensitive-org-roam-node-read)
  (advice-add 'org-roam-node-insert :before #'+evil/smart-insert))

(require 'init-config-consult)


(provide 'init-notes)
;;; notes.el ends here
