#!/usr/bin/env bats

setup() {
	repo_root=$(CDPATH= cd -- "$BATS_TEST_DIRNAME/.." && pwd)
	setup_script=$repo_root/scripts/setup.sh
	export HOME=$BATS_TEST_TMPDIR/home
	mkdir -p "$HOME"
	for name in http_proxy https_proxy all_proxy no_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY; do
		unset "$name"
	done
}

make_executable() {
	path=$1
	shift
	printf '%s\n' '#!/bin/bash' "$@" > "$path"
	chmod +x "$path"
}

prepare_mock_environment() {
	export SETUP_TEST_LOG=$BATS_TEST_TMPDIR/commands.log
	export SETUP_TEST_DNF_FAIL=${SETUP_TEST_DNF_FAIL:-}
	export SETUP_TEST_GIT_DIRTY=${SETUP_TEST_GIT_DIRTY:-0}
	mock_bin=$BATS_TEST_TMPDIR/bin
	mock_repo=$BATS_TEST_TMPDIR/dotfiles
	mkdir -p "$mock_bin" "$mock_repo/.git" "$mock_repo/scripts" "$HOME/.local/bin"

	make_executable "$mock_repo/configure" \
		'printf "configure %s\\n" "$*" >> "$SETUP_TEST_LOG"'
	make_executable "$HOME/.local/bin/proxyctl" \
		'printf "proxyctl %s\\n" "$*" >> "$SETUP_TEST_LOG"'
	make_executable "$mock_bin/git" \
		'printf "git %s\\n" "$*" >> "$SETUP_TEST_LOG"' \
		'if [ "$1" = "-C" ]; then shift 2; fi' \
		'case "$1 $2" in' \
		'  "remote get-url") printf "%s\\n" "https://github.com/Jamie-Cui/dotfiles.git" ;;' \
		'  "status --porcelain") [ "$SETUP_TEST_GIT_DIRTY" = 1 ] && printf "%s\\n" " M local-change" ;;' \
		'  "rev-parse HEAD") printf "%s\\n" abc ;;' \
		'  "rev-parse origin/master") printf "%s\\n" abc ;;' \
		'  "ls-remote git@github.com:Jamie-Cui/dotfiles.git") exit 1 ;;' \
		'esac' \
		'exit 0'
	make_executable "$mock_bin/rpm" 'exit 1'
	make_executable "$mock_bin/dnf" \
		'printf "dnf %s\\n" "$*" >> "$SETUP_TEST_LOG"' \
		'case " $* " in *" $SETUP_TEST_DNF_FAIL "*) exit 42 ;; esac' \
		'exit 0'
	make_executable "$mock_bin/sudo" \
		'printf "sudo %s\\n" "$*" >> "$SETUP_TEST_LOG"' \
		'case "$1" in -v) exit 0 ;; -n) exit 0 ;; esac' \
		'if [ "$1" = env ]; then' \
		'  shift' \
		'  while [ "$#" -gt 0 ] && [[ "$1" == *=* ]]; do export "$1"; shift; done' \
		'fi' \
		'"$@"'
	make_executable "$mock_bin/make" \
		'printf "make %s\\n" "$*" >> "$SETUP_TEST_LOG"'
	make_executable "$mock_bin/zsh" 'exit 0'
	make_executable "$mock_bin/chsh" \
		'printf "chsh %s\\n" "$*" >> "$SETUP_TEST_LOG"'
	make_executable "$mock_bin/systemctl" \
		'printf "systemctl %s\\n" "$*" >> "$SETUP_TEST_LOG"'

	export PATH=$mock_bin:/usr/bin:/bin
	export DOTFILES_SETUP_DISABLE_SUDO_KEEPALIVE=1
	export DOTFILES_SETUP_SKIP_SSH_PROBE=1
}

@test "help documents the public component and execution interface" {
	run /bin/bash "$setup_script" --help
	[ "$status" -eq 0 ]
	[[ "$output" == *"--preset NAME"* ]]
	[[ "$output" == *"--build-emacs"* ]]
	[[ "$output" != *"--non-interactive"* ]]
}

@test "recommended Fedora dry-run is read-only and selects no desktop" {
	run env DOTFILES_SETUP_OS=fedora DOTFILES_SETUP_NO_TTY=1 \
		/bin/bash "$setup_script" --preset recommended --yes --dry-run \
		--repo-dir "$BATS_TEST_TMPDIR/repo"
	[ "$status" -eq 0 ]
	[[ "$output" == *"- shell"* ]]
	[[ "$output" == *"- rime"* ]]
	[[ "$output" != *"- i3"* ]]
	[[ "$output" != *"- hyprland"* ]]
	[ ! -e "$HOME/.local" ]
	[ ! -e "$BATS_TEST_TMPDIR/repo" ]
}

