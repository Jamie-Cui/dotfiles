#!/bin/bash

# Component probes, repository synchronization, installation, and deployment.

setup_component_supported() {
	local component=$1
	local platforms
	setup_catalog_find "$component" || return 1
	platforms=${setup_catalog_platforms[$setup_catalog_index]}
	[ "$platforms" = all ] || [ "$platforms" = "$setup_platform" ]
}

setup_available_components() {
	local component
	for component in "${setup_catalog_names[@]}"; do
		setup_component_supported "$component" && printf '%s\n' "$component"
	done
}

setup_component_label() {
	setup_catalog_find "$1" || return 1
	printf '%s\n' "${setup_catalog_labels[$setup_catalog_index]}"
}

setup_component_present() {
	local component=$1
	case $component in
		shell) command -v zsh >/dev/null 2>&1 && [ -d "$HOME/.oh-my-zsh" ] ;;
		font) command -v fc-list >/dev/null 2>&1 && fc-list 2>/dev/null | grep -i 'Maple Mono NL NF CN' >/dev/null ;;
		vim) command -v vim >/dev/null 2>&1 ;;
		nvim) command -v nvim >/dev/null 2>&1 ;;
		emacs) [ -d "$setup_emacs_dir/.git" ] ;;
		ctags) [ -d "$setup_ctags_dir/.git" ] ;;
		org-root) [ -d "$setup_org_root_dir/.git" ] ;;
		git-overleaf) [ -d "$setup_git_overleaf_dir/.git" ] ;;
		tdlib) [ -d "$setup_tdlib_dir/.git" ] ;;
		kitty)
			command -v kitty >/dev/null 2>&1 || \
				{ [ "$setup_platform" = macos ] && [ -d /Applications/kitty.app ]; }
			;;
		flameshot)
			command -v flameshot >/dev/null 2>&1 || \
				{ [ "$setup_platform" = macos ] && \
					{ [ -d /Applications/flameshot.app ] || [ -d /Applications/Flameshot.app ]; }; }
			;;
		tailscale)
			command -v tailscale >/dev/null 2>&1 || \
				{ [ "$setup_platform" = macos ] && [ -d /Applications/Tailscale.app ]; }
			;;
		rime)
			if [ "$setup_platform" = macos ]; then
				[ -d '/Library/Input Methods/Squirrel.app' ]
			else
				rpm -q fcitx5-rime >/dev/null 2>&1
			fi
			;;
		x11) command -v Xorg >/dev/null 2>&1 ;;
		i3) command -v i3 >/dev/null 2>&1 ;;
		rofi) command -v rofi >/dev/null 2>&1 ;;
		hyprland) command -v Hyprland >/dev/null 2>&1 ;;
		waybar) command -v waybar >/dev/null 2>&1 ;;
		dunst) command -v dunst >/dev/null 2>&1 ;;
		mail) command -v davmail >/dev/null 2>&1 && command -v mbsync >/dev/null 2>&1 ;;
		secrets) command -v gpg >/dev/null 2>&1 ;;
		bitwarden-cli) command -v bw >/dev/null 2>&1 ;;
		alfred) [ -d /Applications/Alfred\ 5.app ] || [ -d /Applications/Alfred.app ] ;;
		stats) [ -d /Applications/Stats.app ] ;;
		caffeine) [ -d /Applications/Caffeine.app ] ;;
		ice) [ -d /Applications/Ice.app ] ;;
		aerospace)
			command -v aerospace >/dev/null 2>&1 || [ -d /Applications/AeroSpace.app ]
			;;
		borders) command -v borders >/dev/null 2>&1 ;;
		*) return 2 ;;
	esac
}

setup_detect_present_components() {
	local component status
	setup_detected_present=()
	while IFS= read -r component; do
		[ -n "$component" ] || continue
		if setup_component_present "$component"; then
			setup_detected_add "$component"
		else
			status=$?
			[ "$status" -eq 1 ] || setup_die "failed to probe component $component" 3
		fi
	done <<EOF
$(setup_available_components)
EOF
}

setup_normalized_repo() {
	case $1 in
		git@github.com:Jamie-Cui/dotfiles.git|git@github.com:Jamie-Cui/dotfiles|https://github.com/Jamie-Cui/dotfiles.git|https://github.com/Jamie-Cui/dotfiles)
			return 0
			;;
		*) return 1 ;;
	esac
}

setup_ssh_repo_available() {
	[ "${SETUP_SKIP_SSH_PROBE:-0}" = 1 ] && return 1
	GIT_SSH_COMMAND='ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=yes' \
		git ls-remote "$setup_repo_ssh" HEAD >/dev/null 2>&1
}

