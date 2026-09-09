;;; org-latex-protocol.el --- Preview and export protocol blocks -*- lexical-binding: t; -*-

;;; Commentary:
;; Write raw LaTeX inside #+begin_protocol / #+end_protocol.  The shared
;; `protocol' environment supplies the frame; no Babel headers are needed.
;; C-c C-c renders an SVG below the block without inserting result text.
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

(defun +org/protocol-preview-changed-h (overlay &rest _)
  "Remove OVERLAY when its protocol source changes."
  (delete-overlay overlay))

(defun +org/protocol-preview ()
  "Render the protocol at point and display its SVG below the source.
Keep buffer text, point and narrowing unchanged.  Editing the block removes
the old preview; use this command or `org-ctrl-c-ctrl-c' to render it again."
  (interactive)
  (let ((block (+org/protocol-at-point)))
    (unless block (user-error "Point is not inside a protocol block"))
    (unless (image-type-available-p 'svg)
      (user-error "This Emacs cannot display SVG images"))
    (save-excursion
      (let* ((file (+org/protocol-render block))
             (absolute (expand-file-name file))
             (begin (org-element-property :begin block))
             (end (progn
                    (goto-char (org-element-property :contents-end block))
                    (forward-line)
                    (point))))
        (clear-image-cache absolute)
        (dolist (overlay (overlays-in begin end))
          (when (overlay-get overlay 'org-protocol-preview)
            (delete-overlay overlay)))
        (let ((overlay (make-overlay begin end)))
          (overlay-put overlay 'org-protocol-preview t)
          (overlay-put overlay 'evaporate t)
          (overlay-put overlay 'modification-hooks
                       '(+org/protocol-preview-changed-h))
          (overlay-put overlay 'after-string
                       (concat (propertize " " 'display
                                           (create-image absolute 'svg nil))
                               "\n")))
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
              (end (save-excursion
                     (goto-char (org-element-property :contents-end block))
                     (forward-line)
                     (point))))
          (goto-char begin)
          (delete-region begin end)
          (insert replacement))))))

(add-hook 'org-ctrl-c-ctrl-c-hook #'+org/protocol-ctrl-c-ctrl-c-h)
(add-hook 'org-export-before-parsing-functions #'+org/protocol-export-h)
(add-hook 'org-font-lock-set-keywords-hook #'+org/protocol-font-lock-setup-h)

(provide 'org-latex-protocol)
;;; org-latex-protocol.el ends here