@test "recommended macOS includes AeroSpace but not borders" {
	run env DOTFILES_SETUP_OS=macos DOTFILES_SETUP_NO_TTY=1 \
		/bin/bash "$setup_script" --preset recommended --yes --dry-run
	[ "$status" -eq 0 ]
	[[ "$output" == *"- aerospace"* ]]
	[[ "$output" != *"- borders"* ]]
}

@test "i3 expands its runtime dependencies" {
	run env DOTFILES_SETUP_OS=fedora DOTFILES_SETUP_NO_TTY=1 \
		/bin/bash "$setup_script" --preset minimal --with i3 --yes --dry-run
	[ "$status" -eq 0 ]
	for component in kitty flameshot x11 i3 rofi dunst; do
		[[ "$output" == *"- $component"* ]]
	done
}

@test "explicitly excluding a required dependency is an error" {
	run env DOTFILES_SETUP_OS=fedora DOTFILES_SETUP_NO_TTY=1 \
		/bin/bash "$setup_script" --preset minimal --with i3 --without kitty --yes --dry-run
	[ "$status" -ne 0 ]
	[[ "$output" == *"required but was explicitly excluded"* ]]
}

@test "a component from the wrong platform is rejected" {
	run env DOTFILES_SETUP_OS=macos DOTFILES_SETUP_NO_TTY=1 \
		/bin/bash "$setup_script" --preset minimal --with hyprland --yes --dry-run
	[ "$status" -ne 0 ]
	[[ "$output" == *"not supported on macos"* ]]
}

@test "no TTY and no selection fails with an actionable message" {
	run env DOTFILES_SETUP_OS=fedora DOTFILES_SETUP_NO_TTY=1 \
		/bin/bash "$setup_script"
	[ "$status" -ne 0 ]
	[[ "$output" == *"pass --preset or --with"* ]]
}

@test "inherited proxy values are hidden in dry-run output" {
	run env DOTFILES_SETUP_OS=fedora DOTFILES_SETUP_NO_TTY=1 \
		https_proxy=http://user:proxy-secret@127.0.0.1:10808 \
		/bin/bash "$setup_script" --preset minimal --yes --dry-run
	[ "$status" -eq 0 ]
	[[ "$output" == *"https_proxy"* ]]
	[[ "$output" != *"proxy-secret"* ]]
}

@test "minimal Fedora execution reaches configure dry-run bootstrap and proxyctl" {
	prepare_mock_environment
	run env DOTFILES_SETUP_OS=fedora DOTFILES_SETUP_NO_TTY=1 \
		/bin/bash "$setup_script" --preset minimal --yes --repo-dir "$mock_repo"
	[ "$status" -eq 0 ]
	run grep -F 'configure --font 10' "$SETUP_TEST_LOG"
	[ "$status" -eq 0 ]
	run grep -F "make -C $mock_repo dry-run" "$SETUP_TEST_LOG"
	[ "$status" -eq 0 ]
	run grep -F "make -C $mock_repo bootstrap" "$SETUP_TEST_LOG"
	[ "$status" -eq 0 ]
	run grep -F 'proxyctl init' "$SETUP_TEST_LOG"
	[ "$status" -eq 0 ]
}

@test "only proxy variables cross the sudo boundary" {
	prepare_mock_environment
	run env DOTFILES_SETUP_OS=fedora DOTFILES_SETUP_NO_TTY=1 \
		https_proxy=http://127.0.0.1:10808 UNRELATED_SECRET=do-not-forward \
		/bin/bash "$setup_script" --preset minimal --yes --repo-dir "$mock_repo"
	[ "$status" -eq 0 ]
	setup_output=$output
	run grep -F 'https_proxy=http://127.0.0.1:10808' "$SETUP_TEST_LOG"
	[ "$status" -eq 0 ]
	run grep -F 'UNRELATED_SECRET' "$SETUP_TEST_LOG"
	[ "$status" -ne 0 ]
	[[ "$setup_output" != *"do-not-forward"* ]]
}

