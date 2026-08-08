#!/bin/bash

set -o pipefail

program=${0##*/}
repo_https=https://github.com/Jamie-Cui/dotfiles.git
repo_ssh=git@github.com:Jamie-Cui/dotfiles.git
repo_branch=master
repo_dir=${HOME}/opt/dotfiles
opt_dir=${HOME}/opt
emacs_dir=${opt_dir}/emacs-src
ctags_dir=${opt_dir}/ctags
org_root_dir=${opt_dir}/org-root
tdlib_dir=${opt_dir}/tdlib
ctags_repo=https://github.com/universal-ctags/ctags.git
org_root_repo=git@github.com:Jamie-Cui/org-root.git
tdlib_repo=https://github.com/tdlib/td.git

all_components="shell font vim nvim emacs ctags org-root tdlib kitty flameshot rime x11 i3 rofi hyprland waybar dunst mail secrets aerospace borders"
selected=()
excluded=()
dependency_notes=()
with_specs=()
without_specs=()
installed=()
skipped=()
failed=()
pending=()
temporary_paths=()

platform=
preset=
font_size=
jobs=
gpg_key=
dry_run=0
assume_yes=0
build_emacs=0
allow_low_disk=0
sudo_keepalive_pid=
log_file=
tty_open=0

usage() {
	cat <<'EOF'
Usage: setup.sh [options]

Install applications and deploy Jamie-Cui/dotfiles on macOS or Fedora.

Selection:
  --preset NAME          minimal, recommended, or all
  --with LIST            Add comma-separated components (repeatable)
  --without LIST         Remove comma-separated components (repeatable)

Configuration:
  --font-size SIZE       Persist the generated dotfiles font size (default: 10)
  --repo-dir DIR         Clone/use the dotfiles repository at DIR
  --gpg-key FILE         Import an armored OpenPGP secret-key backup
  --build-emacs          Build and install Emacs after configuring the source
  --jobs N               Emacs build jobs (default: min(logical CPUs, 4))
  --allow-low-disk       Build Emacs even with less than 10 GiB available

Execution:
  --yes                  Accept the install and Stow confirmations
  --dry-run              Inspect and print the plan without writing or networking
  -h, --help             Show this help

Components:
  shell, font, vim, nvim, emacs, ctags, org-root, tdlib, kitty,
  flameshot, rime, x11, i3, rofi, hyprland, waybar, dunst, mail,
  secrets, aerospace, borders
  Clone-only: ctags and tdlib use depth=1; org-root keeps full history

Examples:
  setup.sh
  setup.sh --preset recommended --yes
  setup.sh --preset minimal --with emacs --build-emacs --yes
  setup.sh --preset all --without borders --yes
EOF
}

say() {
	printf '%s\n' "$*"
}

warn() {
	printf 'warning: %s\n' "$*" >&2
}

die() {
	printf '%s: %s\n' "$program" "$1" >&2
	exit "${2:-1}"
}

array_contains() {
	needle=$1
	shift
	for item in "$@"; do
		[ "$item" = "$needle" ] && return 0
	done
	return 1
}

add_unique() {
	array_name=$1
	value=$2
	eval "set -- \"\${${array_name}[@]}\""
	array_contains "$value" "$@" && return 0
	eval "${array_name}[\${#${array_name}[@]}]=\$value"
}

remove_value() {
	array_name=$1
	value=$2
	eval "set -- \"\${${array_name}[@]}\""
	new_values=()
	for item in "$@"; do
		[ "$item" = "$value" ] || new_values[${#new_values[@]}]=$item
	done
	eval "${array_name}=(\"\${new_values[@]}\")"
}

add_selected() {
	component=$1
	if array_contains "$component" "${excluded[@]}"; then
		die "component '$component' is required but was explicitly excluded"
	fi
	add_unique selected "$component"
}

add_dependency() {
	parent=$1
	dependency=$2
	if ! array_contains "$dependency" "${selected[@]}"; then
		add_selected "$dependency"
		add_unique dependency_notes "$dependency (required by $parent)"
	else
		add_selected "$dependency"
	fi
}

component_known() {
	case " $all_components " in
		*" $1 "*) return 0 ;;
		*) return 1 ;;
	esac
}

component_label() {
	case "$1" in
		ctags|tdlib) printf '%s (clone-only, depth=1)\n' "$1" ;;
		org-root) printf '%s (clone-only, full history)\n' "$1" ;;
		*) printf '%s\n' "$1" ;;
	esac
}

component_supported() {
	component=$1
	case "$component" in
		x11|i3|rofi|hyprland|waybar|dunst|mail)
			[ "$platform" = fedora ]
			;;
		aerospace|borders)
			[ "$platform" = macos ]
			;;
		*)
			return 0
			;;
	esac
}

available_components() {
	for component in $all_components; do
		component_supported "$component" && printf '%s\n' "$component"
	done
}

