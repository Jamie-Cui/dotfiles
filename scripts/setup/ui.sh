#!/bin/bash

# Terminal presentation helpers for the setup program. This file is sourced.

setup_ui_utf8=0

setup_ui_init() {
	case ${LC_ALL:-${LC_CTYPE:-${LANG:-}}} in
		*UTF-8*|*UTF8*|*utf-8*|*utf8*) setup_ui_utf8=1 ;;
		*) setup_ui_utf8=0 ;;
	esac
}

setup_ui_color_enabled() {
	local fd=$1
	[ -t "$fd" ] && [ "${TERM:-dumb}" != dumb ] && [ "${NO_COLOR+x}" != x ]
}

setup_ui_style_code() {
	case $1 in
		accent) printf '1;36\n' ;;
		info) printf '36\n' ;;
		success) printf '1;32\n' ;;
		warning) printf '1;33\n' ;;
		error) printf '1;31\n' ;;
		muted|pending) printf '2\n' ;;
		strong) printf '1\n' ;;
		*) printf '0\n' ;;
	esac
}

setup_ui_write() {
	local fd=$1
	local style=$2
	local value=$3
	local code
	if setup_ui_color_enabled "$fd"; then
		code=$(setup_ui_style_code "$style")
		printf '\033[%sm%s\033[0m' "$code" "$value" >&"$fd"
	else
		printf '%s' "$value" >&"$fd"
	fi
}

setup_ui_line() {
	local fd=$1
	local style=$2
	shift 2
	setup_ui_write "$fd" "$style" "$*"
	printf '\n' >&"$fd"
}

setup_ui_symbol() {
	local name=$1
	if [ "$setup_ui_utf8" -eq 1 ]; then
		case $name in
			selected|success) printf '✓\n' ;;
			warning) printf '!\n' ;;
			error) printf '×\n' ;;
			info) printf '•\n' ;;
			pending) printf '·\n' ;;
			*) printf '%s\n' "$name" ;;
		esac
	else
		case $name in
			selected) printf 'x\n' ;;
			success) printf 'ok\n' ;;
			warning) printf '!\n' ;;
			error) printf 'x\n' ;;
			info) printf '*\n' ;;
			pending) printf '.\n' ;;
			*) printf '%s\n' "$name" ;;
		esac
	fi
}

setup_ui_clear() {
	local fd=$1
	[ -t "$fd" ] || return 0
	[ "${TERM:-dumb}" != dumb ] || return 0
	[ "${SETUP_NO_CLEAR:-0}" != 1 ] || return 0
	printf '\033[2J\033[H' >&"$fd"
}

setup_ui_banner() {
	local fd=$1
	local rule='----------------'
	[ "$setup_ui_utf8" -eq 1 ] && rule='────────────────'
	setup_ui_line "$fd" accent 'DOTFILES SETUP'
	setup_ui_line "$fd" muted "$rule"
}

setup_ui_step() {
	local fd=$1
	local current=$2
	local total=$3
	shift 3
	printf '\n' >&"$fd"
	setup_ui_write "$fd" accent "[$current/$total]"
	setup_ui_write "$fd" strong " $*"
	printf '\n' >&"$fd"
}

setup_ui_section() {
	local fd=$1
	shift
	printf '\n' >&"$fd"
	setup_ui_line "$fd" strong "$*"
}

setup_ui_key_value() {
	local fd=$1
	local key=$2
	shift 2
	printf '  %s: %s\n' "$key" "$*" >&"$fd"
}

setup_ui_status() {
	local fd=$1
	local status=$2
	shift 2
	local symbol
	symbol=$(setup_ui_symbol "$status")
	printf '  ' >&"$fd"
	setup_ui_write "$fd" "$status" "$symbol"
	printf ' %s\n' "$*" >&"$fd"
}

setup_ui_prompt() {
	local fd=$1
	local label=$2
	local default=$3
	printf '\n  %s' "$label" >&"$fd"
	[ -n "$default" ] && setup_ui_write "$fd" muted " [$default]"
	printf '\n  ' >&"$fd"
	setup_ui_write "$fd" accent '› '
}

setup_ui_warning() {
	local fd=$1
	shift
	setup_ui_status "$fd" warning "warning: $*"
}

setup_ui_error() {
	local fd=$1
	shift
	setup_ui_status "$fd" error "$*"
}
