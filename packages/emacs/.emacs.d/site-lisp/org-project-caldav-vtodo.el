;;; org-project-caldav-vtodo.el --- VTODO codec for org-project -*- lexical-binding: t; -*-

;; Copyright (C) 2012-2017 Free Software Foundation, Inc.
;; Copyright (C) 2018-2024 David Engster
;; Copyright (C) 2026 Jamie Cui
;; SPDX-License-Identifier: GPL-3.0-or-later
;;
;; This file is free software: you can redistribute it and/or modify it under
;; the terms of the GNU General Public License as published by the Free
;; Software Foundation, either version 3 of the License, or (at your option)
;; any later version.
;;
;; This file is distributed in the hope that it will be useful, but WITHOUT
;; ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
;; FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
;; more details.
;;
;; You should have received a copy of the GNU General Public License along
;; with GNU Emacs.  If not, see <https://www.gnu.org/licenses/>.

;; This file adapts the iCalendar decoding code from org-caldav.

;;; Commentary:

;; Decode one VTODO from a vdir item into the small property vocabulary used
;; by org-project-caldav.  Keep all use of private `icalendar' APIs localized
;; here so the synchronization state machine does not depend on their shapes.

;;; Code:

(require 'calendar)
(require 'cl-lib)
(require 'icalendar)
(require 'subr-x)

(define-error 'org-project-caldav-vtodo-error "Invalid VTODO data")

(defun org-project-caldav-vtodo-normalize-uid (uid)
  "Return the logical Org UID represented by iCalendar UID.
Signal `org-project-caldav-vtodo-error' when UID is invalid."
  (unless (and (stringp uid) (not (string-empty-p uid)))
    (signal 'org-project-caldav-vtodo-error
            (list "VTODO has no non-empty UID")))
  (let ((normalized (replace-regexp-in-string "[[:space:]]+" "" uid)))
    (when (string-match
           "\\`\\(?:DL\\|SC\\|TS\\|TODO\\|DS\\)[0-9]*-" normalized)
      (setq normalized (replace-match "" nil nil normalized)))
    (when (string-empty-p normalized)
      (signal 'org-project-caldav-vtodo-error
              (list "VTODO UID is empty after normalization")))
    normalized))