detect_platform() {
	case "${DOTFILES_SETUP_OS:-}" in
		macos|fedora)
			platform=$DOTFILES_SETUP_OS
			return
			;;
		'') ;;
		*) die "invalid DOTFILES_SETUP_OS test override" ;;
	esac

	case "$(uname -s)" in
		Darwin)
			platform=macos
			;;
		Linux)
			if [ ! -r /etc/os-release ]; then
				die "Linux is supported only when /etc/os-release identifies Fedora"
			fi
			# shellcheck disable=SC1091
			. /etc/os-release
			[ "${ID:-}" = fedora ] || die "unsupported Linux distribution: ${ID:-unknown}; only Fedora is supported"
			platform=fedora
			;;
		*)
			die "unsupported operating system: $(uname -s)"
			;;
	esac
}

open_tty() {
	[ "$tty_open" -eq 1 ] && return 0
	[ "${DOTFILES_SETUP_NO_TTY:-0}" = 1 ] && return 1
	if exec 3<>/dev/tty 2>/dev/null; then
		tty_open=1
		return 0
	fi
	return 1
}

apply_preset() {
	case "$1" in
		minimal)
			;;
		recommended)
			for component in shell font vim nvim kitty rime; do
				add_selected "$component"
			done
			[ "$platform" = macos ] && add_selected aerospace
			;;
		all)
			while IFS= read -r component; do
				add_selected "$component"
			done <<EOF
$(available_components)
EOF
			;;
		*)
			die "unknown preset '$1'; choose minimal, recommended, or all"
			;;
	esac
}

for_each_spec() {
	action=$1
	spec=$2
	old_ifs=$IFS
	IFS=,
	set -- $spec
	IFS=$old_ifs
	for component in "$@"; do
		component=${component//[[:space:]]/}
		[ -n "$component" ] || continue
		component_known "$component" || die "unknown component '$component'"
		component_supported "$component" || die "component '$component' is not supported on $platform"
		case "$action" in
			add)
				remove_value excluded "$component"
				add_selected "$component"
				;;
			remove)
				remove_value selected "$component"
				add_unique excluded "$component"
				;;
		esac
	done
}

toggle_component() {
	component=$1
	if array_contains "$component" "${selected[@]}"; then
		remove_value selected "$component"
		add_unique excluded "$component"
	else
		remove_value excluded "$component"
		add_selected "$component"
	fi
}

interactive_menu() {
	open_tty || die "interactive selection requires a TTY; pass --preset or --with and --yes"
	menu_components=()
	while IFS= read -r component; do
		menu_components[${#menu_components[@]}]=$component
	done <<EOF
$(available_components)
EOF

	while :; do
		printf '\nSelect components for %s (toggle numbers, Enter to continue):\n' "$platform" >&3
		index=1
		for component in "${menu_components[@]}"; do
			mark=' '
			array_contains "$component" "${selected[@]}" && mark=x
			printf '  %2d. [%s] %s\n' "$index" "$mark" "$(component_label "$component")" >&3
			index=$((index + 1))
		done
		printf '> ' >&3
		IFS= read -r answer <&3 || die "failed to read component selection"
		[ -z "$answer" ] && break
		answer=${answer//,/ }
		for token in $answer; do
			case "$token" in
				*[!0-9]*|'')
					warn "ignoring invalid menu item: $token"
					continue
					;;
			esac
			if [ "$token" -lt 1 ] || [ "$token" -gt "${#menu_components[@]}" ]; then
				warn "menu item out of range: $token"
				continue
			fi
			toggle_component "${menu_components[$((token - 1))]}"
		done
	done
}

resolve_dependencies() {
	changed=1
	while [ "$changed" -eq 1 ]; do
		changed=0
		before=${#selected[@]}
		if array_contains i3 "${selected[@]}"; then
			for dependency in x11 rofi dunst flameshot kitty; do add_dependency i3 "$dependency"; done
		fi
		if array_contains hyprland "${selected[@]}"; then
			for dependency in rofi waybar dunst flameshot rime kitty; do add_dependency hyprland "$dependency"; done
		fi
		if array_contains aerospace "${selected[@]}"; then
			add_dependency aerospace kitty
		fi
		if array_contains mail "${selected[@]}"; then
			add_dependency mail secrets
		fi
		[ "$before" -eq "${#selected[@]}" ] || changed=1
	done
}

default_jobs() {
	if [ "$platform" = macos ]; then
		count=$(sysctl -n hw.logicalcpu 2>/dev/null || printf '1')
	else
		count=$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '1')
	fi
	case "$count" in *[!0-9]*|'') count=1 ;; esac
	[ "$count" -gt 4 ] && count=4
	printf '%s\n' "$count"
}

read_existing_font_size() {
	[ -f "$repo_dir/local.mk" ] || return 1
	awk '
		/^[[:space:]]*FONT_SIZE[[:space:]]*[:?+]?=/ {
			value = $0
			sub(/^[^=]*=[[:space:]]*/, "", value)
			print value
			exit
		}
	' "$repo_dir/local.mk"
}

prompt_font_size() {
	[ -n "$font_size" ] && return
	font_size=$(read_existing_font_size 2>/dev/null || true)
	case "$font_size" in ''|*[!0-9]*) font_size=10 ;; esac
	if [ "$tty_open" -eq 1 ]; then
		printf 'Font size [%s]: ' "$font_size" >&3
		IFS= read -r answer <&3 || die "failed to read font size"
		[ -z "$answer" ] || font_size=$answer
	fi
}

