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
	mkdir -p "$mock_bin" "$mock_repo/.git" "$HOME/.local/bin"

	make_executable "$mock_repo/configure" \
		'printf "configure %s\\n" "$*" >> "$SETUP_TEST_LOG"'
	make_executable "$HOME/.local/bin/proxyctl" \
		'printf "proxyctl %s\\n" "$*" >> "$SETUP_TEST_LOG"'
	make_executable "$mock_bin/git" \
		'printf "git %s\\n" "$*" >> "$SETUP_TEST_LOG"' \
		'if [ "$1" = clone ]; then destination=${!#}; mkdir -p "$destination/.git"; fi' \
		'if [ "$1" = "-C" ]; then shift 2; fi' \
		'case "$1 $2" in' \
		'  "remote get-url") printf "%s\\n" "https://github.com/Jamie-Cui/dotfiles.git" ;;' \
		'  "status --porcelain") [ "$SETUP_TEST_GIT_DIRTY" = 1 ] && printf "%s\\n" " M local-change" ;;' \
		'  "rev-parse HEAD") printf "%s\\n" abc ;;' \
		'  "rev-parse origin/master") printf "%s\\n" abc ;;' \
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
	make_executable "$mock_bin/xcode-select" \
		'[ "$1" = -p ] && exit 0' \
		'exit 0'
	make_executable "$mock_bin/brew" \
		'printf "brew %s\\n" "$*" >> "$SETUP_TEST_LOG"' \
		'[ "$1" = list ] && exit 1' \
		'exit 0'
	make_executable "$mock_bin/defaults" 'exit 1'

	export PATH=$mock_bin:/usr/bin:/bin
	export SETUP_NO_TTY=1
	export SETUP_DISABLE_SUDO_KEEPALIVE=1
	export SETUP_SKIP_SSH_PROBE=1
}

@test "help documents the explicit command interface" {
	run "$setup_script" --help
	[ "$status" -eq 0 ]
	[[ "$output" == *"setup.sh plan"* ]]
	[[ "$output" == *"setup.sh apply"* ]]
	[[ "$output" == *"setup.sh interactive"* ]]
	[[ "$output" != *"--preset"* ]]
}

@test "no command prints usage and returns a usage error" {
	run "$setup_script"
	[ "$status" -eq 2 ]
	[[ "$output" == *"Usage:"* ]]
}

@test "recommended Fedora plan is read-only and excludes macOS components" {
	run env SETUP_TEST_PLATFORM=fedora SETUP_NO_TTY=1 \
		"$setup_script" plan --profile recommended --repo-dir "$BATS_TEST_TMPDIR/repo"
	[ "$status" -eq 0 ]
	[[ "$output" == *"DOTFILES SETUP"* ]]
	[[ "$output" == *"Components (6 selected)"* ]]
	[[ "$output" == *"shell: Oh My Zsh"* ]]
	[[ "$output" == *"rime: Rime input method"* ]]
	[[ "$output" != *"aerospace:"* ]]
	[[ "$output" != *$'\033['* ]]
	[ ! -e "$HOME/.local" ]
	[ ! -e "$BATS_TEST_TMPDIR/repo" ]
}

@test "recommended macOS plan includes Alfred, Stats, and AeroSpace" {
	run env SETUP_TEST_PLATFORM=macos SETUP_NO_TTY=1 \
		"$setup_script" plan --profile recommended
	[ "$status" -eq 0 ]
	[[ "$output" == *"alfred: Alfred"* ]]
	[[ "$output" == *"stats: Stats system monitor"* ]]
	[[ "$output" == *"aerospace: AeroSpace source"* ]]
	[[ "$output" != *"hyprland:"* ]]
}

@test "Alfred apply installs the Homebrew cask" {
	prepare_mock_environment
	run env SETUP_TEST_PLATFORM=macos \
		"$setup_script" apply --profile minimal --with alfred \
		--yes --repo-dir "$mock_repo"
	[ "$status" -eq 0 ]
	run grep -F 'brew install --cask alfred' "$SETUP_TEST_LOG"
	[ "$status" -eq 0 ]
}

@test "Stats apply installs the Homebrew cask" {
	prepare_mock_environment
	run env SETUP_TEST_PLATFORM=macos \
		"$setup_script" apply --profile minimal --with stats \
		--yes --repo-dir "$mock_repo"
	[ "$status" -eq 0 ]
	run grep -F 'brew install --cask stats' "$SETUP_TEST_LOG"
	[ "$status" -eq 0 ]
}

@test "component dependencies are resolved in catalog order" {
	run env SETUP_TEST_PLATFORM=fedora SETUP_NO_TTY=1 \
		"$setup_script" plan --profile minimal --with i3
	[ "$status" -eq 0 ]
	for component in kitty flameshot x11 i3 rofi dunst; do
		[[ "$output" == *"$component:"* ]]
	done
	[[ "$output" == *"Automatically added dependencies"* ]]
}

