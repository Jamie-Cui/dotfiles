;;; magent-submit-pr-test.el --- Tests for magent-submit-pr -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Focused tests for the /submit-pr Action Workflow and parsers.

;;; Code:

(require 'ert)

(add-to-list 'load-path
             (expand-file-name "../site-lisp"
                               (file-name-directory
                                (or load-file-name buffer-file-name))))

(require 'magent-submit-pr)

(defun magent-submit-pr-test--invocation (&rest args)
  "Return an Action Invocation initialized with ARGS."
  (apply #'magent-action-invocation-create args))

(defun magent-submit-pr-test--complete (iterator value)
  "Resume ITERATOR after completing its current Step with VALUE."
  (iter-next
   iterator
   (magent-action-step-outcome-create :status 'completed :value value)))

(defun magent-submit-pr-test--step-argv (step)
  "Return the process argv stored in STEP."
  (plist-get (magent-action-step-options step) :argv))

(ert-deftest magent-submit-pr-test-extracts-subject-line ()
  (should
   (equal (magent-submit-pr--extract-subject
           "Suggested subject:\nrefactor(llm): simplify submit workflow\n")
          "refactor(llm): simplify submit workflow")))

(ert-deftest magent-submit-pr-test-rejects-invalid-or-long-subject ()
  (should-error
   (magent-submit-pr--extract-subject "Simplify submit workflow"))
  (should-error
   (magent-submit-pr--extract-subject
    (concat "refactor(llm): " (make-string 121 ?x))))
  (should-error
   (magent-submit-pr--extract-subject "feat(Invalid): uppercase scope")))

(ert-deftest magent-submit-pr-test-normalizes-pr-body ()
  (should (equal (magent-submit-pr--normalize-body "  ## Summary\nDone.  ")
                 "## Summary\nDone."))
  (should
   (equal (magent-submit-pr--normalize-body
           "```markdown\n## Summary\nDone.\n```")
          "## Summary\nDone."))
  (should-error (magent-submit-pr--normalize-body "  "))
  (should-error (magent-submit-pr--normalize-body "```markdown\n```")))

(ert-deftest magent-submit-pr-test-extracts-pr-url ()
  (should
   (equal (magent-submit-pr--extract-url
           "Created pull request: https://github.com/example/repo/pull/42\n")
          "https://github.com/example/repo/pull/42"))
  (should-error (magent-submit-pr--extract-url "Pull request created")))

(ert-deftest magent-submit-pr-test-yields-new-branch-workflow-in-order ()
  (let* ((root (file-name-as-directory
                (file-truename temporary-file-directory)))
         (invocation
          (magent-submit-pr-test--invocation
           :origin-directory root
           :argument "Keep compatibility"))
         (iterator (magent-submit-pr--workflow invocation))
         (step (iter-next iterator))
         branch
         result)
    (should (eq (magent-action-step-type step) 'process))
    (should (equal (magent-action-step-name step) "Resolve repository"))
    (should
     (equal (magent-submit-pr-test--step-argv step)
            (list "git" "-C" root "rev-parse" "--show-toplevel")))

    (setq step (magent-submit-pr-test--complete iterator root))
    (should
     (equal (magent-submit-pr-test--step-argv step)
            '("git" "branch" "--show-current")))

    (setq step (magent-submit-pr-test--complete iterator "main\n"))
    (should
     (equal (magent-submit-pr-test--step-argv step)
            '("git" "status" "--porcelain=v1" "--untracked-files=all")))

    (setq step
          (magent-submit-pr-test--complete
           iterator " M lisp/modules/llm.el\n")
          branch (car (last (magent-submit-pr-test--step-argv step))))
    (should
     (string-match-p
      "\\`submit-pr/[0-9]\\{8\\}-[0-9]\\{6\\}\\'"
      branch))
    (should
     (equal (magent-submit-pr-test--step-argv step)
            (list "git" "switch" "-c" branch)))

    (setq step (magent-submit-pr-test--complete iterator ""))
    (should (equal (magent-submit-pr-test--step-argv step)
                   '("git" "add" "-A")))

    (setq step (magent-submit-pr-test--complete iterator ""))
    (should
     (equal (magent-submit-pr-test--step-argv step)
            '("git" "diff" "--cached" "--name-only")))

    (setq step
          (magent-submit-pr-test--complete iterator
                                           "lisp/modules/llm.el\n"))
    (should (eq (magent-action-step-type step) 'agent))
    (should (equal (magent-action-step-name step) "Write commit subject"))
    (should (equal (plist-get (magent-action-step-options step) :tools)
                   '(bash)))
    (should
     (string-match-p
      "Optional context: Keep compatibility"
      (plist-get (magent-action-step-options step) :prompt)))

    (setq step
          (magent-submit-pr-test--complete
           iterator "refactor(llm): simplify submit workflow"))
    (should
     (equal (magent-submit-pr-test--step-argv step)
            '("git" "commit" "-m"
              "refactor(llm): simplify submit workflow")))

    (setq step (magent-submit-pr-test--complete iterator ""))
    (should (equal (magent-submit-pr-test--step-argv step)
                   '("git" "rev-parse" "HEAD")))

    (setq step (magent-submit-pr-test--complete iterator "deadbeef\n"))
    (should
     (equal (magent-submit-pr-test--step-argv step)
            (list "git" "push" "--set-upstream" "origin" branch)))

    (setq step (magent-submit-pr-test--complete iterator ""))
    (should (eq (magent-action-step-type step) 'agent))
    (should (equal (magent-action-step-name step) "Write pull request"))
    (should (equal (plist-get (magent-action-step-options step) :tools)
                   '(bash)))

    (setq step
          (magent-submit-pr-test--complete
           iterator "```markdown\n## Summary\nSimplified.\n```"))
    (should
     (equal (magent-submit-pr-test--step-argv step)
            (list "gh" "pr" "create"
                  "--head" branch
                  "--title" "refactor(llm): simplify submit workflow"
                  "--body" "## Summary\nSimplified.")))
    (should-not (plist-get (magent-action-step-options step)
                           :record-command))

    (condition-case condition
        (magent-submit-pr-test--complete
         iterator "https://github.com/example/repo/pull/42\n")
      (iter-end-of-sequence
       (setq result (cdr condition))))
    (should (string-match-p "Commit: deadbeef" result))
    (should (string-match-p "pull/42" result))))

(ert-deftest magent-submit-pr-test-yields-reused-submit-branch ()
  (let* ((root (file-name-as-directory temporary-file-directory))
         (iterator
          (magent-submit-pr--workflow
           (magent-submit-pr-test--invocation :origin-directory root)))
         (step (iter-next iterator)))
    (setq step (magent-submit-pr-test--complete iterator root))
    (setq step
          (magent-submit-pr-test--complete
           iterator "submit-pr/existing\n"))
    (setq step
          (magent-submit-pr-test--complete iterator " M file.el\n"))
    (should (equal (magent-action-step-name step)
                   "Reuse pull request branch"))
    (should
     (equal (magent-submit-pr-test--step-argv step)
            '("git" "switch" "submit-pr/existing")))))

(ert-deftest magent-submit-pr-test-rejects-empty-change-sets ()
  (let* ((root (file-name-as-directory temporary-file-directory))
         (iterator
          (magent-submit-pr--workflow
           (magent-submit-pr-test--invocation :origin-directory root))))
    (iter-next iterator)
    (magent-submit-pr-test--complete iterator root)
    (magent-submit-pr-test--complete iterator "main\n")
    (should-error (magent-submit-pr-test--complete iterator "") :type 'error))
  (let* ((root (file-name-as-directory temporary-file-directory))
         (iterator
          (magent-submit-pr--workflow
           (magent-submit-pr-test--invocation :origin-directory root))))
    (iter-next iterator)
    (magent-submit-pr-test--complete iterator root)
    (magent-submit-pr-test--complete iterator "main\n")
    (magent-submit-pr-test--complete iterator " M file.el\n")
    (magent-submit-pr-test--complete iterator "")
    (magent-submit-pr-test--complete iterator "")
    (should-error
     (magent-submit-pr-test--complete iterator " \n\t")
     :type 'error)))

(ert-deftest magent-submit-pr-test-reports-step-failure-with-progress ()
  (let* ((root (file-name-as-directory temporary-file-directory))
         (iterator
          (magent-submit-pr--workflow
           (magent-submit-pr-test--invocation :origin-directory root)))
         condition)
    (iter-next iterator)
    (condition-case err
        (iter-next
         iterator
         (magent-action-step-outcome-create
          :status 'failed
          :condition '(magent-action-process-error "git failed" result)))
      (magent-action-process-error (setq condition err)))
    (should
     (string-match-p
      "Finish work stopped:"
      (error-message-string condition)))
    (should
     (string-match-p
      "git failed"
      (error-message-string condition)))
    (should
     (string-match-p
      "Branch: not created"
      (error-message-string condition)))))

(ert-deftest magent-submit-pr-test-registers-public-action-contract ()
  (let ((magent-action--registry nil)
        (magent-action--sequence 0)
        (magent-action-registry-changed-hook nil))
    (let ((spec (magent-submit-pr-register)))
      (should (equal (magent-action-spec-name spec) "submit-pr"))
      (should (eq (magent-action-spec-workflow spec)
                  #'magent-submit-pr--workflow))
      (should (eq (magent-action-spec-session-policy spec) 'isolated))
      (should (eq (magent-action-spec-source-layer spec) 'user))
      (should (equal (magent-action-spec-requires spec) '(subr-x))))))

(provide 'magent-submit-pr-test)
;;; magent-submit-pr-test.el ends here
