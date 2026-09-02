;;; gptel-model-discovery.el --- Discover and cache GPTel models -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jamie Cui - MIT License
;; Author: Jamie Cui <jamie.cui@outlook.com>
;; Package-Requires: ((emacs "30.1") (gptel "0.9.8"))
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Refresh GPTel backend model lists from explicitly configured HTTP endpoints.
;; A successful, non-empty response replaces the backend's models and is cached
;; locally.  Invalid responses and transport failures leave the current model
;; list unchanged.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'url)
(require 'url-http)
(require 'gptel)

(defgroup gptel-model-discovery nil
  "Discover model lists for GPTel backends."
  :group 'gptel)

(defcustom gptel-model-discovery-sources nil
  "Explicit model discovery sources.

Each entry has the form (BACKEND-VARIABLE URL PARSER).  BACKEND-VARIABLE is a
symbol whose value is a GPTel backend, URL is the complete model-list endpoint,
and PARSER is one of `openai', `gemini', or `aliyun'."
  :type '(repeat
          (list :tag "Source"
                (symbol :tag "Backend variable")
                (string :tag "Model endpoint")
                (choice (const openai)
                        (const gemini)
                        (const aliyun))))
  :group 'gptel-model-discovery)

(defcustom gptel-model-discovery-cache-file
  (locate-user-emacs-file ".cache/gptel-model-discovery.json")
  "File used to cache the last successful model lists."
  :type 'file
  :group 'gptel-model-discovery)

(define-error 'gptel-model-discovery-invalid-data
  "Invalid GPTel model discovery data")

(defvar gptel-model-discovery--cache nil
  "Alist mapping backend names to cached model symbols.")

(defun gptel-model-discovery--invalid (format-string &rest args)
  "Signal invalid discovery data described by FORMAT-STRING and ARGS."
  (signal 'gptel-model-discovery-invalid-data
          (list (apply #'format format-string args))))

(defun gptel-model-discovery--resolve-source (source)
  "Return SOURCE as (BACKEND URL PARSER), validating every field."
  (pcase source
    (`(,backend-variable ,url ,parser)
     (unless (and (symbolp backend-variable)
                  (boundp backend-variable))
       (gptel-model-discovery--invalid
        "Backend variable is not bound: %S" backend-variable))
     (unless (and (stringp url) (not (string-empty-p url)))
       (gptel-model-discovery--invalid
        "Model endpoint is not a non-empty string: %S" url))
     (unless (memq parser '(openai gemini aliyun))
       (gptel-model-discovery--invalid
        "Unknown parser for %S: %S" backend-variable parser))
     (let ((backend (symbol-value backend-variable)))
       (unless (gptel-backend-p backend)
         (gptel-model-discovery--invalid
          "Variable %S does not contain a GPTel backend" backend-variable))
       (list backend url parser)))
    (_
     (gptel-model-discovery--invalid "Malformed source: %S" source))))

(defun gptel-model-discovery--headers (backend)
  "Return request headers configured by GPTel BACKEND."
  (unless (gptel-backend-p backend)
    (gptel-model-discovery--invalid "Not a GPTel backend: %S" backend))
  (let ((header (gptel-backend-header backend))
        (gptel-backend backend))
    (cond
     ((null header) nil)
     ((functionp header) (funcall header nil))
     ((listp header) header)
     (t
      (gptel-model-discovery--invalid
       "Invalid header configuration for %s"
       (gptel-backend-name backend))))))

(defun gptel-model-discovery--object-list (object key context)
  "Return array KEY from hash-table OBJECT, validated for CONTEXT."
  (unless (hash-table-p object)
    (gptel-model-discovery--invalid "%s is not a JSON object" context))
  (let ((value (gethash key object)))
    (unless (listp value)
      (gptel-model-discovery--invalid
       "%s does not contain an array at %s" context key))
    value))

(defun gptel-model-discovery--entry-string (entry key context)
  "Return non-empty string KEY from ENTRY, validated for CONTEXT."
  (unless (hash-table-p entry)
    (gptel-model-discovery--invalid "%s entry is not an object" context))
  (let ((value (gethash key entry)))
    (unless (and (stringp value) (not (string-empty-p value)))
      (gptel-model-discovery--invalid
       "%s entry has no non-empty %s" context key))
    value))

(defun gptel-model-discovery--openai-model-names (object)
  "Return model names from OpenAI-compatible JSON OBJECT."
  (mapcar
   (lambda (entry)
     (gptel-model-discovery--entry-string entry "id" "OpenAI model"))
   (gptel-model-discovery--object-list object "data" "OpenAI response")))

(defun gptel-model-discovery--gemini-model-names (object)
  "Return chat-capable model names from Gemini JSON OBJECT."
  (let (models)
    (dolist (entry
             (gptel-model-discovery--object-list
              object "models" "Gemini response"))
      (unless (hash-table-p entry)
        (gptel-model-discovery--invalid "Gemini model entry is not an object"))
      (when (member "generateContent"
                    (gethash "supportedGenerationMethods" entry))
        (let ((name
               (gptel-model-discovery--entry-string
                entry "name" "Gemini model")))
          (push (if (string-prefix-p "models/" name)
                    (substring name (length "models/"))
                  name)
                models))))
    (nreverse models)))

(defun gptel-model-discovery--aliyun-model-names (object)
  "Return model names from Alibaba Model Studio JSON OBJECT."
  (let* ((output (and (hash-table-p object) (gethash "output" object)))
         (entries
          (gptel-model-discovery--object-list
           output "models" "Alibaba response output")))
    (mapcar
     (lambda (entry)
       (gptel-model-discovery--entry-string entry "model" "Alibaba model"))
     entries)))

(defun gptel-model-discovery--model-symbols (object parser)
  "Return unique model symbols parsed from JSON OBJECT using PARSER."
  (let ((names
         (pcase parser
           ('openai (gptel-model-discovery--openai-model-names object))
           ('gemini (gptel-model-discovery--gemini-model-names object))
           ('aliyun (gptel-model-discovery--aliyun-model-names object))
           (_ (gptel-model-discovery--invalid "Unknown parser: %S" parser))))
        (seen (make-hash-table :test #'equal))
        models)
    (dolist (name names)
      (unless (gethash name seen)
        (puthash name t seen)
        (push (intern name) models)))
    (setq models (nreverse models))
    (unless models
      (gptel-model-discovery--invalid
       "The %s response contains no usable chat models" parser))
    models))

(defun gptel-model-discovery--parse-response (parser)
  "Parse the current HTTP response buffer using PARSER."
  (goto-char (point-min))
  (unless (re-search-forward "\r?\n\r?\n" nil t)
    (gptel-model-discovery--invalid "HTTP response has no header separator"))
  (gptel-model-discovery--model-symbols
   (json-parse-buffer
    :object-type 'hash-table
    :array-type 'list
    :null-object nil
    :false-object nil)
   parser))

(defun gptel-model-discovery--cache-with (cache backend-name models)
  "Return CACHE with BACKEND-NAME replaced by MODELS."
  (cons (cons backend-name (copy-sequence models))
        (cl-remove backend-name cache :key #'car :test #'string=)))

(defun gptel-model-discovery--cache-json (cache)
  "Return JSON text encoding model CACHE."
  (let ((root (make-hash-table :test #'equal)))
    (puthash "version" 1 root)
    (puthash
     "backends"
     (vconcat
      (mapcar
       (lambda (entry)
         (let ((item (make-hash-table :test #'equal)))
           (puthash "name" (car entry) item)
           (puthash "models"
                    (vconcat (mapcar #'symbol-name (cdr entry)))
                    item)
           item))
       cache))
     root)
    (json-serialize root)))

(defun gptel-model-discovery--write-cache (cache)
  "Atomically write model CACHE to `gptel-model-discovery-cache-file'."
  (let* ((file (expand-file-name gptel-model-discovery-cache-file))
         (directory (file-name-directory file))
         temp-file)
    (make-directory directory t)
    (setq temp-file
          (make-temp-file
           (expand-file-name ".gptel-model-discovery-" directory)))
    (condition-case primary-error
        (progn
          (with-temp-file temp-file
            (set-buffer-file-coding-system 'utf-8-unix)
            (insert (gptel-model-discovery--cache-json cache))
            (insert "\n"))
          (rename-file temp-file file t)
          (setq temp-file nil))
      (error
       (when temp-file
         (condition-case cleanup-error
             (delete-file temp-file)
           (file-error
            (message "gptel-model-discovery: Cache cleanup failed: %s"
                     (error-message-string cleanup-error)))))
       (signal (car primary-error) (cdr primary-error))))))

(defun gptel-model-discovery--read-cache ()
  "Read and validate `gptel-model-discovery-cache-file'."
  (when (file-exists-p gptel-model-discovery-cache-file)
    (with-temp-buffer
      (insert-file-contents gptel-model-discovery-cache-file)
      (let* ((root
              (json-parse-buffer
               :object-type 'hash-table
               :array-type 'list
               :null-object nil
               :false-object nil))
             (version (and (hash-table-p root) (gethash "version" root)))
             (backends
              (and (hash-table-p root) (gethash "backends" root)))
             cache)
        (unless (equal version 1)
          (gptel-model-discovery--invalid
           "Unsupported cache version: %S" version))
        (unless (listp backends)
          (gptel-model-discovery--invalid "Cache backends value is not an array"))
        (dolist (entry backends)
          (let* ((name
                  (gptel-model-discovery--entry-string
                   entry "name" "Cache backend"))
                 (model-names
                  (gptel-model-discovery--object-list
                   entry "models" "Cache backend")))
            (unless (and model-names
                         (cl-every
                          (lambda (model)
                            (and (stringp model) (not (string-empty-p model))))
                          model-names))
              (gptel-model-discovery--invalid
               "Cache backend %s has no valid models" name))
            (push (cons name (mapcar #'intern model-names)) cache)))
        (nreverse cache)))))

(defun gptel-model-discovery--warn-stale-selection (backend models)
  "Warn when active BACKEND selects a model absent from MODELS."
  (when (and (boundp 'gptel-backend)
             (eq gptel-backend backend)
             (boundp 'gptel-model)
             gptel-model
             (not (memq gptel-model models)))
    (message
     "gptel-model-discovery: Current model %s is no longer listed by %s"
     gptel-model
     (gptel-backend-name backend))))

(defun gptel-model-discovery--install-models (backend models)
  "Replace BACKEND's model list with MODELS."
  (unless (and (gptel-backend-p backend) models)
    (gptel-model-discovery--invalid "Cannot install an empty model list"))
  (setf (gptel-backend-models backend) (copy-sequence models))
  (gptel-model-discovery--warn-stale-selection backend models))

(defun gptel-model-discovery--commit-models (backend models)
  "Persist and install MODELS for BACKEND."
  (let* ((backend-name (gptel-backend-name backend))
         (new-cache
          (gptel-model-discovery--cache-with
           gptel-model-discovery--cache backend-name models)))
    (gptel-model-discovery--write-cache new-cache)
    (setq gptel-model-discovery--cache new-cache)
    (gptel-model-discovery--install-models backend models)))

(defun gptel-model-discovery--refresh-callback
    (status backend parser endpoint)
  "Handle STATUS for BACKEND using PARSER and ENDPOINT."
  (let ((response-buffer (current-buffer))
        (backend-name (gptel-backend-name backend)))
    (unwind-protect
        (condition-case callback-error
            (if-let* ((transport-error (plist-get status :error)))
                (message
                 "gptel-model-discovery: %s request failed: %S"
                 backend-name transport-error)
              (let ((http-status (url-http-parse-response)))
                (if (not (and (integerp http-status)
                              (<= 200 http-status)
                              (< http-status 300)))
                    (message
                     "gptel-model-discovery: %s returned HTTP %s from %s"
                     backend-name (or http-status "unknown") endpoint)
                  (let ((models
                         (gptel-model-discovery--parse-response parser)))
                    (gptel-model-discovery--commit-models backend models)
                    (message
                     "gptel-model-discovery: Refreshed %s with %d models"
                     backend-name (length models))))))
          (error
           (message "gptel-model-discovery: %s refresh failed: %s"
                    backend-name
                    (error-message-string callback-error))))
      (when (buffer-live-p response-buffer)
        (kill-buffer response-buffer)))))

(defun gptel-model-discovery--refresh-source (source)
  "Start an asynchronous refresh for SOURCE."
  (pcase-let* ((`(,backend ,endpoint ,parser)
                (gptel-model-discovery--resolve-source source))
               (url-request-method "GET")
               (url-request-extra-headers
                (append '(("Accept" . "application/json"))
                        (gptel-model-discovery--headers backend)))
               (url-proxy-services
                (if (and (boundp 'gptel-proxy)
                         (stringp gptel-proxy)
                         (not (string-empty-p gptel-proxy)))
                    `(("http" . ,gptel-proxy)
                      ("https" . ,gptel-proxy))
                  url-proxy-services)))
    (url-retrieve
     endpoint
     #'gptel-model-discovery--refresh-callback
     (list backend parser endpoint)
     t t)))

;;;###autoload
(defun gptel-model-discovery-load-cache ()
  "Load cached model lists into configured GPTel backends.

Invalid or unreadable cache data is reported and ignored."
  (interactive)
  (condition-case cache-error
      (when-let* ((cache (gptel-model-discovery--read-cache)))
        (setq gptel-model-discovery--cache cache)
        (dolist (source gptel-model-discovery-sources)
          (pcase-let* ((`(,backend ,_endpoint ,_parser)
                        (gptel-model-discovery--resolve-source source))
                       (backend-name (gptel-backend-name backend))
                       (models
                        (alist-get backend-name cache nil nil #'string=)))
            (when models
              (gptel-model-discovery--install-models backend models))))
        t)
    ((file-error json-error json-parse-error
                 gptel-model-discovery-invalid-data)
     (message "gptel-model-discovery: Ignoring cache: %s"
              (error-message-string cache-error))
     nil)))

;;;###autoload
(defun gptel-model-discovery-refresh ()
  "Asynchronously refresh every configured model source.

A failure in one source is reported without preventing other sources from
starting.  Return the response buffers created for successful requests."
  (interactive)
  (let (requests)
    (dolist (source gptel-model-discovery-sources)
      (condition-case source-error
          (when-let* ((request
                       (gptel-model-discovery--refresh-source source)))
            (push request requests))
        (error
         (message "gptel-model-discovery: Could not start %S: %s"
                  source (error-message-string source-error)))))
    (nreverse requests)))

(provide 'gptel-model-discovery)
;;; gptel-model-discovery.el ends here
