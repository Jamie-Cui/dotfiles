#!/bin/bash

# Shared state and invariants for the setup program. This file is sourced.

setup_program=${0##*/}

setup_repo_https=https://github.com/Jamie-Cui/dotfiles.git
setup_repo_ssh=git@github.com:Jamie-Cui/dotfiles.git
setup_repo_branch=master
setup_aerospace_repo=https://github.com/Jamie-Cui/AeroSpace.git
setup_aerospace_branch=main
setup_ctags_repo=https://github.com/universal-ctags/ctags.git
setup_org_root_repo=git@github.com:Jamie-Cui/org-root.git
setup_tdlib_repo=https://github.com/tdlib/td.git

setup_repo_dir=${HOME}/opt/dotfiles
setup_opt_dir=${HOME}/opt
setup_emacs_dir=$setup_opt_dir/emacs-src
setup_aerospace_dir=$setup_opt_dir/aerospace-src
setup_ctags_dir=$setup_opt_dir/ctags
setup_org_root_dir=$setup_opt_dir/org-root
setup_tdlib_dir=$setup_opt_dir/tdlib

setup_command=
setup_platform=
setup_profile=
setup_font_size=
setup_jobs=
setup_gpg_key=
setup_assume_yes=0
setup_build_emacs=0
setup_allow_low_disk=0
setup_interactive=0
setup_tty_open=0
setup_sudo_keepalive_pid=
setup_log_file=
setup_temp_dir=

setup_selected=()
setup_excluded=()
setup_detected_present=()
setup_with_specs=()
setup_without_specs=()
setup_dependency_notes=()
setup_pending=()
setup_temporary_paths=()

setup_catalog_names=()
setup_catalog_platforms=()
setup_catalog_dependencies=()
setup_catalog_labels=()
setup_catalog_states=()
setup_profile_names=()
setup_profile_components=()
setup_catalog_index=-1
setup_profile_index=-1

setup_say() {
	printf '%s\n' "$*"
}

setup_warn() {
	printf 'warning: %s\n' "$*" >&2
}

setup_die() {
	printf '%s: %s\n' "$setup_program" "$1" >&2
	exit "${2:-1}"
}

setup_array_contains() {
	local needle=$1
	shift
	local value
	for value in "$@"; do
		[ "$value" = "$needle" ] && return 0
	done
	return 1
}

setup_selected_contains() {
	setup_array_contains "$1" "${setup_selected[@]}"
}

setup_selected_add() {
	setup_selected_contains "$1" || setup_selected[${#setup_selected[@]}]=$1
}

setup_selected_remove() {
	local remove=$1
	local value
	local kept=()
	for value in "${setup_selected[@]}"; do
		[ "$value" = "$remove" ] || kept[${#kept[@]}]=$value
	done
	setup_selected=("${kept[@]}")
}

setup_excluded_contains() {
	setup_array_contains "$1" "${setup_excluded[@]}"
}

setup_excluded_add() {
	setup_excluded_contains "$1" || setup_excluded[${#setup_excluded[@]}]=$1
}

setup_excluded_remove() {
	local remove=$1
	local value
	local kept=()
	for value in "${setup_excluded[@]}"; do
		[ "$value" = "$remove" ] || kept[${#kept[@]}]=$value
	done
	setup_excluded=("${kept[@]}")
}

setup_detected_contains() {
	setup_array_contains "$1" "${setup_detected_present[@]}"
}

setup_detected_add() {
	setup_detected_contains "$1" || setup_detected_present[${#setup_detected_present[@]}]=$1
}

setup_dependency_note_add() {
	setup_array_contains "$1" "${setup_dependency_notes[@]}" || \
		setup_dependency_notes[${#setup_dependency_notes[@]}]=$1
}

setup_pending_add() {
	setup_array_contains "$1" "${setup_pending[@]}" || setup_pending[${#setup_pending[@]}]=$1
}

setup_catalog_find() {
	local name=$1
	local index
	setup_catalog_index=-1
	for ((index = 0; index < ${#setup_catalog_names[@]}; index++)); do
		if [ "${setup_catalog_names[$index]}" = "$name" ]; then
			setup_catalog_index=$index
			return 0
		fi
	done
	return 1
}

setup_profile_find() {
	local name=$1
	local index
	setup_profile_index=-1
	for ((index = 0; index < ${#setup_profile_names[@]}; index++)); do
		if [ "${setup_profile_names[$index]}" = "$name" ]; then
			setup_profile_index=$index
			return 0
		fi
	done
	return 1
}

setup_catalog_visit() {
	local index=$1
	local dependency dependency_index
	case ${setup_catalog_states[$index]} in
		1) setup_die "component dependency cycle includes ${setup_catalog_names[$index]}" 2 ;;
		2) return 0 ;;
	esac
	setup_catalog_states[$index]=1
	if [ "${setup_catalog_dependencies[$index]}" != - ]; then
		for dependency in ${setup_catalog_dependencies[$index]}; do
			setup_catalog_find "$dependency" || setup_die "unknown dependency $dependency" 2
			dependency_index=$setup_catalog_index
			setup_catalog_visit "$dependency_index"
		done
	fi
	setup_catalog_states[$index]=2
}

setup_load_catalog() {
	local file=$setup_module_dir/catalog.tsv
	local line name platforms dependencies label extra index dependency
	[ -r "$file" ] || setup_die "missing catalog: $file" 2
	while IFS= read -r line || [ -n "$line" ]; do
		case $line in ''|'#'*) continue ;; esac
		name=
		platforms=
		dependencies=
		label=
		extra=
		IFS=$'\t' read -r name platforms dependencies label extra <<< "$line"
		[ -n "$name" ] && [ -n "$platforms" ] && [ -n "$dependencies" ] && \
			[ -n "$label" ] && [ -z "$extra" ] || setup_die "invalid catalog row: $line" 2
		case $name in *[!a-z0-9-]*|'') setup_die "invalid component name: $name" 2 ;; esac
		case $platforms in all|macos|fedora) ;; *) setup_die "invalid platforms for $name: $platforms" 2 ;; esac
		setup_catalog_find "$name" && setup_die "duplicate component: $name" 2
		index=${#setup_catalog_names[@]}
		setup_catalog_names[$index]=$name
		setup_catalog_platforms[$index]=$platforms
		setup_catalog_dependencies[$index]=$dependencies
		setup_catalog_labels[$index]=$label
	done < "$file"
	[ ${#setup_catalog_names[@]} -gt 0 ] || setup_die "component catalog is empty" 2

	for ((index = 0; index < ${#setup_catalog_names[@]}; index++)); do
		dependencies=${setup_catalog_dependencies[$index]}
		if [ "$dependencies" != - ]; then
			for dependency in $dependencies; do
				case $dependency in *[!a-z0-9-]*|'') setup_die "invalid dependency: $dependency" 2 ;; esac
				setup_catalog_find "$dependency" || setup_die "unknown dependency $dependency" 2
			done
		fi
		setup_catalog_states[$index]=0
	done
	for ((index = 0; index < ${#setup_catalog_names[@]}; index++)); do
		setup_catalog_visit "$index"
	done
}

setup_load_profiles() {
	local file=$setup_module_dir/profiles.tsv
	local line name components extra index component
	[ -r "$file" ] || setup_die "missing profiles: $file" 2
	while IFS= read -r line || [ -n "$line" ]; do
		case $line in ''|'#'*) continue ;; esac
		name=
		components=
		extra=
		IFS=$'\t' read -r name components extra <<< "$line"
		[ -n "$name" ] && [ -n "$components" ] && [ -z "$extra" ] || \
			setup_die "invalid profile row: $line" 2
		case $name in *[!a-z0-9-]*|'') setup_die "invalid profile name: $name" 2 ;; esac
		setup_profile_find "$name" && setup_die "duplicate profile: $name" 2
		if [ "$components" != - ]; then
			for component in $components; do
				setup_catalog_find "$component" || setup_die "profile $name references unknown component $component" 2
			done
		fi
		index=${#setup_profile_names[@]}
		setup_profile_names[$index]=$name
		setup_profile_components[$index]=$components
	done < "$file"
	[ ${#setup_profile_names[@]} -gt 0 ] || setup_die "profile catalog is empty" 2
}

setup_cleanup() {
	local path temp_base
	if [ -n "$setup_sudo_keepalive_pid" ]; then
		kill "$setup_sudo_keepalive_pid" 2>/dev/null || true
		wait "$setup_sudo_keepalive_pid" 2>/dev/null || true
		setup_sudo_keepalive_pid=
	fi
	temp_base=${TMPDIR:-/tmp}
	for path in "${setup_temporary_paths[@]}"; do
		case $path in
			"$temp_base"/dotfiles-setup.*|/tmp/dotfiles-setup.*)
				command rm -rf -- "$path"
				;;
		esac
	done
	setup_temporary_paths=()
}

setup_on_signal() {
	local signal=$1
	trap - EXIT HUP INT TERM
	setup_cleanup
	case $signal in
		HUP) exit 129 ;;
		INT) exit 130 ;;
		TERM) exit 143 ;;
	esac
}

setup_install_traps() {
	trap setup_cleanup EXIT
	trap 'setup_on_signal HUP' HUP
	trap 'setup_on_signal INT' INT
	trap 'setup_on_signal TERM' TERM
}

setup_make_temp_dir() {
	setup_temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-setup.XXXXXX") || \
		setup_die "cannot create temporary directory"
	setup_temporary_paths[${#setup_temporary_paths[@]}]=$setup_temp_dir
}

setup_start_logging() {
	local state_dir=$HOME/.local/state/dotfiles
	mkdir -p "$state_dir" || setup_die "cannot create log directory $state_dir"
	setup_log_file=$state_dir/setup-$(date +%Y%m%d-%H%M%S).log
	touch "$setup_log_file" || setup_die "cannot create log file $setup_log_file"
	exec > >(tee -a "$setup_log_file") 2>&1
	setup_say "Log: $setup_log_file"
}

setup_display_home_path() {
	local path=$1
	case $path in
		"$HOME") printf '~\n' ;;
		"$HOME"/*) printf '%s/%s\n' '~' "${path#"$HOME"/}" ;;
		*) printf '%s\n' "$path" ;;
	esac
}
