#!/usr/bin/env bash
# Byte-compile the configuration to a temporary directory.
#
# Loads the configuration with a throwaway HOME and a copied ELPA tree (so
# startup side effects cannot write to the real ~/.emacs.d), then byte-compiles
# every managed Elisp file individually, writing each .elc to a throwaway
# directory so the source tree stays clean.  Package installation is disabled
# for the entire run.  Reports warnings/errors and exits non-zero if any file
# fails to compile.
#
# Like startup, modules are NOT placed on `load-path' (several basenames shadow
# built-in libraries); they are compiled by absolute path after the config has
# loaded, matching how `+emacs/load-modules' loads them at runtime.
set -euo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
REAL_ELPA="${HOME}/.emacs.d/elpa"

if [ ! -d "$REAL_ELPA" ]; then
    echo "compile: no ELPA found at $REAL_ELPA; run 'make download' first." >&2
    exit 1
fi

TMP_ROOT="$(mktemp -d)"
OUT_DIR="$TMP_ROOT/elc"
COMPILE_HOME="$TMP_ROOT/home"
trap 'rm -rf "$TMP_ROOT"' EXIT

mkdir -p "$OUT_DIR" "$COMPILE_HOME/.emacs.d"
cp -a "$REAL_ELPA" "$COMPILE_HOME/.emacs.d/elpa"

echo "compile: loading config and byte-compiling to $OUT_DIR"
DOTFILES_EMACS_COMPILE_REPO="$REPO_DIR" \
DOTFILES_EMACS_COMPILE_OUT="$OUT_DIR" \
HOME="$COMPILE_HOME" emacs -q --batch \
    --eval '(setq use-package-ensure-function (function ignore))' \
    --eval '(setq byte-compile-dest-file-function
                  (lambda (file)
                    (let ((destination
                           (expand-file-name
                            (concat
                             (file-relative-name
                              file (getenv "DOTFILES_EMACS_COMPILE_REPO"))
                             "c")
                            (getenv "DOTFILES_EMACS_COMPILE_OUT"))))
                      (make-directory (file-name-directory destination) t)
                      destination)))' \
    --load "$REPO_DIR/init.el" \
    --eval '(let* ((repo (getenv "DOTFILES_EMACS_COMPILE_REPO"))
                   (files
                    (append
                     (directory-files-recursively
                      (expand-file-name "lisp" repo) "\\.el$")
                     (directory-files-recursively
                      (expand-file-name "site-lisp" repo) "\\.el$")))
                   failed)
              (dolist (file files)
                (condition-case error-data
                    (unless (byte-compile-file file)
                      (push file failed))
                  (error
                   (message "compile: %s: %s"
                            file (error-message-string error-data))
                   (push file failed))))
              (when failed
                (error "Compilation failed for: %s"
                       (mapconcat (function identity)
                                  (nreverse failed) ", "))))' \
    --eval "(message \"compile: done (artifacts discarded)\")"
