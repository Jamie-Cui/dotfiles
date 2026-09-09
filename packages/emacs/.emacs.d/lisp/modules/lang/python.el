;;; python.el --- Python language server -*- lexical-binding: t -*-
;;; Commentary:
;; Use Pyright through uvx when Eglot loads.
;;; Code:

(with-eval-after-load 'eglot
  (add-to-list 'eglot-server-programs
               '((python-mode python-ts-mode)
                 . ("uvx" "--from" "pyright" "pyright-langserver" "--stdio"))))

(provide 'init-lang-python)
;;; python.el ends here
