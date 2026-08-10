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
	printf 'Dotfiles repository [%s]: ' "$display" >&3
	IFS= read -r answer <&3 || setup_die "failed to read dotfiles repository path"
	[ -n "$answer" ] || return 0
	case $answer in
		\~) setup_repo_dir=$HOME ;;
		\~/*) setup_repo_dir=$HOME/${answer#\~/} ;;
		*) setup_repo_dir=$answer ;;
	esac
}

setup_prepare_numeric_options() {
	local answer
	if [ -z "$setup_font_size" ]; then
		setup_read_existing_font_size 2>/dev/null || setup_font_size=10
	fi
	if [ "$setup_interactive" -eq 1 ]; then
		printf 'Font size [%s]: ' "$setup_font_size" >&3
		IFS= read -r answer <&3 || setup_die "failed to read font size"
		[ -z "$answer" ] || setup_font_size=$answer
	fi
	case $setup_font_size in ''|*[!0-9]*|0) setup_die "--font-size must be a positive integer" 2 ;; esac
	[ -n "$setup_jobs" ] || setup_default_jobs
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
	local component index mark state answer token label
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

	while :; do
		printf '\nSelect components for %s (toggle numbers, Enter to continue):\n' "$setup_platform" >&3
		printf '  Missing or unverified:\n' >&3
		[ ${#missing[@]} -gt 0 ] || printf '    none\n' >&3
		index=1
		for component in "${menu[@]}"; do
			if [ "$index" -eq $((${#missing[@]} + 1)) ] && [ ${#present[@]} -gt 0 ]; then
				printf '  Already installed (default off; select to rerun):\n' >&3
			fi
			mark=' '
			setup_selected_contains "$component" && mark=x
			state=
			setup_detected_contains "$component" && state=' [installed]'
			label=$(setup_component_label "$component")
			printf '  %2d. [%s] %-12s %s%s\n' "$index" "$mark" "$component" "$label" "$state" >&3
			index=$((index + 1))
		done
		printf '> ' >&3
		IFS= read -r answer <&3 || setup_die "failed to read component selection"
		[ -z "$answer" ] && break
		answer=${answer//,/ }
		for token in $answer; do
			case $token in *[!0-9]*|'') setup_warn "ignoring invalid menu item: $token"; continue ;; esac
			if [ "$token" -lt 1 ] || [ "$token" -gt "${#menu[@]}" ]; then
				setup_warn "menu item out of range: $token"
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
	local component label proxy_names note
	setup_say ""
	setup_say "Setup plan"
	setup_say "  Platform: $setup_platform"
	setup_say "  Repository: $setup_repo_dir"
	setup_say "  Profile: ${setup_profile:-custom}"
	setup_say "  Font size: $setup_font_size"
	setup_say "  Components:"
	if [ ${#setup_selected[@]} -eq 0 ]; then
		setup_say "    - none (core and dotfiles only)"
	else
		while IFS= read -r component; do
			[ -n "$component" ] || continue
			label=$(setup_component_label "$component")
			setup_say "    - $component: $label"
		done <<EOF
$(setup_selection_in_catalog_order)
EOF
	fi
	if [ ${#setup_dependency_notes[@]} -gt 0 ]; then
		setup_say "  Automatically added dependencies:"
		for note in "${setup_dependency_notes[@]}"; do setup_say "    - $note"; done
	fi
	if [ "$setup_build_emacs" -eq 1 ]; then
		setup_say "  Emacs: configure, build with $setup_jobs jobs, and install"
	elif setup_selected_contains emacs; then
		setup_say "  Emacs: prepare source through configure; build remains manual"
	fi
	proxy_names=$(setup_proxy_variable_names)
	if [ -n "$proxy_names" ]; then
		setup_say "  Inherited proxy variables (values hidden):"
		while IFS= read -r note; do [ -n "$note" ] && setup_say "    - $note"; done <<EOF
$proxy_names
EOF
	else
		setup_say "  Inherited proxy variables: none"
	fi
	setup_say "  Existing files are never adopted, deleted, or overwritten by setup."
}

setup_confirm() {
	local prompt=$1
	local answer
	[ "$setup_assume_yes" -eq 1 ] && return 0
	setup_open_tty || setup_die "confirmation requires a TTY; pass --yes for unattended execution" 3
	printf '%s [y/N] ' "$prompt" >&3
	IFS= read -r answer <&3 || return 1
	case $answer in y|Y|yes|YES|Yes) return 0 ;; *) return 1 ;; esac
}

setup_execute() {
	local component
	[ "$(id -u)" -ne 0 ] || setup_die "do not run apply as root; it uses sudo only for privileged steps" 3
	setup_confirm "Apply this setup plan?" || setup_die "setup cancelled"
	setup_start_logging
	setup_prepare_privileges
	setup_install_core
	setup_sync_dotfiles_repo
	while IFS= read -r component; do
		[ -n "$component" ] && setup_run_component "$component"
	done <<EOF
$(setup_selection_in_catalog_order)
EOF
	setup_deploy_dotfiles
	setup_activate_post_deploy
	setup_finish
}

setup_main() {
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
