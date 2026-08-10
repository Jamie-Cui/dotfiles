#!/bin/bash

# Public CLI, selection policy, dependency planning, and interactive UI.

setup_usage() {
	cat <<'EOF'
Usage:
  setup.sh plan --profile PROFILE [options]
  setup.sh apply --profile PROFILE [options] [--yes]
  setup.sh interactive [options]

Commands:
  plan         Print a read-only setup plan
  apply        Print, confirm, and execute a setup plan
  interactive  Detect components and open the numbered selection menu

Selection:
  --profile NAME       minimal, recommended, or all
  --with NAME          Add one component (repeatable)
  --without NAME       Remove one component (repeatable)

Configuration:
  --repo-dir DIR       Clone/use the dotfiles repository at DIR
  --font-size SIZE     Persist the generated dotfiles font size
  --gpg-key FILE       Import an armored OpenPGP secret-key backup
  --build-emacs        Build and install Emacs after configuring it
  --jobs N             Emacs build jobs (default: min(logical CPUs, 4))
  --allow-low-disk     Build Emacs with less than 10 GiB available
  --yes                Skip the apply confirmation
  -h, --help           Show this help
EOF
}

setup_parse_args() {
	[ "$#" -gt 0 ] || { setup_usage >&2; exit 2; }
	case $1 in
		plan|apply|interactive) setup_command=$1; shift ;;
		-h|--help) setup_usage; exit 0 ;;
		*) setup_die "unknown command: $1" 2 ;;
	esac

	while [ "$#" -gt 0 ]; do
		case $1 in
			--profile)
				[ "$#" -ge 2 ] || setup_die "--profile requires a value" 2
				[ -z "$setup_profile" ] || setup_die "--profile may be specified only once" 2
				setup_profile=$2
				shift 2
				;;
			--with)
				[ "$#" -ge 2 ] || setup_die "--with requires a value" 2
				setup_with_specs[${#setup_with_specs[@]}]=$2
				shift 2
				;;
			--without)
				[ "$#" -ge 2 ] || setup_die "--without requires a value" 2
				setup_without_specs[${#setup_without_specs[@]}]=$2
				shift 2
				;;
			--repo-dir)
				[ "$#" -ge 2 ] || setup_die "--repo-dir requires a value" 2
				setup_repo_dir=$2
				shift 2
				;;
			--font-size)
				[ "$#" -ge 2 ] || setup_die "--font-size requires a value" 2
				setup_font_size=$2
				shift 2
				;;
			--gpg-key)
				[ "$#" -ge 2 ] || setup_die "--gpg-key requires a value" 2
				setup_gpg_key=$2
				shift 2
				;;
			--jobs)
				[ "$#" -ge 2 ] || setup_die "--jobs requires a value" 2
				setup_jobs=$2
				shift 2
				;;
			--build-emacs) setup_build_emacs=1; shift ;;
			--allow-low-disk) setup_allow_low_disk=1; shift ;;
			--yes) setup_assume_yes=1; shift ;;
			-h|--help) setup_usage; exit 0 ;;
			*) setup_die "unknown option: $1" 2 ;;
		esac
	done

	if [ "$setup_command" != apply ] && [ "$setup_assume_yes" -eq 1 ]; then
		setup_die "--yes is valid only with apply" 2
	fi
	if [ "$setup_command" = interactive ]; then
		[ -n "$setup_profile" ] || setup_profile=recommended
	elif [ -z "$setup_profile" ] && [ ${#setup_with_specs[@]} -eq 0 ]; then
		setup_die "$setup_command requires --profile or at least one --with" 2
	fi
}

setup_read_existing_font_size() {
	local file=$setup_repo_dir/local.mk
	[ -f "$file" ] || return 1
	setup_font_size=$(awk '
		/^[[:space:]]*FONT_SIZE[[:space:]]*[:?+]?=/ {
			value = $0
			sub(/^[^=]*=[[:space:]]*/, "", value)
			print value
			exit
		}
	' "$file")
	[ -n "$setup_font_size" ]
}

setup_prompt_repo_dir() {
	local display answer
	display=$(setup_display_home_path "$setup_repo_dir")
	setup_ui_clear 3
	setup_ui_banner 3
	setup_ui_step 3 1 4 'Repository'
	setup_ui_key_value 3 Platform "$setup_platform"
	setup_ui_key_value 3 Profile "${setup_profile:-recommended}"
	setup_ui_prompt 3 'Dotfiles repository' "$display"
	IFS= read -r answer <&3 || setup_die "failed to read dotfiles repository path"
	[ -n "$answer" ] || return 0
	case $answer in
		\~) setup_repo_dir=$HOME ;;
		\~/*) setup_repo_dir=$HOME/${answer#\~/} ;;
		*) setup_repo_dir=$answer ;;
	esac
}

setup_prepare_numeric_options() {
	local answer emacs_build
	if [ -z "$setup_font_size" ]; then
		setup_read_existing_font_size 2>/dev/null || setup_font_size=10
	fi
	[ -n "$setup_jobs" ] || setup_default_jobs
	if [ "$setup_interactive" -eq 1 ]; then
		emacs_build=disabled
		[ "$setup_build_emacs" -eq 1 ] && emacs_build=enabled
		setup_ui_clear 3
		setup_ui_banner 3
		setup_ui_step 3 3 4 'Options'
		setup_ui_key_value 3 'Emacs build' "$emacs_build"
		setup_ui_key_value 3 'Build jobs' "$setup_jobs"
		setup_ui_prompt 3 'Font size' "$setup_font_size"
		IFS= read -r answer <&3 || setup_die "failed to read font size"
		[ -z "$answer" ] || setup_font_size=$answer
	fi
	case $setup_font_size in ''|*[!0-9]*|0) setup_die "--font-size must be a positive integer" 2 ;; esac
	case $setup_jobs in ''|*[!0-9]*|0) setup_die "--jobs must be a positive integer" 2 ;; esac
}

setup_apply_profile() {
	local components component
	[ -n "$setup_profile" ] || return 0
	setup_profile_find "$setup_profile" || setup_die "unknown profile: $setup_profile" 2
	components=${setup_profile_components[$setup_profile_index]}
	[ "$components" = - ] && return 0
	for component in $components; do
		setup_component_supported "$component" && setup_selected_add "$component"
	done
}

setup_validate_requested_component() {
	local component=$1
	case $component in *[!a-z0-9-]*|'') setup_die "invalid component name: $component" 2 ;; esac
	setup_catalog_find "$component" || setup_die "unknown component: $component" 2
	setup_component_supported "$component" || \
		setup_die "component $component is not supported on $setup_platform" 2
}

setup_apply_explicit_selection() {
	local component
	for component in "${setup_with_specs[@]}"; do
		setup_validate_requested_component "$component"
		setup_excluded_remove "$component"
		setup_selected_add "$component"
	done
	for component in "${setup_without_specs[@]}"; do
		setup_validate_requested_component "$component"
		setup_selected_remove "$component"
		setup_excluded_add "$component"
	done
	if [ "$setup_build_emacs" -eq 1 ]; then
		setup_excluded_contains emacs && setup_die "emacs is required by --build-emacs but was excluded" 2
		setup_selected_add emacs
	fi
	if [ -n "$setup_gpg_key" ]; then
		setup_excluded_contains secrets && setup_die "secrets is required by --gpg-key but was excluded" 2
		setup_selected_add secrets
	fi
}

setup_add_dependency() {
	local parent=$1
	local dependency=$2
	setup_excluded_contains "$dependency" && \
		setup_die "component $dependency is required by $parent but was explicitly excluded" 2
	if [ "$setup_interactive" -eq 1 ] && setup_detected_contains "$dependency" && \
		! setup_selected_contains "$dependency"; then
		return 0
	fi
	if ! setup_selected_contains "$dependency"; then
		setup_selected_add "$dependency"
		setup_dependency_note_add "$dependency (required by $parent)"
	fi
}

setup_resolve_dependencies() {
	local changed before component dependency dependencies
	changed=1
	while [ "$changed" -eq 1 ]; do
		changed=0
		before=${#setup_selected[@]}
		for component in "${setup_selected[@]}"; do
			setup_catalog_find "$component" || setup_die "unknown selected component: $component" 2
			dependencies=${setup_catalog_dependencies[$setup_catalog_index]}
			if [ "$dependencies" != - ]; then
				for dependency in $dependencies; do
					setup_add_dependency "$component" "$dependency"
				done
			fi
		done
		[ "$before" -eq "${#setup_selected[@]}" ] || changed=1
	done
}

setup_selection_in_catalog_order() {
	local component
	for component in "${setup_catalog_names[@]}"; do
		setup_selected_contains "$component" && printf '%s\n' "$component"
	done
}

setup_toggle_component() {
	local component=$1
	if setup_selected_contains "$component"; then
		setup_selected_remove "$component"
		setup_excluded_add "$component"
	else
		setup_excluded_remove "$component"
		setup_selected_add "$component"
	fi
}

setup_interactive_menu() {
	local component index mark answer token label feedback status_style
	local missing=()
	local present=()
	local menu=()
	while IFS= read -r component; do
		[ -n "$component" ] || continue
		if setup_detected_contains "$component"; then
			present[${#present[@]}]=$component
		else
			missing[${#missing[@]}]=$component
		fi
	done <<EOF
$(setup_available_components)
EOF
	for component in "${missing[@]}" "${present[@]}"; do
		[ -n "$component" ] && menu[${#menu[@]}]=$component
	done

	feedback=
	while :; do
		setup_ui_clear 3
		setup_ui_banner 3
		setup_ui_step 3 2 4 'Components'
		setup_ui_key_value 3 Platform "$setup_platform"
		setup_ui_key_value 3 Selected "${#setup_selected[@]}"
		setup_ui_section 3 'Needs setup'
		[ ${#missing[@]} -gt 0 ] || setup_ui_status 3 pending 'None detected'
		index=1
		for component in "${menu[@]}"; do
			if [ "$index" -eq $((${#missing[@]} + 1)) ] && [ ${#present[@]} -gt 0 ]; then
				setup_ui_section 3 'Already installed'
			fi
			mark=' '
			status_style=muted
			if setup_selected_contains "$component"; then
				mark=$(setup_ui_symbol selected)
				status_style=success
			fi
			label=$(setup_component_label "$component")
			printf '  %2d  [' "$index" >&3
			setup_ui_write 3 "$status_style" "$mark"
			printf '] %-12s %s' "$component" "$label" >&3
			if setup_detected_contains "$component"; then
				setup_ui_write 3 muted '  installed; select to rerun'
			fi
			printf '\n' >&3
			index=$((index + 1))
		done
		setup_ui_line 3 muted ''
		setup_ui_line 3 muted '  Toggle one or more numbers (spaces or commas), then press Enter.'
		[ -z "$feedback" ] || setup_ui_warning 3 "$feedback"
		feedback=
		setup_ui_prompt 3 'Selection' ''
		IFS= read -r answer <&3 || setup_die "failed to read component selection"
		[ -z "$answer" ] && break
		answer=${answer//,/ }
		for token in $answer; do
			case $token in
				*[!0-9]*|'') feedback="Ignoring invalid menu item: $token"; continue ;;
			esac
			if [ "$token" -lt 1 ] || [ "$token" -gt "${#menu[@]}" ]; then
				feedback="Menu item out of range: $token"
				continue
			fi
			setup_toggle_component "${menu[$((token - 1))]}"
		done
	done
}

setup_prepare_selection() {
	local component
	if [ "$setup_command" = interactive ]; then
		setup_interactive=1
		setup_open_tty || setup_die "interactive mode requires a TTY" 3
		setup_prompt_repo_dir
		setup_ui_status 3 info 'Detecting installed components...'
		setup_detect_present_components
		setup_apply_profile
		for component in "${setup_detected_present[@]}"; do
			setup_selected_remove "$component"
		done
		setup_apply_explicit_selection
		setup_interactive_menu
	else
		setup_apply_profile
		setup_apply_explicit_selection
	fi
	setup_resolve_dependencies
	setup_prepare_numeric_options
}

setup_print_plan() {
	local component label proxy_names note annotation symbol
	if [ "$setup_interactive" -eq 1 ]; then
		setup_ui_clear 1
		setup_ui_banner 1
		setup_ui_step 1 4 4 'Review'
	else
		setup_ui_banner 1
		setup_ui_section 1 'Setup plan'
	fi
	setup_ui_section 1 'Environment'
	setup_ui_key_value 1 Platform "$setup_platform"
	setup_ui_key_value 1 Repository "$(setup_display_home_path "$setup_repo_dir")"
	setup_ui_key_value 1 Profile "${setup_profile:-custom}"
	setup_ui_key_value 1 'Font size' "$setup_font_size"
	setup_ui_section 1 "Components (${#setup_selected[@]} selected)"
	if [ ${#setup_selected[@]} -eq 0 ]; then
		setup_ui_status 1 pending 'none (core and dotfiles only)'
	else
		while IFS= read -r component; do
			[ -n "$component" ] || continue
			label=$(setup_component_label "$component")
			annotation=
			for note in "${setup_dependency_notes[@]}"; do
				case $note in "$component "*) annotation=dependency ;; esac
			done
			if setup_detected_contains "$component"; then
				annotation="${annotation:+$annotation; }reinstall"
			fi
			symbol=$(setup_ui_symbol success)
			printf '  '
			setup_ui_write 1 success "$symbol"
			printf ' '
			setup_ui_write 1 strong "$component:"
			printf ' %s' "$label"
			[ -z "$annotation" ] || setup_ui_write 1 muted "  [$annotation]"
			printf '\n'
		done <<EOF
$(setup_selection_in_catalog_order)
EOF
	fi
	if [ ${#setup_dependency_notes[@]} -gt 0 ]; then
		setup_ui_section 1 'Automatically added dependencies'
		for note in "${setup_dependency_notes[@]}"; do setup_ui_status 1 info "$note"; done
	fi
	if [ "$setup_build_emacs" -eq 1 ]; then
		setup_ui_section 1 'Build options'
		setup_ui_key_value 1 Emacs "configure, build with $setup_jobs jobs, and install"
	elif setup_selected_contains emacs; then
		setup_ui_section 1 'Build options'
		setup_ui_key_value 1 Emacs 'prepare source through configure; build remains manual'
	fi
	proxy_names=$(setup_proxy_variable_names)
	setup_ui_section 1 'Network'
	if [ -n "$proxy_names" ]; then
		setup_ui_line 1 muted '  Inherited proxy variables (values hidden):'
		while IFS= read -r note; do [ -n "$note" ] && setup_ui_status 1 info "$note"; done <<EOF
$proxy_names
EOF
	else
		setup_ui_line 1 muted '  Inherited proxy variables: none'
	fi
	setup_ui_section 1 'Safety'
	setup_ui_status 1 info 'Existing files are never adopted, deleted, or overwritten by setup.'
}

setup_confirm() {
	local prompt=$1
	local answer
	[ "$setup_assume_yes" -eq 1 ] && return 0
	setup_open_tty || setup_die "confirmation requires a TTY; pass --yes for unattended execution" 3
	printf '\n  ' >&3
	setup_ui_write 3 warning "$prompt"
	setup_ui_write 3 muted ' [y/N] '
	IFS= read -r answer <&3 || return 1
	case $answer in y|Y|yes|YES|Yes) return 0 ;; *) return 1 ;; esac
}

setup_execute() {
	local component index total
	[ "$(id -u)" -ne 0 ] || setup_die "do not run apply as root; it uses sudo only for privileged steps" 3
	setup_confirm "Apply this setup plan?" || setup_die "setup cancelled"
	setup_started_at=$(date +%s)
	setup_start_logging
	setup_prepare_privileges
	setup_install_core
	setup_sync_dotfiles_repo
	total=${#setup_selected[@]}
	setup_ui_step 1 3 5 "Installing components ($total selected)"
	[ "$total" -gt 0 ] || setup_ui_status 1 pending 'No optional components selected.'
	index=0
	while IFS= read -r component; do
		if [ -n "$component" ]; then
			index=$((index + 1))
			setup_run_component "$component" "$index" "$total"
		fi
	done <<EOF
$(setup_selection_in_catalog_order)
EOF
	setup_deploy_dotfiles
	setup_activate_post_deploy
	setup_finish
}

setup_main() {
	setup_ui_init
	setup_install_traps
	setup_load_catalog
	setup_load_profiles
	setup_detect_platform
	setup_parse_args "$@"
	setup_prepare_selection
	setup_print_plan
	case $setup_command in
		plan) return 0 ;;
		apply|interactive) setup_execute ;;
	esac
}
