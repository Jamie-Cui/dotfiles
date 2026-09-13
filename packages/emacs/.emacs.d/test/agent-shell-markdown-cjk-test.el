;;; agent-shell-markdown-cjk-test.el --- Tests for CJK emphasis rendering -*- lexical-binding: t; -*-

;;; Commentary:

;; Focused tests for the `agent-shell-markdown-cjk' override, which lets
;; asterisk emphasis (`**bold**' / `*italic*') be flanked by CJK word
;; characters while keeping underscore emphasis (`__bold__' / `_italic_')
;; intraword-restricted.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'agent-shell-markdown-cjk)

(defun agent-shell-markdown-cjk-test--convert (s)
  "Render S through Agent Shell's Markdown renderer."
  (agent-shell-markdown-convert s))

(defun agent-shell-markdown-cjk-test--plain (s)
  "Render S and return it without text properties."
  (substring-no-properties (agent-shell-markdown-convert s)))

(defun agent-shell-markdown-cjk-test--face-of (needle s)
  "Return the face on NEEDLE in the rendered S, or nil if absent."
  (let* ((rendered (agent-shell-markdown-convert s))
         (pos (string-match (regexp-quote needle) rendered)))
    (and pos (get-text-property pos 'face rendered))))

(ert-deftest agent-shell-markdown-cjk-bold-adjacent-to-cjk ()
  (should (eq (agent-shell-markdown-cjk-test--face-of
               "加粗" "中文**加粗**文字")
              'agent-shell-markdown-bold))
  (should (eq (agent-shell-markdown-cjk-test--face-of
               "测试" "这是**测试**。")
              'agent-shell-markdown-bold))
  (should (eq (agent-shell-markdown-cjk-test--face-of
               "加粗" "**加粗**文字")
              'agent-shell-markdown-bold)))

(ert-deftest agent-shell-markdown-cjk-italic-adjacent-to-cjk ()
  (should (eq (agent-shell-markdown-cjk-test--face-of
               "斜体" "中文*斜体*文字")
              'agent-shell-markdown-italic))
  (should (eq (agent-shell-markdown-cjk-test--face-of
               "测试" "这是*测试*。")
              'agent-shell-markdown-italic)))

(ert-deftest agent-shell-markdown-cjk-ascii-bold-still-works ()
  (should (eq (agent-shell-markdown-cjk-test--face-of
               "world" "hello **world**.")
              'agent-shell-markdown-bold)))

(ert-deftest agent-shell-markdown-cjk-underscore-stays-literal ()
  (should (equal (agent-shell-markdown-cjk-test--plain "foo_bar_baz")
                 "foo_bar_baz"))
  (should (equal (agent-shell-markdown-cjk-test--plain "foo__bar__baz")
                 "foo__bar__baz")))

(ert-deftest agent-shell-markdown-cjk-inline-code-preserved ()
  (let ((rendered (agent-shell-markdown-cjk-test--convert
                   "中文 `**代码**` 文字")))
    (should (equal (substring-no-properties rendered)
                   "中文 **代码** 文字"))
    (should (eq (agent-shell-markdown-cjk-test--face-of
                 "代码" "中文 `**代码**` 文字")
                'agent-shell-markdown-inline-code))))

(ert-deftest agent-shell-markdown-cjk-delimiters-inside-code-stay-literal ()
  (dolist (style '(("*" . agent-shell-markdown-italic)
                   ("**" . agent-shell-markdown-bold)))
    (let* ((delimiter (car style))
           (code (concat "a" delimiter "b"))
           (source (format "中文 `%s` 和 %s强调%s"
                           code delimiter delimiter)))
      (should (equal (agent-shell-markdown-cjk-test--plain source)
                     (concat "中文 " code " 和 强调")))
      (should (eq (agent-shell-markdown-cjk-test--face-of code source)
                  'agent-shell-markdown-inline-code))
      (should (eq (agent-shell-markdown-cjk-test--face-of "强调" source)
                  (cdr style))))
    (let* ((delimiter (car style))
           (source (format "中文%s未闭合 `a%sb`" delimiter delimiter)))
      (should (equal (agent-shell-markdown-cjk-test--plain source)
                     (format "中文%s未闭合 a%sb" delimiter delimiter)))
      (should-not (agent-shell-markdown-cjk-test--face-of "未闭合" source)))))

(ert-deftest agent-shell-markdown-cjk-emphasis-can-contain-inline-code ()
  (dolist (style '(("*" . agent-shell-markdown-italic)
                   ("**" . agent-shell-markdown-bold)))
    (let* ((delimiter (car style))
           (source (format "中文%s包含 `代码` 的文本%s"
                           delimiter delimiter)))
      (should (equal (agent-shell-markdown-cjk-test--plain source)
                     "中文包含 代码 的文本"))
      (should (eq (agent-shell-markdown-cjk-test--face-of "包含" source)
                  (cdr style)))
      (should (memq 'agent-shell-markdown-inline-code
                    (agent-shell-markdown-cjk-test--face-of "代码" source))))))

(ert-deftest agent-shell-markdown-cjk-frozen-delimiter-chars-stay-literal ()
  (dolist (source (list (concat "中文*"
                               (propertize "*" 'agent-shell-markdown-frozen t)
                               "文本** 和 **强调**")
                       (concat "中文**文本"
                               (propertize "*" 'agent-shell-markdown-frozen t)
                               "* 和 **强调**")))
    (should (equal (agent-shell-markdown-cjk-test--plain source)
                   "中文**文本** 和 强调"))
    (should (eq (agent-shell-markdown-cjk-test--face-of "强调" source)
                'agent-shell-markdown-bold))))

(ert-deftest agent-shell-markdown-cjk-invalid-flanking-stays-literal ()
  (dolist (source '("foo* bar*baz" "foo*bar *baz" "foo* bar *baz"
                    "foo** bar**baz" "foo**bar **baz" "foo** bar **baz"
                    "foo*\tbar*baz" "foo**bar\t**baz"
                    "foo*\u00a0bar*baz" "foo**bar\u3000**baz"
                    "foo*。bar*baz" "foo**bar。**baz"
                    "foo*€*baz" "foo**€**baz"))
    (should (equal (agent-shell-markdown-cjk-test--plain source) source))))

(ert-deftest agent-shell-markdown-cjk-valid-punctuation-flanking-renders ()
  (should (eq (agent-shell-markdown-cjk-test--face-of "€" "*€*")
              'agent-shell-markdown-italic))
  (should (eq (agent-shell-markdown-cjk-test--face-of "。文本。" "**。文本。**")
              'agent-shell-markdown-bold)))

(ert-deftest agent-shell-markdown-cjk-retries-after-invalid-flanking ()
  (dolist (style '(("*" . agent-shell-markdown-italic)
                   ("**" . agent-shell-markdown-bold)))
    (let* ((delimiter (car style))
           (source (format "foo%s bar %sbaz; %s强调%s"
                           delimiter delimiter delimiter delimiter)))
      (should (equal (agent-shell-markdown-cjk-test--plain source)
                     (format "foo%s bar %sbaz; 强调" delimiter delimiter)))
      (should (eq (agent-shell-markdown-cjk-test--face-of "强调" source)
                  (cdr style))))))

(ert-deftest agent-shell-markdown-cjk-escaped-asterisk-stays-literal ()
  (should (equal (agent-shell-markdown-cjk-test--plain
                  "中文 \\*不斜体\\* 文字")
                 "中文 *不斜体* 文字"))
  (should-not (agent-shell-markdown-cjk-test--face-of
               "不斜体" "中文 \\*不斜体\\* 文字")))

(provide 'agent-shell-markdown-cjk-test)
;;; agent-shell-markdown-cjk-test.el ends here
