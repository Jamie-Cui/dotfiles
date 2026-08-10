#!/bin/bash

set -euo pipefail

archive_url=${SETUP_ARCHIVE_URL:-https://github.com/Jamie-Cui/dotfiles/archive/refs/heads/master.tar.gz}
temporary=$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-setup-loader.XXXXXX")
trap 'rm -rf -- "$temporary"' EXIT HUP INT TERM

archive=$temporary/dotfiles.tar.gz
source_dir=$temporary/source
mkdir -p "$source_dir"

curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 15 \
	"$archive_url" -o "$archive"
test -s "$archive"
tar -xzf "$archive" -C "$source_dir" --strip-components=1
test -x "$source_dir/scripts/setup.sh"

/bin/bash "$source_dir/scripts/setup.sh" "$@"
