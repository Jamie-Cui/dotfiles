;;; magent-magit-test.el --- Tests for magent-magit -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Focused tests for Magent-backed commit-message behavior and Action
;; registration.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'json)

(add-to-list 'load-path
             (expand-file-name "../site-lisp"
                               (file-name-directory
                                (or load-file-name buffer-file-name))))

(require 'magent-magit)

(defun magent-magit-test--complete (iterator value)
  "Resume ITERATOR with a completed Step outcome containing VALUE."
  (iter-next
   iterator
   (magent-action-step-outcome-create :status 'completed :value value)))

(ert-deftest magent-magit-json-safe-string-replaces-raw-bytes ()
  (let* ((raw-byte (string (unibyte-char-to-multibyte #x80)))
         (safe (magent-magit--json-safe-string
                (concat "before" raw-byte "after"))))
    (should (equal safe "before�after"))
    (should (stringp (json-serialize (list :prompt safe))))))

(ert-deftest magent-magit-normalize-removes-inline-code-markers ()
  (should
   (equal
    (magent-magit--normalize-commit-message
     (concat "refactor(memory): Remove `status` command\n\n"
             "Drop the obsolete status display."))
    (concat "refactor(memory): Remove status command\n\n"
            "Drop the obsolete status display."))))

(ert-deftest magent-magit-normalize-unwraps-fenced-message ()
  (should
   (equal
    (magent-magit--normalize-commit-message
     "```text\nstyle(llm): Reformat skill entry\n```")
    "style(llm): Reformat skill entry")))

(ert-deftest magent-magit-extractor-does-not-return-partial-subject ()
  (should-not
   (magent-magit--extract-commit-subject
    "feat: Remove `magent-open-memory-status`")))

(ert-deftest magent-magit-extractor-finds-complete-subject-line ()
  (should
   (equal
    (magent-magit--extract-commit-subject
     "Suggested commit:\nrefactor(memory): Remove status command")
    "refactor(memory): Remove status command")))

(ert-deftest magent-magit-non-conventional-response-is-applied ()
  (let ((target (generate-new-buffer " *magent-magit-test-target*"))
        (invocation (magent-action-invocation-create :id "test-action"))
        (commit-message "Update staged changes."))
    (unwind-protect
        (progn
          (magent-magit--apply-commit-response
           target invocation default-directory "" commit-message)
          (with-current-buffer target
            (should (equal (string-trim-right (buffer-string))
                           commit-message))))
      (when (buffer-live-p target)
        (kill-buffer target)))))

(ert-deftest magent-magit-changed-buffer-opens-preview ()
  (let ((target (generate-new-buffer " *magent-magit-test-target*"))
        (invocation (magent-action-invocation-create :id "test-action"))
        preview)
    (unwind-protect
        (progn
          (with-current-buffer target
            (insert "user text"))
          (cl-letf (((symbol-function 'git-commit-buffer-message)
                     (lambda () (buffer-string)))
                    ((symbol-function 'magent-magit--show-commit-preview)
                     (lambda (_invocation _root message reason)
                       (setq preview (list message reason)))))
            (magent-magit--apply-commit-response
             target invocation default-directory "" "fix: Preserve text"))
          (with-current-buffer target
            (should (equal (buffer-string) "user text")))
          (should (equal (car preview) "fix: Preserve text"))
          (should (string-match-p "buffer changed" (cadr preview))))
      (when (buffer-live-p target)
        (kill-buffer target)))))

(ert-deftest magent-magit-long-subject-is-applied-with-log-message ()
  (let ((target (generate-new-buffer " *magent-magit-test-target*"))
        (invocation (magent-action-invocation-create :id "test-action"))
        (commit-message
         "feat(isync): Add mbsync configuration for Outlook mail mirroring")
        log-message)
    (unwind-protect
        (progn
          (cl-letf (((symbol-function 'message)
                     (lambda (format-string &rest args)
                       (setq log-message
                             (apply #'format format-string args)))))
            (magent-magit--apply-commit-response
             target invocation default-directory "" commit-message))
          (with-current-buffer target
            (should (equal (string-trim-right (buffer-string))
                           commit-message)))
          (should (string-match-p
                   "subject is 64 characters (maximum is 50)"
                   log-message)))
      (when (buffer-live-p target)
        (kill-buffer target)))))

(ert-deftest magent-magit-agent-preserves-request-policy ()
  (let ((agent (magent-magit--make-agent)))
    (should (equal (magent-agent-info-name agent) "magent-magit"))
    (should (eq (magent-agent-info-model agent) 'deepseek-v4-flash))
    (should (= (magent-agent-info-temperature agent) 0.1))
    (should (eq (magent-agent-info-effort agent) 'auto))
    (should (magent-agent-info-hidden agent))))

(ert-deftest magent-magit-callback-starters-return-no-cancel-function ()
  (let (commit-outcome diff-outcome)
    (cl-letf (((symbol-function 'magent-magit--apply-commit-response)
               (lambda (&rest _args) "commit applied"))
              ((symbol-function 'magent-magit--show-diff-explanation)
               (lambda (&rest _args) "diff displayed")))
      (should-not
       (magent-magit--apply-commit-step
        (lambda (status value)
          (setq commit-outcome (cons status value)))
        nil nil nil nil nil))
      (should-not
       (magent-magit--show-diff-step
        (lambda (status value)
          (setq diff-outcome (cons status value)))
        nil nil)))
    (should (equal commit-outcome '(completed . "commit applied")))
    (should (equal diff-outcome '(completed . "diff displayed")))))

(ert-deftest magent-magit-commit-workflow-uses-process-agent-callback-steps ()
  (with-temp-buffer
    (setq-local git-commit-mode t)
    (let* ((root (file-name-as-directory
                  (file-truename (magit-toplevel))))
           (git-dir (expand-file-name ".git/" root))
           (invocation
            (magent-action-invocation-create
             :id "test-action"
             :origin-buffer (current-buffer)
             :origin-directory git-dir))
           (iterator (magent-magit--commit-message-workflow invocation))
           step)
      (setq step (iter-next iterator))
      (should (eq (magent-action-step-type step) 'process))
      (should (equal (magent-action-step-name step) "Resolve repository"))
      (should (equal (plist-get (magent-action-step-options step) :directory)
                     root))
      (setq step (magent-magit-test--complete iterator (concat root "\n")))
      (should (equal (magent-action-step-name step) "Read current branch"))
      (setq step (magent-magit-test--complete iterator "main\n"))
      (should (equal (magent-action-step-name step) "Read staged summary"))
      (setq step (magent-magit-test--complete iterator "one file changed\n"))
      (should (equal (magent-action-step-name step) "Read staged patch"))
      (setq step (magent-magit-test--complete iterator "diff --git a/a b/a\n"))
      (should (eq (magent-action-step-type step) 'agent))
      (should (equal (magent-action-step-name step) "Write commit message"))
      (should (equal (plist-get (magent-action-step-options step) :agent)
                     "magent-magit"))
      (should-not (plist-get (magent-action-step-options step) :tools))
      (should
       (string-match-p
        (regexp-quote "Staged patch:\ndiff --git a/a b/a")
        (plist-get (magent-action-step-options step) :prompt)))
      (setq step
            (magent-magit-test--complete iterator "fix: Preserve behavior"))
      (should (eq (magent-action-step-type step) 'callback))
      (should (equal (magent-action-step-name step) "Insert commit message")))))

(ert-deftest magent-magit-find-commit-buffer-recognizes-minor-mode ()
  (let ((commit-buffer (generate-new-buffer " *magent-magit-test-commit*"))
        (ordinary-buffer (generate-new-buffer " *magent-magit-test-ordinary*"))
        (repo-root (file-name-as-directory
                    (file-truename default-directory))))
    (unwind-protect
        (progn
          (with-current-buffer commit-buffer
            (fundamental-mode)
            (setq-local git-commit-mode t))
          (with-current-buffer ordinary-buffer
            (setq-local major-mode 'git-commit-mode))
          (cl-letf (((symbol-function 'buffer-list)
                     (lambda (&optional _frame)
                       (list ordinary-buffer commit-buffer)))
                    ((symbol-function 'magit-toplevel)
                     (lambda () repo-root)))
            (should (eq (magent-magit--find-commit-buffer repo-root)
                        commit-buffer))))
      (when (buffer-live-p commit-buffer)
        (kill-buffer commit-buffer))
      (when (buffer-live-p ordinary-buffer)
        (kill-buffer ordinary-buffer)))))

(ert-deftest magent-magit-diff-workflow-uses-agent-and-callback-steps ()
  (let* ((snapshot '(:repo-root "/repo/"
                     :repo-name "repo"
                     :branch "main"
                     :scope hunk
                     :diff-type staged
                     :region-derived nil
                     :text "@@ -1 +1 @@"))
         (invocation (magent-action-invocation-create
                      :id "test-action"
                      :origin-buffer (current-buffer)))
         iterator
         step)
    (cl-letf (((symbol-function 'magent-magit--capture-diff-snapshot)
               (lambda (_buffer) snapshot)))
      (setq iterator (magent-magit--diff-explain-workflow invocation))
      (setq step (iter-next iterator))
      (should (eq (magent-action-step-type step) 'agent))
      (should (equal (magent-action-step-name step) "Explain diff"))
      (should (equal (plist-get (magent-action-step-options step) :agent)
                     "magent-magit"))
      (should-not (plist-get (magent-action-step-options step) :tools))
      (setq step (magent-magit-test--complete iterator "The diff changes A."))
      (should (eq (magent-action-step-type step) 'callback))
      (should (equal (magent-action-step-name step)
                     "Display diff explanation")))))

(ert-deftest magent-magit-registers-interactive-isolated-actions ()
  (let ((magent-action--registry nil)
        (magent-action--sequence 0)
        (magent-action-registry-changed-hook nil))
    (cl-letf (((symbol-function 'magent-agent-registry-ensure-initialized)
               #'ignore)
              ((symbol-function 'magent-agent-registry-register)
               #'identity))
      (magent-magit-register)
      (dolist (name '("magit-commit-message" "magit-diff-explain"))
        (let ((spec (magent-action-get name 'global 'interactive)))
          (should spec)
          (should (eq (magent-action-spec-session-policy spec) 'isolated))
          (should (eq (magent-action-spec-source-layer spec) 'user))
          (should (equal (magent-action-spec-exposure spec)
                         '(interactive))))))))

(ert-deftest magent-magit-prompt-includes-classification-guardrails ()
  (should
   (string-match-p
    (regexp-quote "Removing a command is not a feat")
    magent-magit--default-commit-prompt))
  (should
   (string-match-p
    (regexp-quote "A whitespace-only or line-wrapping change is style")
    magent-magit--default-commit-prompt))
  (should-not
   (string-match-p
    (regexp-quote "Capitalize the first word of the description")
    magent-magit--default-commit-prompt)))

(provide 'magent-magit-test)
;;; magent-magit-test.el ends here
