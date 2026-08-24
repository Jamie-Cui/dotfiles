;;; magent-repo-summary-test.el --- Tests for repository summary Action -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Focused tests for the personal /summarize Action and its Org-roam writer.

;;; Code:

(require 'ert)

(add-to-list 'load-path
             (expand-file-name "../site-lisp"
                               (file-name-directory
                                (or load-file-name buffer-file-name))))

(require 'magent-repo-summary-action)

(defun magent-repo-summary-test--make-repository ()
  "Create and return a temporary Git repository with one commit."
  (let ((directory (make-temp-file "magent-repo-summary-repository-" t)))
    (unless (zerop (process-file "git" nil nil nil
                                 "-C" directory "init" "--quiet"))
      (error "Could not initialize test Git repository"))
    (with-temp-file (expand-file-name "README.md" directory)
      (insert "# Test repository\n"))
    (unless
        (and
         (zerop (process-file "git" nil nil nil
                              "-C" directory "add" "README.md"))
         (zerop
          (process-file
           "git" nil nil nil "-C" directory
           "-c" "user.name=Magent Tests"
           "-c" "user.email=magent@example.invalid"
           "commit" "--quiet" "-m" "Initial commit")))
      (delete-directory directory t)
      (error "Could not commit test Git repository"))
    directory))

(defun magent-repo-summary-test--invocation (directory &optional argument)
  "Return an Action invocation rooted at DIRECTORY with ARGUMENT."
  (magent-action-invocation-create
   :origin-directory directory
   :argument (or argument "")))

(defun magent-repo-summary-test--complete (iterator value)
  "Resume ITERATOR after completing its current Step with VALUE."
  (iter-next
   iterator
   (magent-action-step-outcome-create :status 'completed :value value)))

(ert-deftest magent-repo-summary-test-parses-structured-agent-output ()
  (should
   (equal
    (magent-repo-summary--parse-agent-output
     "SUMMARY_FILES_JSON: []\n---ORG---\n** Architecture\nSmall."
     'full)
    '(:content "** Architecture\nSmall." :scope-files nil)))
  (should
   (equal
    (magent-repo-summary--parse-agent-output
     (concat "SUMMARY_FILES_JSON: [\"lisp/a.el\", \"test/a-test.el\"]\n"
             "---ORG---\n*** Parser\nFocused.")
     'scoped)
    '(:content "*** Parser\nFocused."
      :scope-files ("lisp/a.el" "test/a-test.el"))))
  (should-error
   (magent-repo-summary--parse-agent-output "** Missing envelope" 'full))
  (should-error
   (magent-repo-summary--parse-agent-output
    "SUMMARY_FILES_JSON: [1]\n---ORG---\n*** Invalid\nValue"
    'scoped))
  (should-error
   (magent-repo-summary--parse-agent-output
    "SUMMARY_FILES_JSON: [\"README.md\"]\n---ORG---\n** Invalid\nValue"
    'full)))

(ert-deftest magent-repo-summary-test-yields-isolated-read-only-workflow ()
  (let* ((repository (magent-repo-summary-test--make-repository))
         (iterator
          (magent-repo-summary--workflow
           (magent-repo-summary-test--invocation repository)))
         (step (iter-next iterator)))
    (unwind-protect
        (progn
          (should (eq (magent-action-step-type step) 'agent))
          (should (equal (magent-action-step-name step) "Summarize repository"))
          (should
           (equal (plist-get (magent-action-step-options step) :tools)
                  '(read_file grep glob read_tool_output)))
          (should
           (string-match-p
            "Mode: full"
            (plist-get (magent-action-step-options step) :prompt)))
          (setq step
                (magent-repo-summary-test--complete
                 iterator
                 "SUMMARY_FILES_JSON: []\n---ORG---\n** Purpose\nTest."))
          (should (eq (magent-action-step-type step) 'callback))
          (should (equal (magent-action-step-name step)
                         "Write Org-roam summary"))
          (let (result)
            (condition-case condition
                (magent-repo-summary-test--complete
                 iterator '(:path "/tmp/summary.org" :created t))
              (iter-end-of-sequence (setq result (cdr condition))))
            (should (equal result
                           "Created repository summary: /tmp/summary.org"))))
      (ignore-errors (iter-close iterator))
      (delete-directory repository t))))

(ert-deftest magent-repo-summary-test-yields-scoped-envelope-contract ()
  (let* ((repository (magent-repo-summary-test--make-repository))
         (iterator
          (magent-repo-summary--workflow
           (magent-repo-summary-test--invocation repository "parser layer")))
         (step (iter-next iterator))
         (prompt (plist-get (magent-action-step-options step) :prompt)))
    (unwind-protect
        (progn
          (should (string-match-p "Mode: scoped" prompt))
          (should (string-match-p "Requested scope: parser layer" prompt))
          (should (string-match-p "Use \\*\\*\\* or deeper headings" prompt)))
      (iter-close iterator)
      (delete-directory repository t))))

(ert-deftest magent-repo-summary-test-writes-and-updates-one-org-note ()
  (require 'org-element)
  (let* ((repository (magent-repo-summary-test--make-repository))
         (roam-directory (make-temp-file "magent-repo-summary-roam-" t))
         (magent-org-roam-directory roam-directory)
         first-path first-id)
    (cl-letf (((symbol-function
                'magent-repo-summary--org-roam-capture-available-p)
               #'ignore))
      (unwind-protect
          (progn
            (setq first-path
                  (plist-get
                   (magent-repo-summary-write
                    repository "full"
                    "The repository exists for testing.\n\n** Architecture\nSmall.")
                   :path))
            (should
             (string-match-p
              "\\`[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}t[0-9]\\{4\\}\\.org\\'"
              (file-name-nondirectory first-path)))
            (with-temp-buffer
              (insert-file-contents first-path)
              (org-mode)
              (goto-char (point-min))
              (setq first-id (org-id-get))
              (should (stringp first-id))
              (should (re-search-forward "^:REPO_PATH: " nil t))
              (should (re-search-forward
                       "^:LAST_ANALYZED_COMMIT: [0-9a-f]+$" nil t))
              (should (org-element-parse-buffer)))
            (magent-repo-summary-write
             repository "scoped" "*** Parser\nFirst."
             "parser" '("src/parser.el" "test/parser-test.el"))
            (magent-repo-summary-write
             repository "scoped" "*** Parser\nUpdated."
             "parser" '("src/parser.el" "test/parser-test.el"))
            (magent-repo-summary-write
             repository "full" "** Purpose\nUpdated full summary.")
            (should (= (length (directory-files roam-directory nil "\\.org\\'"))
                       1))
            (with-temp-buffer
              (insert-file-contents first-path)
              (org-mode)
              (goto-char (point-min))
              (should (equal (org-id-get) first-id))
              (should (= (how-many "^:ID:" (point-min) (point-max)) 1))
              (should (re-search-forward "^\\* Repository Summary$" nil t))
              (should (re-search-forward "Updated full summary" nil t))
              (should (re-search-forward "^\\* Scoped Summaries$" nil t))
              (should (= (how-many "^:SUMMARY_SCOPE_ID:"
                                   (point-min) (point-max))
                         1))
              (should (re-search-forward "Updated" nil t))
              (should-not (re-search-forward "First" nil t))))
        (delete-directory repository t)
        (delete-directory roam-directory t)))))

(ert-deftest magent-repo-summary-test-callback-persists-agent-result ()
  (let* ((repository (magent-repo-summary-test--make-repository))
         (roam-directory (make-temp-file "magent-repo-summary-callback-" t))
         (magent-org-roam-directory roam-directory)
         status value)
    (cl-letf (((symbol-function
                'magent-repo-summary--org-roam-capture-available-p)
               #'ignore))
      (unwind-protect
          (progn
            (magent-repo-summary--write-step
             (lambda (step-status step-value)
               (setq status step-status value step-value))
             repository 'full
             '(:content "** Purpose\nCallback." :scope-files nil) "")
            (should (eq status 'completed))
            (should (file-exists-p (plist-get value :path))))
        (delete-directory repository t)
        (delete-directory roam-directory t)))))

(ert-deftest magent-repo-summary-test-rejects-invalid-destinations ()
  (let ((repository (magent-repo-summary-test--make-repository))
        (plain-directory (make-temp-file "magent-repo-summary-plain-" t)))
    (unwind-protect
        (progn
          (let ((magent-org-roam-directory nil)
                (org-roam-directory nil))
            (should-error
             (magent-repo-summary-write repository "full" "Summary")))
          (let ((magent-org-roam-directory plain-directory))
            (should-error
             (magent-repo-summary-write 'global "full" "Summary"))
            (should-error
             (magent-repo-summary-write plain-directory "full" "Summary"))
            (should-error
             (magent-repo-summary-write
              repository "scoped" "*** Scope\nSummary"
              "parser" '("../outside.el")))
            (should-error
             (magent-repo-summary-write repository "invalid" "Summary"))
            (should-error
             (magent-repo-summary-write repository "full" ""))))
      (delete-directory repository t)
      (delete-directory plain-directory t))))

(ert-deftest magent-repo-summary-test-registers-user-action-contract ()
  (let ((magent-action--registry nil)
        (magent-action--sequence 0)
        (magent-action-registry-changed-hook nil))
    (let ((spec (magent-repo-summary-register)))
      (should (equal (magent-action-spec-name spec) "summarize"))
      (should (eq (magent-action-spec-workflow spec)
                  #'magent-repo-summary--workflow))
      (should (eq (magent-action-spec-session-policy spec) 'isolated))
      (should (eq (magent-action-spec-source-layer spec) 'user))
      (should
       (equal (magent-action-spec-requires spec)
              '(json org org-element org-id subr-x))))))

(provide 'magent-repo-summary-test)
;;; magent-repo-summary-test.el ends here
