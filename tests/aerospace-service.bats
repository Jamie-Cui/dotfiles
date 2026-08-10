#!/usr/bin/env bats

setup() {
	export HOME=$BATS_TEST_TMPDIR/home
	export AEROSPACE_SOURCE_DIR=$HOME/opt/aerospace-src
	export AEROSPACE_INSTALL_DIR=$HOME/.local/libexec/aerospace-debug
	export AEROSPACE_BIN_DIR=$HOME/.local/bin
	export AEROSPACE_LAUNCH_AGENTS_DIR=$HOME/Library/LaunchAgents
	export AEROSPACE_LOG_DIR=$HOME/Library/Logs/AeroSpace-Debug
	export AEROSPACE_BREW_PREFIX=$BATS_TEST_TMPDIR/homebrew
	export AEROSPACE_TEST_LOG=$BATS_TEST_TMPDIR/launchctl.log
	export AEROSPACE_TEST_STATE=$BATS_TEST_TMPDIR/launchctl.state
	export AEROSPACE_LAUNCHCTL=$BATS_TEST_TMPDIR/bin/launchctl
	export AEROSPACE_BASH=$BATS_TEST_TMPDIR/bin/bash
	service_script=$BATS_TEST_DIRNAME/../packages/bin/.local/bin/aerospace-service

	mkdir -p "$AEROSPACE_SOURCE_DIR" "$BATS_TEST_TMPDIR/bin"
	git -C "$AEROSPACE_SOURCE_DIR" init -q
	git -C "$AEROSPACE_SOURCE_DIR" remote add origin https://github.com/Jamie-Cui/AeroSpace.git

	cat > "$AEROSPACE_BASH" <<'EOF'
#!/bin/bash
if [ "${1:-}" = --version ]; then
	echo 'GNU bash, version 5.3.0'
	exit 0
fi
exec /bin/bash "$@"
EOF

	cat > "$AEROSPACE_LAUNCHCTL" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$AEROSPACE_TEST_LOG"
case "$1" in
	print) [ -f "$AEROSPACE_TEST_STATE" ] ;;
	bootstrap) touch "$AEROSPACE_TEST_STATE" ;;
	bootout) rm -f "$AEROSPACE_TEST_STATE" ;;
esac
EOF

	cat > "$AEROSPACE_SOURCE_DIR/build-debug.sh" <<'EOF'
#!/bin/bash
mkdir -p .debug
printf '#!/bin/bash\necho app\n' > .debug/AeroSpaceApp
printf '#!/bin/bash\necho cli\n' > .debug/aerospace
chmod +x .debug/AeroSpaceApp .debug/aerospace
EOF
	chmod +x "$AEROSPACE_BASH" "$AEROSPACE_LAUNCHCTL" "$AEROSPACE_SOURCE_DIR/build-debug.sh"
}

@test "install deploys unsigned debug artifacts and enables the LaunchAgent" {
	run /bin/bash "$service_script" install
	[ "$status" -eq 0 ]
	[ -x "$AEROSPACE_INSTALL_DIR/AeroSpaceApp" ]
	[ -x "$AEROSPACE_BIN_DIR/aerospace-debug" ]
	[ -f "$AEROSPACE_LAUNCH_AGENTS_DIR/bobko.aerospace.debug.plist" ]
	[ "$(plutil -extract Label raw -o - "$AEROSPACE_LAUNCH_AGENTS_DIR/bobko.aerospace.debug.plist")" = bobko.aerospace.debug ]
	[ "$(plutil -extract ProgramArguments.0 raw -o - "$AEROSPACE_LAUNCH_AGENTS_DIR/bobko.aerospace.debug.plist")" = "$AEROSPACE_INSTALL_DIR/AeroSpaceApp" ]
	grep -F "enable gui/$(id -u)/bobko.aerospace.debug" "$AEROSPACE_TEST_LOG"
	grep -F "bootstrap gui/$(id -u) $AEROSPACE_LAUNCH_AGENTS_DIR/bobko.aerospace.debug.plist" "$AEROSPACE_TEST_LOG"
	grep -F "kickstart -k gui/$(id -u)/bobko.aerospace.debug" "$AEROSPACE_TEST_LOG"
}

@test "uninstall disables the agent and keeps source and logs" {
	/bin/bash "$service_script" install
	run /bin/bash "$service_script" uninstall
	[ "$status" -eq 0 ]
	[ ! -e "$AEROSPACE_INSTALL_DIR/AeroSpaceApp" ]
	[ ! -e "$AEROSPACE_BIN_DIR/aerospace-debug" ]
	[ ! -e "$AEROSPACE_LAUNCH_AGENTS_DIR/bobko.aerospace.debug.plist" ]
	[ -d "$AEROSPACE_SOURCE_DIR/.git" ]
	[ -d "$AEROSPACE_LOG_DIR" ]
	grep -F "disable gui/$(id -u)/bobko.aerospace.debug" "$AEROSPACE_TEST_LOG"
}
