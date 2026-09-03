;;; caldav-magit.el --- Load the Org CalDAV Magit adapter -*- lexical-binding: t; -*-
;;; Commentary:
;; Keep package implementation in site-lisp and module loading in the manifest.
;; Re-evaluate the adapter so reloading init also refreshes its commands.
;;; Code:

(load "org-caldav-magit" nil t)
(+notes/caldav-magit-setup)

(provide 'init-caldav-magit)
;;; caldav-magit.el ends here
