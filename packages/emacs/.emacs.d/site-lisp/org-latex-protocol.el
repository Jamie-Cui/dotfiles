;;; org-latex-protocol.el --- Preview and export protocol blocks -*- lexical-binding: t; -*-

;;; Commentary:
;; Write raw LaTeX inside #+begin_protocol / #+end_protocol.  The shared
;; `protocol' environment supplies the frame; no Babel headers are needed.
;; C-c C-c renders an SVG and inserts or updates a standard RESULTS file link.
;; LaTeX export embeds the source; other exports render an image link.
;; Rendering uses the existing ob-latex compiler, preamble and white background.
;; Protocol bodies use Org's native LaTeX source fontification and theme faces.

;;; Code:

(require 'org)
(require 'org-element)
(require 'org-src)
(require 'ob-latex)
(require 'ox)

(defun +org/protocol-block-p (element)
  "Return non-nil when ELEMENT is a protocol special block."
  (and (org-element-type-p element 'special-block)
       (string-equal-ignore-case
        (org-element-property :type element) "protocol")))

(defun +org/protocol-at-point ()
  "Return the protocol block containing point, or nil."
  (let ((element (org-element-context)))
    (while (and element (not (+org/protocol-block-p element)))
      (setq element (org-element-property :parent element)))
    element))

(defun +org/protocol-fontify (limit)
  "Fontify the next protocol body before LIMIT using LaTeX syntax."
  (when org-src-fontify-natively
    (let ((case-fold-search t) block)
      (while (and (not block)
                  (re-search-forward
                   "^[ \t]*#\\+begin_protocol\\(?:[ \t].*\\)?$" limit t))
        (let ((element (save-excursion
                         (goto-char (match-beginning 0))
                         (save-match-data (org-element-at-point)))))
          ;; Literal examples and source blocks may contain these delimiters.
          (when (+org/protocol-block-p element)
            (setq block element))))
      (when block
        (let ((begin (org-element-property :contents-begin block))
              (end (org-element-property :contents-end block)))
          (when (and begin end (< begin end))
            (save-match-data
              (org-src-font-lock-fontify-block "latex" begin end)))
          (goto-char (org-element-property :end block))
          t)))))

(defun +org/protocol-font-lock-setup-h ()
  "Add native protocol fontification after Org's standard block faces."
  (add-to-list 'org-font-lock-extra-keywords '(+org/protocol-fontify) t))

(defun +org/protocol-body (block)
  "Return BLOCK's raw LaTeX, wrapped in the protocol environment."
  (let ((begin (org-element-property :contents-begin block))
        (end (org-element-property :contents-end block)))
    (unless (and begin end
                 (org-string-nw-p
                  (buffer-substring-no-properties begin end)))
      (user-error "Protocol block is empty"))
    (concat "\\begin{protocol}\n"
            (buffer-substring-no-properties begin end)
            "\\end{protocol}\n")))

(defun +org/protocol-image-file (block)
  "Return a relative SVG filename for BLOCK, using its name or content hash."
  (let ((name (or (org-element-property :name block)
                  (concat "protocol-"
                          (substring (secure-hash 'sha256
                                                  (+org/protocol-body block))
                                     0 16)))))
    (unless (and (string-match-p "\\`[[:alnum:]_.-]+\\'" name)
                 (not (member name '("." ".."))))
      (user-error "Protocol name must contain only letters, numbers, _, . or -"))
    (concat "img/" name ".svg")))

