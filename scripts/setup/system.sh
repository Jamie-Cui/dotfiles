#!/bin/bash

# Platform, privilege, package-manager, and download mechanisms. This file is sourced.

setup_detect_platform() {
	case ${SETUP_TEST_PLATFORM:-} in
		macos|fedora)
			setup_platform=$SETUP_TEST_PLATFORM
			return 0
			;;
		'') ;;
		*) setup_die "invalid SETUP_TEST_PLATFORM" 3 ;;
	esac

	case $(uname -s) in
		Darwin)
			setup_platform=macos
			;;
		Linux)
			[ -r /etc/os-release ] || setup_die "Linux requires /etc/os-release" 3
			# shellcheck disable=SC1091
			. /etc/os-release
			[ "${ID:-}" = fedora ] || \
				setup_die "unsupported Linux distribution: ${ID:-unknown}; only Fedora is supported" 3
			setup_platform=fedora
			;;
		*) setup_die "unsupported operating system: $(uname -s)" 3 ;;
	esac
}

setup_open_tty() {
	[ "$setup_tty_open" -eq 1 ] && return 0
	[ "${SETUP_NO_TTY:-0}" = 1 ] && return 1
	if exec 3<>/dev/tty 2>/dev/null; then
		setup_tty_open=1
		return 0
	fi
	return 1
}

setup_default_jobs() {
	local count
	if [ "$setup_platform" = macos ]; then
		count=$(sysctl -n hw.logicalcpu 2>/dev/null || printf '1')
	else
		count=$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '1')
	fi
	case $count in *[!0-9]*|'') count=1 ;; esac
	[ "$count" -gt 4 ] && count=4
	setup_jobs=$count
}

setup_proxy_variable_names() {
	local name value
	for name in http_proxy https_proxy all_proxy no_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY; do
		value=${!name}
		[ -n "$value" ] && printf '%s\n' "$name"
	done
}

setup_sudo_proxy_args() {
	local name value
	setup_proxy_args=()
	for name in http_proxy https_proxy all_proxy no_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY; do
		value=${!name}
		[ -n "$value" ] && setup_proxy_args[${#setup_proxy_args[@]}]="$name=$value"
	done
}

setup_sudo_run() {
	setup_sudo_proxy_args
	if [ ${#setup_proxy_args[@]} -gt 0 ]; then
		sudo env "${setup_proxy_args[@]}" "$@"
	else
		sudo "$@"
	fi
}

setup_ensure_sudo() {
	sudo -v || setup_die "sudo authentication failed"
	if [ "${SETUP_DISABLE_SUDO_KEEPALIVE:-0}" != 1 ]; then
		(
			while kill -0 "$$" 2>/dev/null; do
				sudo -n -v 2>/dev/null || exit 0
				sleep 50
			done
		) &
		setup_sudo_keepalive_pid=$!
	fi
}

setup_download_file() {
	local url=$1
	local destination=$2
	curl -fL --retry 3 --retry-delay 2 --connect-timeout 15 \
		"$url" -o "$destination" && [ -s "$destination" ]
}

setup_all_rpms_installed() {
	local package
	for package in "$@"; do
		rpm -q "$package" >/dev/null 2>&1 || return 1
	done
	return 0
}

setup_dnf_install() {
	setup_all_rpms_installed "$@" && return 0
	setup_sudo_run dnf install -y "$@"
}

setup_brew_command() {
	local candidate
	command -v brew >/dev/null 2>&1 && return 0
	for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew; do
		if [ -x "$candidate" ]; then
			PATH=${candidate%/brew}:$PATH
			export PATH
			return 0
		fi
	done
	return 1
}

setup_brew_formula() {
	local package=$1
	brew list --formula "$package" >/dev/null 2>&1 && return 0
	brew install "$package"
}

setup_brew_cask() {
	local package=$1
	shift
	brew list --cask "$package" >/dev/null 2>&1 && return 0
	brew install --cask "$@"
}

setup_install_homebrew() {
	local installer
	setup_brew_command && return 0
	setup_make_temp_dir
	installer=$setup_temp_dir/install-homebrew.sh
	setup_download_file https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh "$installer" || return 1
	NONINTERACTIVE=1 /bin/bash "$installer" || return 1
	setup_brew_command
}

setup_install_core() {
	setup_ui_step 1 1 5 'Installing core prerequisites'
	if [ "$setup_platform" = fedora ]; then
		setup_dnf_install git curl make stow || setup_die "failed to install core Fedora packages"
	else
		if ! xcode-select -p >/dev/null 2>&1; then
			xcode-select --install >/dev/null 2>&1 || true
			setup_die "Xcode Command Line Tools installation was requested; finish it and rerun setup" 3
		fi
		setup_install_homebrew || setup_die "failed to install or initialize Homebrew"
		brew list --formula stow >/dev/null 2>&1 || \
			brew install stow || setup_die "failed to install GNU Stow"
	fi
	setup_ui_status 1 success 'Core prerequisites ready.'
}

setup_prepare_privileges() {
	local needs_sudo=0
	[ "$setup_platform" = fedora ] && needs_sudo=1
	[ "$setup_platform" = macos ] && ! setup_brew_command && needs_sudo=1
	[ "$setup_platform" = macos ] && setup_selected_contains tailscale && needs_sudo=1
	[ "$setup_build_emacs" -eq 1 ] && needs_sudo=1
	[ "$needs_sudo" -eq 1 ] && setup_ensure_sudo
}
