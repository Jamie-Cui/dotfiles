;;; magent-profile-memory-test.el --- Tests for profile memory -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jamie Cui
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Tests for the personal Magent Emacs profile-memory provider.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'magent)
(require 'magent-profile-memory)

(magent-define-workflow magent-profile-memory-test--empty-action-workflow (_invocation)
			"Return immediately for Action tests."
			nil)

(defun magent-profile-memory-test--register-actions-only ()
  "Register the personal profile-memory provider and Actions."
  (magent-profile-memory-register))

(ert-deftest magent-profile-memory-test-registers-user-actions-and-provider ()
  "Registration installs the provider and three user-layer Actions."
  (let ((magent-action--registry nil)
        (magent-action--sequence 0)
        (magent-action-registry-changed-hook nil)
        (magent-context-provider-functions nil))
    (magent-profile-memory-register)
    (should (memq #'magent-memory-system-message
                  magent-context-provider-functions))
    (dolist (name '("memory-init" "memory-refresh" "memory-clear"))
      (let ((spec (magent-action-get name 'global 'interactive)))
        (should spec)
        (should (eq (magent-action-spec-source-layer spec) 'user))
        (should (eq (magent-action-spec-session-policy spec) 'isolated))))))

(ert-deftest magent-profile-memory-test-memory-scan-plan-skips-sensitive-and-org-notes ()
  "Test memory scan plans avoid secrets, custom-file contents, and Org notes."
  (let* ((root (file-name-as-directory
                (make-temp-file "magent-memory-root" t)))
         (init-file (expand-file-name "init.el" root))
         (custom-path (expand-file-name "custom.el" root))
         (readme (expand-file-name "README.org" root))
         (notes (expand-file-name "notes.org" root))
         (secret (expand-file-name "secrets.el" root))
         (user-emacs-directory root)
         (user-init-file init-file)
         (early-init-file nil)
         (custom-file custom-path)
         (magent-memory-extra-scan-roots nil)
         (magent-memory-exclude-patterns
          (remove "/var/" magent-memory-exclude-patterns))
         (magent-memory-scan-custom-file nil)
         (magent-memory-max-files 20)
         (magent-memory-max-file-bytes 10000)
         (magent-memory-max-scan-bytes 50000))
    (with-temp-file init-file
      (insert "(use-package magit)\n"))
    (with-temp-file custom-path
      (insert "(custom-set-variables '(secret-token \"abc\"))\n"))
    (with-temp-file readme
      (insert "# Emacs config\n"))
    (with-temp-file notes
      (insert "* Personal notes\n"))
    (with-temp-file secret
      (insert "(setq token \"secret\")\n"))
    (let* ((plan (magent-memory-build-scan-plan))
           (files (magent-memory--scan-plan-file-paths plan)))
      (should (member init-file files))
      (should (member readme files))
      (should-not (member custom-path files))
      (should-not (member notes files))
      (should-not (member secret files))
      (should (member secret
                      (magent-memory-scan-plan-skipped-sensitive plan))))))

(ert-deftest magent-profile-memory-test-memory-refresh-preserves-user-notes ()
  "Test memory refresh rewrites managed content and preserves User Notes."
  (let* ((root (file-name-as-directory
                (make-temp-file "magent-memory-root" t)))
         (memory-dir (file-name-as-directory
                      (make-temp-file "magent-memory-store" t)))
         (init-file (expand-file-name "init.el" root))
         (user-emacs-directory root)
         (user-init-file init-file)
         (early-init-file nil)
         (custom-file nil)
         (magent-memory-directory memory-dir)
         (magent-memory-use-llm nil)
         (magent-memory-open-after-write nil)
         (magent-memory-extra-scan-roots nil))
    (with-temp-file init-file
      (insert "(use-package project)\n"))
    (magent-memory-run
     'init
     :confirm-fn (lambda (_plan continue) (funcall continue t)))
    (with-temp-buffer
      (insert-file-contents (magent-memory-file))
      (goto-char (point-max))
      (insert "Prefer minibuffer-driven confirmations.\n")
      (write-region (point-min) (point-max) (magent-memory-file)))
    (magent-memory-run
     'refresh
     :confirm-fn (lambda (_plan continue) (funcall continue t)))
    (with-temp-buffer
      (insert-file-contents (magent-memory-file))
      (let ((text (buffer-string)))
        (should (string-match-p
                 (regexp-quote "* Magent Managed Profile")
                 text))
        (should (string-match-p
                 (regexp-quote "Prefer minibuffer-driven confirmations.")
                 text))
        (should (file-directory-p
                 (magent-memory-snapshots-directory)))))))

(ert-deftest magent-profile-memory-test-memory-profile-and-snapshots-use-private-modes ()
  "Memory persistence enforces 0700 directories and 0600 files."
  (let* ((memory-dir (file-name-as-directory
                      (make-temp-file "magent-memory-private-" t)))
         (magent-memory-directory memory-dir)
         (file (magent-memory-file))
         (plan (magent-memory-scan-plan--create
                :roots nil
                :entry-files nil
                :files nil
                :skipped-sensitive nil
                :skipped-excluded nil
                :skipped-budget nil
                :total-bytes 0
                :generated-at (current-time)
                :provider "test"
                :model "test")))
    (unwind-protect
        (progn
          (set-file-modes memory-dir #o755)
          (with-temp-file file
            (insert "old profile\n"))
          (set-file-modes file #o644)
          (magent-memory--write-profile
           plan "* Magent Managed Profile\n" "private note")
          (let* ((snapshots (magent-memory-snapshots-directory))
                 (backup (car (directory-files snapshots t "\\.org\\'"))))
            (should backup)
            (should (= (logand (file-modes memory-dir) #o777) #o700))
            (should (= (logand (file-modes snapshots) #o777) #o700))
            (should (= (logand (file-modes file) #o777) #o600))
            (should (= (logand (file-modes backup) #o777) #o600))))
      (delete-directory memory-dir t))))

(ert-deftest magent-profile-memory-test-memory-clear-deactivates-and-preserves-user-notes ()
  "Test memory clear writes inactive metadata and keeps local user notes."
  (let* ((root (file-name-as-directory
                (make-temp-file "magent-memory-root" t)))
         (memory-dir (file-name-as-directory
                      (make-temp-file "magent-memory-store" t)))
         (init-file (expand-file-name "init.el" root))
         (user-emacs-directory root)
         (user-init-file init-file)
         (early-init-file nil)
         (custom-file nil)
         (magent-memory-directory memory-dir)
         (magent-memory-use-llm nil)
         (magent-memory-open-after-write nil)
         (magent-memory-extra-scan-roots nil))
    (unwind-protect
        (progn
          (with-temp-file init-file
            (insert "(use-package project)\n"))
          (magent-memory-run
           'init :confirm-fn
           (lambda (_plan continue) (funcall continue t)))
          (with-temp-buffer
            (insert-file-contents (magent-memory-file))
            (goto-char (point-max))
            (insert "Keep minibuffer confirmations.\n")
            (write-region (point-min) (point-max) (magent-memory-file)))
          (magent-memory-run
           'clear :confirm-fn
           (lambda (_plan continue) (funcall continue t)))
          (let ((text (with-temp-buffer
                        (insert-file-contents (magent-memory-file))
                        (buffer-string))))
            (should (string-match-p
                     (regexp-quote "#+magent-active: false") text))
            (should (string-match-p
                     (regexp-quote "Keep minibuffer confirmations.") text))
            (should-not (magent-memory-active-p))
            (should-not (magent-memory-system-message "help with Emacs"))
            (should (directory-files
                     (magent-memory-snapshots-directory) nil "\\.org$"))))
      (delete-directory root t)
      (delete-directory memory-dir t))))

(ert-deftest magent-profile-memory-test-memory-outbound-injection-redacts-user-secret ()
  "Test prompt-time memory injection never emits a user-note secret."
  (let* ((memory-dir (file-name-as-directory
                      (make-temp-file "magent-memory-store" t)))
         (magent-memory-directory memory-dir)
         (magent-memory-enable-auto-injection t)
         (magent-memory-injection-max-chars 6000)
         (secret "sk-MemoryCanaryAbCdEf1234567890"))
    (unwind-protect
        (progn
          (with-temp-file (magent-memory-file)
            (insert "#+magent-active: true\n\n"
                    "* Magent Managed Profile\n"
                    "** Overview\nUse Emacs daily.\n"
                    "* User Notes\n"
                    "api-key: " secret "\n"))
          (cl-letf (((symbol-function 'magent-memory--relevant-request-p)
                     (lambda (&rest _) t)))
            (let ((message (magent-memory-system-message "Emacs api-key")))
              (should message)
              (should-not (string-match-p (regexp-quote secret) message))
              (should (string-match-p "<redacted:key>" message)))))
      (delete-directory memory-dir t))))

(ert-deftest magent-profile-memory-test-action-memory-init-uses-isolated-action-session ()
  "The memory M-x wrapper and slash spec share one isolated handler."
  (require 'magent-action-session)
  (let* ((magent-session-directory (make-temp-file "magent-sessions-" t))
         (magent-action-session-directory nil)
         (magent-action--registry nil)
         (magent-action--active-invocations (make-hash-table :test #'eq))
         (magent-action-session--active-invocations
          (make-hash-table :test #'equal))
         (magent-context-provider-functions nil)
         (magent-session--scoped-sessions (make-hash-table :test #'equal))
         (magent-session--current-scope 'global)
         (magent--current-session nil)
         (parent (magent-session-create :id "session-parent"))
         operation)
    (unwind-protect
        (progn
          (magent-session-install 'global parent)
          (magent-profile-memory-test--register-actions-only)
          (cl-letf (((symbol-function 'magent-runtime-ensure-initialized)
                     #'ignore)
                    ((symbol-function 'magent-runtime-context-scope)
                     (lambda () 'global))
                    ((symbol-function 'magent-runtime-prepare-context)
                     (lambda (&optional scope) (or scope 'global)))
                    ((symbol-function 'magent-session-save-deferred-for-session)
                     #'ignore)
                    ((symbol-function 'magent-memory-run)
                     (lambda (op &rest args)
                       (setq operation op)
                       (funcall (plist-get args :notify-fn)
                                "memory init progress")
                       (funcall (plist-get args :on-complete)
                                'completed
                                "memory init complete"))))
            (magent-action-run-memory-init))
          (let* ((files (magent-session-list-action-files "memory-init"))
                 (meta (magent-session--read-file-metadata-cached (car files)))
                 (spec (magent-action-get "memory-init" 'global 'interactive)))
            (should (eq operation 'init))
            (should (= (length files) 1))
            (should (equal (plist-get meta :kind) "action"))
            (should (equal (plist-get meta :status) "completed"))
            (should (equal (magent-action-spec-session-policy spec) 'isolated))
            (should (equal (magent-action-spec-exposure spec)
                           '(slash interactive)))
            (should (eq magent--current-session parent))))
      (delete-directory magent-session-directory t))))

(ert-deftest magent-profile-memory-test-action-memory-confirm-respects-bypass-permission ()
  "Memory command confirmation continues to honor permission bypass."
  (require 'magent-action-session)
  (let* ((magent-session-directory (make-temp-file "magent-sessions-" t))
         (magent-action-session-directory nil)
         (magent-bypass-permission t)
         (magent-session--scoped-sessions (make-hash-table :test #'equal))
         (spec (magent-action-spec-create
                :name "memory-init"
                :title "Initialize memory"
                :exposure '(interactive)
                :session-policy 'isolated
                :workflow #'magent-profile-memory-test--empty-action-workflow))
         (invocation (magent-action-invocation-create
                      :id "invocation-memory"
                      :spec spec
                      :origin-scope 'global))
         approved)
    (unwind-protect
        (progn
          (magent-action-session-initialize invocation)
          (cl-letf (((symbol-function 'magent-memory--interactive-confirm)
                     (lambda (&rest _)
                       (error "interactive confirmation must be bypassed"))))
            (funcall (magent-memory--action-confirm-provider invocation 'init)
                     nil (lambda (value) (setq approved value))))
          (should approved))
      (delete-directory magent-session-directory t))))

(ert-deftest magent-profile-memory-test-memory-system-message-selects-relevant-sections ()
  "Test prompt-time memory injection selects bounded relevant sections."
  (let* ((memory-dir (file-name-as-directory
                      (make-temp-file "magent-memory-store" t)))
         (magent-memory-directory memory-dir)
         (magent-memory-enable-auto-injection t)
         (magent-memory-max-injected-sections 2)
         (magent-memory-injection-max-chars 2000))
    (make-directory memory-dir t)
    (with-temp-file (magent-memory-file)
      (insert "#+magent-active: true\n")
      (insert "#+magent-generated-at: 2026-07-09T00:00:00+0800\n")
      (insert "#+magent-generated-at-float: 1783526400.000\n")
      (insert "#+magent-roots-json: []\n")
      (insert "#+magent-source-files-json: []\n\n")
      (insert "* Magent Managed Profile\n")
      (dolist (heading magent-memory--managed-section-headings)
        (insert "** " heading "\n")
        (insert "Body for " heading ".\n"))
      (insert "* User Notes\n")
      (insert "For magent completion work, prefer concise status updates.\n"))
    (let ((message (magent-memory-system-message
                    "debug magent completion workflow"
                    nil
                    "/tmp/magent")))
      (should message)
      (should (string-match-p
               (regexp-quote "* Magent Emacs Profile Memory")
               message))
      (should (string-match-p (regexp-quote "User Notes") message))
      (should (<= (length message) 2100)))
    (should-not
     (magent-memory-system-message
      "ignore magent memory and debug completion"
      nil
      "/tmp/magent"))
    (should-not
     (magent-memory-system-message
      "review this git config"
      nil
      "/tmp/project"))))

(ert-deftest magent-profile-memory-test-memory-prompt-declares-precedence ()
  "Test injected profile memory cannot silently override current state."
  (let ((prompt (magent-profile-memory--render-prompt
                 magent-profile-memory--injection-prompt
                 '((memory . "Stored preference.")))))
    (should (string-match-p "incomplete or stale" prompt))
    (should (string-match-p "live Emacs or repository state take precedence"
                            prompt))
    (should (string-suffix-p "Stored preference." prompt))))

(ert-deftest magent-profile-memory-test-memory-async-commit-preserves-latest-user-notes ()
  "Memory completion re-reads notes edited while the provider is sampling."
  (let* ((directory (make-temp-file "magent-memory-stale-" t))
         (magent-memory-directory directory)
         (magent-memory-open-after-write nil)
         (magent-memory-use-llm t)
         (magent-memory--operation-generation 0)
         (magent-memory--active-operation nil)
         callback)
    (unwind-protect
        (progn
          (with-temp-file (magent-memory-file)
            (insert "* Magent Managed Profile\n** Overview\nold\n\n* User Notes\nold note\n"))
          (cl-letf (((symbol-function 'magent-memory--build-source-bundle)
                     (lambda (_plan) "bundle"))
                    ((symbol-function 'magent-memory--summarize-with-llm)
                     (lambda (_plan _bundle fn)
                       (setq callback fn)
                       nil)))
            (magent-memory--write-from-plan
             'refresh (magent-memory--empty-plan) nil nil)
            (with-temp-file (magent-memory-file)
              (insert "* Magent Managed Profile\n** Overview\nold\n\n* User Notes\nlatest note\n"))
            (funcall callback
                     "* Magent Managed Profile\n** Overview\nnew\n"))
          (with-temp-buffer
            (insert-file-contents (magent-memory-file))
            (should (string-match-p "latest note" (buffer-string)))
            (should-not (string-match-p "old note" (buffer-string)))))
      (delete-directory directory t))))

(ert-deftest magent-profile-memory-test-memory-deleted-source-marks-profile-stale ()
  "A source recorded by memory generation is stale when later deleted."
  (let* ((directory (make-temp-file "magent-memory-source-missing-" t))
         (magent-memory-directory directory)
         (missing (expand-file-name "deleted.el" directory)))
    (unwind-protect
        (progn
          (with-temp-file (magent-memory-file) (insert "memory"))
          (cl-letf (((symbol-function 'magent-memory--metadata)
                     (lambda ()
                       '(("active" . "true")
                         ("generated-at-float" . "100"))))
                    ((symbol-function 'magent-memory--metadata-json-list)
                     (lambda (_metadata key)
                       (pcase key
                         ("roots-json" '("/root"))
                         ("source-files-json" (list missing)))))
                    ((symbol-function 'magent-memory-discover-roots)
                     (lambda () '("/root"))))
            (let ((status (magent-memory-stale-status)))
              (should (plist-get status :stale))
              (should (member (format "source missing: %s" missing)
                              (plist-get status :reasons))))))
      (delete-directory directory t))))

(ert-deftest magent-profile-memory-test-memory-new-generation-cancels-stale-request ()
  "A newer memory operation aborts and terminalizes the older generation."
  (let ((magent-memory-use-llm t)
        (magent-memory--operation-generation 0)
        (magent-memory--active-operation nil)
        callbacks aborted completions)
    (cl-letf (((symbol-function 'magent-memory--build-source-bundle)
               (lambda (_plan) "bundle"))
              ((symbol-function 'magent-memory--summarize-with-llm)
               (lambda (_plan _bundle fn)
                 (push fn callbacks)
                 (generate-new-buffer " *magent-memory-test*")))
              ((symbol-function 'magent-memory--abort-handle)
               (lambda (handle)
                 (push handle aborted)
                 (when (buffer-live-p handle) (kill-buffer handle))))
              ((symbol-function 'magent-memory--write-profile)
               (lambda (&rest _args) (list :file "/tmp/memory.org"))))
      (magent-memory--write-from-plan
       'refresh (magent-memory--empty-plan) nil
       (lambda (status _message) (push status completions)))
      (magent-memory--write-from-plan
       'refresh (magent-memory--empty-plan) nil
       (lambda (status _message) (push status completions)))
      (should (= (length aborted) 1))
      (should (memq 'cancelled completions))
      ;; The first callback is now stale and cannot complete or write.
      (funcall (cadr callbacks) "* Magent Managed Profile\n")
      (should-not (memq 'completed completions))
      (funcall (car callbacks) "* Magent Managed Profile\n")
      (should (memq 'completed completions)))))

(ert-deftest magent-profile-memory-test-memory-supersession-callback-cannot-clobber-newest-operation ()
  "A cancelled operation callback may reenter without leaking the middle run."
  (let ((magent-memory--operation-generation 0)
        (magent-memory--active-operation nil)
        newest
        middle-confirmed
        aborted
        completions)
    (cl-letf (((symbol-function 'magent-memory--abort-handle)
               (lambda (handle)
                 (when handle (push handle aborted)))))
      (let ((old
             (magent-memory--begin-operation
              'old
              (lambda (status _message)
                (push (list 'old status) completions)
                (setq newest
                      (magent-memory--begin-operation 'newest nil))))))
        (setf (magent-memory-operation-handle old) 'old-handle)
        (let ((middle
               (magent-memory-run
                'clear
                :confirm-fn
                (lambda (_plan _continue) (setq middle-confirmed t))
                :on-complete
                (lambda (status _message)
                  (push (list 'middle status) completions)))))
          (should (magent-memory-operation-completed-p old))
          (should (magent-memory-operation-completed-p middle))
          (should-not middle-confirmed)
          (should (eq magent-memory--active-operation newest))
          (should (magent-memory--operation-current-p newest))
          (should-not (magent-memory--operation-current-p middle))
          (should (equal aborted '(old-handle)))
          (should (member '(old cancelled) completions))
          (should (member '(middle cancelled) completions)))))))

(ert-deftest magent-profile-memory-test-memory-stale-clear-confirmation-cannot-write ()
  "A delayed clear approval cannot write after a newer operation supersedes it."
  (let ((magent-memory--operation-generation 0)
        (magent-memory--active-operation nil)
        old-continue new-continue (writes 0))
    (cl-letf (((symbol-function 'magent-memory--write-profile)
               (lambda (&rest _args)
                 (cl-incf writes)
                 (list :file "/tmp/memory.org"))))
      (magent-memory-run
       'clear :confirm-fn
       (lambda (_plan continue) (setq old-continue continue)))
      (magent-memory-run
       'clear :confirm-fn
       (lambda (_plan continue) (setq new-continue continue)))
      (funcall old-continue t)
      (should (= writes 0))
      (funcall new-continue t)
      (should (= writes 1)))))

(provide 'magent-profile-memory-test)
;;; magent-profile-memory-test.el ends here
