;;; core-loader.el --- Module manifest loader -*- lexical-binding: t -*-
;;; Commentary:
;; `+emacs/load-modules' loads feature modules from `lisp/modules' in the given
;; order.  Module names may be path-like (e.g. "lang/cmake" ->
;; lisp/modules/lang/cmake.el).  Manifest membership and order are the contract.
;;; Code:

(require 'core-vars)
(require 'core-paths)

(defun +emacs/load-modules (modules)
  "Load each module in MODULES.
MODULES is a list of name strings such as \"ui\" or \"lang/cmake\",
resolved to files under `+emacs/modules-directory'."
  (dolist (name modules)
    (load (expand-file-name name +emacs/modules-directory) nil t)))

(provide 'core-loader)
;;; core-loader.el ends here