@test "explicitly excluding a dependency is rejected" {
	run env SETUP_TEST_PLATFORM=fedora SETUP_NO_TTY=1 \
		"$setup_script" plan --profile minimal --with i3 --without kitty
	[ "$status" -eq 2 ]
	[[ "$output" == *"required by i3 but was explicitly excluded"* ]]
}

@test "a component from the wrong platform is rejected" {
	run env SETUP_TEST_PLATFORM=macos SETUP_NO_TTY=1 \
		"$setup_script" plan --profile minimal --with hyprland
	[ "$status" -eq 2 ]
	[[ "$output" == *"not supported on macos"* ]]
}

@test "comma-separated component syntax is no longer accepted" {
	run env SETUP_TEST_PLATFORM=fedora SETUP_NO_TTY=1 \
		"$setup_script" plan --profile minimal --with i3,rofi
	[ "$status" -eq 2 ]
	[[ "$output" == *"invalid component name"* ]]
}

@test "build-emacs selects Emacs and validates jobs" {
	run env SETUP_TEST_PLATFORM=fedora SETUP_NO_TTY=1 \
		"$setup_script" plan --profile minimal --build-emacs --jobs 3
	[ "$status" -eq 0 ]
	[[ "$output" == *"emacs: Emacs source"* ]]
	[[ "$output" == *"build with 3 jobs"* ]]

	run env SETUP_TEST_PLATFORM=fedora SETUP_NO_TTY=1 \
		"$setup_script" plan --profile minimal --jobs zero
	[ "$status" -eq 2 ]
}

@test "proxy values are hidden from plan output" {
	run env SETUP_TEST_PLATFORM=fedora SETUP_NO_TTY=1 \
		https_proxy=http://user:proxy-secret@127.0.0.1:10808 \
		"$setup_script" plan --profile minimal
	[ "$status" -eq 0 ]
	[[ "$output" == *"https_proxy"* ]]
	[[ "$output" != *"proxy-secret"* ]]
}

@test "interactive mode requires a TTY" {
	run env SETUP_TEST_PLATFORM=fedora SETUP_NO_TTY=1 \
		"$setup_script" interactive
	[ "$status" -eq 3 ]
	[[ "$output" == *"requires a TTY"* ]]
}

@test "minimal Fedora apply reaches bootstrap sync deploy and proxy activation" {
	prepare_mock_environment
	run env SETUP_TEST_PLATFORM=fedora \
		"$setup_script" apply --profile minimal --yes --repo-dir "$mock_repo"
	[ "$status" -eq 0 ]
	run grep -F 'dnf install -y git curl make stow' "$SETUP_TEST_LOG"
	[ "$status" -eq 0 ]
	run grep -F "git -C $mock_repo fetch origin master" "$SETUP_TEST_LOG"
	[ "$status" -eq 0 ]
	run grep -F "make -C $mock_repo dry-run" "$SETUP_TEST_LOG"
	[ "$status" -eq 0 ]
	run grep -F "make -C $mock_repo bootstrap" "$SETUP_TEST_LOG"
	[ "$status" -eq 0 ]
	run grep -F 'proxyctl init' "$SETUP_TEST_LOG"
	[ "$status" -eq 0 ]
}

@test "component failure stops before later components and deployment" {
	export SETUP_TEST_DNF_FAIL=vim-enhanced
	prepare_mock_environment
	run env SETUP_TEST_PLATFORM=fedora \
		"$setup_script" apply --profile minimal --with vim --with rofi \
		--yes --repo-dir "$mock_repo"
	[ "$status" -ne 0 ]
	[[ "$output" == *"component failed: vim"* ]]
	run grep -F 'firefox' "$SETUP_TEST_LOG"
	[ "$status" -ne 0 ]
	run grep -F "make -C $mock_repo bootstrap" "$SETUP_TEST_LOG"
	[ "$status" -ne 0 ]
}

@test "a dirty repository stops before component installation" {
	export SETUP_TEST_GIT_DIRTY=1
	prepare_mock_environment
	run env SETUP_TEST_PLATFORM=fedora \
		"$setup_script" apply --profile minimal --with vim --yes --repo-dir "$mock_repo"
	[ "$status" -ne 0 ]
	[[ "$output" == *"has local changes"* ]]
	run grep -F 'vim-enhanced' "$SETUP_TEST_LOG"
	[ "$status" -ne 0 ]
}

@test "source-only components clone with their declared history depth" {
	prepare_mock_environment
	run env SETUP_TEST_PLATFORM=fedora \
		"$setup_script" apply --profile minimal --with ctags --with org-root \
		--with git-overleaf --with tdlib \
		--yes --repo-dir "$mock_repo"
	[ "$status" -eq 0 ]
	run grep -F "git clone --depth 1 https://github.com/universal-ctags/ctags.git $HOME/opt/ctags" "$SETUP_TEST_LOG"
	[ "$status" -eq 0 ]
	run grep -F "git clone git@github.com:Jamie-Cui/org-root.git $HOME/opt/org-root" "$SETUP_TEST_LOG"
	[ "$status" -eq 0 ]
	run grep -F "git clone git@github.com:Jamie-Cui/git-overleaf.git $HOME/opt/git-overleaf" "$SETUP_TEST_LOG"
	[ "$status" -eq 0 ]
	run grep -F "git clone --depth 1 https://github.com/tdlib/td.git $HOME/opt/tdlib" "$SETUP_TEST_LOG"
	[ "$status" -eq 0 ]
}