(defun +org/protocol-render (block)
  "Render BLOCK through ob-latex and return its relative SVG filename.
Only replace an existing image after rendering succeeds."
  (let* ((body (+org/protocol-body block))
         (file (+org/protocol-image-file block))
         (directory (file-name-directory (expand-file-name file))))
    (make-directory directory t)
    (let ((temporary (make-temp-file
                      (expand-file-name ".protocol-" directory) nil ".svg")))
      (unwind-protect
          (progn
            (org-babel-execute:latex body `((:file . ,temporary)))
            (unless (> (file-attribute-size (file-attributes temporary)) 0)
              (error "Protocol renderer produced an empty SVG"))
            (rename-file temporary file t)
            file)
        (when (file-exists-p temporary)
          (delete-file temporary))))))

(defun +org/protocol-end (block)
  "Return the position immediately after BLOCK's closing delimiter."
  (save-excursion
    (goto-char (org-element-property :contents-end block))
    (forward-line)
    (point)))

(defun +org/protocol-result-bounds (block)
  "Return bounds of BLOCK's adjacent RESULTS file link, or nil.
Refuse unexpected result contents rather than overwriting document text."
  (save-excursion
    (goto-char (org-element-property :end block))
    (let ((case-fold-search t) (begin (point)))
      (when (looking-at-p "[ \t]*#\\+RESULTS:.*$")
        (forward-line)
        (unless (looking-at-p "[ \t]*\\[\\[file:[^]\n]+\\]\\][ \t]*$")
          (user-error "Protocol results must contain a single file link"))
        (forward-line)
        (cons begin (point))))))

(defun +org/protocol-preview ()
  "Render the protocol at point and update its RESULTS file link.
Preserve point and narrowing.  Save the buffer to persist the result, just
as with Babel.  Use this command or `org-ctrl-c-ctrl-c' after source edits."
  (interactive)
  (barf-if-buffer-read-only)
  (let ((block (+org/protocol-at-point)))
    (unless block (user-error "Point is not inside a protocol block"))
    (save-excursion
      (let* ((bounds (+org/protocol-result-bounds block))
             (file (+org/protocol-render block))
             (name (org-element-property :name block))
             result-begin result-end)
        ;; Remove previews created by the earlier overlay-only implementation.
        (dolist (overlay (overlays-in (org-element-property :begin block)
                                     (+org/protocol-end block)))
          (when (overlay-get overlay 'org-protocol-preview)
            (delete-overlay overlay)))
        (atomic-change-group
          (if bounds
              (progn
                (goto-char (car bounds))
                (delete-region (car bounds) (cdr bounds)))
            (goto-char (+org/protocol-end block))
            (unless (bolp) (insert "\n"))
            (insert "\n"))
          (setq result-begin (point))
          (insert "#+RESULTS:" (if name (concat " " name) "")
                  "\n[[file:" file "]]\n")
          (setq result-end (point))
          (unless (looking-at-p "[ \t]*$") (insert "\n")))
        (when (image-type-available-p 'svg)
          (clear-image-cache (expand-file-name file))
          (funcall (if (fboundp 'org-link-preview-region)
                       #'org-link-preview-region
                     #'org-display-inline-images)
                   nil t result-begin result-end))
        (message "Protocol preview: %s" file)
        file))))

(defun +org/protocol-ctrl-c-ctrl-c-h ()
  "Preview a protocol block through `org-ctrl-c-ctrl-c'."
  (when (+org/protocol-at-point)
    (+org/protocol-preview)
    t))

(defun +org/protocol-export-h (backend)
  "Expand protocol blocks in the export copy for BACKEND.
Keep raw LaTeX for LaTeX-derived backends and use SVG links otherwise.
Leave Org export unchanged so the protocol source remains editable."
  (unless (org-export-derived-backend-p backend 'org)
    (let ((blocks (org-element-map (org-element-parse-buffer) 'special-block
                    (lambda (element)
                      (when (+org/protocol-block-p element) element)))))
      ;; Work backwards so earlier positions remain valid.  Only the export
      ;; copy is edited; affiliated names and attributes remain in place.
      (dolist (block (reverse blocks))
        (let ((replacement
               (if (org-export-derived-backend-p backend 'latex)
                   (concat "#+begin_export latex\n"
                           (+org/protocol-body block)
                           "#+end_export\n")
                 (concat "[[file:" (+org/protocol-render block) "]]\n")))
              (begin (org-element-post-affiliated block))
              (end (or (cdr (+org/protocol-result-bounds block))
                       (+org/protocol-end block))))
          (goto-char begin)
          (delete-region begin end)
          (insert replacement))))))

(add-hook 'org-ctrl-c-ctrl-c-hook #'+org/protocol-ctrl-c-ctrl-c-h)
(add-hook 'org-export-before-parsing-functions #'+org/protocol-export-h)
(add-hook 'org-font-lock-set-keywords-hook #'+org/protocol-font-lock-setup-h)

(provide 'org-latex-protocol)
;;; org-latex-protocol.el ends here
