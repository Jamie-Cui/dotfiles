;;; magent-forge-test.el --- Tests for Forge PR drafting -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; Offline tests with real Git ranges and Forge's actual post format.
;;; Code:

(require 'ert)
(require 'cl-lib)
(add-to-list 'load-path
             (expand-file-name "../site-lisp"
                               (file-name-directory (or load-file-name buffer-file-name))))
(require 'magent-forge)

(defconst magent-forge-test--response
  "{\"title\":\"feat(forge): Draft pull requests\",\"body\":\"## Summary\\nAdd drafting.\\n\\n## Testing\\nNot run (not provided).\"}")

(defmacro magent-forge-test--with-draft (&rest body)
  "Run BODY in a fresh Forge PR buffer with a template."
  (declare (indent 0) (debug t))
  `(with-temp-buffer
     (let ((forge-post-mode-hook nil)) (forge-post-mode))
     (setq-local forge-edit-post-action 'new-pullreq
                 forge--buffer-head-branch "fork/topic"
                 forge--buffer-base-branch "origin/main")
     (insert "# Original title\n\n## Summary\n\n## Testing\n- [ ] Verified\n")
     (magent-forge-mode 1)
     ,@body))

(ert-deftest magent-forge-valid-conventional-titles ()
  (dolist (title '("feat: Add PR drafting" "fix(forge): Keep user edits"
                   "refactor(api)!: Remove old endpoint" "feat!: Change API"
                   "docs(emacs/forge): Document drafting" "chore: X"))
    (should (equal (magent-forge--validate-title title) title))))

(ert-deftest magent-forge-rejects-invalid-titles ()
  (dolist (title '(nil 1 "" "Add drafts" "Feat: Add drafts" "fix(): Bug"
                   "fix(Forge): Bug" "fix: " "feat:  " "feat:  Extra space"
                   "fix: Message\nSecond line" "fix: Bad\rline"
                   "feat: Description " "feat!:Missing space"))
    (should-error (magent-forge--validate-title title) :type 'user-error)))

(ert-deftest magent-forge-parses-json-to-forge-format ()
  (dolist (response (list magent-forge-test--response
                         (concat "```json\n" magent-forge-test--response "\n```")))
    (magent-forge-test--with-draft
      (erase-buffer)
      (insert (magent-forge--parse-response response))
      (should (equal (car (forge--post-buffer-text))
                     "feat(forge): Draft pull requests"))
      (should (string-match-p "## Testing" (cdr (forge--post-buffer-text)))))))

(ert-deftest magent-forge-rejects-malformed-response-without-editing ()
  (dolist (response '("not JSON" "{}" "[]" "null"
                      "{\"title\":\"Add PR\",\"body\":\"Text\"}"
                      "{\"title\":\"feat: Add PR\",\"body\":\" \"}"
                      "{\"title\":\"feat: Add PR\",\"body\":false}"))
    (magent-forge-test--with-draft
      (let ((before (buffer-string)) outcome)
        (magent-forge--apply-step
         (lambda (status _value) (setq outcome status))
         (current-buffer) nil nil response)
        (should (eq outcome 'failed))
        (should (equal before (buffer-string)))))))

(ert-deftest magent-forge-bounds-and-sanitizes-context ()
  (let ((magent-forge-max-context-chars 4))
    (should (equal (magent-forge--bounded-text "abcdef")
                   "abcd\n[Truncated by magent-forge]\n")))
  (should (equal (magent-forge--bounded-text
                  (string (unibyte-char-to-multibyte #x80) #xd800))
                 "��")))

(ert-deftest magent-forge-inserts-only-into-unchanged-owned-draft ()
  (magent-forge-test--with-draft
    (let* ((invocation (magent-action-invocation-create :status 'active))
           (magent-forge--active-invocation invocation)
           (snapshot (list :directory default-directory
                           :source "fork/topic" :base "origin/main"
                           :head-oid "head" :base-oid "base"
                           :tick (buffer-chars-modified-tick))))
      (cl-letf (((symbol-function 'magit-toplevel) (lambda () default-directory))
                ((symbol-function 'magit-rev-parse)
                 (lambda (&rest args)
                   (if (equal (car (last args)) "fork/topic^{commit}") "head" "base"))))
        (magent-forge--apply-response
         (current-buffer) invocation snapshot magent-forge-test--response)
        (should (equal (car (forge--post-buffer-text)) "feat(forge): Draft pull requests"))))))

(ert-deftest magent-forge-late-responses-preserve-edits-and-ownership ()
  (dolist (change '(edit undo-edit refs selection ownership cancelled read-only mode))
    (magent-forge-test--with-draft
      (let* ((invocation (magent-action-invocation-create :status 'active))
             (magent-forge--active-invocation invocation)
             (snapshot (list :directory default-directory
                             :source "fork/topic" :base "origin/main"
                             :head-oid "head" :base-oid "base"
                             :tick (buffer-chars-modified-tick)))
             preview)
        (pcase change
          ('edit (insert "User edit"))
          ('undo-edit (insert "x") (delete-char -1))
          ('selection (setq forge--buffer-head-branch "fork/other"))
          ('ownership (setq magent-forge--active-invocation nil))
          ('cancelled (setf (magent-action-invocation-status invocation) 'cancelled))
          ('read-only (setq buffer-read-only t))
          ('mode (setq magent-forge-mode nil)))
        (let ((before (buffer-string)))
          (cl-letf (((symbol-function 'magit-toplevel) (lambda () default-directory))
                    ((symbol-function 'magit-rev-parse)
                     (lambda (&rest args)
                       (if (eq change 'refs) "moved"
                         (if (equal (car (last args)) "fork/topic^{commit}") "head" "base"))))
                    ((symbol-function 'magent-forge--preview)
                     (lambda (text _reason) (setq preview text))))
            (magent-forge--apply-response
             (current-buffer) invocation snapshot magent-forge-test--response)
            (should preview)
            (should (equal before (buffer-string)))))
        (setq magent-forge--active-invocation nil)))))

(ert-deftest magent-forge-closed-buffer-opens-preview ()
  (let ((buffer (generate-new-buffer " *magent-forge-closed*")) preview)
    (kill-buffer buffer)
    (cl-letf (((symbol-function 'magent-forge--preview)
               (lambda (text _reason) (setq preview text))))
      (magent-forge--apply-response buffer nil nil magent-forge-test--response)
      (should preview))))

(ert-deftest magent-forge-setup-only-generates-new-pullreqs ()
  (dolist (action '(new-pullreq new-issue new-discussion reply edit))
    (magent-forge-test--with-draft
      (magent-forge-mode -1)
      (setq forge-edit-post-action action)
      (let ((magent-forge-auto-generate t) generated)
        (cl-letf (((symbol-function 'magent-forge-generate)
                   (lambda () (setq generated t))))
          (magent-forge--setup-h)
          (should (eq (not (null generated)) (eq action 'new-pullreq)))
          (should (eq (not (null magent-forge-mode)) (eq action 'new-pullreq))))))))

(ert-deftest magent-forge-saved-draft-and-manual-setting-skip-auto ()
  (let ((file (make-temp-file "magent-forge-draft-" nil nil "# Saved PR\n")))
    (unwind-protect
        (dolist (saved '(t nil))
          (magent-forge-test--with-draft
            (setq-local buffer-file-name (and saved file))
            (let ((magent-forge-auto-generate saved) generated)
              (cl-letf (((symbol-function 'magent-forge-generate)
                         (lambda () (setq generated t))))
                (magent-forge--setup-h)
                (should-not generated)
                (should magent-forge-mode)))
            (set-buffer-modified-p nil)))
      (delete-file file))))

(ert-deftest magent-forge-submit-guard-rejects-invalid-and-leaves-issues-alone ()
  (magent-forge-test--with-draft
    (let (submitted)
      (cl-letf (((symbol-function 'forge-post-submit)
                 (lambda () (setq submitted t))))
        (advice-add 'forge-post-submit :before #'magent-forge--before-submit-a)
        (should-error (forge-post-submit) :type 'user-error)
        (should-not submitted)
        (setq forge-edit-post-action 'new-issue)
        (forge-post-submit)
        (should submitted)
        (setq forge-edit-post-action 'new-pullreq submitted nil)
        (erase-buffer)
        (insert "# fix(forge)!: Preserve user edits\n\nBody\n")
        (forge-post-submit)
        (should submitted)))))

(ert-deftest magent-forge-kill-and-disable-cancel-owned-invocation ()
  (dolist (operation '(kill disable))
    ;; `with-temp-buffer' inhibits kill hooks; use an ordinary buffer here.
    (let ((buffer (generate-new-buffer " *magent-forge-cancel*")))
      (unwind-protect
          (with-current-buffer buffer
            (magent-forge-mode 1)
            (let* ((invocation (magent-action-invocation-create :status 'active))
                   cancelled)
              (setq magent-forge--active-invocation invocation)
              (cl-letf (((symbol-function 'magent-action-cancel)
                         (lambda (value _reason)
                           (setq cancelled value)
                           (setf (magent-action-invocation-status value) 'cancelled))))
                (if (eq operation 'kill) (kill-buffer buffer)
                  (magent-forge-mode -1))
                (should (eq invocation cancelled)))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(defun magent-forge-test--git (&rest args)
  "Run Git ARGS in the current directory, returning output or signaling."
  (with-temp-buffer
    (unless (zerop (apply #'process-file "git" nil t nil args))
      (error "Git failed: %S: %s" args (buffer-string)))
    (string-trim-right (buffer-string))))

(ert-deftest magent-forge-workflow-uses-selected-refs-and-merge-base ()
  (let* ((directory (make-temp-file "magent-forge-git-" t))
         (default-directory (file-name-as-directory directory))
         (process-environment (append '("GIT_CONFIG_NOSYSTEM=1" "GIT_CONFIG_GLOBAL=/dev/null")
                                      process-environment)))
    (unwind-protect
        (progn
          (magent-forge-test--git "init" "-b" "main")
          (magent-forge-test--git "config" "user.name" "Test")
          (magent-forge-test--git "config" "user.email" "test@example.invalid")
          (magent-forge-test--git "commit" "--allow-empty" "-m" "Initial")
          (magent-forge-test--git "switch" "-c" "topic")
          (write-region "FEATURE_EVIDENCE\n" nil "feature.txt" nil 'silent)
          (magent-forge-test--git "add" "feature.txt")
          (magent-forge-test--git "commit" "-m" "feat: Add feature")
          (magent-forge-test--git "update-ref" "refs/remotes/fork/topic" "HEAD")
          (magent-forge-test--git "switch" "main")
          (write-region "BASE_ONLY_EVIDENCE\n" nil "base.txt" nil 'silent)
          (magent-forge-test--git "add" "base.txt")
          (magent-forge-test--git "commit" "-m" "chore: Advance base")
          (magent-forge-test--git "update-ref" "refs/remotes/origin/main" "HEAD")
          (write-region "UNCOMMITTED_EVIDENCE\n" nil "dirty.txt" nil 'silent)
          (magent-forge-test--git "add" "dirty.txt")
          (magent-forge-test--with-draft
            (let* ((invocation (magent-action-invocation-create
                                :status 'active :origin-buffer (current-buffer)))
                   (iterator (magent-forge--workflow invocation))
                   (step (iter-next iterator)) prompt)
              (while (eq (magent-action-step-type step) 'process)
                (let* ((options (magent-action-step-options step))
                       (argv (plist-get options :argv))
                       (output (apply #'magent-forge-test--git (cdr argv))))
                  (setq step (iter-next iterator
                                        (magent-action-step-outcome-create
                                         :status 'completed :value output)))))
              (should (eq (magent-action-step-type step) 'agent))
              (should-not (plist-get (magent-action-step-options step) :tools))
              (setq prompt (plist-get (magent-action-step-options step) :prompt))
              (should (string-match-p "FEATURE_EVIDENCE" prompt))
              (should (string-match-p "Verified" prompt))
              (should-not (string-match-p "BASE_ONLY_EVIDENCE" prompt))
              (should-not (string-match-p "UNCOMMITTED_EVIDENCE" prompt))
              (setq step (iter-next iterator (magent-action-step-outcome-create
                                              :status 'completed
                                              :value magent-forge-test--response)))
              (should (eq (magent-action-step-type step) 'callback))
              (let (outcome)
                (funcall (plist-get (magent-action-step-options step) :start)
                         (lambda (status value)
                           (setq outcome (magent-action-step-outcome-create
                                          :status status :value value))))
                (should (eq (magent-action-step-outcome-status outcome) 'completed))
                (should (equal (condition-case end
                                   (iter-next iterator outcome)
                                 (iter-end-of-sequence (cdr end)))
                               "Inserted the PR draft")))
              (should-not magent-forge--active-invocation)
              (should (equal (car (forge--post-buffer-text))
                             "feat(forge): Draft pull requests"))))
          (should (string-match-p "dirty.txt" (magent-forge-test--git "diff" "--cached" "--name-only"))))
      (delete-directory directory t))))

(provide 'magent-forge-test)
;;; magent-forge-test.el ends here
