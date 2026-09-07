;;; magent-magit.el --- Magit actions powered by Magent -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jamie Cui

;; Author: Jamie Cui <jamie.cui@outlook.com>
;; Keywords: tools, ai, vc
;; Package-Requires: ((emacs "30.1") (magent "0") (magit "4.0"))

;;; Commentary:

;; This package connects Magit to isolated Magent Actions.  Git inspection is
;; performed by process Steps, model work by a tool-free agent Step, and UI
;; changes by trusted callback Steps.  Commit text is applied only while the
;; original commit buffer is still live and unchanged.

;;; Code:

(require 'cl-lib)
(require 'git-commit)
(require 'magent-action)
(require 'magent-agent-info)
(require 'magent-agent-registry)
(require 'magit)
(require 'subr-x)
(require 'transient)

(declare-function gfm-view-mode "markdown-mode")
(declare-function markdown-view-mode "markdown-mode")

(defgroup magent-magit nil
  "Magent Actions for Magit."
  :group 'magit
  :prefix "magent-magit-")

(defconst magent-magit--agent-name "magent-magit"
  "Name of the hidden agent used by Magit Actions.")

(defconst magent-magit--default-commit-prompt
  (string-join
   '("You write Git commit messages from staged diffs."
     ""
     "Return only the commit message in this form:"
     ""
     "    <type>(<optional scope>): <description>"
     ""
     "    [optional body]"
     ""
     "Choose the type from evidence in the staged patch:"
     ""
     "- feat: Add new user-visible behavior"
     "- fix: Correct demonstrably incorrect behavior"
     "- refactor: Restructure or remove code without adding a feature or fixing a bug"
     "- style: Make formatting-only changes with no behavior change"
     "- docs: Change documentation only"
     "- test: Change tests only"
     "- build: Change the build system or dependencies"
     "- ci: Change continuous-integration configuration"
     "- perf: Improve performance"
     "- chore: Perform repository maintenance not covered above"
     ""
     "Removing a command is not a feat. Use refactor unless the patch clearly demonstrates that the removal fixes a bug."
     "A whitespace-only or line-wrapping change is style."
     "Do not invent motivations such as unused, incomplete, or buggy unless the staged patch provides direct evidence."
     ""
     "Hard requirements:"
     ""
     "- Keep type and scope lowercase"
     "- Use imperative mood"
     "- Keep the entire subject at 50 characters or fewer"
     "- Do not end the subject with punctuation"
     "- Add a short body only when it provides useful context"
     "- Separate the body from the subject with exactly one blank line"
     "- Return plain text only"
     "- Never use Markdown, inline backticks, code fences, quotations, or explanatory labels")
   "\n")
  "Default instruction for commit message generation.")

(defconst magent-magit--default-diff-explain-prompt
  (concat
   "Explain this Git diff for a developer reading it in Magit.\n\n"
   "Answer in Markdown. Focus on intent, behavior changes, risks, and any "
   "missing follow-up work. When the diff is ambiguous, distinguish facts "
   "from inference.")
  "Default instruction for diff explanation.")

(defcustom magent-magit-commit-prompt
  magent-magit--default-commit-prompt
  "Instruction used by the commit-message Action."
  :type 'string
  :group 'magent-magit)

(defcustom magent-magit-diff-explain-prompt
  magent-magit--default-diff-explain-prompt
  "Instruction used by the diff-explanation Action."
  :type 'string
  :group 'magent-magit)

(defcustom magent-magit-model 'deepseek-v4-flash
  "Model used by the hidden Magit agent.
Nil inherits Magent's default model."
  :type '(choice (const :tag "Inherit Magent default" nil) symbol string)
  :group 'magent-magit)

(defcustom magent-magit-temperature 0.1
  "Sampling temperature used by the hidden Magit agent."
  :type 'number
  :group 'magent-magit)

(defcustom magent-magit-effort 'auto
  "Reasoning effort used by the hidden Magit agent.
The default `auto' leaves reasoning disabled or provider-controlled instead of
inheriting the global `magent-default-effort'."
  :type '(choice (const auto) (const minimal) (const low) (const medium)
                 (const high) (const xhigh))
  :group 'magent-magit)

(defcustom magent-magit-max-diff-chars 120000
  "Maximum patch size included in a Magent request.
The summary remains present when the patch is truncated."
  :type 'integer
  :group 'magent-magit)

(defcustom magent-magit-commit-buffer-wait-seconds 2.0
  "How long `magent-magit-commit-create' waits for a commit buffer."
  :type 'number
  :group 'magent-magit)

(defcustom magent-magit-explain-buffer-name "*Magent Magit Explain*"
  "Buffer used to display diff explanations."
  :type 'string
  :group 'magent-magit)

(defcustom magent-magit-preview-buffer-name "*Magent Magit Preview*"
  "Buffer used for commit messages that cannot be applied safely."
  :type 'string
  :group 'magent-magit)

(defcustom magent-magit-commit-transient-key "g"
  "Key used in `magit-commit' for Magent-assisted commit drafting."
  :type 'string
  :group 'magent-magit)

(defcustom magent-magit-diff-transient-key "e"
  "Key used in `magit-diff' for Magent diff explanation."
  :type 'string
  :group 'magent-magit)

(defcustom magent-magit-commit-buffer-key (kbd "C-c C-g")
  "Key used in `git-commit-mode' to draft a message with Magent."
  :type 'key-sequence
  :group 'magent-magit)

(defcustom magent-magit-cancel-key (kbd "C-c M-k")
  "Key used in `git-commit-mode' to cancel its active Magent Action."
  :type 'key-sequence
  :group 'magent-magit)

(defvar magent-magit--installed nil
  "Non-nil after Magit key and transient integration is installed.")

(defvar magent-magit--commit-wait-generation 0
  "Generation used to invalidate stale commit-buffer wait timers.")

(defvar-local magent-magit--active-invocation nil
  "Magent commit-message invocation currently owned by this buffer.")

(defvar-local magent-magit--generated-message nil
  "Last commit message inserted by `magent-magit'.")

(defun magent-magit--json-safe-string (text)
  "Return TEXT with characters invalid in JSON strings replaced."
  (with-temp-buffer
    (mapc (lambda (char)
            (insert-char
             (if (or (> char #x10ffff)
                     (and (>= char #xd800) (<= char #xdfff)))
                 #xfffd
               char)))
          (or text ""))
    (buffer-string)))

(defun magent-magit--truncate-diff (diff)
  "Return DIFF truncated to `magent-magit-max-diff-chars'."
  (if (and magent-magit-max-diff-chars
           (> (length diff) magent-magit-max-diff-chars))
      (concat (substring diff 0 magent-magit-max-diff-chars)
              (format
               "\n\n[diff truncated after %d characters by magent-magit]\n"
               magent-magit-max-diff-chars))
    diff))

(defun magent-magit--unwrap-code-fence (text)
  "Remove one surrounding fenced code block from TEXT."
  (let* ((trimmed (string-trim text))
         (lines (split-string trimmed "\n")))
    (if (and (>= (length lines) 2)
             (string-prefix-p "```" (string-trim (car lines)))
             (string= "```" (string-trim (car (last lines)))))
        (string-join (butlast (cdr lines)) "\n")
      trimmed)))

(defun magent-magit--strip-inline-markup (text)
  "Remove inline Markdown code markers from TEXT."
  (replace-regexp-in-string "`\\([^`\n]+\\)`" "\\1" text))

(defconst magent-magit--commit-subject-search-regexp
  (concat "\\(?:build\\|chore\\|ci\\|docs\\|feat\\|fix\\|perf\\|"
          "refactor\\|style\\|test\\)"
          "\\(?:([^)\n\"`]+)\\)?: [^\"`\n]+")
  "Regexp matching a Conventional Commit subject inside a line.")

(defconst magent-magit--commit-subject-line-regexp
  (concat "\\`" magent-magit--commit-subject-search-regexp "\\'")
  "Regexp matching a full Conventional Commit subject line.")

(defun magent-magit--commit-subject-line-p (line)
  "Return non-nil when LINE is a Conventional Commit subject."
  (let ((case-fold-search nil))
    (string-match-p magent-magit--commit-subject-line-regexp
                    (string-trim line))))

(defun magent-magit--extract-commit-subject (text)
  "Extract the first complete Conventional Commit subject from TEXT."
  (catch 'subject
    (dolist (line (split-string text "\n"))
      (when (magent-magit--commit-subject-line-p line)
        (throw 'subject (string-trim line))))
    nil))

(defun magent-magit--normalize-commit-message (text)
  "Normalize model TEXT into a plain commit message."
  (let* ((unfenced (magent-magit--unwrap-code-fence text))
         (plain (magent-magit--strip-inline-markup unfenced))
         (trimmed (string-trim plain))
         (lines (split-string trimmed "\n"))
         (lines (if (and lines
                         (string-match-p
                          "\\`\\(?:Suggested \\)?Commit message:?\\'"
                          (string-trim (car lines))))
                    (cdr lines)
                  lines))
         (message (string-trim-right (string-join lines "\n"))))
    (if (or (string-empty-p message)
            (magent-magit--commit-subject-line-p
             (car (split-string message "\n"))))
        message
      (or (magent-magit--extract-commit-subject message)
          message))))

(defun magent-magit--commit-message-region ()
  "Return the editable commit-message region."
  (save-excursion
    (goto-char (point-min))
    (let* ((comment-char (or comment-start "#"))
           (comment-re (concat "^" (regexp-quote comment-char)))
           (cut-re (format "^%s -\\{8,\\} >8 -\\{8,\\}$"
                           (regexp-quote comment-char)))
           (end (point-max)))
      (when (re-search-forward cut-re nil t)
        (setq end (line-beginning-position)))
      (goto-char (point-min))
      (when (re-search-forward comment-re end t)
        (setq end (line-beginning-position)))
      (cons (point-min) end))))

(defun magent-magit--display-text-buffer (buffer-name text &optional markdown)
  "Display TEXT in BUFFER-NAME.
When MARKDOWN is non-nil, use a Markdown viewing mode when available."
  (let ((buffer (get-buffer-create buffer-name)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert text)
        (goto-char (point-min))
        (cond
         ((and markdown (fboundp 'markdown-view-mode))
          (markdown-view-mode))
         ((and markdown (fboundp 'gfm-view-mode))
          (gfm-view-mode)
          (view-mode 1))
         (t
          (text-mode)
          (view-mode 1)))))
    (pop-to-buffer buffer)
    buffer))

(defun magent-magit--show-commit-preview
    (invocation repo-root message reason)
  "Preview MESSAGE for INVOCATION in REPO-ROOT with REASON."
  (magent-magit--display-text-buffer
   magent-magit-preview-buffer-name
   (string-join
    (list
     "Magent generated a commit message but did not apply it automatically."
     ""
     (format "Reason: %s" reason)
     (format "Repository: %s" repo-root)
     (format "Action: %s" (magent-action-invocation-id invocation))
     ""
     message)
    "\n")))

(defun magent-magit--apply-commit-response
    (target invocation repo-root baseline response)
  "Apply RESPONSE to TARGET when INVOCATION still owns BASELINE.
REPO-ROOT is included in any fallback preview."
  (let* ((message (magent-magit--normalize-commit-message response))
         (subject-length (length (car (split-string message "\n")))))
    (cond
     ((string-empty-p message)
      (magent-magit--show-commit-preview
       invocation repo-root response "The model returned an empty message")
      "Commit message was empty; opened a preview")
     ((not (buffer-live-p target))
      (magent-magit--show-commit-preview
       invocation repo-root message "The target commit buffer was closed")
      "Commit buffer was closed; opened a preview")
     (t
      (with-current-buffer target
        (let ((active magent-magit--active-invocation)
              (current (or (git-commit-buffer-message) "")))
          (cond
           ((and active (not (eq active invocation)))
            (magent-magit--show-commit-preview
             invocation repo-root message
             "A newer Action now owns the commit buffer")
            "A newer Action owns the commit buffer; opened a preview")
           ((not (string= baseline current))
            (magent-magit--show-commit-preview
             invocation repo-root message
             "The commit buffer changed while the Action was running")
            "Commit buffer changed; opened a preview")
           (t
            (pcase-let ((`(,beg . ,end)
                         (magent-magit--commit-message-region)))
              (let ((inhibit-read-only t))
                (delete-region beg end)
                (goto-char beg)
                (insert message)
                (unless (bolp)
                  (insert "\n"))
                (when (< (point) (point-max))
                  (unless (looking-at "\n")
                    (insert "\n")))
                (setq-local magent-magit--generated-message message
                            magent-magit--active-invocation nil)))
            (if (> subject-length 50)
                (message
                 "magent-magit: Commit message inserted; subject is %d characters (maximum is 50)"
                 subject-length)
              (message "magent-magit: Commit message inserted"))
            "Inserted the generated commit message"))))))))

(defun magent-magit--apply-commit-step
    (done target invocation repo-root baseline response)
  "Apply RESPONSE and complete callback DONE for INVOCATION and TARGET."
  (condition-case err
      (funcall done 'completed
               (magent-magit--apply-commit-response
                target invocation repo-root baseline response))
    (error
     (funcall done 'failed err))))

(defun magent-magit--commit-payload (repo-root branch summary patch)
  "Build an agent payload from REPO-ROOT, BRANCH, SUMMARY, and PATCH."
  (let ((repo-name
         (file-name-nondirectory (directory-file-name repo-root))))
    (string-join
     (delq nil
           (list
            magent-magit-commit-prompt
            (format "Repository: %s" repo-name)
            (format "Branch: %s" branch)
            (when (string-match-p "[^[:space:]]" summary)
              (format "Staged change summary:\n%s" summary))
            (format "Staged patch:\n%s"
                    (magent-magit--truncate-diff patch))))
     "\n\n")))

(magent-define-workflow magent-magit--commit-message-workflow (invocation)
  "Generate and safely insert a commit message for INVOCATION."
  (let* ((target (magent-action-invocation-origin-buffer invocation))
         (origin
          (file-name-as-directory
           (expand-file-name
            (or (magent-action-invocation-origin-directory invocation)
                default-directory))))
         (environment '(("GIT_TERMINAL_PROMPT" . "0")))
         baseline
         repo-root
         branch
         summary
         patch
         response)
    (unless (buffer-live-p target)
      (user-error "The commit buffer is no longer live"))
    (with-current-buffer target
      (unless (derived-mode-p 'git-commit-mode)
        (user-error "Run this Action from a Git commit buffer"))
      (when (and (magent-action-invocation-p
                  magent-magit--active-invocation)
                 (eq (magent-action-invocation-status
                      magent-magit--active-invocation)
                     'active))
        (magent-action-cancel
         magent-magit--active-invocation
         "Replaced by a newer commit-message Action"))
      (setq baseline (or (git-commit-buffer-message) "")
            magent-magit--active-invocation invocation))
    (setq repo-root
          (file-name-as-directory
           (file-truename
            (string-trim
             (magent-workflow-process
                 "Resolve repository"
                 '("git" "rev-parse" "--show-toplevel")
               :directory origin
               :environment environment)))))
    (setq branch
          (string-trim
           (magent-workflow-process
               "Read current branch"
               '("git" "branch" "--show-current")
             :directory repo-root
             :environment environment)))
    (when (string-empty-p branch)
      (setq branch
            (string-trim
             (magent-workflow-process
                 "Read current commit"
                 '("git" "rev-parse" "--short" "HEAD")
               :directory repo-root
               :environment environment))))
    (setq summary
          (string-trim-right
           (magent-magit--json-safe-string
            (magent-workflow-process
                "Read staged summary"
                '("git" "diff" "--cached" "--stat=80,120" "--summary"
                  "--no-ext-diff" "--no-color" "--submodule=diff" "-M")
              :directory repo-root
              :environment environment))))
    (setq patch
          (string-trim-right
           (magent-magit--json-safe-string
            (magent-workflow-process
                "Read staged patch"
                '("git" "diff" "--cached" "--patch" "--no-ext-diff"
                  "--no-color" "--submodule=diff" "-M")
              :directory repo-root
              :environment environment))))
    (unless (string-match-p "[^[:space:]]" patch)
      (user-error "No staged changes to summarize"))
    (setq response
          (magent-workflow-agent-turn
              "Write commit message"
              (magent-magit--commit-payload
               repo-root branch summary patch)
            :agent magent-magit--agent-name
            :tools nil))
    (magent-workflow-callback
        "Insert commit message"
        (lambda (done)
          (magent-magit--apply-commit-step
           done target invocation repo-root baseline response))
      :activity-input (list :repository repo-root :buffer (buffer-name target)))))

(defun magent-magit--capture-diff-snapshot (buffer)
  "Capture the diff section at point in Magit BUFFER."
  (unless (buffer-live-p buffer)
    (user-error "The originating Magit buffer is no longer live"))
  (with-current-buffer buffer
    (unless (derived-mode-p 'magit-mode)
      (user-error "Run this Action from a Magit buffer"))
    (let* ((repo-root (or (magit-toplevel)
                          (user-error "Not inside a Git repository")))
           (section (magit-current-section))
           (scope (magit-diff-scope section t))
           (diff-type (magit-diff-type section))
           (regionp (eq scope 'region))
           (raw-text
            (magent-magit--json-safe-string
             (cond
              ((null scope)
               (user-error "Point is not on a diff or hunk section"))
              (t
               (buffer-substring-no-properties
                (oref section start) (oref section end)))))))
      (unless (string-match-p "[^[:space:]]" raw-text)
        (user-error "No diff text is available at point"))
      (list :repo-root repo-root
            :repo-name
            (file-name-nondirectory (directory-file-name repo-root))
            :branch
            (or (magit-git-string "symbolic-ref" "--quiet" "--short" "HEAD")
                (magit-git-string "rev-parse" "--short" "HEAD")
                "HEAD")
            :scope scope
            :diff-type diff-type
            :region-derived regionp
            :text (string-trim-right raw-text)))))

(defun magent-magit--diff-payload (snapshot)
  "Build an explanation prompt from diff SNAPSHOT."
  (string-join
   (list
    magent-magit-diff-explain-prompt
    (format "Repository: %s" (plist-get snapshot :repo-name))
    (format "Branch: %s" (plist-get snapshot :branch))
    (format "Scope: %s%s"
            (plist-get snapshot :scope)
            (if (plist-get snapshot :region-derived)
                " (explaining enclosing hunk)"
              ""))
    (format "Diff type: %s" (plist-get snapshot :diff-type))
    (format "Diff snapshot:\n%s"
            (magent-magit--truncate-diff (plist-get snapshot :text))))
   "\n\n"))

(defun magent-magit--show-diff-explanation (snapshot response)
  "Display RESPONSE for diff SNAPSHOT and return a status string."
  (let ((text (string-trim response)))
    (when (string-empty-p text)
      (error "Magent returned an empty diff explanation"))
    (magent-magit--display-text-buffer
     magent-magit-explain-buffer-name
     (string-join
      (list
       "# Diff Explanation"
       ""
       (format "- Repository: `%s`" (plist-get snapshot :repo-name))
       (format "- Branch: `%s`" (plist-get snapshot :branch))
       (format "- Scope: `%s`%s"
               (plist-get snapshot :scope)
               (if (plist-get snapshot :region-derived)
                   " (explaining enclosing hunk)"
                 ""))
       (format "- Diff type: `%s`" (plist-get snapshot :diff-type))
       ""
       text)
      "\n")
     t)
    (message "magent-magit: Diff explanation ready")
    "Displayed the diff explanation"))

(defun magent-magit--show-diff-step (done snapshot response)
  "Display RESPONSE for SNAPSHOT and complete callback DONE."
  (condition-case err
      (funcall done 'completed
               (magent-magit--show-diff-explanation snapshot response))
    (error
     (funcall done 'failed err))))

(magent-define-workflow magent-magit--diff-explain-workflow (invocation)
  "Explain the Magit diff captured for INVOCATION."
  (let* ((snapshot
          (magent-magit--capture-diff-snapshot
           (magent-action-invocation-origin-buffer invocation)))
         (response
          (magent-workflow-agent-turn
              "Explain diff"
              (magent-magit--diff-payload snapshot)
            :agent magent-magit--agent-name
            :tools nil)))
    (magent-workflow-callback
        "Display diff explanation"
        (lambda (done)
          (magent-magit--show-diff-step done snapshot response))
      :activity-input
      (list :repository (plist-get snapshot :repo-root)
            :scope (plist-get snapshot :scope)))))

(defun magent-magit--make-agent ()
  "Create the hidden agent used by Magit Actions."
  (magent-agent-info-create
   :name magent-magit--agent-name
   :description "Tool-free commit-message and diff writing for Magit"
   :mode 'all
   :hidden t
   :temperature magent-magit-temperature
   :effort magent-magit-effort
   :model magent-magit-model
   :source-layer 'builtin))

;;;###autoload
(defun magent-magit-register ()
  "Register the hidden agent and Magit Actions."
  (magent-agent-registry-ensure-initialized)
  (magent-agent-registry-register (magent-magit--make-agent))
  (list
   (magent-action-register
    "magit-commit-message"
    :description "Generate a message for the current staged changes."
    :title "Generate Magit commit message"
    :exposure '(interactive)
    :session-policy 'isolated
    :workflow #'magent-magit--commit-message-workflow
    :source-layer 'user
    :requires '(git-commit magit subr-x))
   (magent-action-register
    "magit-diff-explain"
    :description "Explain the diff section at point in a Magit buffer."
    :title "Explain Magit diff"
    :exposure '(interactive)
    :session-policy 'isolated
    :workflow #'magent-magit--diff-explain-workflow
    :source-layer 'user
    :requires '(magit subr-x))))

;;;###autoload
(defun magent-magit-generate-message ()
  "Run the commit-message Action from the current commit buffer."
  (interactive)
  (magent-action-run "magit-commit-message"))

;;;###autoload
(defun magent-magit-cancel ()
  "Cancel the Magent Action owned by the current commit buffer."
  (interactive)
  (if (and (magent-action-invocation-p magent-magit--active-invocation)
           (eq (magent-action-invocation-status
                magent-magit--active-invocation)
               'active))
      (magent-action-cancel magent-magit--active-invocation
                            "Commit-message Action cancelled")
    (setq-local magent-magit--active-invocation nil)
    (user-error "No active Magent Action for this commit buffer")))

(defun magent-magit--repo-root (&optional buffer)
  "Return the repository root for BUFFER or signal a user error."
  (with-current-buffer (or buffer (current-buffer))
    (or (magit-toplevel)
        (user-error "Not inside a Git repository"))))

(defun magent-magit--find-commit-buffer (repo-root)
  "Return the live commit buffer associated with REPO-ROOT."
  (cl-find-if
   (lambda (buffer)
     (with-current-buffer buffer
       (and (derived-mode-p 'git-commit-mode)
            (when-let* ((top-level (magit-toplevel)))
              (equal (file-truename top-level)
                     (file-truename repo-root))))))
   (buffer-list)))

(defun magent-magit--wait-for-commit-buffer (repo-root callback)
  "Call CALLBACK when a commit buffer for REPO-ROOT becomes available."
  (let ((generation (cl-incf magent-magit--commit-wait-generation)))
    (cl-labels
        ((poll (remaining)
           (if-let* ((buffer (magent-magit--find-commit-buffer repo-root)))
               (when (= generation magent-magit--commit-wait-generation)
                 (funcall callback buffer))
             (if (<= remaining 0)
                 (when (= generation magent-magit--commit-wait-generation)
                   (message
                    "magent-magit: Timed out waiting for a commit buffer in %s"
                    repo-root))
               (run-at-time 0.05 nil #'poll (- remaining 0.05))))))
      (poll magent-magit-commit-buffer-wait-seconds))))

;;;###autoload
(defun magent-magit-commit-create (&optional args)
  "Open a commit buffer with ARGS and run the commit-message Action."
  (interactive (list (magit-commit-arguments)))
  (let ((repo-root (magent-magit--repo-root)))
    (magit-commit-create args)
    (magent-magit--wait-for-commit-buffer
     repo-root
     (lambda (buffer)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (magent-magit-generate-message)))))
    (message "magent-magit: Opening commit buffer")))

;;;###autoload
(defun magent-magit-diff-explain ()
  "Run the diff-explanation Action from the current Magit buffer."
  (interactive)
  (magent-action-run "magit-diff-explain"))

(defun magent-magit--install-transient (prefix anchor suffix)
  "Install SUFFIX into PREFIX after ANCHOR and report failure."
  (condition-case err
      (transient-append-suffix prefix anchor suffix)
    (error
     (message "magent-magit: Could not install %s into %s: %s"
              (car suffix) prefix (error-message-string err)))))

(defun magent-magit--retire-gptel-integration ()
  "Remove bindings left by the previous `magit-gptel' integration."
  (when (eq (lookup-key git-commit-mode-map (kbd "C-c C-g"))
            'magit-gptel-generate-message)
    (define-key git-commit-mode-map (kbd "C-c C-g") nil))
  (when (eq (lookup-key git-commit-mode-map (kbd "C-c M-k"))
            'magit-gptel-cancel)
    (define-key git-commit-mode-map (kbd "C-c M-k") nil))
  (dolist (entry '((magit-commit magit-gptel-commit-create)
                   (magit-diff magit-gptel-diff-explain)))
    (when (fboundp (cadr entry))
      (condition-case err
          (transient-remove-suffix (car entry) (cadr entry))
        (error
         (message "magent-magit: Could not retire %s from %s: %s"
                  (cadr entry) (car entry) (error-message-string err)))))))

;;;###autoload
(defun magent-magit-install ()
  "Install Magit key bindings and transient entries for Magent Actions."
  (interactive)
  (unless magent-magit--installed
    (magent-magit--retire-gptel-integration)
    (define-key git-commit-mode-map magent-magit-commit-buffer-key
                #'magent-magit-generate-message)
    (define-key git-commit-mode-map magent-magit-cancel-key
                #'magent-magit-cancel)
    (magent-magit--install-transient
     'magit-commit
     #'magit-commit-create
     `(,magent-magit-commit-transient-key
       "Generate Commit (Magent)" magent-magit-commit-create))
    (magent-magit--install-transient
     'magit-diff
     #'magit-stash-show
     `(,magent-magit-diff-transient-key
       "Explain (Magent)" magent-magit-diff-explain))
    (setq magent-magit--installed t)))

(provide 'magent-magit)
;;; magent-magit.el ends here
