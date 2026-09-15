;;; agent-shell-dense-test.el --- Dense layout tests -*- lexical-binding: t; -*-

;;; Commentary:
;; Exercise the installed renderer, including stream updates and folding.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'agent-shell-ui)
(require 'agent-shell-markdown)
(require 'agent-shell-dense)

(defun agent-shell-dense-test--overlays ()
  "Return only Dense overlays in the current buffer."
  (cl-remove-if-not (lambda (overlay) (overlay-get overlay 'agent-shell-dense))
                    (overlays-in (point-min) (point-max))))

(defun agent-shell-dense-test--fragment (id body &optional append)
  "Render BODY as fragment ID, optionally using APPEND."
  (let ((range (agent-shell-ui-update-fragment
                (agent-shell-ui-make-fragment-model
                 :block-id id :label-left "Tool" :body body)
                :append append :expanded t)))
    (save-restriction
      (narrow-to-region (map-nested-elt range '(:body :start))
                        (map-nested-elt range '(:body :end)))
      (agent-shell-markdown-replace-markup
       :render-images nil :highlight-blocks nil))))

(ert-deftest agent-shell-dense-preserves-content-and-copy ()
  (with-temp-buffer
    (let ((inhibit-read-only t))
      (agent-shell-dense-test--fragment
       "1" "First paragraph.\n\nSecond paragraph.\n\n```elisp\n(first)\n\n(second)\n```"))
    (let ((text (buffer-string))
          (source (agent-shell-markdown-reconstruct (point-min) (point-max)))
          (modified (buffer-modified-p))
          (undo buffer-undo-list))
      (agent-shell-dense-mode 1)
      (should (>= (length (agent-shell-dense-test--overlays)) 4))
      (should (equal-including-properties text (buffer-string)))
      (should (equal source (agent-shell-markdown-reconstruct
                            (point-min) (point-max))))
      (should (eq modified (buffer-modified-p)))
      (should (eq undo buffer-undo-list))
      (dolist (needle '("First paragraph.\n\n" "(first)\n\n"))
        (goto-char (point-min))
        (search-forward needle)
        (should-not (get-char-property (1- (point)) 'display)))
      (agent-shell-dense-mode -1)
      (should-not (agent-shell-dense-test--overlays))
      (should (equal-including-properties text (buffer-string))))))

(ert-deftest agent-shell-dense-streaming-and-replacement ()
  (with-temp-buffer
    (agent-shell-dense-mode 1)
    (let ((inhibit-read-only t))
      (agent-shell-dense-test--fragment "1" "Before.\n\n```text\nline\n")
      (agent-shell-dense--redisplay-h nil)
      (let ((initial (length (agent-shell-dense-test--overlays))))
        (agent-shell-dense-test--fragment "1" "\nnext\n```\n" t)
        (should agent-shell-dense--dirty-start)
        (agent-shell-dense--redisplay-h nil)
        (should (> (length (agent-shell-dense-test--overlays)) initial)))
      (agent-shell-dense-test--fragment "1" "Replacement.\n\nParagraph."))
    (agent-shell-dense--redisplay-h nil)
    (goto-char (point-min))
    (search-forward "Replacement.\n\n")
    (should-not (get-char-property (1- (point)) 'display))
    (let ((count (length (agent-shell-dense-test--overlays))))
      (agent-shell-dense-refresh)
      (should (= count (length (agent-shell-dense-test--overlays)))))))

(ert-deftest agent-shell-dense-folding-and-groups ()
  (with-temp-buffer
    (let ((inhibit-read-only t))
      (dolist (id '("1" "2"))
        (agent-shell-ui-update-fragment
         (agent-shell-ui-make-fragment-model
          :block-id id :label-left "Read" :body "Some text.\n\nMore text."
          :group-id "tools" :group-label "2 tools" :group-expanded t)
         :expanded t)))
    (agent-shell-dense-mode 1)
    (goto-char (point-min))
    (search-forward "Some text.")
    (let ((body (copy-marker (1- (point)))))
      (goto-char (point-min))
      (search-forward "2 tools")
      (agent-shell-ui-toggle-fragment)
      (agent-shell-dense--redisplay-h nil)
      (should (invisible-p body))
      (agent-shell-dense-refresh)
      (should (invisible-p body))
      (agent-shell-ui-toggle-fragment)
      (agent-shell-dense--redisplay-h nil)
      (should-not (invisible-p body))
      (set-marker body nil))))

(ert-deftest agent-shell-dense-leaves-input-and-foreign-displays-alone ()
  (with-temp-buffer
    (insert "User paragraph\n\nNext\n")
    (let ((begin (point)))
      (insert (propertize "\n" 'agent-shell-non-trimmable t
                          'agent-shell-markdown-source ""))
      (let ((foreign (make-overlay begin (point))))
        (overlay-put foreign 'display '(space :height 2))
        (agent-shell-dense-mode 1)
        (should-not (agent-shell-dense-test--overlays))
        (agent-shell-dense-mode -1)
        (should (overlay-buffer foreign))))))

(ert-deftest agent-shell-dense-narrowing-edit-and-mode-cleanup ()
  (with-temp-buffer
    (let ((inhibit-read-only t))
      (agent-shell-dense-test--fragment "1" "Body."))
    (agent-shell-dense-mode 1)
    (let ((overlay (car (agent-shell-dense-test--overlays)))
          (inhibit-read-only t))
      ;; A previously blank line that receives text must regain normal height.
      (goto-char (overlay-start overlay))
      (insert "Now content")
      (agent-shell-dense--redisplay-h nil)
      (should-not (get-char-property (1- (point)) 'display)))
    (save-restriction
      (narrow-to-region (point-min) (1+ (point-min)))
      (agent-shell-dense-mode -1)
      (should (= (point-max) (1+ (point-min)))))
    (should-not (agent-shell-dense-test--overlays))
    (agent-shell-dense-mode 1)
    (fundamental-mode)
    (should-not (agent-shell-dense-test--overlays))
    (should-not agent-shell-dense--dirty-start)))

(ert-deftest agent-shell-dense-copied-viewport-content ()
  (let ((content (with-temp-buffer
                   (let ((inhibit-read-only t))
                     (agent-shell-dense-test--fragment "1" "```text\ncode\n```"))
                   (agent-shell-dense-mode 1)
                   (buffer-string))))
    (with-temp-buffer
      (agent-shell-dense-mode 1)
      (insert content)
      (agent-shell-dense--redisplay-h nil)
      (should (>= (length (agent-shell-dense-test--overlays)) 4))
      (should (equal-including-properties content (buffer-string))))))

(provide 'agent-shell-dense-test)
;;; agent-shell-dense-test.el ends here
