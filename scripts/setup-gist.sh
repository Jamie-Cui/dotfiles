#!/bin/bash

set -euo pipefail

setup_url=https://raw.githubusercontent.com/Jamie-Cui/dotfiles/master/scripts/setup.sh
temporary=$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-setup-loader.XXXXXX")
trap 'rm -rf -- "$temporary"' EXIT HUP INT TERM

curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 15 \
	"$setup_url" -o "$temporary/setup.sh"
test -s "$temporary/setup.sh"

/bin/bash "$temporary/setup.sh" "$@"