(defun org-project-caldav-vtodo--all-todos (icalendar)
  "Return every VTODO below parsed ICALENDAR data."
  (let (result)
    (dolist (element (nreverse icalendar) result)
      (setq result
            (append (icalendar--get-children element 'VTODO) result)))))

(defun org-project-caldav-vtodo--datetime-time
    (datetime element property &optional default)
  "Return time text from DATETIME for PROPERTY in ELEMENT, or DEFAULT."
  (if (and datetime
           (not (string=
                 (cadr
                  (icalendar--get-event-property-attributes
                   element property))
                 "DATE")))
      (icalendar--datetime-to-colontime datetime)
    default))

(defun org-project-caldav-vtodo--date-plist (element property zone-map)
  "Return decoded date metadata for PROPERTY in ELEMENT using ZONE-MAP."
  (let* ((raw (icalendar--get-event-property element property))
         (zone (icalendar--find-time-zone
                (icalendar--get-event-property-attributes element property)
                zone-map))
         (decoded (icalendar--decode-isodatetime raw nil zone)))
    (list :date (icalendar--datetime-to-diary-date decoded)
          :time (org-project-caldav-vtodo--datetime-time
                 decoded element property))))

(defun org-project-caldav-vtodo--unescape-text (element property default)
  "Return decoded PROPERTY text from ELEMENT, falling back to DEFAULT."
  (icalendar--convert-string-for-import
   (or (icalendar--get-event-property element property) default)))

(defun org-project-caldav-vtodo--categories (element)
  "Return normalized category names from ELEMENT."
  (let ((text (org-project-caldav-vtodo--unescape-text
               element 'CATEGORIES "")))
    (when (not (string-empty-p text))
      (mapcar
       (lambda (category)
         (replace-regexp-in-string " " "-" (string-trim category)))
       (split-string text "," t)))))

(defun org-project-caldav-vtodo--percent (element)
  "Return a normalized completion percentage string from ELEMENT."
  (or (icalendar--get-event-property element 'PERCENT-COMPLETE)
      (pcase (icalendar--get-event-property element 'STATUS)
        ("NEEDS-ACTION" "0")
        ("IN-PROCESS" "50")
        ("COMPLETED" "100")
        (_ "0"))))

(defun org-project-caldav-vtodo-parse-buffer ()
  "Decode the single VTODO in the current buffer into a plist.
The current buffer must contain one complete VCALENDAR vdir item."
  (let ((source (current-buffer)))
    (with-temp-buffer
      (insert-buffer-substring source)
      (goto-char (point-min))
      (while (re-search-forward "\r\n\\|\n\r" nil t)
        (replace-match "\n" nil nil))
      (goto-char (point-min))
      (while (re-search-forward "\n[ \t]" nil t)
        (replace-match "" nil nil))
      (goto-char (point-min))
      (let* ((calendar-date-style 'european)
             (calendar (icalendar--read-element nil nil))
             (zone-map (icalendar--convert-all-timezones calendar))
             (todos (org-project-caldav-vtodo--all-todos calendar)))
        (unless (= (length todos) 1)
          (signal 'org-project-caldav-vtodo-error
                  (list (format "Expected one VTODO, found %d"
                                (length todos)))))
        (let* ((todo (car todos))
               (start (org-project-caldav-vtodo--date-plist
                       todo 'DTSTART zone-map))
               (due (org-project-caldav-vtodo--date-plist
                     todo 'DUE zone-map))
               (completed (org-project-caldav-vtodo--date-plist
                           todo 'COMPLETED zone-map))
               (sequence (icalendar--get-event-property todo 'SEQUENCE)))
          (list
           :uid (org-project-caldav-vtodo-normalize-uid
                 (icalendar--get-event-property todo 'UID))
           :summary (org-project-caldav-vtodo--unescape-text
                     todo 'SUMMARY "No Title")
           :description (org-project-caldav-vtodo--unescape-text
                         todo 'DESCRIPTION "")
           :location (org-project-caldav-vtodo--unescape-text
                      todo 'LOCATION "")
           :categories (org-project-caldav-vtodo--categories todo)
           :priority (icalendar--get-event-property todo 'PRIORITY)
           :percent (org-project-caldav-vtodo--percent todo)
           :status (icalendar--get-event-property todo 'STATUS)
           :scheduled-date (plist-get start :date)
           :scheduled-time (plist-get start :time)
           :due-date (plist-get due :date)
           :due-time (plist-get due :time)
           :completed-date (plist-get completed :date)
           :completed-time (plist-get completed :time)
           :rrule (icalendar--split-value
                   (icalendar--get-event-property todo 'RRULE))
           :sequence (and sequence (string-to-number sequence))))))))

(defun org-project-caldav-vtodo--calendar-date (date)
  "Convert European DATE text to a calendar.el date list."
  (let ((parts (mapcar #'string-to-number (split-string date))))
    (unless (= (length parts) 3)
      (signal 'org-project-caldav-vtodo-error
              (list (format "Invalid VTODO date: %S" date))))
    (list (nth 1 parts) (nth 0 parts) (nth 2 parts))))

(defun org-project-caldav-vtodo-org-time (date &optional time rrule)
  "Convert VTODO DATE, optional TIME, and RRULE to Org timestamp text."
  (when date
    (let* ((clock (and time
                       (mapcar #'string-to-number (split-string time ":"))))
           (hours (or (car clock) 0))
           (minutes (or (nth 1 clock) 0))
           (calendar-date (org-project-caldav-vtodo--calendar-date date))
           (encoded
            (encode-time 0 minutes hours
                         (calendar-extract-day calendar-date)
                         (calendar-extract-month calendar-date)
                         (calendar-extract-year calendar-date)))
           (interval (or (cadr (assq 'INTERVAL rrule)) "1"))
           (frequency (cadr (assq 'FREQ rrule))))
      (concat
       (if time
           (format-time-string "%Y-%m-%d %a %H:%M" encoded)
         (format-time-string "%Y-%m-%d %a" encoded))
       (when frequency
         (format " +%d%s"
                 (string-to-number interval)
                 (downcase (substring frequency 0 1))))))))

(provide 'org-project-caldav-vtodo)
;;; org-project-caldav-vtodo.el ends here
