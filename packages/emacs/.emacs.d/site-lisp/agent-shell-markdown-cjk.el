;;; agent-shell-markdown-cjk.el --- Render CJK-adjacent emphasis in Agent Shell -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jamie Cui
;; Author: Jamie Cui <jamie.cui@outlook.com>

;;; Commentary:

;; Agent Shell's Markdown emphasis passes require ASCII whitespace or
;; punctuation on the boundaries of `**` / `*`, which breaks in mixed
;; Chinese/English text.  `中文**加粗**文字` stays literal because Chinese
;; characters are word-syntax (`w`), not whitespace or punctuation, so the
;; flanking delimiters never satisfy the original boundary regex.
;;
;; CommonMark allows `*` emphasis to be flanked by word characters (intraword
;; asterisks are valid), while `_` cannot be.  This file overrides the two
;; asterisk emphasis passes to follow that rule:
;;
;;   - `**X**' / `*X*' may now be flanked by word characters, so
;;     `中文**加粗**文字' and `中文*斜体*文字' render.
;;   - `__X__' / `_X_' keep their intraword restriction, so snake_case and
;;     other intraword underscores remain literal.
;;
;; Only the two emphasis functions are replaced via `:override' advice; the
;; span renderer and other Markdown passes are reused.  Delimiters in code
;; or frozen regions are protected, and asterisk spans must satisfy
;; CommonMark's whitespace and punctuation flanking conditions.

;;; Code:

(require 'agent-shell-markdown)
(require 'cl-lib)
(require 'rx)

(defun agent-shell-markdown-cjk--delimiter-avoid-range (start end avoid-ranges)
  "Return an AVOID-RANGES entry containing a delimiter char in START..END."
  (cl-loop for position from start below end
           thereis (agent-shell-markdown-in-avoid-range-p
                    position (1+ position) avoid-ranges)))

(defun agent-shell-markdown-cjk--whitespace-p (char)
  "Return non-nil if CHAR is CommonMark whitespace or a buffer boundary."
  (or (null char)
      (memq char '(?\t ?\n ?\f ?\r))
      (eq (get-char-code-property char 'general-category) 'Zs)))

(defun agent-shell-markdown-cjk--punctuation-p (char)
  "Return non-nil if CHAR is Unicode punctuation or a symbol."
  (and char
       (memq (get-char-code-property char 'general-category)
             '(Pc Pd Ps Pe Pi Pf Po Sm Sc Sk So))))

(defun agent-shell-markdown-cjk--asterisk-flanking-p
    (start content-start content-end end)
  "Return non-nil if START..END has valid asterisk delimiter flanking.
CONTENT-START..CONTENT-END bounds the text between the delimiters."
  (let ((before (char-before start))
        (first (char-after content-start))
        (last (char-before content-end))
        (after (char-after end)))
    (and (not (agent-shell-markdown-cjk--whitespace-p first))
         (not (agent-shell-markdown-cjk--whitespace-p last))
         (or (not (agent-shell-markdown-cjk--punctuation-p first))
             (agent-shell-markdown-cjk--whitespace-p before)
             (agent-shell-markdown-cjk--punctuation-p before))
         (or (not (agent-shell-markdown-cjk--punctuation-p last))
             (agent-shell-markdown-cjk--whitespace-p after)
             (agent-shell-markdown-cjk--punctuation-p after)))))

(defun agent-shell-markdown-cjk--replace-emphasis (regex face avoid-ranges)
  "Replace emphasis spans matching REGEX in the current buffer with FACE.

REGEX must capture the whole markup in group 1 (asterisk branch) or
group 3 (underscore branch), and the inner content in group 2 or group 4
respectively.  Markup characters are deleted and the inner text carries
FACE layered on top of any existing face.  Delimiters inside AVOID-RANGES
are left untouched, including code and frozen regions.  Asterisk spans
must satisfy flanking conditions.  Return non-nil on a replacement."
  (let ((case-fold-search nil)
        (changed nil))
    (goto-char (point-min))
    (while (re-search-forward regex nil t)
      (let* ((markup-start (or (match-beginning 1) (match-beginning 3)))
             (markup-end (or (match-end 1) (match-end 3)))
             (content-start (or (match-beginning 2) (match-beginning 4)))
             (content-end (or (match-end 2) (match-end 4)))
             (asterisk (match-beginning 1))
             (opening-avoid (agent-shell-markdown-cjk--delimiter-avoid-range
                             markup-start content-start avoid-ranges)))
        (cond
         (opening-avoid
          (goto-char (cdr opening-avoid)))
         ((or (agent-shell-markdown-cjk--delimiter-avoid-range
               content-end markup-end avoid-ranges)
              (and asterisk
                   (not (agent-shell-markdown-cjk--asterisk-flanking-p
                         markup-start content-start content-end markup-end))))
          ;; The rejected candidate may contain a later valid opener.
          (goto-char content-start))
         (t
          (agent-shell-markdown--emphasize-span
           :markup-start markup-start
           :markup-end markup-end
           :content-start content-start
           :content-end content-end
           :face face)
          (setq changed t)))))
    changed))

(cl-defun agent-shell-markdown-cjk--replace-bolds (&key avoid-ranges)
  "Replace `**X**' / `__X__' spans in the current buffer with bold X.

`**X**' may be flanked by word characters (so `中文**加粗**文字' renders);
`__X__' keeps its intraword restriction.  Spans inside AVOID-RANGES are
left untouched.  Return non-nil if at least one replacement was made."
  (agent-shell-markdown-cjk--replace-emphasis
   (rx (or
        (seq (or line-start (syntax whitespace) (syntax word))
             (group "**" (group (one-or-more (not (any "\n*")))) "**")
             (or (syntax punctuation) (syntax whitespace) (syntax word) line-end))
        (seq (or line-start (syntax whitespace))
             (group "__" (group (one-or-more (not (any "\n_")))) "__")
             (or (syntax punctuation) (syntax whitespace) line-end))))
   'agent-shell-markdown-bold
   avoid-ranges))

(cl-defun agent-shell-markdown-cjk--replace-italics (&key avoid-ranges)
  "Replace `*X*' / `_X_' spans in the current buffer with italic X.

`*X*' may be flanked by word characters (so `中文*斜体*文字' renders);
`_X_' keeps its intraword restriction.  Spans inside AVOID-RANGES are
left untouched.  Return non-nil if at least one replacement was made."
  (agent-shell-markdown-cjk--replace-emphasis
   (rx (or
        (seq (or bol (one-or-more (any "\n \t")) (syntax word))
             (group "*" (group (one-or-more (not (any "\n*")))) "*"))
        (seq (or bol (one-or-more (any "\n \t")))
             (group "_" (group (one-or-more (not (any "\n_")))) "_")
             (or (syntax punctuation) (syntax whitespace) line-end))))
   'agent-shell-markdown-italic
   avoid-ranges))

(advice-add 'agent-shell-markdown--replace-bolds
            :override #'agent-shell-markdown-cjk--replace-bolds)
(advice-add 'agent-shell-markdown--replace-italics
            :override #'agent-shell-markdown-cjk--replace-italics)

(provide 'agent-shell-markdown-cjk)
;;; agent-shell-markdown-cjk.el ends here
