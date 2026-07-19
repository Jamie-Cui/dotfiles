.DEFAULT_GOAL := all

.PHONY: all clean dry-run generate help list-profile restow stow unstow verify \
	_check-profile _check-stow _deploy-skills _preflight _prepare-skills \
	_restow _stow

-include local.mk
FONT_SIZE ?= 10

STOW ?= stow
PACKAGES_DIR := $(CURDIR)/packages
DEPLOY_HOME ?= $(HOME)
TARGET ?= $(DEPLOY_HOME)
UNAME_S ?= $(shell uname -s)
DEFAULT_PROFILE := $(if $(filter Darwin,$(UNAME_S)),macos,$(if $(filter Linux,$(UNAME_S)),linux))
PROFILE ?= $(DEFAULT_PROFILE)
RIME ?= 1
EXTRA_PACKAGES ?=

PROFILES := macos linux

PACKAGES_macos := vim kitty aerospace bin skills
PACKAGES_linux := vim tmux nvim kitty bin x11 rofi i3 i3blocks hypr waybar dunst flameshot fcitx5 gtk-2.0 gtk-3.0 gtk-4.0 imsettings davmail skills

RIME_TARGET_macos ?= $(DEPLOY_HOME)/Library/Rime
RIME_TARGET_linux ?= $(DEPLOY_HOME)/.local/share/fcitx5/rime

PACKAGES := $(sort $(PACKAGES_$(PROFILE)) $(EXTRA_PACKAGES))
REGULAR_PACKAGES := $(filter-out skills,$(PACKAGES))
SKILLS_ENABLED := $(filter skills,$(PACKAGES))
SKILLS_SOURCE_ROOT := $(PACKAGES_DIR)/skills/.agents/skills
SKILLS_INSTALL_DIR := $(TARGET)/.agents/skills
RIME_TARGET ?= $(RIME_TARGET_$(PROFILE))
STOW_BASE := $(STOW) --dir="$(PACKAGES_DIR)" --no-folding --ignore='.*[.]in'
SKILLS_STOW_BASE := $(STOW) --dir="$(PACKAGES_DIR)" --ignore='.*[.]in'

# -- Help ---------------------------------------------------------------------

help: ## Show commands and profile selection
	@echo "Available targets:"
	@echo "  generate      Render tracked *.in templates into ignored package files"
	@echo "  list-profile  Show packages and the Rime target for PROFILE"
	@echo "  dry-run       Preview links without changing the target tree"
	@echo "  stow          Generate, preflight, and deploy PROFILE"
	@echo "  restow        Prune stale links and redeploy PROFILE"
	@echo "  unstow        Remove links owned by PROFILE"
	@echo "  verify        Exercise stow/unstow in a temporary HOME"
	@echo "  clean         Remove generated package files"
	@echo ""
	@echo "Profiles: $(PROFILES)"
	@echo "Detected system: $(UNAME_S)"
	@echo "Selected: $(or $(PROFILE),unsupported)"
	@echo "Extra packages: $(or $(strip $(EXTRA_PACKAGES)),none)"
	@echo "Font size: $(FONT_SIZE)"
	@echo "Examples:"
	@echo "  make dry-run"
	@echo "  make stow"
	@echo "  make verify"
	@echo "  make stow PROFILE=macos  # override auto-selection"

list-profile: _check-profile ## Show the selected profile
	@echo "Profile: $(PROFILE)"
	@echo "Packages: $(PACKAGES)"
	@if [ "$(RIME)" = "1" ]; then \
		echo "Rime: packages/rime -> $(RIME_TARGET)"; \
	else \
		echo "Rime: disabled (RIME=$(RIME))"; \
	fi

# -- Generation ---------------------------------------------------------------

all: generate ## Backward-compatible alias for generate

generate: ## Render package files from *.in templates
	@find "$(PACKAGES_DIR)" -type f -name "*.in" \
		-exec sh -c 'for f; do out=$${f%.in}; sed "s/@FONT_SIZE@/$(FONT_SIZE)/g" "$$f" > "$$out"; done' _ {} \;
	@echo "Generated package files with font_size=$(FONT_SIZE)"

