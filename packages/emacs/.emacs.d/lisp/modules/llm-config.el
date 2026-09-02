;;; llm-config.el --- Configure LLM backends and models -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jamie Cui - MIT License
;; Author: Jamie Cui <jamie.cui@outlook.com>
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Register this configuration's GPTel backends and default selection.  Model
;; lists can be refreshed from explicit HTTP endpoints and cached locally.  An
;; invalid response or transport failure leaves the current model list intact.

;;; Code:

(require 'auth-source)
(require 'cl-lib)
(require 'gptel)
(require 'gptel-gemini)
(require 'gptel-openai)
(require 'gptel-openai-extras)
(require 'json)
(require 'subr-x)
(require 'url)
(require 'url-http)

(defvar +llm/deepseek
  (gptel-make-deepseek "DeepSeek"
    :key (lambda ()
           (auth-source-pick-first-password :host "deepseek"))
    :stream t)
  "GPTel backend for DeepSeek.")

(defvar +llm/gemini
  (gptel-make-gemini "Gemini"
    :key (lambda ()
           (auth-source-pick-first-password :host "gemini"))
    :stream t)
  "GPTel backend for Gemini.")

(defvar +llm/moonshot-cn
  (gptel-make-openai "Moonshot (CN)"
    :host "api.moonshot.cn"
    :key (lambda ()
           (auth-source-pick-first-password :host "moonshot-cn"))
    :stream t
    :models '(kimi-k3))
  "GPTel backend for Moonshot's Chinese endpoint.")

(defvar +llm/aliyun
  (gptel-make-deepseek "Aliyun"
    :host "dashscope.aliyuncs.com/compatible-mode/v1"
    :endpoint "/chat/completions"
    :stream t
    :key (lambda ()
           (auth-source-pick-first-password :host "aliyun"))
    :models '(qwen3.7-plus
              (qwen3.7-max :request-params (:enable_thinking t))))
  "GPTel backend for Alibaba Model Studio.")

(defvar +llm/sssaicode
  (gptel-make-openai "SssAiCode"
    :host "codex1.sssaicode.com"
    :endpoint "/api/v1/chat/completions"
    :stream t
    :key (lambda ()
           (auth-source-pick-first-password :host "sssaicode"))
    :models '(gpt-5.4))
  "GPTel backend for SssAiCode.")

(defvar +llm/zhipu
  (gptel-make-deepseek "Zhipu"
    :host "open.bigmodel.cn/api/coding/paas/v4"
    :endpoint "/chat/completions"
    :stream t
    :key (lambda ()
           (auth-source-pick-first-password :host "zhipu"))
    :models '(glm-4.7))
  "GPTel backend for Zhipu's coding endpoint.")

(defvar +llm/model-sources
  `((,+llm/deepseek
     "https://api.deepseek.com/v1/models"
     openai)
    (,+llm/gemini
     "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1000"
     gemini)
    (,+llm/moonshot-cn
     "https://api.moonshot.cn/v1/models"
     openai)
    (,+llm/aliyun
     "https://dashscope.aliyuncs.com/api/v1/models?providers=qwen&capabilities=TG&page_no=1&page_size=100"
     aliyun)
    (,+llm/sssaicode
     "https://codex1.sssaicode.com/api/v1/models"
     openai)
    (,+llm/zhipu
     "https://open.bigmodel.cn/api/coding/paas/v4/models"
     openai))
  "GPTel backends and their model-list endpoints and parsers.")

(defvar +llm/model-cache-file
  (locate-user-emacs-file ".cache/gptel-model-discovery.json")
  "File used to cache the last successful model lists.")

(defun +llm--backend-headers (backend)
  "Return request headers configured by GPTel BACKEND."
  (let ((header (gptel-backend-header backend))
        (gptel-backend backend))
    (cond
     ((functionp header) (funcall header nil))
     ((listp header) header)
     (t
      (error "Invalid headers for backend %s"
             (gptel-backend-name backend))))))

(defun +llm--model-names (object parser)
  "Return validated model names from JSON OBJECT using PARSER."
  (let ((names
         (pcase parser
           ('openai
            (mapcar (lambda (entry) (gethash "id" entry))
                    (gethash "data" object)))
           ('gemini
            (cl-loop
             for entry in (gethash "models" object)
             when (member "generateContent"
                          (gethash "supportedGenerationMethods" entry))
             collect (string-remove-prefix "models/"
                                           (gethash "name" entry))))
           ('aliyun
            (mapcar
             (lambda (entry) (gethash "model" entry))
             (gethash "models" (gethash "output" object))))
           (_ (error "Unknown model parser: %S" parser)))))
    (unless (and names
                 (cl-every (lambda (name)
                             (and (stringp name)
                                  (not (string-empty-p name))))
                           names))
      (error "Invalid %s model response" parser))
    (delete-dups names)))

(defun +llm--parse-model-response (parser)
  "Parse the current HTTP response buffer using PARSER."
  (goto-char (point-min))
  (unless (re-search-forward "\r?\n\r?\n" nil t)
    (error "HTTP response has no header separator"))
  (mapcar
   #'intern
   (+llm--model-names
    (json-parse-buffer
     :object-type 'hash-table
     :array-type 'list
     :null-object nil
     :false-object nil)
    parser)))

(defun +llm--model-cache-json (cache)
  "Return JSON text encoding model CACHE."
  (json-serialize
   `(:version 1
     :backends
     ,(vconcat
       (mapcar
        (lambda (entry)
          (list :name (car entry)
                :models (vconcat (mapcar #'symbol-name (cdr entry)))))
        cache)))))

(defun +llm--read-model-cache ()
  "Read and validate `+llm/model-cache-file'."
  (when (file-exists-p +llm/model-cache-file)
    (with-temp-buffer
      (insert-file-contents +llm/model-cache-file)
      (let* ((root
              (json-parse-buffer
               :object-type 'plist
               :array-type 'list
               :null-object nil
               :false-object nil))
             (entries (plist-get root :backends)))
        (unless (and (equal (plist-get root :version) 1)
                     (listp entries))
          (error "Invalid model cache format"))
        (mapcar
         (lambda (entry)
           (let ((name (plist-get entry :name))
                 (models (plist-get entry :models)))
             (unless (and (stringp name)
                          (not (string-empty-p name))
                          models
                          (listp models)
                          (cl-every
                           (lambda (model)
                             (and (stringp model)
                                  (not (string-empty-p model))))
                           models))
               (error "Invalid model cache entry"))
             (cons name (mapcar #'intern models))))
         entries)))))

(defun +llm--read-model-cache-safely ()
  "Read the model cache, reporting invalid or unreadable data."
  (condition-case cache-error
      (+llm--read-model-cache)
    (error
     (message "llm-config: Ignoring cache: %s"
              (error-message-string cache-error))
     nil)))

(defun +llm--write-model-cache (cache)
  "Atomically write model CACHE to `+llm/model-cache-file'."
  (let* ((file (expand-file-name +llm/model-cache-file))
         (directory (file-name-directory file)))
    (make-directory directory t)
    (let ((temp-file
           (make-temp-file
            (expand-file-name ".gptel-model-discovery-" directory))))
      (unwind-protect
          (progn
            (with-temp-file temp-file
              (set-buffer-file-coding-system 'utf-8-unix)
              (insert (+llm--model-cache-json cache))
              (insert "\n"))
            (rename-file temp-file file t)
            (setq temp-file nil))
        (when temp-file
          (condition-case cleanup-error
              (delete-file temp-file)
            (file-error
             (message "llm-config: Cache cleanup failed: %s"
                      (error-message-string cleanup-error)))))))))

(defun +llm--install-models (backend models)
  "Replace BACKEND's model list with MODELS."
  (setf (gptel-backend-models backend) (copy-sequence models))
  (when (and (eq gptel-backend backend)
             gptel-model
             (not (memq gptel-model models)))
    (message "llm-config: Current model %s is no longer listed by %s"
             gptel-model
             (gptel-backend-name backend))))

(defun +llm--commit-models (backend models)
  "Persist and install MODELS for BACKEND."
  (let ((backend-name (gptel-backend-name backend)))
    (+llm--write-model-cache
     (cons (cons backend-name models)
           (cl-remove backend-name
                      (+llm--read-model-cache-safely)
                      :key #'car
                      :test #'string=))))
  (+llm--install-models backend models))

(defun +llm--refresh-callback (status backend parser endpoint)
  "Handle STATUS for BACKEND using PARSER and ENDPOINT."
  (let ((response-buffer (current-buffer))
        (backend-name (gptel-backend-name backend)))
    (unwind-protect
        (condition-case refresh-error
            (if-let* ((transport-error (plist-get status :error)))
                (error "Request failed: %S" transport-error)
              (let ((http-status (url-http-parse-response)))
                (unless (and (integerp http-status)
                             (<= 200 http-status)
                             (< http-status 300))
                  (error "HTTP %s from %s"
                         (or http-status "unknown") endpoint))
                (let ((models (+llm--parse-model-response parser)))
                  (+llm--commit-models backend models)
                  (message "llm-config: Refreshed %s with %d models"
                           backend-name (length models)))))
          (error
           (message "llm-config: %s refresh failed: %s"
                    backend-name
                    (error-message-string refresh-error))))
      (when (buffer-live-p response-buffer)
        (kill-buffer response-buffer)))))

(defun +llm--refresh-source (source)
  "Start an asynchronous model refresh for SOURCE."
  (pcase-let* ((`(,backend ,endpoint ,parser) source)
               (url-request-method "GET")
               (url-request-extra-headers
                (append '(("Accept" . "application/json"))
                        (+llm--backend-headers backend)))
               (url-proxy-services
                (if (and (stringp gptel-proxy)
                         (not (string-empty-p gptel-proxy)))
                    `(("http" . ,gptel-proxy)
                      ("https" . ,gptel-proxy))
                  url-proxy-services)))
    (url-retrieve endpoint #'+llm--refresh-callback
                  (list backend parser endpoint) t t)))

(defun +llm/load-model-cache ()
  "Load cached model lists into configured GPTel backends."
  (interactive)
  (when-let* ((cache (+llm--read-model-cache-safely)))
    (dolist (source +llm/model-sources)
      (let* ((backend (car source))
             (models
              (alist-get (gptel-backend-name backend)
                         cache nil nil #'string=)))
        (when models
          (+llm--install-models backend models))))
    t))

(defun +llm/refresh-models ()
  "Asynchronously refresh every configured model source."
  (interactive)
  (let (requests)
    (dolist (source +llm/model-sources)
      (condition-case source-error
          (when-let* ((request (+llm--refresh-source source)))
            (push request requests))
        (error
         (message "llm-config: Could not refresh %s: %s"
                  (gptel-backend-name (car source))
                  (error-message-string source-error)))))
    (nreverse requests)))

(setopt gptel-backend +llm/deepseek
        gptel-model 'deepseek-v4-pro)

;; Startup stays offline.  Refresh explicitly with `M-x +llm/refresh-models'.
(+llm/load-model-cache)

(provide 'init-llm-config)
;;; llm-config.el ends here