@test "AeroSpace apply is portable under a mocked macOS preflight" {
	prepare_mock_environment
	run env SETUP_TEST_PLATFORM=macos \
		"$setup_script" apply --profile minimal --with aerospace \
		--yes --repo-dir "$mock_repo"
	[ "$status" -eq 0 ]
	run grep -F 'brew install bash' "$SETUP_TEST_LOG"
	[ "$status" -eq 0 ]
	run grep -F "git clone --branch main --single-branch --depth 1 https://github.com/Jamie-Cui/AeroSpace.git $HOME/opt/aerospace-src" "$SETUP_TEST_LOG"
	[ "$status" -eq 0 ]
}

@test "only proxy variables cross the sudo boundary" {
	prepare_mock_environment
	run env SETUP_TEST_PLATFORM=fedora \
		https_proxy=http://127.0.0.1:10808 UNRELATED_SECRET=do-not-forward \
		"$setup_script" apply --profile minimal --yes --repo-dir "$mock_repo"
	[ "$status" -eq 0 ]
	run grep -F 'https_proxy=http://127.0.0.1:10808' "$SETUP_TEST_LOG"
	[ "$status" -eq 0 ]
	run grep -F 'UNRELATED_SECRET' "$SETUP_TEST_LOG"
	[ "$status" -ne 0 ]
	[[ "$output" != *"do-not-forward"* ]]
}

@test "temporary directories are registered in the parent shell and removed" {
	run /bin/bash -c '
		setup_entry_dir=$1/scripts
		setup_module_dir=$setup_entry_dir/setup
		. "$setup_module_dir/core.sh"
		setup_make_temp_dir
		created=$setup_temp_dir
		[ ${#setup_temporary_paths[@]} -eq 1 ]
		[ -d "$created" ]
		setup_cleanup
		[ ! -e "$created" ]
	' _ "$repo_root"
	[ "$status" -eq 0 ]
}

@test "duplicate catalog entries are rejected" {
	tree=$BATS_TEST_TMPDIR/tree
	mkdir -p "$tree"
	cp -R "$repo_root/scripts" "$tree/scripts"
	printf 'vim\tall\t-\tDuplicate Vim\n' >> "$tree/scripts/setup/catalog.tsv"
	run env SETUP_TEST_PLATFORM=fedora SETUP_NO_TTY=1 \
		"$tree/scripts/setup.sh" plan --profile minimal
	[ "$status" -eq 2 ]
	[[ "$output" == *"duplicate component: vim"* ]]
}

@test "catalog dependency cycles are rejected" {
	tree=$BATS_TEST_TMPDIR/tree
	mkdir -p "$tree"
	cp -R "$repo_root/scripts" "$tree/scripts"
	printf 'cycle-a\tall\tcycle-b\tCycle A\ncycle-b\tall\tcycle-a\tCycle B\n' \
		>> "$tree/scripts/setup/catalog.tsv"
	run env SETUP_TEST_PLATFORM=fedora SETUP_NO_TTY=1 \
		"$tree/scripts/setup.sh" plan --profile minimal
	[ "$status" -eq 2 ]
	[[ "$output" == *"dependency cycle"* ]]
}

@test "archive loader runs the complete modular setup tree" {
	archive_parent=$BATS_TEST_TMPDIR/archive
	archive_root=$archive_parent/dotfiles-master
	archive=$BATS_TEST_TMPDIR/dotfiles.tar.gz
	mkdir -p "$archive_root"
	cp -R "$repo_root/scripts" "$archive_root/scripts"
	tar -czf "$archive" -C "$archive_parent" dotfiles-master
	run env SETUP_ARCHIVE_URL="file://$archive" SETUP_TEST_PLATFORM=fedora SETUP_NO_TTY=1 \
		"$repo_root/scripts/setup-gist.sh" plan --profile minimal
	[ "$status" -eq 0 ]
	[[ "$output" == *"Profile: minimal"* ]]
}

@test "desktop configs retain portable paths and privacy defaults" {
	run grep -F '/Users/jamie' "$repo_root/packages/aerospace/.config/aerospace/aerospace.toml"
	[ "$status" -ne 0 ]
	run grep -F '${HOME}' "$repo_root/packages/aerospace/.config/aerospace/aerospace.toml"
	[ "$status" -eq 0 ]
	run grep -E 'savePath=.*/home/|savePath=.*/Users/' "$repo_root/packages/flameshot/.config/flameshot/flameshot.ini"
	[ "$status" -ne 0 ]
}
