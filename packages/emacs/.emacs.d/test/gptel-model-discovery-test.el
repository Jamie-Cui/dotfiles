;;; gptel-model-discovery-test.el --- Tests for model discovery -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Focused tests for model parsing, cache persistence, and failure safety.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'json)
(require 'gptel-openai)

(add-to-list 'load-path
             (expand-file-name "../site-lisp"
                               (file-name-directory
                                (or load-file-name buffer-file-name))))

(require 'gptel-model-discovery)

(defvar gptel-model-discovery-test--backend nil)

(defun gptel-model-discovery-test--json (text)
  "Parse JSON TEXT using the package's in-memory representation."
  (json-parse-string text
                     :object-type 'hash-table
                     :array-type 'list
                     :null-object nil
                     :false-object nil))

(ert-deftest gptel-model-discovery-openai-preserves-order-and-deduplicates ()
  (should
   (equal
    (gptel-model-discovery--model-symbols
     (gptel-model-discovery-test--json
      "{\"data\":[{\"id\":\"model-b\"},{\"id\":\"model-a\"},{\"id\":\"model-b\"}]}")
     'openai)
    '(model-b model-a))))

(ert-deftest gptel-model-discovery-gemini-keeps-generate-content-models ()
  (should
   (equal
    (gptel-model-discovery--model-symbols
     (gptel-model-discovery-test--json
      (concat
       "{\"models\":["
       "{\"name\":\"models/gemini-chat\","
       "\"supportedGenerationMethods\":[\"generateContent\"]},"
       "{\"name\":\"models/gemini-embed\","
       "\"supportedGenerationMethods\":[\"embedContent\"]}]}"))
     'gemini)
    '(gemini-chat))))

(ert-deftest gptel-model-discovery-aliyun-reads-output-models ()
  (should
   (equal
    (gptel-model-discovery--model-symbols
     (gptel-model-discovery-test--json
      "{\"output\":{\"models\":[{\"model\":\"qwen-a\"},{\"model\":\"qwen-b\"}]}}")
     'aliyun)
    '(qwen-a qwen-b))))

(ert-deftest gptel-model-discovery-rejects-empty-model-list ()
  (should-error
   (gptel-model-discovery--model-symbols
    (gptel-model-discovery-test--json "{\"data\":[]}")
    'openai)
   :type 'gptel-model-discovery-invalid-data))

(ert-deftest gptel-model-discovery-cache-round-trip ()
  (let* ((cache-file (make-temp-file "gptel-model-discovery-test-"))
         (gptel-model-discovery-cache-file cache-file)
         (cache '(("Provider A" . (model-a model-b))
                  ("Provider B" . (model-c)))))
    (unwind-protect
        (progn
          (gptel-model-discovery--write-cache cache)
          (should (equal (gptel-model-discovery--read-cache) cache)))
      (when (file-exists-p cache-file)
        (delete-file cache-file)))))

(ert-deftest gptel-model-discovery-cache-write-failure-preserves-backend ()
  (let* ((backend
          (gptel-make-openai
              "Discovery cache failure test"
            :host "example.invalid"
            :models '(old-model)))
         (gptel-model-discovery--cache
          '(("Discovery cache failure test" . (old-model)))))
    (cl-letf (((symbol-function 'gptel-model-discovery--write-cache)
               (lambda (_cache)
                 (signal 'file-error '("Cache unavailable")))))
      (should-error
       (gptel-model-discovery--commit-models backend '(new-model))
       :type 'file-error))
    (should (equal (gptel-backend-models backend) '(old-model)))
    (should
     (equal gptel-model-discovery--cache
            '(("Discovery cache failure test" . (old-model)))))))

(ert-deftest gptel-model-discovery-load-cache-replaces-known-backend-models ()
  (let* ((cache-file (make-temp-file "gptel-model-discovery-test-"))
         (gptel-model-discovery-cache-file cache-file)
         (backend
          (gptel-make-openai
              "Discovery load test"
            :host "example.invalid"
            :models '(fallback-model)))
         (gptel-model-discovery-test--backend backend)
         (gptel-model-discovery-sources
          '((gptel-model-discovery-test--backend
             "https://example.invalid/v1/models"
             openai))))
    (unwind-protect
        (progn
          (gptel-model-discovery--write-cache
           '(("Discovery load test" . (cached-a cached-b))))
          (should (gptel-model-discovery-load-cache))
          (should
           (equal (gptel-backend-models backend) '(cached-a cached-b))))
      (when (file-exists-p cache-file)
        (delete-file cache-file)))))

(ert-deftest gptel-model-discovery-invalid-cache-preserves-backend ()
  (let* ((cache-file (make-temp-file "gptel-model-discovery-test-"))
         (gptel-model-discovery-cache-file cache-file)
         (backend
          (gptel-make-openai
              "Discovery invalid cache test"
            :host "example.invalid"
            :models '(fallback-model)))
         (gptel-model-discovery-test--backend backend)
         (gptel-model-discovery-sources
          '((gptel-model-discovery-test--backend
             "https://example.invalid/v1/models"
             openai))))
    (unwind-protect
        (progn
          (with-temp-file cache-file
            (insert "not-json"))
          (should-not (gptel-model-discovery-load-cache))
          (should
           (equal (gptel-backend-models backend) '(fallback-model))))
      (when (file-exists-p cache-file)
        (delete-file cache-file)))))

(ert-deftest gptel-model-discovery-uses-backend-headers ()
  (let ((backend
         (gptel-make-openai
             "Discovery header test"
           :host "example.invalid"
           :header (lambda (_info) '(("X-Test" . "present")))
           :models '(model-a))))
    (should
     (equal (gptel-model-discovery--headers backend)
            '(("X-Test" . "present"))))))

(provide 'gptel-model-discovery-test)
;;; gptel-model-discovery-test.el ends here