clean: ## Remove generated package files; unstow first to avoid dangling links
	@find "$(PACKAGES_DIR)" -type f -name "*.in" \
		-exec sh -c 'for f; do out=$${f%.in}; rm -f "$$out"; done' _ {} \;
	@echo "Removed generated package files"

# -- Stow ---------------------------------------------------------------------

dry-run: generate _check-profile _check-stow ## Preview the selected profile
	@if [ -n "$(REGULAR_PACKAGES)" ]; then \
		$(STOW_BASE) --target="$(TARGET)" --simulate --verbose=2 $(REGULAR_PACKAGES); \
	fi
	@if [ -n "$(SKILLS_ENABLED)" ]; then \
		if [ -d "$(SKILLS_INSTALL_DIR)" ]; then \
			$(SKILLS_STOW_BASE) --target="$(TARGET)" --simulate --verbose=2 skills; \
		else \
			echo "Skills target does not exist yet; stow will create it: $(SKILLS_INSTALL_DIR)"; \
		fi; \
	fi
	@if [ "$(RIME)" = "1" ]; then \
		if [ -d "$(RIME_TARGET)" ]; then \
			$(STOW_BASE) --target="$(RIME_TARGET)" --simulate --verbose=2 rime; \
		else \
			echo "Rime target does not exist yet; stow will create it: $(RIME_TARGET)"; \
		fi; \
	fi

stow: generate _check-profile _check-stow ## Deploy the selected profile
	@mkdir -p "$(TARGET)"
	@if [ -n "$(SKILLS_ENABLED)" ]; then mkdir -p "$(SKILLS_INSTALL_DIR)"; fi
	@if [ "$(RIME)" = "1" ]; then mkdir -p "$(RIME_TARGET)"; fi
	@$(MAKE) --no-print-directory _preflight PROFILE="$(PROFILE)" DEPLOY_HOME="$(DEPLOY_HOME)" TARGET="$(TARGET)" RIME="$(RIME)" EXTRA_PACKAGES="$(EXTRA_PACKAGES)"
	@$(MAKE) --no-print-directory _stow PROFILE="$(PROFILE)" DEPLOY_HOME="$(DEPLOY_HOME)" TARGET="$(TARGET)" RIME="$(RIME)" EXTRA_PACKAGES="$(EXTRA_PACKAGES)"
	@echo "Stowed profile $(PROFILE) into $(TARGET)"

restow: generate _check-profile _check-stow ## Restow and prune stale links
	@mkdir -p "$(TARGET)"
	@if [ -n "$(SKILLS_ENABLED)" ]; then mkdir -p "$(SKILLS_INSTALL_DIR)"; fi
	@if [ "$(RIME)" = "1" ]; then mkdir -p "$(RIME_TARGET)"; fi
	@$(MAKE) --no-print-directory _preflight PROFILE="$(PROFILE)" DEPLOY_HOME="$(DEPLOY_HOME)" TARGET="$(TARGET)" RIME="$(RIME)" EXTRA_PACKAGES="$(EXTRA_PACKAGES)"
	@$(MAKE) --no-print-directory _restow PROFILE="$(PROFILE)" DEPLOY_HOME="$(DEPLOY_HOME)" TARGET="$(TARGET)" RIME="$(RIME)" EXTRA_PACKAGES="$(EXTRA_PACKAGES)"
	@echo "Restowed profile $(PROFILE) into $(TARGET)"

