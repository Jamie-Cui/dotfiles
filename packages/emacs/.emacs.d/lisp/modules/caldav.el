;;; caldav.el --- Optional CalDAV synchronization -*- lexical-binding: t -*-
;;; Commentary:
;; Enable this module after `notes' in the init.el manifest to synchronize
;; org-project tasks with CalDAV.  Requires the system vdirsyncer executable.
;;; Code:

(use-package org-project-caldav
  :load-path (lambda () +emacs/site-lisp-directory)
  :after org-project
  :demand t
  :custom
  (org-project-caldav-pair-name "org_project_caldav")
  (org-project-caldav-config-file
   (expand-file-name "vdirsyncer/config"
                     (or (getenv "XDG_CONFIG_HOME") "~/.config")))
  (org-project-caldav-vdir-directory
   (expand-file-name "org-project-caldav/org-tasks"
                     (or (getenv "XDG_DATA_HOME") "~/.local/share")))
  (org-project-caldav-auth-host "caldav.jamie-cui.com")
  (org-project-caldav-calendar-id "caldav-tasks")
  (org-project-caldav-sync-interval 300)
  (org-project-caldav-initial-delay 20)
  (org-project-caldav-after-save-delay 8)
  (org-project-caldav-auto-sync t)
  (org-project-caldav-conflict-policy 'org-wins)
  :config
  (org-project-caldav-setup))

(provide 'init-caldav)
;;; caldav.el ends here