setup_sync_dotfiles_repo() {
	local remote head upstream
	setup_ui_step 1 2 5 'Preparing dotfiles repository'
	if [ ! -e "$setup_repo_dir" ]; then
		mkdir -p "$(dirname "$setup_repo_dir")" || setup_die "cannot create repository parent directory"
		git clone --branch "$setup_repo_branch" --single-branch \
			"$setup_repo_https" "$setup_repo_dir" || setup_die "failed to clone dotfiles"
	else
		[ -d "$setup_repo_dir/.git" ] || setup_die "$setup_repo_dir exists but is not a Git repository"
		remote=$(git -C "$setup_repo_dir" remote get-url origin 2>/dev/null) || \
			setup_die "$setup_repo_dir has no origin remote"
		setup_normalized_repo "$remote" || setup_die "$setup_repo_dir origin is not Jamie-Cui/dotfiles: $remote"
		[ -z "$(git -C "$setup_repo_dir" status --porcelain)" ] || \
			setup_die "$setup_repo_dir has local changes; commit or stash them before setup"
		case $remote in
			git@github.com:*)
				if ! setup_ssh_repo_available; then
					git -C "$setup_repo_dir" remote set-url origin "$setup_repo_https" || \
						setup_die "failed to switch origin to HTTPS"
				fi
				;;
		esac
		git -C "$setup_repo_dir" fetch origin "$setup_repo_branch" || setup_die "failed to fetch dotfiles"
		head=$(git -C "$setup_repo_dir" rev-parse HEAD) || setup_die "failed to inspect dotfiles HEAD"
		upstream=$(git -C "$setup_repo_dir" rev-parse "origin/$setup_repo_branch") || \
			setup_die "failed to inspect origin/$setup_repo_branch"
		if [ "$head" != "$upstream" ]; then
			git -C "$setup_repo_dir" merge-base --is-ancestor HEAD "origin/$setup_repo_branch" || \
				setup_die "dotfiles cannot be fast-forwarded to origin/$setup_repo_branch"
			git -C "$setup_repo_dir" merge --ff-only "origin/$setup_repo_branch" || \
				setup_die "failed to fast-forward dotfiles"
		fi
	fi
	if setup_ssh_repo_available; then
		git -C "$setup_repo_dir" remote set-url origin "$setup_repo_ssh" || \
			setup_die "failed to switch origin to SSH"
	fi
	setup_ui_status 1 success 'Dotfiles repository ready.'
}

setup_sync_emacs_repo() {
	local remote head upstream
	if [ ! -e "$setup_emacs_dir" ]; then
		mkdir -p "$(dirname "$setup_emacs_dir")" || return 1
		git clone --branch emacs-31 --single-branch --depth 1 \
			https://github.com/emacs-mirror/emacs.git "$setup_emacs_dir"
		return $?
	fi
	[ -d "$setup_emacs_dir/.git" ] || { setup_warn "$setup_emacs_dir exists but is not a Git repository"; return 1; }
	[ -z "$(git -C "$setup_emacs_dir" status --porcelain)" ] || \
		{ setup_warn "$setup_emacs_dir has local changes"; return 1; }
	remote=$(git -C "$setup_emacs_dir" remote get-url origin 2>/dev/null) || return 1
	case $remote in
		https://github.com/emacs-mirror/emacs.git|https://github.com/emacs-mirror/emacs) ;;
		*) setup_warn "$setup_emacs_dir origin is not emacs-mirror/emacs"; return 1 ;;
	esac
	git -C "$setup_emacs_dir" fetch origin emacs-31 || return 1
	head=$(git -C "$setup_emacs_dir" rev-parse HEAD) || return 1
	upstream=$(git -C "$setup_emacs_dir" rev-parse origin/emacs-31) || return 1
	if [ "$head" != "$upstream" ]; then
		git -C "$setup_emacs_dir" merge-base --is-ancestor HEAD origin/emacs-31 || return 1
		git -C "$setup_emacs_dir" merge --ff-only origin/emacs-31 || return 1
	fi
}

setup_clone_source_repo() {
	local url=$1
	local destination=$2
	local depth=${3:-}
	if [ -e "$destination" ]; then
		[ -d "$destination/.git" ] && return 0
		setup_warn "$destination exists but is not a Git repository"
		return 1
	fi
	mkdir -p "$(dirname "$destination")" || return 1
	if [ -n "$depth" ]; then
		git clone --depth "$depth" "$url" "$destination"
	else
		git clone "$url" "$destination"
	fi
}