validate_number_options() {
	case "$font_size" in ''|*[!0-9]*|0) die "--font-size must be a positive integer" ;; esac
	if [ -z "$jobs" ]; then jobs=$(default_jobs); fi
	case "$jobs" in ''|*[!0-9]*|0) die "--jobs must be a positive integer" ;; esac
}

selected_in_catalog_order() {
	for component in $all_components; do
		array_contains "$component" "${selected[@]}" && printf '%s\n' "$component"
	done
}

proxy_variable_names() {
	for name in http_proxy https_proxy all_proxy no_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY; do
		eval "is_set=\${$name+x}"
		# ShellCheck cannot follow the eval-based Bash 3.2-compatible indirection.
		# shellcheck disable=SC2154
		[ "$is_set" = x ] && printf '%s\n' "$name"
	done
}

print_summary() {
	say ""
	say "Setup plan"
	say "  Platform: $platform"
	say "  Repository: $repo_dir"
	say "  Preset: ${preset:-custom}"
	say "  Font size: $font_size"
	say "  Components:"
	while IFS= read -r component; do
		[ -n "$component" ] && say "    - $(component_label "$component")"
	done <<EOF
$(selected_in_catalog_order)
EOF
	[ ${#selected[@]} -gt 0 ] || say "    - none (core and dotfiles only)"
	if [ ${#dependency_notes[@]} -gt 0 ]; then
		say "  Automatically added dependencies:"
		for note in "${dependency_notes[@]}"; do say "    - $note"; done
	fi
	if [ "$build_emacs" -eq 1 ]; then
		say "  Emacs: configure, build with $jobs jobs, and install"
	elif array_contains emacs "${selected[@]}"; then
		say "  Emacs: prepare source through configure; build remains manual"
	fi
	if { [ "$platform" = fedora ] && array_contains mail "${selected[@]}"; } || \
		{ [ "$platform" = macos ] && { array_contains aerospace "${selected[@]}" || array_contains borders "${selected[@]}"; }; }; then
		say "  Third-party sources:"
		[ "$platform" = fedora ] && array_contains mail "${selected[@]}" && say "    - COPR mguessan/davmail"
		[ "$platform" = macos ] && array_contains aerospace "${selected[@]}" && say "    - Homebrew tap nikitabobko/tap"
		[ "$platform" = macos ] && array_contains borders "${selected[@]}" && say "    - Homebrew tap FelixKratz/formulae"
	fi
	proxy_names=$(proxy_variable_names)
	if [ -n "$proxy_names" ]; then
		say "  Inherited proxy variables (values hidden):"
		while IFS= read -r name; do say "    - $name"; done <<EOF
$proxy_names
EOF
	else
		say "  Inherited proxy variables: none"
	fi
	say "  Existing files are never adopted, deleted, or overwritten by setup."
}

confirm() {
	prompt=$1
	[ "$assume_yes" -eq 1 ] && return 0
	open_tty || die "confirmation requires a TTY; pass --yes for unattended execution"
	printf '%s [y/N] ' "$prompt" >&3
	IFS= read -r answer <&3 || return 1
	case "$answer" in y|Y|yes|YES|Yes) return 0 ;; *) return 1 ;; esac
}

print_dry_run() {
	say ""
	say "Dry run only; no files, packages, repositories, logs, or credentials were changed."
	say "Would:"
	if [ "$platform" = macos ]; then
		say "  1. Verify Xcode Command Line Tools and install Homebrew/GNU Stow if missing."
	else
		say "  1. Install missing core packages with dnf through a proxy-only sudo environment."
	fi
	say "  2. Clone or safely fast-forward $repo_https at $repo_dir."
	say "  3. Install the selected independent components and collect failures."
	say "  4. Run ./configure --font $font_size and make dry-run."
	say "  5. Run make bootstrap, proxyctl init, and selected user-service activation."
}

cleanup() {
	if [ -n "$sudo_keepalive_pid" ]; then
		kill "$sudo_keepalive_pid" 2>/dev/null || true
		wait "$sudo_keepalive_pid" 2>/dev/null || true
	fi
	for path in "${temporary_paths[@]}"; do
		case "$path" in /tmp/*|"${TMPDIR:-/tmp}"/*) rm -rf -- "$path" ;; esac
	done
}

on_signal() {
	trap - EXIT HUP INT TERM
	cleanup
	exit 130
}

trap cleanup EXIT
trap on_signal HUP INT TERM

make_temp_dir() {
	temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-setup.XXXXXX") || return 1
	temporary_paths[${#temporary_paths[@]}]=$temp_dir
	printf '%s\n' "$temp_dir"
}

start_logging() {
	state_dir=$HOME/.local/state/dotfiles
	mkdir -p "$state_dir" || die "cannot create log directory $state_dir"
	log_file=$state_dir/setup-$(date +%Y%m%d-%H%M%S).log
	touch "$log_file" || die "cannot create log file $log_file"
	exec > >(tee -a "$log_file") 2>&1
	say "Log: $log_file"
}

download_file() {
	url=$1
	destination=$2
	curl -fL --retry 3 --retry-delay 2 --connect-timeout 15 "$url" -o "$destination" && [ -s "$destination" ]
}

sudo_proxy_args() {
	for name in http_proxy https_proxy all_proxy no_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY; do
		eval "is_set=\${$name+x}"
		if [ "$is_set" = x ]; then
			eval "value=\${$name}"
			printf '%s=%s\n' "$name" "$value"
		fi
	done
}

sudo_run() {
	proxy_args=()
	while IFS= read -r assignment; do
		[ -n "$assignment" ] && proxy_args[${#proxy_args[@]}]=$assignment
	done <<EOF
$(sudo_proxy_args)
EOF
	if [ ${#proxy_args[@]} -gt 0 ]; then
		sudo env "${proxy_args[@]}" "$@"
	else
		sudo "$@"
	fi
}

ensure_sudo() {
	sudo -v || die "sudo authentication failed"
	if [ "${DOTFILES_SETUP_DISABLE_SUDO_KEEPALIVE:-0}" != 1 ]; then
		(
			while kill -0 "$$" 2>/dev/null; do
				sudo -n -v 2>/dev/null || exit 0
				sleep 50
			done
		) &
		sudo_keepalive_pid=$!
	fi
}

all_rpms_installed() {
	for package in "$@"; do
		rpm -q "$package" >/dev/null 2>&1 || return 1
	done
	return 0
}

dnf_install() {
	if all_rpms_installed "$@"; then return 0; fi
	sudo_run dnf install -y "$@"
}

brew_command() {
	if command -v brew >/dev/null 2>&1; then return 0; fi
	for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew; do
		if [ -x "$candidate" ]; then
			eval "$("$candidate" shellenv)"
			return 0
		fi
	done
	return 1
}

brew_formula() {
	package=$1
	if brew list --formula "$package" >/dev/null 2>&1; then
		component_state=skipped
		return 0
	fi
	brew install "$package"
}

brew_cask() {
	package=$1
	shift
	if brew list --cask "$package" >/dev/null 2>&1; then
		component_state=skipped
		return 0
	fi
	brew install --cask "$@"
}

install_homebrew() {
	brew_command && return 0
	temp_dir=$(make_temp_dir) || return 1
	installer=$temp_dir/install-homebrew.sh
	download_file https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh "$installer" || return 1
	NONINTERACTIVE=1 /bin/bash "$installer" || return 1
	brew_command
}

install_core() {
	say ""
	say "==> Installing core prerequisites"
	if [ "$platform" = fedora ]; then
		dnf_install git curl make stow || die "failed to install core Fedora packages"
	else
		if ! xcode-select -p >/dev/null 2>&1; then
			xcode-select --install >/dev/null 2>&1 || true
			die "Xcode Command Line Tools installation was requested; finish it and rerun setup" 75
		fi
		install_homebrew || die "failed to install or initialize Homebrew"
		brew list --formula stow >/dev/null 2>&1 || brew install stow || die "failed to install GNU Stow"
	fi
}

normalized_repo() {
	case "$1" in
		git@github.com:Jamie-Cui/dotfiles.git|git@github.com:Jamie-Cui/dotfiles|https://github.com/Jamie-Cui/dotfiles.git|https://github.com/Jamie-Cui/dotfiles)
			return 0
			;;
		*) return 1 ;;
	esac
}

ssh_repo_available() {
	[ "${DOTFILES_SETUP_SKIP_SSH_PROBE:-0}" = 1 ] && return 1
	GIT_SSH_COMMAND='ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=yes' \
		git ls-remote "$repo_ssh" HEAD >/dev/null 2>&1
}

sync_dotfiles_repo() {
	say ""
	say "==> Preparing dotfiles repository"
	if [ ! -e "$repo_dir" ]; then
		mkdir -p "$(dirname "$repo_dir")" || die "cannot create repository parent directory"
		git clone --branch "$repo_branch" --single-branch "$repo_https" "$repo_dir" || die "failed to clone dotfiles"
	else
		[ -d "$repo_dir/.git" ] || die "$repo_dir exists but is not a Git repository"
		remote=$(git -C "$repo_dir" remote get-url origin 2>/dev/null) || die "$repo_dir has no origin remote"
		normalized_repo "$remote" || die "$repo_dir origin is not Jamie-Cui/dotfiles: $remote"
		[ -z "$(git -C "$repo_dir" status --porcelain)" ] || die "$repo_dir has local changes; commit or stash them before setup"
		case "$remote" in
			git@github.com:*)
				if ! ssh_repo_available; then
					git -C "$repo_dir" remote set-url origin "$repo_https" || die "failed to switch origin to HTTPS"
				fi
				;;
		esac
		git -C "$repo_dir" fetch origin "$repo_branch" || die "failed to fetch dotfiles"
		head=$(git -C "$repo_dir" rev-parse HEAD) || die "failed to inspect dotfiles HEAD"
		upstream=$(git -C "$repo_dir" rev-parse "origin/$repo_branch") || die "failed to inspect origin/$repo_branch"
		if [ "$head" != "$upstream" ]; then
			git -C "$repo_dir" merge-base --is-ancestor HEAD "origin/$repo_branch" || \
				die "dotfiles cannot be fast-forwarded to origin/$repo_branch"
			git -C "$repo_dir" merge --ff-only "origin/$repo_branch" || die "failed to fast-forward dotfiles"
		fi
	fi
	if ssh_repo_available; then
		git -C "$repo_dir" remote set-url origin "$repo_ssh" || die "failed to switch origin to SSH"
	fi
}

sync_emacs_repo() {
	if [ ! -e "$emacs_dir" ]; then
		mkdir -p "$(dirname "$emacs_dir")" || return 1
		git clone --branch emacs-31 --single-branch https://github.com/emacs-mirror/emacs.git "$emacs_dir" || return 1
		return 0
	fi
	[ -d "$emacs_dir/.git" ] || { warn "$emacs_dir exists but is not a Git repository"; return 1; }
	[ -z "$(git -C "$emacs_dir" status --porcelain)" ] || { warn "$emacs_dir has local changes"; return 1; }
	remote=$(git -C "$emacs_dir" remote get-url origin 2>/dev/null) || return 1
	case "$remote" in
		https://github.com/emacs-mirror/emacs.git|https://github.com/emacs-mirror/emacs) ;;
		*) warn "$emacs_dir origin is not emacs-mirror/emacs"; return 1 ;;
	esac
	git -C "$emacs_dir" fetch origin emacs-31 || return 1
	head=$(git -C "$emacs_dir" rev-parse HEAD) || return 1
	upstream=$(git -C "$emacs_dir" rev-parse origin/emacs-31) || return 1
	if [ "$head" != "$upstream" ]; then
		git -C "$emacs_dir" merge-base --is-ancestor HEAD origin/emacs-31 || return 1
		git -C "$emacs_dir" merge --ff-only origin/emacs-31 || return 1
	fi
}

clone_source_repo() {
	url=$1
	destination=$2
	depth=${3:-}
	if [ -e "$destination" ]; then
		if [ -d "$destination/.git" ]; then
			component_state=skipped
			return 0
		fi
		warn "$destination exists but is not a Git repository"
		return 1
	fi
	mkdir -p "$(dirname "$destination")" || return 1
	if [ -n "$depth" ]; then
		git clone --depth "$depth" "$url" "$destination"
	else
		git clone "$url" "$destination"
	fi
}

install_shell() {
	component_state=installed
	if [ "$platform" = fedora ]; then
		dnf_install zsh curl util-linux || return 1
	fi
	if [ -d "$HOME/.oh-my-zsh" ]; then
		component_state=skipped
	else
		temp_dir=$(make_temp_dir) || return 1
		installer=$temp_dir/install-oh-my-zsh.sh
		download_file https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh "$installer" || return 1
		KEEP_ZSHRC=yes RUNZSH=no CHSH=no sh "$installer" --unattended || return 1
	fi
	if [ "$platform" = fedora ] && [ "${SHELL:-}" != "$(command -v zsh)" ]; then
		chsh -s "$(command -v zsh)" || return 1
		add_unique pending "Log out and back in to start the new zsh login shell."
	fi
}

install_font() {
	component_state=installed
	if [ "$platform" = macos ]; then
		brew_cask font-maple-mono-nl-nf-cn font-maple-mono-nl-nf-cn
		return
	fi
	dnf_install curl unzip fontconfig || return 1
	if fc-list 2>/dev/null | grep -qi 'Maple Mono NL NF CN'; then
		component_state=skipped
		return 0
	fi
	temp_dir=$(make_temp_dir) || return 1
	archive=$temp_dir/maple-mono.zip
	download_file https://github.com/subframe7536/maple-font/releases/latest/download/MapleMonoNL-NF-CN-unhinted.zip "$archive" || return 1
	mkdir -p "$HOME/.local/share/fonts/maple-mono" || return 1
	unzip -oq "$archive" -d "$HOME/.local/share/fonts/maple-mono" || return 1
	fc-cache -f >/dev/null || return 1
}

install_vim() {
	component_state=installed
	if [ "$platform" = macos ]; then brew_formula vim; else dnf_install vim-enhanced; fi
}

install_nvim() {
	component_state=installed
	if [ "$platform" = macos ]; then brew_formula neovim; else dnf_install neovim; fi
}

emacs_disk_ok() {
	available_kb=$(df -Pk "$HOME" | awk 'NR == 2 { print $4 }')
	case "$available_kb" in ''|*[!0-9]*) return 1 ;; esac
	[ "$available_kb" -ge 10485760 ]
}

install_emacs() {
	component_state=installed
	if [ "$platform" = macos ]; then
		brew install autoconf automake texinfo libgccjit gcc gnutls tree-sitter@0.25 pkg-config coreutils sqlite librsvg || return 1
	else
		dnf_install dnf-plugins-core gcc gcc-c++ make autoconf automake texinfo || return 1
		sudo_run dnf builddep -y emacs || return 1
		dnf_install libgccjit-devel tree-sitter-devel sqlite-devel librsvg2-devel gtk3-devel || return 1
	fi
	sync_emacs_repo || return 1
	(
		cd "$emacs_dir" || exit 1
		./autogen.sh || exit 1
		if [ "$platform" = macos ]; then
			texinfo_prefix=$(brew --prefix texinfo) || exit 1
			PATH="$texinfo_prefix/bin:$PATH"
			export PATH
			PKG_CONFIG_PATH="$(brew --prefix tree-sitter@0.25)/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
			export PKG_CONFIG_PATH
			./configure --with-ns --with-native-compilation --with-tree-sitter --with-sqlite3 --with-rsvg --without-pop --without-mailutils
		else
			./configure --with-pgtk --with-native-compilation --with-tree-sitter --with-sqlite3 --with-rsvg --without-pop --without-mailutils
		fi
	) || return 1

	if [ "$build_emacs" -eq 0 ]; then
		if [ "$platform" = macos ]; then
			add_unique pending "Build Emacs manually: cd $emacs_dir && make -j$jobs && make install; then copy Emacs.app and create CLI links as documented."
		else
			add_unique pending "Build Emacs manually: cd $emacs_dir && make -j$jobs && sudo make install"
		fi
		return 0
	fi
	if [ "$allow_low_disk" -eq 0 ] && ! emacs_disk_ok; then
		warn "less than 10 GiB is available for the Emacs build"
		return 1
	fi
	(
		cd "$emacs_dir" || exit 1
		make -j"$jobs" || exit 1
		if [ "$platform" = macos ]; then
			make install || exit 1
			sudo ditto nextstep/Emacs.app /Applications/Emacs.app || exit 1
			sudo mkdir -p /usr/local/bin || exit 1
			sudo ln -sf /Applications/Emacs.app/Contents/MacOS/Emacs /usr/local/bin/emacs || exit 1
			sudo ln -sf /Applications/Emacs.app/Contents/MacOS/bin/emacsclient /usr/local/bin/emacsclient || exit 1
		else
			sudo_run make install || exit 1
		fi
	)
}

install_ctags() {
	component_state=installed
	clone_source_repo "$ctags_repo" "$ctags_dir" 1
}

install_org_root() {
	component_state=installed
	clone_source_repo "$org_root_repo" "$org_root_dir"
}

install_tdlib() {
	component_state=installed
	clone_source_repo "$tdlib_repo" "$tdlib_dir" 1
}

install_kitty() {
	component_state=installed
	if [ "$platform" = macos ]; then brew_cask kitty kitty; else dnf_install kitty; fi
}

install_flameshot() {
	component_state=installed
	if [ "$platform" = macos ]; then
		if [ -d /Applications/flameshot.app ] || [ -d /Applications/Flameshot.app ]; then
			component_state=skipped
		else
			component_state=pending
			add_unique pending "Install Flameshot from its official macOS release, open it once, and grant Screen & System Audio Recording permission."
		fi
		return 0
	fi
	dnf_install flameshot grim
}

install_rime() {
	component_state=installed
	if [ "$platform" = macos ]; then
		brew_cask squirrel-app squirrel-app
	else
		dnf_install fcitx5 fcitx5-rime fcitx5-gtk fcitx5-qt imsettings im-chooser gtk2 gtk3 gtk4
	fi
}

install_x11() {
	component_state=installed
	dnf_install xorg-x11-server-Xorg xorg-x11-xinit xorg-x11-xauth
}

install_i3() {
	component_state=installed
	dnf_install i3 i3lock picom feh xclip dex-autostart network-manager-applet pulseaudio-utils ibus jq xss-lock setxkbmap i3blocks alsa-utils sysstat perl
}

install_rofi() {
	component_state=installed
	dnf_install rofi firefox
}

install_hyprland() {
	component_state=installed
	dnf_install hyprland hyprlock hyprpaper xdg-desktop-portal-hyprland brightnessctl playerctl wireplumber xclip
}

install_waybar() {
	component_state=installed
	dnf_install waybar jq playerctl blueman network-manager-applet NetworkManager-tui pavucontrol htop baobab
}

install_dunst() {
	component_state=installed
	dnf_install dunst
}

install_secrets() {
	component_state=installed
	if [ "$platform" = macos ]; then brew_formula gnupg || return 1; else dnf_install gnupg2 || return 1; fi
	if [ -n "$gpg_key" ]; then
		[ -f "$gpg_key" ] || { warn "GPG key file does not exist: $gpg_key"; return 1; }
		if [ "$platform" = macos ]; then mode=$(stat -f %Lp "$gpg_key") || return 1; else mode=$(stat -c %a "$gpg_key") || return 1; fi
		case "$mode" in *00) ;; *) warn "GPG key file permissions must be 0600 or stricter: $gpg_key ($mode)"; return 1 ;; esac
		gpg --import "$gpg_key" || return 1
	fi
	ciphertext=$repo_dir/packages/secrets/.authinfo.gpg
	if [ -f "$ciphertext" ]; then
		if [ "$assume_yes" -eq 1 ]; then
			gpg --batch --quiet --decrypt "$ciphertext" >/dev/null 2>&1 || \
				add_unique pending "Import/unlock the matching GPG private key and verify $ciphertext can be decrypted."
		else
			gpg --quiet --decrypt "$ciphertext" >/dev/null 2>&1 || \
				add_unique pending "Import/unlock the matching GPG private key and verify $ciphertext can be decrypted."
		fi
	fi
}

install_mail() {
	component_state=installed
	dnf_install dnf-plugins-core || return 1
	sudo_run dnf copr enable -y mguessan/davmail || return 1
	dnf_install davmail java-latest-openjdk-headless isync maildir-utils gnupg2 || return 1
	mkdir -p "$HOME/.local/state/davmail" "$HOME/.local/share/mail/outlook" || return 1
}

install_aerospace() {
	component_state=installed
	brew_cask aerospace nikitabobko/tap/aerospace || return 1
	needs_defaults=0
	[ "$(defaults read com.apple.dock expose-group-apps 2>/dev/null)" = 1 ] || needs_defaults=1
	[ "$(defaults read com.apple.dock autohide 2>/dev/null)" = 1 ] || needs_defaults=1
	[ "$(defaults read com.apple.dock pinning 2>/dev/null)" = start ] || needs_defaults=1
	if [ "$needs_defaults" -eq 1 ]; then
		add_unique pending "Review and apply the AeroSpace Dock/Mission Control defaults documented in README.org, then restart Dock."
	fi
}

install_borders() {
	component_state=installed
	if brew list --formula borders >/dev/null 2>&1; then
		component_state=skipped
		return 0
	fi
	brew tap FelixKratz/formulae || return 1
	brew install borders
}

run_component() {
	component=$1
	say ""
	say "==> Component: $component"
	component_state=installed
	case "$component" in
		shell) installer=install_shell ;;
		font) installer=install_font ;;
		vim) installer=install_vim ;;
		nvim) installer=install_nvim ;;
		emacs) installer=install_emacs ;;
		ctags) installer=install_ctags ;;
		org-root) installer=install_org_root ;;
		tdlib) installer=install_tdlib ;;
		kitty) installer=install_kitty ;;
		flameshot) installer=install_flameshot ;;
		rime) installer=install_rime ;;
		x11) installer=install_x11 ;;
		i3) installer=install_i3 ;;
		rofi) installer=install_rofi ;;
		hyprland) installer=install_hyprland ;;
		waybar) installer=install_waybar ;;
		dunst) installer=install_dunst ;;
		mail) installer=install_mail ;;
		secrets) installer=install_secrets ;;
		aerospace) installer=install_aerospace ;;
		borders) installer=install_borders ;;
		*) warn "no installer for component $component"; add_unique failed "$component"; return ;;
	esac
	if "$installer"; then
		case "$component_state" in
			skipped) add_unique skipped "$component" ;;
			pending) add_unique pending "$component requires manual completion." ;;
			*) add_unique installed "$component" ;;
		esac
	else
		warn "component failed: $component"
		add_unique failed "$component"
	fi
}

failed_contains() {
	array_contains "$1" "${failed[@]}"
}

deploy_dotfiles() {
	say ""
	say "==> Configuring and previewing dotfiles"
	"$repo_dir/configure" --font "$font_size" || die "failed to persist FONT_SIZE"
	make -C "$repo_dir" dry-run || die "dotfiles dry-run failed; no Stow changes were made"
	confirm "Apply the Stow plan above?" || die "dotfiles deployment cancelled"
	make -C "$repo_dir" bootstrap || die "dotfiles bootstrap failed"
}

activate_post_deploy() {
	say ""
	say "==> Post-deploy activation"
	if command -v zsh >/dev/null 2>&1 && [ -x "$HOME/.local/bin/proxyctl" ]; then
		"$HOME/.local/bin/proxyctl" init || add_unique failed "proxyctl activation"
	else
		add_unique pending "Install zsh and run proxyctl init after dotfiles are deployed."
	fi
	if array_contains mail "${selected[@]}" && ! failed_contains mail; then
		if systemctl --user enable --now davmail.service; then
			add_unique pending "Follow the DavMail device-code prompt in ~/.local/state/davmail/davmail.log, then run the first mbsync manually."
		else
			add_unique failed "DavMail service activation"
		fi
	fi
	if array_contains rime "${selected[@]}"; then
		if [ "$platform" = macos ]; then
			add_unique pending "Add Squirrel in macOS Input Sources, redeploy Rime, and log out if existing apps do not pick it up."
		else
			add_unique pending "Select Fcitx 5 as the input method and log out and back in."
		fi
	fi
}

print_group() {
	title=$1
	shift
	[ "$#" -gt 0 ] || return
	say "$title:"
	for item in "$@"; do say "  - $item"; done
}

finish() {
	say ""
	say "Setup summary"
	print_group Installed "${installed[@]}"
	print_group Skipped "${skipped[@]}"
	print_group Failed "${failed[@]}"
	print_group Pending "${pending[@]}"
	[ -n "$log_file" ] && say "Log: $log_file"
	if [ ${#failed[@]} -gt 0 ]; then
		return 1
	fi
	return 0
}

main() {
	[ "$(id -u)" -ne 0 ] || die "do not run setup as root; it uses sudo only for privileged steps"
	detect_platform
	while [ "$#" -gt 0 ]; do
		case "$1" in
			--preset)
				[ "$#" -ge 2 ] || die "--preset requires a value"
				preset=$2
				shift 2
				;;
			--preset=*) preset=${1#*=}; shift ;;
			--with)
				[ "$#" -ge 2 ] || die "--with requires a value"
				with_specs[${#with_specs[@]}]=$2
				shift 2
				;;
			--with=*) with_specs[${#with_specs[@]}]=${1#*=}; shift ;;
			--without)
				[ "$#" -ge 2 ] || die "--without requires a value"
				without_specs[${#without_specs[@]}]=$2
				shift 2
				;;
			--without=*) without_specs[${#without_specs[@]}]=${1#*=}; shift ;;
			--font-size)
				[ "$#" -ge 2 ] || die "--font-size requires a value"
				font_size=$2
				shift 2
				;;
			--font-size=*) font_size=${1#*=}; shift ;;
			--repo-dir)
				[ "$#" -ge 2 ] || die "--repo-dir requires a value"
				repo_dir=$2
				shift 2
				;;
			--repo-dir=*) repo_dir=${1#*=}; shift ;;
			--gpg-key)
				[ "$#" -ge 2 ] || die "--gpg-key requires a value"
				gpg_key=$2
				shift 2
				;;
			--gpg-key=*) gpg_key=${1#*=}; shift ;;
			--jobs)
				[ "$#" -ge 2 ] || die "--jobs requires a value"
				jobs=$2
				shift 2
				;;
			--jobs=*) jobs=${1#*=}; shift ;;
			--build-emacs) build_emacs=1; shift ;;
			--allow-low-disk) allow_low_disk=1; shift ;;
			--yes) assume_yes=1; shift ;;
			--dry-run) dry_run=1; shift ;;
			-h|--help) usage; exit 0 ;;
			*) die "unknown option: $1" ;;
		esac
	done

	selection_explicit=0
	[ -n "$preset" ] && selection_explicit=1
	[ ${#with_specs[@]} -gt 0 ] && selection_explicit=1
	[ ${#without_specs[@]} -gt 0 ] && selection_explicit=1
	if [ "$selection_explicit" -eq 0 ]; then
		open_tty || die "no component selection and no TTY; pass --preset or --with"
		preset=recommended
		apply_preset "$preset"
		interactive_menu
	else
		[ -n "$preset" ] || preset=minimal
		apply_preset "$preset"
	fi

	for spec in "${with_specs[@]}"; do for_each_spec add "$spec"; done
	for spec in "${without_specs[@]}"; do for_each_spec remove "$spec"; done
	if [ "$build_emacs" -eq 1 ]; then add_selected emacs; fi
	if [ -n "$gpg_key" ]; then add_selected secrets; fi
	resolve_dependencies
	prompt_font_size
	validate_number_options
	print_summary

	if [ "$dry_run" -eq 1 ]; then
		print_dry_run
		exit 0
	fi
	confirm "Run this setup plan?" || die "setup cancelled"
	start_logging

	needs_sudo=0
	[ "$platform" = fedora ] && needs_sudo=1
	[ "$platform" = macos ] && ! brew_command && needs_sudo=1
	[ "$build_emacs" -eq 1 ] && needs_sudo=1
	[ "$needs_sudo" -eq 1 ] && ensure_sudo

	install_core
	sync_dotfiles_repo
	while IFS= read -r component; do
		[ -n "$component" ] && run_component "$component"
	done <<EOF
$(selected_in_catalog_order)
EOF
	deploy_dotfiles
	activate_post_deploy
	finish
}

main "$@"