@test "a dirty existing dotfiles clone stops before deployment" {
	export SETUP_TEST_GIT_DIRTY=1
	prepare_mock_environment
	run env DOTFILES_SETUP_OS=fedora DOTFILES_SETUP_NO_TTY=1 \
		/bin/bash "$setup_script" --preset minimal --yes --repo-dir "$mock_repo"
	[ "$status" -ne 0 ]
	[[ "$output" == *"has local changes"* ]]
	run grep -F "make -C $mock_repo bootstrap" "$SETUP_TEST_LOG"
	[ "$status" -ne 0 ]
}

@test "build-emacs adds the component and caps default jobs at four" {
	job_bin=$BATS_TEST_TMPDIR/job-bin
	mkdir -p "$job_bin"
	make_executable "$job_bin/getconf" 'printf "%s\\n" 12'

	run env PATH="$job_bin:/usr/bin:/bin" \
		DOTFILES_SETUP_OS=fedora DOTFILES_SETUP_NO_TTY=1 \
		/bin/bash "$setup_script" --preset minimal --build-emacs --yes --dry-run
	[ "$status" -eq 0 ]
	[[ "$output" == *"- emacs"* ]]
	[[ "$output" == *"build with 4 jobs"* ]]
}

@test "macOS all includes secrets and borders but excludes Fedora mail" {
	run env DOTFILES_SETUP_OS=macos DOTFILES_SETUP_NO_TTY=1 \
		/bin/bash "$setup_script" --preset all --yes --dry-run
	[ "$status" -eq 0 ]
	[[ "$output" == *"- secrets"* ]]
	[[ "$output" == *"- borders"* ]]
	[[ "$output" != *"- mail"* ]]
}

@test "gpg-key implies the secrets component" {
	key=$BATS_TEST_TMPDIR/private.asc
	printf 'placeholder\n' > "$key"
	chmod 0600 "$key"
	run env DOTFILES_SETUP_OS=fedora DOTFILES_SETUP_NO_TTY=1 \
		/bin/bash "$setup_script" --preset minimal --gpg-key "$key" --yes --dry-run
	[ "$status" -eq 0 ]
	[[ "$output" == *"- secrets"* ]]
}

@test "an optional component failure still deploys dotfiles and returns nonzero" {
	export SETUP_TEST_DNF_FAIL=vim-enhanced
	prepare_mock_environment
	run env DOTFILES_SETUP_OS=fedora DOTFILES_SETUP_NO_TTY=1 \
		/bin/bash "$setup_script" --preset minimal --with vim --yes --repo-dir "$mock_repo"
	[ "$status" -ne 0 ]
	[[ "$output" == *"component failed: vim"* ]]
	run grep -F "make -C $mock_repo bootstrap" "$SETUP_TEST_LOG"
	[ "$status" -eq 0 ]
}

@test "an over-permissive GPG key is refused without blocking Stow" {
	prepare_mock_environment
	key=$BATS_TEST_TMPDIR/private.asc
	printf 'not a real private key\n' > "$key"
	chmod 0644 "$key"
	run env DOTFILES_SETUP_OS=fedora DOTFILES_SETUP_NO_TTY=1 \
		/bin/bash "$setup_script" --preset minimal --with secrets --gpg-key "$key" \
		--yes --repo-dir "$mock_repo"
	[ "$status" -ne 0 ]
	[[ "$output" == *"permissions must be 0600 or stricter"* ]]
	run grep -F "make -C $mock_repo bootstrap" "$SETUP_TEST_LOG"
	[ "$status" -eq 0 ]
}

@test "AeroSpace uses HOME and guards optional borders" {
	config=$repo_root/packages/aerospace/.config/aerospace/aerospace.toml
	run grep -F '${HOME}/.config/aerospace/toggle-layout.sh' "$config"
	[ "$status" -eq 0 ]
	run grep -F '/Users/jamie' "$config"
	[ "$status" -ne 0 ]
	command=$(sed -n "s/.*exec-and-forget \(if command -v borders.*fi\)'.*/\1/p" "$config")
	run /bin/bash -c "$command"
	[ "$status" -eq 0 ]
}

@test "Flameshot avoids personal paths and removed settings" {
	config=$repo_root/packages/flameshot/.config/flameshot/flameshot.ini
	run grep -E '^(savePath=|useGrimAdapter=|.*(/home|/Users)/jamie)' "$config"
	[ "$status" -ne 0 ]
}

@test "tmux is absent from managed packages and profiles" {
	[ ! -e "$repo_root/packages/tmux" ]
	run grep -E 'PACKAGES_(linux|macos).*tmux' "$repo_root/Makefile"
	[ "$status" -ne 0 ]
}
