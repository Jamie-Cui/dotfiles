;;; agent-shell-dense.el --- Compact Agent Shell spacing -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jamie Cui
;; Author: Jamie Cui <jamie.cui@outlook.com>
;; Version: 0.1.0
;; URL: https://github.com/Jamie-Cui/dotfiles/tree/main/packages/emacs/.emacs.d/site-lisp
;; Keywords: convenience, tools
;; Package-Requires: ((emacs "30.1") (agent-shell "0.70.2"))

;;; Commentary:

;; Compress renderer-added blank lines with buffer-local overlays.  Text,
;; Markdown source, folding properties and ordinary paragraph/code spacing
;; stay intact.  No Agent Shell functions are advised or replaced.
;;
;; Enable `agent-shell-dense-mode' in an Agent Shell or viewport view buffer:
;;
;;   (add-hook 'agent-shell-mode-hook #'agent-shell-dense-mode)
;;   (add-hook 'agent-shell-viewport-view-mode-hook #'agent-shell-dense-mode)
;;
;; Customize `agent-shell-dense-height' and call `agent-shell-dense-refresh'
;; to update an existing buffer.  Disabling the mode removes its overlays.
;; Fractional heights require graphical Emacs; terminal cells stay unchanged.
;;
;; Compatibility is confined to `agent-shell-dense--padding-p', which reads
;; the renderer's text properties.  Unrecognized whitespace stays untouched.

;;; Code:

(defgroup agent-shell-dense nil
  "Compact display of Agent Shell's layout whitespace."
  :group 'convenience
  :prefix "agent-shell-dense-")

(defcustom agent-shell-dense-height 0.25
  "Height of layout blank lines relative to the default font.
Use a positive number no greater than 1.  Call
`agent-shell-dense-refresh' after changing this in an existing buffer."
  :type '(restricted-sexp :match-alternatives
                          ((lambda (value)
                             (and (numberp value) (< 0 value) (<= value 1)))))
  :group 'agent-shell-dense)

(defvar-local agent-shell-dense--dirty-start nil
  "Marker at the beginning of pending display work.")
(defvar-local agent-shell-dense--dirty-end nil
  "Marker at the end of pending display work.")
(defvar agent-shell-dense-mode)

