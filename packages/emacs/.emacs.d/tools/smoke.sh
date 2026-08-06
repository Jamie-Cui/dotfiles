#!/usr/bin/env bash
# Offline startup smoke test for the configuration.
#
# Validates both startup chains without touching the user's real ~/.emacs.d
# and without network access:
#   1. repo-init chain:      emacs -q --load <repo>/init.el
#   2. stowed-home chain:     link managed source into a throwaway ~/.emacs.d,
#                             then load early-init.el + init.el
#
# Both chains copy the current machine's ELPA into throwaway HOME directories
# so packages resolve offline without writing to the real ~/.emacs.d or package
# tree.  Exit non-zero if either chain fails to boot.
set -euo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
REAL_ELPA="${HOME}/.emacs.d/elpa"

if [ ! -d "$REAL_ELPA" ]; then
    echo "smoke: no ELPA found at $REAL_ELPA; run 'make download' first." >&2
    exit 1
fi

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

prepare_home() {
    local target_home="$1"
    mkdir -p "$target_home/.emacs.d"
    cp -a "$REAL_ELPA" "$target_home/.emacs.d/elpa"
}

fail=0

echo "smoke: [1/2] repo-init chain (emacs -q --load init.el)"
REPO_HOME="$TMP_ROOT/repo-home"
prepare_home "$REPO_HOME"
if HOME="$REPO_HOME" emacs -q --batch --load "$REPO_DIR/init.el" \
        --eval '(unless (featurep (quote init-keys)) (error "keys module did not load"))' \
        --eval '(message "smoke: repo-init OK")'; then
    echo "smoke: repo-init chain PASSED"
else
    echo "smoke: repo-init chain FAILED" >&2
    fail=1
fi

echo "smoke: [2/2] stowed-home chain (managed links in temp HOME)"
INSTALL_HOME="$TMP_ROOT/installed-home"
prepare_home "$INSTALL_HOME"
for path in early-init.el init.el lisp site-lisp snippets cnfonts data agents; do
    ln -s "$REPO_DIR/$path" "$INSTALL_HOME/.emacs.d/$path"
done
if HOME="$INSTALL_HOME" emacs --batch \
        --load "$INSTALL_HOME/.emacs.d/early-init.el" \
        --load "$INSTALL_HOME/.emacs.d/init.el" \
        --eval '(unless (featurep (quote init-keys)) (error "keys module did not load"))' \
        --eval '(message "smoke: stowed-home OK")'; then
    echo "smoke: stowed-home chain PASSED"
else
    echo "smoke: stowed-home chain FAILED" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "smoke: FAILED" >&2
    exit 1
fi
echo "smoke: all chains PASSED"
