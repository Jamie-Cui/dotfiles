;;; init-config-xenops.el --- Xenops configuration -*- lexical-binding: t -*-
;;; Commentary:
;; Integrate Xenops with Org, Smartparens, and cnfonts.  The async override
;; keeps rendering tied to its original buffer generation and semaphore;
;; SVG previews also carry a TeX baseline for inline alignment.
;;; Code:

(require 'cl-lib)
(require 'dom)
(require 'org)
(require 'org-element)
(require 'subr-x)

(use-package aio
  :ensure t
  :demand t)
(require 'aio)

(declare-function fn/xenops-math-latex-create-image-a "init-config-xenops"
                  (element latex colors cache-file display-image) t) ; aio-defun
(declare-function fn/xenops-src-parse-at-point "init-config-xenops" ())
(declare-function smartparens-mode "smartparens" (&optional arg))
(declare-function f-read-bytes "f" (path &optional beg end))
(declare-function f-write-bytes "f" (data path))
(declare-function xenops-aio-subprocess "xenops-aio" (command &optional _ __))
(declare-function xenops-math-deactivate-marker-on-element "xenops-math" (element))
(declare-function xenops-math-display-error-badge "xenops-math"
                  (element error display-error-p))
(declare-function xenops-math-latex-make-commands "xenops-math-latex"
                  (element dir tex-file image-input-file image-output-file))
(declare-function xenops-math-latex-make-latex-document "xenops-math-latex"
                  (latex colors))
(declare-function xenops-math-latex-process-get "xenops-math-latex" (key))
(declare-function xenops-math-latex-waiting-tasks-count "xenops-math-latex" ())
(declare-function xenops-math-parse-element-at "xenops-math" (pos))
(declare-function xenops-math-set-marker-on-element "xenops-math" (element))
(declare-function xenops-overlay-delete-overlays-in "xenops-overlay"
                  (&optional beg end))
(declare-function xenops-png-set-phys-chunk "xenops-png" (png-string ppi))
(declare-function xenops-cancel-waiting-tasks "xenops-math-latex" ())
(declare-function xenops-render "xenops" () t) ; Generated apply command.
(declare-function xenops-parse-element-at-point "xenops-parse"
                  (type &optional lim-up lim-down delimiters))
(declare-function xenops-util-plist-update "xenops-util" (plist &rest args))

(defvar xenops-apply-user-point)
(defvar xenops-math-latex-max-tasks-in-flight)
(defvar xenops-math-latex-tasks-semaphore)
(defvar xenops-mode)

(defconst fn/xenops-math-image-reference-cap-height 9.0
  "Maple capital height in pixels matched by the reference image scale.")

(defconst fn/xenops-math-image-reference-scale-factor 0.78
  "Xenops image scale matched by the reference buffer font size.")

(defconst fn/xenops-math-svg-baseline-cache-version 1
  "Cache version for SVG previews carrying an inline TeX baseline marker.")

(defconst fn/xenops-math-refresh-retry-delay 0.5
  "Seconds to wait before checking whether Xenops rendering is idle.")

(defvar fn/xenops-math-buffer-generations
  (make-hash-table :test #'eq :weakness 'key)
  "Generation numbers used to reject stale Xenops async results.")

(defvar-local fn/xenops-math-refresh-pending nil
  "Non-nil when this buffer needs rendering at the current image scale.")

(defvar-local fn/xenops-math-refresh-timer nil
  "Timer waiting to refresh this buffer at the current image scale.")

(defvar-local fn/xenops-math-smartparens-suspended nil
  "Non-nil when Smartparens is suspended while editing inline math.")

(defvar-local fn/xenops-math-inline-editing-begin nil
  "Beginning of the Xenops inline math element currently being edited.")

(defun fn/xenops-src-skip-delimiter-newline-a (args)
  "Adjust fontification ARGS to skip the newline after a block delimiter.
Xenops includes that newline in its source-content range.  Applying a
source mode's syntax table there can make Org parse the language and
the first source word as one token."
  (pcase-let ((`(,language ,start ,end) args))
    (list language
          (if (and (< start end) (eq (char-after start) ?\n))
              (1+ start)
            start)
          end)))

(advice-add 'org-src-font-lock-fontify-block
            :filter-args #'fn/xenops-src-skip-delimiter-newline-a)

(defun fn/xenops-math-inline-editing-element ()
  "Return the Xenops inline math element being edited at point."
  (and (bound-and-true-p xenops-mode)
       (fboundp 'xenops-math-parse-inline-element-at-point)
       (when-let* ((element (xenops-math-parse-inline-element-at-point))
                   (begin-content (plist-get element :begin-content))
                   (end-content (plist-get element :end-content)))
         (when (and (eq (plist-get element :type) 'inline-math)
                    (<= begin-content (point) end-content))
           element))))

(defun fn/xenops-math-sync-smartparens-h ()
  "Suspend Smartparens while editing Xenops inline math."
  (when (fboundp 'smartparens-mode)
    (if-let* ((element (fn/xenops-math-inline-editing-element)))
        (progn
          (setq fn/xenops-math-inline-editing-begin
                (plist-get element :begin))
          (when (bound-and-true-p smartparens-mode)
            (setq fn/xenops-math-smartparens-suspended t)
            (smartparens-mode -1)))
      (setq fn/xenops-math-inline-editing-begin nil)
      (fn/xenops-math-restore-smartparens-h))))

(defun fn/xenops-math-restore-smartparens-h ()
  "Restore Smartparens if inline math editing suspended it."
  (when (and fn/xenops-math-smartparens-suspended
             (fboundp 'smartparens-mode))
    (setq fn/xenops-math-smartparens-suspended nil)
    (smartparens-mode 1)))

(defun fn/xenops-math-ignore-repeated-reveal-a (orig-fn window oldpos event-type)
  "Skip ORIG-FN for repeated entry into the inline math being edited.
Otherwise pass WINDOW, OLDPOS, and EVENT-TYPE to ORIG-FN."
  (if (and (eq event-type 'entered)
           fn/xenops-math-inline-editing-begin
           (when-let* ((element (fn/xenops-math-inline-editing-element)))
             (= (plist-get element :begin)
                fn/xenops-math-inline-editing-begin)))
      nil
    (funcall orig-fn window oldpos event-type)))

(defun fn/xenops-math-setup-smartparens-suspension-h ()
  "Install buffer-local Smartparens suspension for Xenops inline math."
  (add-hook 'pre-command-hook #'fn/xenops-math-sync-smartparens-h nil t)
  (add-hook 'post-command-hook #'fn/xenops-math-sync-smartparens-h nil t)
  (add-hook 'change-major-mode-hook
            #'fn/xenops-math-cleanup-buffer-h nil t)
  (add-hook 'kill-buffer-hook
            #'fn/xenops-math-cleanup-buffer-h nil t))

(use-package xenops
  :ensure t
  :if (and window-system (not (eq system-type 'windows-nt)))
  :preface
  (defun fn/xenops-math-buffer-generation (&optional buffer)
    "Return the Xenops async generation for BUFFER or the current buffer."
    (gethash (or buffer (current-buffer))
             fn/xenops-math-buffer-generations
             0))

  (defun fn/xenops-math-advance-buffer-generation (&optional buffer)
    "Invalidate outstanding Xenops async work for BUFFER or the current buffer."
    (let* ((buffer (or buffer (current-buffer)))
           (generation (1+ (fn/xenops-math-buffer-generation buffer))))
      (puthash buffer generation fn/xenops-math-buffer-generations)
      generation))

  (defun fn/xenops-math-current-generation-p (buffer generation)
    "Return non-nil when BUFFER is live and still at GENERATION."
    (and (buffer-live-p buffer)
         (= generation (fn/xenops-math-buffer-generation buffer))
         (buffer-local-value 'xenops-mode buffer)))

  (defun fn/xenops-math-latex-add-svg-baseline (element latex)
    "Add a dvisvgm baseline marker to inline ELEMENT's LATEX."
    (if (and (eq (plist-get element :type) 'inline-math)
             (equal (xenops-math-latex-process-get :image-output-type)
                    "svg"))
        (concat
         "\\leavevmode\\special{dvisvgm:raw "
         "<desc id='xenops-baseline' data-x='{?x}' data-y='{?y}'/>}"
         latex)
      latex))

  (defun fn/xenops-math-current-cap-height ()
    "Return the live Maple bold capital height for the current buffer."
    (when-let* ((window (get-buffer-window (current-buffer) t))
                (string (propertize "U" 'face 'bold))
                (font (font-at 0 window string))
                (glyph (aref (font-get-glyphs font 0 1 string) 0)))
      (+ (aref glyph 7) (aref glyph 8))))

  (defun fn/xenops-math-sync-image-scale (&rest _)
    "Sync `xenops-math-image-scale-factor' with the live Maple cap height.
Return non-nil when the scale changed."
    (when-let* ((cap-height (fn/xenops-math-current-cap-height))
                (scale (* fn/xenops-math-image-reference-scale-factor
                          (/ cap-height
                             fn/xenops-math-image-reference-cap-height))))
      (unless (equal xenops-math-image-scale-factor scale)
        (setq-local xenops-math-image-scale-factor scale)
        t)))

  (defun fn/xenops-math-buffer-has-overlays-p (&optional type)
    "Return non-nil when this buffer has Xenops overlays of TYPE.
When TYPE is nil, match any Xenops overlay."
    (save-restriction
      (widen)
      (cl-some (lambda (overlay)
                 (let ((overlay-type (overlay-get overlay 'xenops-overlay-type)))
                   (and overlay-type (or (null type) (eq overlay-type type)))))
               (overlays-in (point-min) (point-max)))))

  (defun fn/xenops-math-render-queue-idle-p ()
    "Return non-nil when the current Xenops render queue is idle.
A semaphore value above the configured maximum is treated as an
idle but corrupted semaphore left by older Xenops code."
    (let ((semaphore xenops-math-latex-tasks-semaphore))
      (or (null semaphore)
          (and (>= (aio-sem-value semaphore)
                   xenops-math-latex-max-tasks-in-flight)
               (null (car (aio-sem-queue semaphore)))))))

  (defun fn/xenops-math-normalize-idle-semaphore ()
    "Restore the current idle Xenops semaphore to its configured maximum."
    (when (and (fn/xenops-math-render-queue-idle-p)
               (or (null xenops-math-latex-tasks-semaphore)
                   (/= (aio-sem-value xenops-math-latex-tasks-semaphore)
                       xenops-math-latex-max-tasks-in-flight)))
      (setq xenops-math-latex-tasks-semaphore
            (aio-sem xenops-math-latex-max-tasks-in-flight))))

  (defun fn/xenops-math-cancel-refresh-timer ()
    "Cancel the pending scale refresh timer in the current buffer."
    (when (timerp fn/xenops-math-refresh-timer)
      (cancel-timer fn/xenops-math-refresh-timer))
    (setq fn/xenops-math-refresh-timer nil
          fn/xenops-math-refresh-pending nil))

  (defun fn/xenops-math-cleanup-buffer-h ()
    "Invalidate Xenops work and clean up the current buffer."
    (fn/xenops-math-advance-buffer-generation)
    (fn/xenops-math-cancel-refresh-timer)
    (fn/xenops-math-restore-smartparens-h)
    (save-restriction
      (widen)
      (when (bound-and-true-p xenops-mode)
        (xenops-cancel-waiting-tasks))
      (xenops-overlay-delete-overlays-in (point-min) (point-max))))

  (defun fn/xenops-math-mode-state-h ()
    "Invalidate outstanding work after Xenops is disabled manually."
    (unless (bound-and-true-p xenops-mode)
      (fn/xenops-math-cleanup-buffer-h)))

  (defun fn/xenops-math-render-current-scale ()
    "Replace all Xenops overlays and render using the current image scale."
    (fn/xenops-math-normalize-idle-semaphore)
    (setq fn/xenops-math-refresh-pending nil
          fn/xenops-math-refresh-timer nil)
    (save-excursion
      (save-restriction
        (widen)
        (xenops-overlay-delete-overlays-in (point-min) (point-max))
        (goto-char (point-min))
        (xenops-render))))

  (defun fn/xenops-math-finish-scheduled-refresh (buffer generation)
    "Refresh BUFFER at the current scale once GENERATION becomes idle."
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (setq fn/xenops-math-refresh-timer nil)
        (cond
         ((or (not fn/xenops-math-refresh-pending)
              (not (bound-and-true-p xenops-mode))
              (/= generation (fn/xenops-math-buffer-generation)))
          (setq fn/xenops-math-refresh-pending nil))
         ((fn/xenops-math-render-queue-idle-p)
          (fn/xenops-math-render-current-scale))
         (t
          (setq fn/xenops-math-refresh-timer
                (run-at-time
                 fn/xenops-math-refresh-retry-delay nil
                 #'fn/xenops-math-finish-scheduled-refresh
                 buffer generation)))))))

  (defun fn/xenops-math-schedule-current-scale-refresh ()
    "Schedule a current-scale refresh for the current Xenops buffer."
    (setq fn/xenops-math-refresh-pending t)
    (unless (timerp fn/xenops-math-refresh-timer)
      (setq fn/xenops-math-refresh-timer
            (run-at-time
             0 nil #'fn/xenops-math-finish-scheduled-refresh
             (current-buffer)
             (fn/xenops-math-buffer-generation)))))

  (defun fn/xenops-refresh-rendered-buffers (&optional _fontsizes-list)
    "Schedule rendered Xenops buffers to refresh after a scale change.
An active render queue is allowed to finish first.  This prevents
hundreds of old promises and waiting overlays from being orphaned
when a large document is refreshed."
    (when (featurep 'xenops)
      (dolist (buffer (buffer-list))
        (with-current-buffer buffer
          (when (and (bound-and-true-p xenops-mode)
                     (fn/xenops-math-buffer-has-overlays-p))
            (fn/xenops-math-schedule-current-scale-refresh))))))

  (defun fn/xenops-math-recover-stale-rendered-buffers ()
    "Recover idle Xenops buffers that still contain waiting overlays."
    (when (featurep 'xenops)
      (dolist (buffer (buffer-list))
        (with-current-buffer buffer
          (when (and (bound-and-true-p xenops-mode)
                     (fn/xenops-math-buffer-has-overlays-p 'xenops-math-waiting)
                     (fn/xenops-math-render-queue-idle-p))
            (fn/xenops-math-schedule-current-scale-refresh))))))

  (defun fn/xenops-math-cache-key-include-scale (orig-fn &rest args)
    "Add scale and SVG baseline version to Xenops math cache keys."
    (append (apply orig-fn args)
            (list (list 'xenops-math-image-scale-factor
                        xenops-math-image-scale-factor)
                  (list 'fn/xenops-math-svg-baseline-cache-version
                        fn/xenops-math-svg-baseline-cache-version))))

  (defun fn/xenops-math-svg-numbers (value)
    "Return the numeric components in SVG attribute VALUE."
    (when (stringp value)
      (mapcar #'string-to-number (split-string value "[, ]+" t))))

  (defun fn/xenops-math-svg-baseline-ascent (file)
    "Return FILE's TeX baseline as an Emacs image ascent percentage."
    (when (and (stringp file)
               (file-readable-p file)
               (fboundp 'libxml-parse-xml-region))
      (condition-case nil
          (with-temp-buffer
            (insert-file-contents-literally file)
            (let* ((document
                    (libxml-parse-xml-region (point-min) (point-max)))
                   (svg (car (dom-by-tag document 'svg)))
                   (page (dom-by-id document "page1"))
                   (marker (dom-by-id document "xenops-baseline"))
                   (view-box
                    (fn/xenops-math-svg-numbers
                     (dom-attr svg 'viewBox)))
                   (transform (and page (dom-attr page 'transform)))
                   (matrix
                    (if (and transform
                             (string-match "\\`matrix(\\(.*\\))\\'" transform))
                        (fn/xenops-math-svg-numbers
                         (match-string 1 transform))
                      '(1.0 0.0 0.0 1.0 0.0 0.0)))
                   (x (when-let* ((value (dom-attr marker 'data-x)))
                        (string-to-number value)))
                   (y (when-let* ((value (dom-attr marker 'data-y)))
                        (string-to-number value))))
              (when (and (= (length view-box) 4)
                         (= (length matrix) 6)
                         x y
                         (> (nth 3 view-box) 0))
                (let* ((top (nth 1 view-box))
                       (height (nth 3 view-box))
                       (baseline-y (+ (* (nth 1 matrix) x)
                                      (* (nth 3 matrix) y)
                                      (nth 5 matrix)))
                       (ascent
                        (round (* 100.0 (/ (- baseline-y top) height)))))
                  (max 0 (min 100 ascent))))))
        (file-error nil))))

  (defun fn/xenops-math-display-image-set-svg-foreground (element &rest _)
    "Set SVG foreground and align inline math to its TeX baseline."
    (let ((beg (plist-get element :begin))
          (end (plist-get element :end)))
      (when (and beg end)
        (dolist (ov (overlays-in beg end))
          (let ((display (overlay-get ov 'display)))
            (when (and (eq (overlay-get ov 'xenops-overlay-type) 'xenops-overlay)
                       (consp display)
                       (eq (car display) 'image)
                       (eq (plist-get (cdr display) :type) 'svg))
              (let* ((properties (copy-sequence (cdr display)))
                     (file (plist-get properties :file))
                     (ascent
                      (and (eq (plist-get element :type) 'inline-math)
                           (fn/xenops-math-svg-baseline-ascent file))))
                (setq properties
                      (plist-put properties :foreground "black"))
                (when ascent
                  (setq properties (plist-put properties :ascent ascent)))
                (overlay-put ov 'display (cons 'image properties)))))))))
  :config
  (setq xenops-font-family "Maple Mono NL NF CN"
        xenops-reveal-on-entry t
        xenops-math-latex-process-alist org-preview-latex-process-alist
        xenops-math-latex-process 'xdvisvgm)
  (add-hook 'org-mode-hook #'xenops-mode)
  (aio-defun fn/xenops-math-latex-create-image-a
    (element latex colors cache-file display-image)
    "Create a Xenops math image without leaking work across buffer generations.
This replaces `xenops-math-latex-create-image'.  In particular, it
posts completion to the same semaphore it acquired, even if a major
mode restart has installed a new buffer-local semaphore."
    (let ((buffer (current-buffer))
          (generation (fn/xenops-math-buffer-generation))
          (semaphore xenops-math-latex-tasks-semaphore))
      (aio-await (aio-sem-wait semaphore))
      (condition-case error
          (when (fn/xenops-math-current-generation-p buffer generation)
            (with-current-buffer buffer
              (xenops-math-set-marker-on-element element))
            (let* ((dir (expand-file-name "xenops" temporary-file-directory))
                   (base-name (file-name-base cache-file))
                   (make-file-name
                    (lambda (extension)
                      (expand-file-name
                       (concat base-name "." extension)
                       dir)))
                   (tex-file (funcall make-file-name "tex"))
                   (image-input-file
                    (funcall make-file-name
                             (with-current-buffer buffer
                               (xenops-math-latex-process-get
                                :image-input-type))))
                   (image-output-file
                    (funcall make-file-name
                             (with-current-buffer buffer
                               (xenops-math-latex-process-get
                                :image-output-type))))
                   (commands
                    (with-current-buffer buffer
                      (xenops-math-latex-make-commands
                       element dir tex-file image-input-file
                       image-output-file))))
              (make-directory dir t)
              (aio-await
               (xenops-aio-with-async-with-buffer
                buffer
                (let ((latex-document
                       (xenops-math-latex-make-latex-document
                        (fn/xenops-math-latex-add-svg-baseline element latex)
                        colors)))
                  (with-temp-file tex-file
                    (insert latex-document)))))
              (dolist (command commands)
                (aio-await (xenops-aio-subprocess command)))
              (aio-await
               (aio-with-async
                 (with-current-buffer buffer
                   (if (and
                        (equal
                         (xenops-math-latex-process-get
                          :image-output-type)
                         "png")
                        (xenops-math-latex-process-get
                         :image-output-ppi))
                       (let ((png-bytes
                              (xenops-png-set-phys-chunk
                               (f-read-bytes image-output-file)
                               (xenops-math-latex-process-get
                                :image-output-ppi))))
                         (f-write-bytes png-bytes cache-file))
                     (copy-file image-output-file cache-file t)))))
              (when (fn/xenops-math-current-generation-p
                     buffer generation)
                (aio-await
                 (xenops-aio-with-async-with-buffer
                  buffer
                  (if-let* ((marker (plist-get element :begin-marker))
                            (current-element
                             (xenops-math-parse-element-at marker)))
                      (funcall display-image current-element commands)
                    (when marker
                      (message "Failed to parse Xenops element at %S"
                               marker)))))
                (with-current-buffer buffer
                  (xenops-math-deactivate-marker-on-element element)))))
        (error
         (when (fn/xenops-math-current-generation-p buffer generation)
           (aio-await
            (xenops-aio-with-async-with-buffer
             buffer
             (when-let*
                 ((current-element
                   (xenops-math-parse-element-at
                    (plist-get element :begin-marker))))
               (xenops-math-display-error-badge
                current-element error
                (and (not xenops-apply-user-point)
                     (<= (xenops-math-latex-waiting-tasks-count)
                         0)))
               (xenops-math-deactivate-marker-on-element element)))))))
      ;; Never post to a newer buffer-local semaphore.  Doing so was the
      ;; source of the observed impossible 64/32 semaphore state.
      (aio-sem-post semaphore)))
  (advice-add 'xenops-math-latex-create-image
              :override #'fn/xenops-math-latex-create-image-a)
  (fn/xenops-math-sync-image-scale)
  (add-hook 'cnfonts-set-font-finish-hook
            #'fn/xenops-refresh-rendered-buffers)
  (advice-add 'xenops-math-render
              :before #'fn/xenops-math-sync-image-scale)
  (advice-add 'xenops-math-file-name-static-hash-data
              :around #'fn/xenops-math-cache-key-include-scale)
  (advice-add 'xenops-math-display-image
              :after #'fn/xenops-math-display-image-set-svg-foreground)
  (add-hook 'xenops-mode-hook #'fn/xenops-math-mode-state-h)
  (add-hook 'org-mode-hook #'fn/xenops-math-setup-smartparens-suspension-h)
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (derived-mode-p 'org-mode)
        (fn/xenops-math-setup-smartparens-suspension-h))))
  (advice-add 'xenops-math-handle-element-transgression
              :around #'fn/xenops-math-ignore-repeated-reveal-a)
  (fn/xenops-math-recover-stale-rendered-buffers)
  (defun fn/xenops-src-parse-at-point ()
    "Parse a source block using its temporary Org buffer's element cache."
    (when-let*
        ((element (xenops-parse-element-at-point 'src))
         (org-babel-info
          (xenops-src-do-in-org-mode
           (org-babel-get-src-block-info 'light (org-element-context)))))
        (xenops-util-plist-update
         element
         :type 'src
         :language (nth 0 org-babel-info)
         :org-babel-info org-babel-info)))

  ;; Org 9.7+ requires Babel lookup in the buffer that owns the element cache.
  ;; https://github.com/dandavison/xenops/pull/74
  (advice-add 'xenops-src-parse-at-point
              :override #'fn/xenops-src-parse-at-point))

(provide 'init-config-xenops)
;;; init-config-xenops.el ends here
