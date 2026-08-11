#!/usr/bin/env bash
# Run the complete ERT suite with an isolated HOME and no package installs.
set -euo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
REAL_ELPA="${HOME}/.emacs.d/elpa"

if [ ! -d "$REAL_ELPA" ]; then
    echo "test: no ELPA found at $REAL_ELPA; run 'make download' first." >&2
    exit 1
fi

TMP_ROOT="$(mktemp -d)"
TEST_HOME="$TMP_ROOT/home"
trap 'rm -rf "$TMP_ROOT"' EXIT

mkdir -p "$TEST_HOME/.emacs.d"
cp -a "$REAL_ELPA" "$TEST_HOME/.emacs.d/elpa"

echo "test: running ERT suite offline"
DOTFILES_EMACS_TEST_REPO="$REPO_DIR" \
HOME="$TEST_HOME" emacs -Q --batch \
    --eval '(setq use-package-ensure-function (function ignore))' \
    --eval '(require (quote package))' \
    --eval '(package-initialize)' \
    --eval '(require (quote use-package))' \
    --eval '(let ((repo (getenv "DOTFILES_EMACS_TEST_REPO")))
              (dolist (dir (list (expand-file-name "lisp" repo)
                                 (expand-file-name "lisp/core" repo)
                                 (expand-file-name "site-lisp" repo)))
                (add-to-list (quote load-path) dir)))' \
    --eval '(setq window-system (quote pgtk))' \
    --eval '(dolist (file
                     (directory-files
                      (expand-file-name
                       "test" (getenv "DOTFILES_EMACS_TEST_REPO"))
                      t "-test\\.el$"))
              (load file nil t))' \
    --funcall ert-run-tests-batch-and-exit