unstow: _check-profile _check-stow ## Remove links for the selected profile
	@if [ "$(RIME)" = "1" ] && [ -d "$(RIME_TARGET)" ]; then \
		$(STOW_BASE) --target="$(RIME_TARGET)" --delete rime; \
	fi
	@if [ -d "$(TARGET)" ]; then \
		if [ -n "$(REGULAR_PACKAGES)" ]; then \
			$(STOW_BASE) --target="$(TARGET)" --delete $(REGULAR_PACKAGES); \
		fi; \
		if [ -n "$(SKILLS_ENABLED)" ] && [ -d "$(SKILLS_INSTALL_DIR)" ]; then \
			$(SKILLS_STOW_BASE) --target="$(TARGET)" --delete skills; \
		fi; \
	fi
	@if [ -n "$(SKILLS_ENABLED)" ] && [ -d "$(SKILLS_INSTALL_DIR)" ]; then \
		$(MAKE) --no-print-directory _prepare-skills PROFILE="$(PROFILE)" TARGET="$(TARGET)" EXTRA_PACKAGES="$(EXTRA_PACKAGES)" CHECK_SKILL_CONFLICTS=0; \
	fi
	@echo "Unstowed profile $(PROFILE) from $(TARGET)"

_preflight:
	@if [ -n "$(REGULAR_PACKAGES)" ]; then \
		$(STOW_BASE) --target="$(TARGET)" --simulate --verbose=1 $(REGULAR_PACKAGES); \
	fi
	@if [ -n "$(SKILLS_ENABLED)" ]; then \
		$(SKILLS_STOW_BASE) --target="$(TARGET)" --simulate --verbose=1 skills; \
	fi
	@if [ "$(RIME)" = "1" ]; then \
		$(STOW_BASE) --target="$(RIME_TARGET)" --simulate --verbose=1 rime; \
	fi

_stow:
	@if [ -n "$(REGULAR_PACKAGES)" ]; then \
		$(STOW_BASE) --target="$(TARGET)" $(REGULAR_PACKAGES); \
	fi
	@if [ -n "$(SKILLS_ENABLED)" ]; then \
		$(MAKE) --no-print-directory _deploy-skills PROFILE="$(PROFILE)" TARGET="$(TARGET)" EXTRA_PACKAGES="$(EXTRA_PACKAGES)"; \
	fi
	@if [ "$(RIME)" = "1" ]; then \
		$(STOW_BASE) --target="$(RIME_TARGET)" rime; \
	fi

_restow:
	@if [ -n "$(REGULAR_PACKAGES)" ]; then \
		$(STOW_BASE) --target="$(TARGET)" --restow $(REGULAR_PACKAGES); \
	fi
	@if [ -n "$(SKILLS_ENABLED)" ]; then \
		$(MAKE) --no-print-directory _deploy-skills PROFILE="$(PROFILE)" TARGET="$(TARGET)" EXTRA_PACKAGES="$(EXTRA_PACKAGES)"; \
	fi
	@if [ "$(RIME)" = "1" ]; then \
		$(STOW_BASE) --target="$(RIME_TARGET)" --restow rime; \
	fi

_deploy-skills:
	@if [ -d "$(SKILLS_INSTALL_DIR)" ]; then \
		$(SKILLS_STOW_BASE) --target="$(TARGET)" --delete skills; \
	fi
	@$(MAKE) --no-print-directory _prepare-skills PROFILE="$(PROFILE)" TARGET="$(TARGET)" EXTRA_PACKAGES="$(EXTRA_PACKAGES)"
	@$(SKILLS_STOW_BASE) --target="$(TARGET)" skills

_prepare-skills:
	@mkdir -p "$(SKILLS_INSTALL_DIR)"
	@find "$(SKILLS_SOURCE_ROOT)" -mindepth 1 -depth -type d -print | \
	while IFS= read -r source_dir; do \
		relative=$${source_dir#"$(SKILLS_SOURCE_ROOT)/"}; \
		rmdir "$(SKILLS_INSTALL_DIR)/$$relative" 2>/dev/null || true; \
	done
	@if [ "$(CHECK_SKILL_CONFLICTS)" != "0" ]; then \
		for source_dir in "$(SKILLS_SOURCE_ROOT)"/*; do \
			name=$${source_dir##*/}; \
			target_dir="$(SKILLS_INSTALL_DIR)/$$name"; \
			if [ -d "$$target_dir" ] && [ ! -L "$$target_dir" ]; then \
				echo "Cannot deploy managed skill $$name: $$target_dir contains non-Stow files" >&2; \
				exit 1; \
			fi; \
		done; \
	fi

