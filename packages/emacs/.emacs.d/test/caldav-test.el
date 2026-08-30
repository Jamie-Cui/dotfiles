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
  (list uid "md5" etag nil (or status 'synced)))

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

(ert-deftest caldav-force-conflict-resolution-chooses-requested-side ()
  (let* ((root (make-temp-file "caldav-conflicts-" t))
         (+emacs/org-root-dir root)
         (org-mode-hook nil)
         (local-file (expand-file-name "local.org" root))
         (remote-file (expand-file-name "remote.org" root))
         (conflict (concat "before\n<<<<<<< LOCAL\n* TODO local\n"
                           "=======\n* DONE remote\n>>>>>>> CALDAV\nafter\n")))
    (unwind-protect
        (progn
          (write-region conflict nil local-file nil 'silent)
          (let ((+emacs/org-root-dir root))
            (+notes/caldav--resolve-conflicts 'local)
            (write-region conflict nil remote-file nil 'silent)
            (+notes/caldav--resolve-conflicts 'remote))
          (with-temp-buffer
            (insert-file-contents local-file)
            (should (search-forward "* TODO local" nil t))
            (should-not (search-forward "* DONE remote" nil t)))
          (with-temp-buffer
            (insert-file-contents remote-file)
            (should (search-forward "* DONE remote" nil t))
            (should-not (search-forward "* TODO local" nil t))))
      (dolist (file (list local-file remote-file))
        (when-let* ((buffer (find-buffer-visiting file)))
          (kill-buffer buffer)))
      (delete-directory root t))))
(provide 'caldav-test)
;;; caldav-test.el ends here