(defun agent-shell-dense--padding-p (position)
  "Return non-nil for renderer-owned whitespace at POSITION.
The caller must first establish that the entire line is blank."
  (let ((state (get-text-property position 'agent-shell-ui-state))
        (source (get-text-property position 'agent-shell-markdown-source)))
    (and
     ;; Source blocks mark their actual code as non-trimmable too.
     (not (get-text-property position 'agent-shell-markdown-source-block-body))
     (or
      ;; Code-panel chrome and the framing gaps around rendered lists/code.
      (and (get-text-property position 'agent-shell-non-trimmable)
           (member source '("" "\n")))
      (and
       (get-text-property position 'read-only)
       (not (get-text-property position 'agent-shell-ui-section))
       (if state
           ;; A fragment's label/body separator.  Plain text entries also
           ;; have a state, but do not have a folding-state entry.
           (assq :collapsed state)
         ;; Inter-fragment padding has no state.  Require an adjacent
         ;; fragment so unrelated read-only whitespace is left alone.
         (save-excursion
           (goto-char position)
           (or (progn
                 (skip-chars-backward " \t\n")
                 (and (> (point) (point-min))
                      (get-text-property (1- (point)) 'agent-shell-ui-state)))
               (progn
                 (goto-char position)
                 (skip-chars-forward " \t\n")
                 (get-text-property (point) 'agent-shell-ui-state))))))))))

(defun agent-shell-dense--mark-dirty (start end)
  "Queue START through END, with neighboring lines, for redisplay.
Markers follow streaming insertions; work is coalesced until redisplay."
  (save-excursion
    (save-restriction
      (widen)
      (goto-char start)
      (setq start (line-beginning-position 0))
      (goto-char end)
      (setq end (line-beginning-position 3))
      (if agent-shell-dense--dirty-start
          (progn
            (set-marker agent-shell-dense--dirty-start
                        (min start agent-shell-dense--dirty-start))
            (set-marker agent-shell-dense--dirty-end
                        (max end agent-shell-dense--dirty-end)))
        (setq agent-shell-dense--dirty-start (copy-marker start)
              agent-shell-dense--dirty-end (copy-marker end t))))))

(defun agent-shell-dense--after-change-h (start end _old-length)
  "Queue the changed span from START through END."
  (agent-shell-dense--mark-dirty start end))

(defun agent-shell-dense--clear-dirty ()
  "Release pending range markers."
  (when agent-shell-dense--dirty-start
    (set-marker agent-shell-dense--dirty-start nil)
    (set-marker agent-shell-dense--dirty-end nil)
    (setq agent-shell-dense--dirty-start nil
          agent-shell-dense--dirty-end nil)))

(defun agent-shell-dense--redisplay-h (_window)
  "Refresh pending layout overlays before displaying a window."
  (when (and agent-shell-dense-mode agent-shell-dense--dirty-start)
    (save-match-data
      (save-excursion
        (save-restriction
          (widen)
          (let ((start (marker-position agent-shell-dense--dirty-start))
                (end (marker-position agent-shell-dense--dirty-end)))
            (remove-overlays start end 'agent-shell-dense t)
            (goto-char start)
            (while (re-search-forward "^[ \t]*\n" end t)
              (let ((begin (match-beginning 0))
                    (finish (match-end 0)))
                (when (and (agent-shell-dense--padding-p (1- finish))
                           ;; Preserve display replacements from other tools.
                           (let ((pos begin))
                             (while (and (< pos finish)
                                         (not (get-char-property pos 'display)))
                               (setq pos (1+ pos)))
                             (= pos finish)))
                  (let ((overlay (make-overlay begin finish nil t nil)))
                    (overlay-put overlay 'agent-shell-dense t)
                    (overlay-put overlay 'evaporate t)
                    (overlay-put overlay 'display
                                 `(height ,agent-shell-dense-height))
                    ;; Full-sized indentation would keep a blank line tall.
                    (overlay-put overlay 'line-prefix "")
                    (overlay-put overlay 'wrap-prefix "")
                    ;; Retain the glyph height, ignoring extra line spacing.
                    (overlay-put overlay 'line-height '(1 1))))))
            (agent-shell-dense--clear-dirty)))))))

;;;###autoload
(defun agent-shell-dense-refresh ()
  "Rebuild compact spacing overlays in the current buffer."
  (interactive)
  (unless (and (numberp agent-shell-dense-height)
               (< 0 agent-shell-dense-height) (<= agent-shell-dense-height 1))
    (user-error "Dense height must be greater than 0 and at most 1"))
  (when agent-shell-dense-mode
    (save-restriction
      (widen)
      (agent-shell-dense--mark-dirty (point-min) (point-max))
      (agent-shell-dense--redisplay-h nil))))

(defun agent-shell-dense--cleanup-h ()
  "Remove this mode's overlays and release pending markers."
  (save-restriction
    (widen)
    (remove-overlays (point-min) (point-max) 'agent-shell-dense t))
  (agent-shell-dense--clear-dirty))

;;;###autoload
(define-minor-mode agent-shell-dense-mode
  "Display Agent Shell's layout blank lines at a reduced height.
Only display overlays are changed.  Disabling restores the original layout.
Intended for `agent-shell-mode' and `agent-shell-viewport-view-mode'."
  :lighter " Dense"
  :group 'agent-shell-dense
  (if agent-shell-dense-mode
      (progn
        (agent-shell-dense-refresh)
        (add-hook 'after-change-functions #'agent-shell-dense--after-change-h nil t)
        (add-hook 'pre-redisplay-functions #'agent-shell-dense--redisplay-h nil t)
        (add-hook 'change-major-mode-hook #'agent-shell-dense--cleanup-h nil t)
        (add-hook 'kill-buffer-hook #'agent-shell-dense--cleanup-h nil t))
    (remove-hook 'after-change-functions #'agent-shell-dense--after-change-h t)
    (remove-hook 'pre-redisplay-functions #'agent-shell-dense--redisplay-h t)
    (remove-hook 'change-major-mode-hook #'agent-shell-dense--cleanup-h t)
    (remove-hook 'kill-buffer-hook #'agent-shell-dense--cleanup-h t)
    (agent-shell-dense--cleanup-h)))

(provide 'agent-shell-dense)
;;; agent-shell-dense.el ends here