# -- Verification -------------------------------------------------------------

verify: generate _check-profile _check-stow ## Test deployment in a temporary HOME
	@tmp=$$(mktemp -d); \
	trap 'rm -rf "$$tmp"' EXIT HUP INT TERM; \
	echo "Verifying profile $(PROFILE) in $$tmp"; \
	mkdir -p "$$tmp/.agents/skills/external-skill"; \
	touch "$$tmp/.agents/skills/external-skill/SKILL.md"; \
	$(MAKE) --no-print-directory stow PROFILE="$(PROFILE)" DEPLOY_HOME="$$tmp" TARGET="$$tmp" RIME="$(RIME)" EXTRA_PACKAGES="$(EXTRA_PACKAGES)" FONT_SIZE="$(FONT_SIZE)"; \
	$(MAKE) --no-print-directory restow PROFILE="$(PROFILE)" DEPLOY_HOME="$$tmp" TARGET="$$tmp" RIME="$(RIME)" EXTRA_PACKAGES="$(EXTRA_PACKAGES)" FONT_SIZE="$(FONT_SIZE)"; \
	test -L "$$tmp/.vimrc"; \
	test -L "$$tmp/.config/kitty/kitty.conf"; \
	if [ "$(PROFILE)" = "linux" ]; then \
		test -L "$$tmp/.config/davmail/davmail.properties"; \
		test -L "$$tmp/.config/systemd/user/davmail.service"; \
		test -L "$$tmp/.config/fcitx5/config"; \
		test -L "$$tmp/.config/fcitx5/profile"; \
		test -L "$$tmp/.gtkrc-2.0"; \
	fi; \
	test -L "$$tmp/.local/bin/proxyctl"; \
	test -L "$$tmp/.agents/skills/project-plan"; \
	test -f "$$tmp/.agents/skills/project-plan/SKILL.md"; \
	test -f "$$tmp/.agents/skills/external-skill/SKILL.md"; \
	init_block=$$("$$tmp/.local/bin/proxyctl" init --print); \
	printf '%s\n' "$$init_block" | grep -Fq "fpath=($$tmp/.local/bin \$$fpath)" || { \
		echo "proxyctl init resolved the Stow link outside $$tmp/.local/bin" >&2; \
		exit 1; \
	}; \
	if [ "$(RIME)" = "1" ]; then \
		find "$$tmp" -type l -name 'default.custom.yaml' -print -quit | grep -q .; \
	fi; \
	if find "$$tmp" -type l -name '*.in' -print -quit | grep -q .; then \
		echo "Template files were unexpectedly stowed" >&2; \
		exit 1; \
	fi; \
	$(MAKE) --no-print-directory unstow PROFILE="$(PROFILE)" DEPLOY_HOME="$$tmp" TARGET="$$tmp" RIME="$(RIME)" EXTRA_PACKAGES="$(EXTRA_PACKAGES)"; \
	test -f "$$tmp/.agents/skills/external-skill/SKILL.md"; \
	if find "$$tmp" -type l -print -quit | grep -q .; then \
		echo "Unstow left symbolic links behind" >&2; \
		exit 1; \
	fi; \
	echo "Verified profile $(PROFILE)"

# -- Guards -------------------------------------------------------------------

_check-profile:
	@if [ -z "$(PROFILE)" ]; then \
		echo "Unsupported system $(UNAME_S); set PROFILE to one of: $(PROFILES)" >&2; \
		exit 2; \
	elif [ -z "$(filter $(PROFILE),$(PROFILES))" ]; then \
		echo "Unknown PROFILE=$(PROFILE); choose one of: $(PROFILES)" >&2; \
		exit 2; \
	fi

_check-stow:
	@command -v "$(STOW)" >/dev/null 2>&1 || { \
		echo "GNU Stow is required. Install it with 'brew install stow' or your system package manager." >&2; \
		exit 2; \
	}