setup_install_shell() {
	if [ "$setup_platform" = fedora ]; then
		setup_dnf_install zsh curl util-linux || return 1
	fi
	if [ ! -d "$HOME/.oh-my-zsh" ]; then
		setup_make_temp_dir
		local installer=$setup_temp_dir/install-oh-my-zsh.sh
		setup_download_file https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh "$installer" || return 1
		KEEP_ZSHRC=yes RUNZSH=no CHSH=no sh "$installer" --unattended || return 1
	fi
	if [ "$setup_platform" = fedora ] && [ "${SHELL:-}" != "$(command -v zsh)" ]; then
		chsh -s "$(command -v zsh)" || return 1
		setup_pending_add "Log out and back in to start the new zsh login shell."
	fi
}

setup_install_font() {
	local archive
	if [ "$setup_platform" = macos ]; then
		setup_brew_cask font-maple-mono-nl-nf-cn font-maple-mono-nl-nf-cn
		return
	fi
	setup_dnf_install curl unzip fontconfig || return 1
	fc-list 2>/dev/null | grep -i 'Maple Mono NL NF CN' >/dev/null && return 0
	setup_make_temp_dir
	archive=$setup_temp_dir/maple-mono.zip
	setup_download_file https://github.com/subframe7536/maple-font/releases/latest/download/MapleMonoNL-NF-CN-unhinted.zip "$archive" || return 1
	mkdir -p "$HOME/.local/share/fonts/maple-mono" || return 1
	unzip -oq "$archive" -d "$HOME/.local/share/fonts/maple-mono" || return 1
	fc-cache -f >/dev/null
}

setup_emacs_disk_ok() {
	local available_kb
	available_kb=$(df -Pk "$HOME" | awk 'NR == 2 { print $4 }')
	case $available_kb in ''|*[!0-9]*) return 1 ;; esac
	[ "$available_kb" -ge 10485760 ]
}

setup_install_emacs() {
	local texinfo_prefix
	if [ "$setup_platform" = macos ]; then
		brew install autoconf automake texinfo libgccjit gcc gnutls tree-sitter@0.25 pkg-config coreutils sqlite librsvg || return 1
	else
		setup_dnf_install dnf-plugins-core gcc gcc-c++ make autoconf automake texinfo || return 1
		setup_sudo_run dnf builddep -y emacs || return 1
		setup_dnf_install libgccjit-devel tree-sitter-devel sqlite-devel librsvg2-devel gtk3-devel || return 1
	fi
	setup_sync_emacs_repo || return 1
	(
		cd "$setup_emacs_dir" || exit 1
		./autogen.sh || exit 1
		if [ "$setup_platform" = macos ]; then
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

	if [ "$setup_build_emacs" -eq 0 ]; then
		if [ "$setup_platform" = macos ]; then
			setup_pending_add "Build Emacs manually: cd $setup_emacs_dir && make -j$setup_jobs && make install; then copy Emacs.app and create CLI links as documented."
		else
			setup_pending_add "Build Emacs manually: cd $setup_emacs_dir && make -j$setup_jobs && sudo make install"
		fi
		return 0
	fi
	if [ "$setup_allow_low_disk" -eq 0 ] && ! setup_emacs_disk_ok; then
		setup_warn "less than 10 GiB is available for the Emacs build"
		return 1
	fi
	(
		cd "$setup_emacs_dir" || exit 1
		make -j"$setup_jobs" || exit 1
		if [ "$setup_platform" = macos ]; then
			make install || exit 1
			sudo ditto nextstep/Emacs.app /Applications/Emacs.app || exit 1
			sudo mkdir -p /usr/local/bin || exit 1
			sudo ln -sf /Applications/Emacs.app/Contents/MacOS/Emacs /usr/local/bin/emacs || exit 1
			sudo ln -sf /Applications/Emacs.app/Contents/MacOS/bin/emacsclient /usr/local/bin/emacsclient || exit 1
		else
			setup_sudo_run make install || exit 1
		fi
	)
}

setup_install_flameshot() {
	if [ "$setup_platform" = macos ]; then
		if [ ! -d /Applications/flameshot.app ] && [ ! -d /Applications/Flameshot.app ]; then
			setup_pending_add "Install Flameshot from its official macOS release, open it once, and grant Screen & System Audio Recording permission."
		fi
		return 0
	fi
	setup_dnf_install flameshot grim
}

setup_install_tailscale() {
	local repo=https://pkgs.tailscale.com/stable/fedora/tailscale.repo
	if [ "$setup_platform" = macos ]; then
		setup_brew_cask tailscale-app tailscale-app || return 1
		setup_pending_add "Open Tailscale, approve its system extension and VPN configuration, then sign in."
		return 0
	fi
	if [ ! -r /etc/yum.repos.d/tailscale.repo ]; then
		if dnf --version 2>/dev/null | head -n 1 | grep -q '^dnf5 '; then
			setup_dnf_install dnf5-plugins || return 1
			setup_sudo_run dnf config-manager addrepo --from-repofile="$repo" || return 1
		else
			setup_dnf_install dnf-plugins-core || return 1
			setup_sudo_run dnf config-manager --add-repo "$repo" || return 1
		fi
	fi
	setup_dnf_install tailscale || return 1
	setup_sudo_run systemctl enable --now tailscaled || return 1
	setup_pending_add "Run sudo tailscale up and authenticate this device with your tailnet."
}

setup_install_secrets() {
	local mode ciphertext
	if [ "$setup_platform" = macos ]; then
		setup_brew_formula gnupg || return 1
	else
		setup_dnf_install gnupg2 || return 1
	fi
	if [ -n "$setup_gpg_key" ]; then
		[ -f "$setup_gpg_key" ] || { setup_warn "GPG key file does not exist: $setup_gpg_key"; return 1; }
		if [ "$setup_platform" = macos ]; then
			mode=$(stat -f %Lp "$setup_gpg_key") || return 1
		else
			mode=$(stat -c %a "$setup_gpg_key") || return 1
		fi
		case $mode in *00) ;; *) setup_warn "GPG key file permissions must be 0600 or stricter: $setup_gpg_key ($mode)"; return 1 ;; esac
		gpg --import "$setup_gpg_key" || return 1
	fi
	ciphertext=$setup_repo_dir/packages/secrets/.authinfo.gpg
	if [ -f "$ciphertext" ]; then
		if [ "$setup_assume_yes" -eq 1 ]; then
			gpg --batch --quiet --decrypt "$ciphertext" >/dev/null 2>&1 || \
				setup_pending_add "Import/unlock the matching GPG private key and verify $ciphertext can be decrypted."
		else
			gpg --quiet --decrypt "$ciphertext" >/dev/null 2>&1 || \
				setup_pending_add "Import/unlock the matching GPG private key and verify $ciphertext can be decrypted."
		fi
	fi
}

