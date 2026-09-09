;;; org-latex-protocol-test.el --- Protocol block regressions -*- lexical-binding: t; -*-

;;; Commentary:
;; Exercise real Org parsing/export and isolate only the external TeX renderer.
;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'org-latex-protocol)
(require 'ox-latex)
(require 'ox-html)
(require 'ox-org)
(require 'org-lint)

(defconst org-latex-protocol-test--source
  "#+name: sample\n#+begin_protocol\n\\small\n\\textbf{协议 $n_U$}\n\\begin{enumerate}\n\\item Request $q$.\n\\end{enumerate}\n#+end_protocol\n"
  "Example protocol with raw LaTeX commands and subscripts.")

(ert-deftest org-latex-protocol-raw-latex-export ()
  (let ((org-export-use-babel nil))
    (with-temp-buffer
      (org-mode)
      (insert org-latex-protocol-test--source)
      (let ((source (buffer-string))
            (output (org-export-as 'latex nil nil t)))
        (should (string-match-p
                 (regexp-quote "\\begin{protocol}\n\\small\n\\textbf{协议 $n_U$}")
                 output))
        (should (string-match-p (regexp-quote "\\item Request $q$.") output))
        (should-not (string-match-p "includegraphics\\|begin_protocol" output))
        (should (equal source (buffer-string)))))))

(ert-deftest org-latex-protocol-html-renders-once-without-source ()
  (let ((org-export-use-babel nil) calls)
    (cl-letf (((symbol-function '+org/protocol-render)
               (lambda (block)
                 (push (org-element-property :name block) calls)
                 (+org/protocol-image-file block))))
      (let ((output (org-export-string-as org-latex-protocol-test--source
                                          'html t)))
        (should (equal calls '("sample")))
        (should (string-match-p "img/sample.svg" output))
        (should-not (string-match-p "begin_protocol\\|textbf\\|Request" output))))))

(ert-deftest org-latex-protocol-preserves-org-and-example-blocks ()
  (cl-letf (((symbol-function '+org/protocol-render)
             (lambda (&rest _) (ert-fail "Unexpected rendering"))))
    (should (string-match-p
             "#\\+begin_protocol"
             (org-export-string-as org-latex-protocol-test--source 'org t)))
    (should (string-match-p
             "begin_protocol"
             (org-export-string-as
              (concat "#+begin_example\n" org-latex-protocol-test--source
                      "#+end_example\n") 'latex t)))))

(ert-deftest org-latex-protocol-context-and-lint ()
  (with-temp-buffer
    (org-mode)
    (insert org-latex-protocol-test--source)
    (goto-char (point-min))
    (search-forward "Request")
    (should (equal (org-element-property :name (+org/protocol-at-point))
                   "sample"))
    (should-not (org-lint-wrong-header-value (org-element-parse-buffer)))
    (goto-char (point-max))
    (insert "\nOrdinary text\n")
    (backward-char 2)
    (should-not (+org/protocol-at-point))))

(ert-deftest org-latex-protocol-rejects-path-and-empty-body ()
  (dolist (source '("#+name: ../escape\n#+begin_protocol\nBody\n#+end_protocol\n"
                    "#+begin_protocol\n#+end_protocol\n"))
    (with-temp-buffer
      (org-mode)
      (insert source)
      (goto-char (point-min))
      (should-error
       (let ((block (+org/protocol-at-point)))
         (+org/protocol-body block)
         (+org/protocol-image-file block))
       :type 'user-error))))

(ert-deftest org-latex-protocol-keeps-image-on-render-failure ()
  (let ((directory (make-temp-file "protocol-test-" t)))
    (unwind-protect
        (with-temp-buffer
          (org-mode)
          (insert org-latex-protocol-test--source)
          (goto-char (point-min))
          (let ((default-directory (file-name-as-directory directory)))
            (make-directory "img")
            (with-temp-file "img/sample.svg" (insert "Original image"))
            (cl-letf (((symbol-function 'org-babel-execute:latex)
                       (lambda (&rest _) (error "TeX compilation failed"))))
              (should-error (+org/protocol-render (+org/protocol-at-point))))
            (should (equal (directory-files "img" nil "^[^.]") '("sample.svg")))
            (with-temp-buffer
              (insert-file-contents "img/sample.svg")
              (should (equal (buffer-string) "Original image")))))
      (delete-directory directory t))))

(ert-deftest org-latex-protocol-preview-persists-and-replaces-result ()
  (with-temp-buffer
    (org-mode)
    (insert org-latex-protocol-test--source)
    (goto-char (point-min))
    (search-forward "Request")
    (let ((source (buffer-string)) (position (point)) first-result)
      (cl-letf (((symbol-function '+org/protocol-render)
                 (lambda (_) "img/sample.svg"))
                ((symbol-function 'image-type-available-p) (lambda (_) nil)))
        (org-ctrl-c-ctrl-c)
        (setq first-result (buffer-string))
        (org-ctrl-c-ctrl-c))
      (should (= position (point)))
      (should (equal first-result (buffer-string)))
      (should (equal (buffer-string)
                     (concat source "\n#+RESULTS: sample\n[[file:img/sample.svg]]\n")))
      (should-not (overlays-in (point-min) (point-max))))))

(ert-deftest org-latex-protocol-anonymous-result-updates-after-edit ()
  (with-temp-buffer
    (org-mode)
    (insert "#+begin_protocol\nFirst\n#+end_protocol\n")
    (goto-char (point-min))
    (let (old-file new-file)
      (cl-letf (((symbol-function '+org/protocol-render)
                 #'+org/protocol-image-file)
                ((symbol-function 'image-type-available-p) (lambda (_) nil)))
        (setq old-file (+org/protocol-preview))
        (search-forward "First")
        (insert " changed")
        (setq new-file (+org/protocol-preview)))
      (should-not (equal old-file new-file))
      (should-not (string-match-p (regexp-quote old-file) (buffer-string)))
      (should (string-match-p
               (regexp-quote (concat "#+RESULTS:\n[[file:" new-file "]]"))
               (buffer-string))))))

(ert-deftest org-latex-protocol-export-omits-saved-results ()
  (let ((source (concat org-latex-protocol-test--source
                        "\n#+RESULTS: sample\n[[file:img/old.svg]]\n\n"
                        "[[file:img/unrelated.svg]]\n")))
    (cl-letf (((symbol-function '+org/protocol-render)
               (lambda (_) "img/sample.svg")))
      (let ((latex (org-export-string-as source 'latex t))
            (html (org-export-string-as source 'html t))
            (org (org-export-string-as source 'org t)))
        (should (string-match-p (regexp-quote "\\begin{protocol}") latex))
        (should-not (string-match-p "img/old\\|img/sample" latex))
        (should (string-match-p "img/unrelated" latex))
        (should (= 2 (length (split-string html (regexp-quote "img/sample.svg")))))
        (should-not (string-match-p "img/old.svg" html))
        (should (string-match-p "img/unrelated.svg" html))
        (should (string-match-p "img/old.svg" org))))))

(ert-deftest org-latex-protocol-refuses-unexpected-results ()
  (with-temp-buffer
    (org-mode)
    (insert org-latex-protocol-test--source
            "\n#+RESULTS: sample\nManually written notes.\n")
    (goto-char (point-min))
    (let ((source (buffer-string)))
      (cl-letf (((symbol-function '+org/protocol-render)
                 (lambda (_) (ert-fail "Unexpected rendering"))))
        (should-error (+org/protocol-preview) :type 'user-error))
      (should (equal source (buffer-string))))))

(ert-deftest org-latex-protocol-uses-native-latex-faces ()
  (with-temp-buffer
    (org-mode)
    (let* ((body "\\textbf{Title}\n% Comment\n\\item $q$\n")
           (org-src-fontify-natively t)
           (native-faces
            (with-temp-buffer
              (org-mode)
              (insert "#+begin_src latex\n" body "#+end_src\n")
              (font-lock-ensure)
              (goto-char (point-min))
              (forward-line)
              (cl-loop for pos from (point) below (+ (point) (length body))
                       collect (get-text-property pos 'face)))))
      (insert "#+begin_protocol\n" body "#+end_protocol\n\n*bold*\n")
      (font-lock-ensure)
      (goto-char (point-min))
      (let* ((block (org-element-at-point))
             (begin (org-element-property :contents-begin block))
             (end (org-element-property :contents-end block)))
        (should (equal native-faces
                       (cl-loop for pos from begin below end
                                collect (get-text-property pos 'face))))
        (should (memq 'font-lock-comment-face (nth (length "\\textbf{Title}\n% ")
                                                 native-faces)))
        (should-not (get-text-property (1- begin) 'syntax-table))
        (should-not (get-text-property end 'syntax-table))
        (goto-char end)
        (should (+org/protocol-block-p (org-element-at-point))))
      (search-forward "bold")
      (should (memq 'bold (ensure-list (get-text-property (1- (point)) 'face)))))))

(ert-deftest org-latex-protocol-fontification-skips-literal-examples ()
  (with-temp-buffer
    (org-mode)
    (insert "#+begin_example\n" org-latex-protocol-test--source
            "#+end_example\n")
    (let (languages)
      (cl-letf (((symbol-function 'org-src-font-lock-fontify-block)
                 (lambda (language _begin _end) (push language languages))))
        (font-lock-ensure))
      (should-not (member "latex" languages)))))

(provide 'org-latex-protocol-test)
;;; org-latex-protocol-test.el ends here
