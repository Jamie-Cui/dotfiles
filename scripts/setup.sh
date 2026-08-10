#!/bin/bash

set -o pipefail

setup_entry_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
setup_module_dir=$setup_entry_dir/setup

for setup_module_path in \
	"$setup_module_dir/core.sh" \
	"$setup_module_dir/ui.sh" \
	"$setup_module_dir/system.sh" \
	"$setup_module_dir/install.sh" \
	"$setup_module_dir/plan.sh"; do
	if [ ! -r "$setup_module_path" ]; then
		printf 'setup.sh: missing module: %s\n' "$setup_module_path" >&2
		exit 1
	fi
done

unset setup_module_path

# shellcheck source=setup/core.sh
. "$setup_module_dir/core.sh"
# shellcheck source=setup/ui.sh
. "$setup_module_dir/ui.sh"
# shellcheck source=setup/system.sh
. "$setup_module_dir/system.sh"
# shellcheck source=setup/install.sh
. "$setup_module_dir/install.sh"
# shellcheck source=setup/plan.sh
. "$setup_module_dir/plan.sh"

setup_main "$@"