setup_install_mail() {
	setup_dnf_install dnf-plugins-core || return 1
	setup_sudo_run dnf copr enable -y mguessan/davmail || return 1
	setup_dnf_install davmail java-latest-openjdk-headless isync maildir-utils gnupg2 || return 1
	mkdir -p "$HOME/.local/state/davmail" "$HOME/.local/share/mail/outlook"
}

setup_install_aerospace() {
	local needs_defaults=0
	setup_brew_cask aerospace aerospace || return 1
	[ "$(defaults read com.apple.dock expose-group-apps 2>/dev/null)" = 1 ] || needs_defaults=1
	[ "$(defaults read com.apple.dock autohide 2>/dev/null)" = 1 ] || needs_defaults=1
	[ "$(defaults read com.apple.dock pinning 2>/dev/null)" = start ] || needs_defaults=1
	if [ "$needs_defaults" -eq 1 ]; then
		setup_pending_add "Review and apply the AeroSpace Dock/Mission Control defaults documented in README.org, then restart Dock."
	fi
}

setup_install_borders() {
	brew list --formula borders >/dev/null 2>&1 && return 0
	brew tap FelixKratz/formulae || return 1
	brew install borders
}

setup_run_component() {
	local component=$1
	local index=${2:-1}
	local total=${3:-1}
	local label
	label=$(setup_component_label "$component")
	setup_ui_status 1 pending "$index/$total  $component - $label"
	case $component in
		shell) setup_install_shell ;;
		font) setup_install_font ;;
		vim) if [ "$setup_platform" = macos ]; then setup_brew_formula vim; else setup_dnf_install vim-enhanced; fi ;;
		nvim) if [ "$setup_platform" = macos ]; then setup_brew_formula neovim; else setup_dnf_install neovim; fi ;;
		emacs) setup_install_emacs ;;
		ctags) setup_clone_source_repo "$setup_ctags_repo" "$setup_ctags_dir" 1 ;;
		org-root) setup_clone_source_repo "$setup_org_root_repo" "$setup_org_root_dir" ;;
		git-overleaf) setup_clone_source_repo "$setup_git_overleaf_repo" "$setup_git_overleaf_dir" ;;
		tdlib) setup_clone_source_repo "$setup_tdlib_repo" "$setup_tdlib_dir" 1 ;;
		kitty) if [ "$setup_platform" = macos ]; then setup_brew_cask kitty kitty; else setup_dnf_install kitty; fi ;;
		flameshot) setup_install_flameshot ;;
		tailscale) setup_install_tailscale ;;
		rime) if [ "$setup_platform" = macos ]; then setup_brew_cask squirrel-app squirrel-app; else setup_dnf_install fcitx5 fcitx5-rime fcitx5-gtk fcitx5-qt imsettings im-chooser gtk2 gtk3 gtk4; fi ;;
		x11) setup_dnf_install xorg-x11-server-Xorg xorg-x11-xinit xorg-x11-xauth ;;
		i3) setup_dnf_install i3 i3lock picom feh xclip dex-autostart network-manager-applet pulseaudio-utils ibus jq xss-lock setxkbmap i3blocks alsa-utils sysstat perl ;;
		rofi) setup_dnf_install rofi firefox ;;
		hyprland) setup_dnf_install hyprland hyprlock hyprpaper xdg-desktop-portal-hyprland brightnessctl playerctl wireplumber xclip ;;
		waybar) setup_dnf_install waybar jq playerctl blueman network-manager-applet NetworkManager-tui pavucontrol htop baobab ;;
		dunst) setup_dnf_install dunst ;;
		mail) setup_install_mail ;;
		secrets) setup_install_secrets ;;
		bitwarden-cli) setup_brew_formula bitwarden-cli ;;
		alfred) setup_brew_cask alfred alfred ;;
		stats) setup_brew_cask stats stats ;;
		caffeine) setup_brew_cask caffeine caffeine ;;
		ice) setup_brew_cask jordanbaird-ice jordanbaird-ice ;;
		aerospace) setup_install_aerospace ;;
		borders) setup_install_borders ;;
		*) setup_die "no installer for component $component" 2 ;;
	esac || setup_die "component failed: $component"
	setup_completed_components=$((setup_completed_components + 1))
	setup_ui_status 1 success "$component completed."
}

setup_deploy_dotfiles() {
	setup_ui_step 1 4 5 'Configuring and deploying dotfiles'
	"$setup_repo_dir/configure" --font "$setup_font_size" || setup_die "failed to persist FONT_SIZE"
	make -C "$setup_repo_dir" dry-run || setup_die "dotfiles dry-run failed; no Stow changes were made"
	make -C "$setup_repo_dir" bootstrap || setup_die "dotfiles bootstrap failed"
	setup_ui_status 1 success 'Dotfiles deployed.'
}

setup_activate_post_deploy() {
	setup_ui_step 1 5 5 'Post-deploy activation'
	if command -v zsh >/dev/null 2>&1 && [ -x "$HOME/.local/bin/proxyctl" ]; then
		"$HOME/.local/bin/proxyctl" init || setup_die "proxyctl activation failed"
	else
		setup_pending_add "Install zsh and run proxyctl init after dotfiles are deployed."
	fi
	if setup_selected_contains mail; then
		systemctl --user enable --now davmail.service || setup_die "DavMail service activation failed"
		setup_pending_add "Follow the DavMail device-code prompt in ~/.local/state/davmail/davmail.log, then run the first mbsync manually."
	fi
	if setup_selected_contains rime; then
		if [ "$setup_platform" = macos ]; then
			setup_pending_add "Add Squirrel in macOS Input Sources, redeploy Rime, and log out if existing apps do not pick it up."
		else
			setup_pending_add "Select Fcitx 5 as the input method and log out and back in."
		fi
	fi
	setup_ui_status 1 success 'Post-deploy activation complete.'
}

setup_finish() {
	local item finished_at elapsed
	finished_at=$(date +%s)
	elapsed=$((finished_at - setup_started_at))
	setup_ui_section 1 'Setup completed'
	setup_ui_status 1 success 'Your dotfiles environment is ready.'
	setup_ui_key_value 1 Components "$setup_completed_components/${#setup_selected[@]} completed"
	setup_ui_key_value 1 Duration "${elapsed}s"
	if [ ${#setup_pending[@]} -gt 0 ]; then
		setup_ui_section 1 'Pending manual steps'
		for item in "${setup_pending[@]}"; do
			setup_ui_status 1 warning "$item"
		done
	fi
	[ -n "$setup_log_file" ] && setup_ui_key_value 1 Log "$setup_log_file"
}
