# Makefile for Emacs configuration management

.PHONY: clean elpa standalone debug run download smoke compile test help

# Repository directory (this Makefile's directory), independent of cwd/shell.
REPO_DIR := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
USER_EMACS_DIR := $(HOME)/.emacs.d

# Default target
help:
	@echo "Available targets:"
	@echo "  download    - Download/update all ELPA packages"
	@echo "  smoke       - Offline startup smoke test (source + stowed-home chains)"
	@echo "  compile     - Byte-compile all managed Elisp to a temp dir"
	@echo "  test        - Run the complete ERT suite offline"
	@echo "  clean       - Remove .elc/.eln from the repo and ~/.emacs.d"
	@echo "  elpa        - Create elpa.tar.gz archive"
	@echo "  standalone  - Create standalone emacs.d-standalone.tar.gz"
	@echo "  debug       - Run Emacs with --debug-init"
	@echo "  run         - Run Emacs"
	@echo "  help        - Show this help message"

# Download/update all ELPA packages
download:
	@echo "Refreshing package contents and installing all packages..."
	@emacs --batch --load "$(USER_EMACS_DIR)/init.el" \
		--funcall package-refresh-contents \
		--eval "(package-install-all)"

# Offline startup smoke test for both startup chains.
smoke:
	@"$(REPO_DIR)/tools/smoke.sh"

# Byte-compile core + modules to a temp dir (does not touch the source tree).
compile:
	@"$(REPO_DIR)/tools/compile.sh"

# Offline ERT suite for local packages and configuration helpers.
test:
	@"$(REPO_DIR)/tools/test.sh"

# Remove compiled artifacts from the repo and the user dir.
clean:
	@echo "Cleaning .elc/.eln from the repo..."
	@find "$(REPO_DIR)" -name "*.elc" -type f -delete
	@find "$(REPO_DIR)" -name "*.eln" -type f -delete
	@echo "Cleaning .elc/.eln from $(USER_EMACS_DIR)..."
	@[ -d "$(USER_EMACS_DIR)" ] && find "$(USER_EMACS_DIR)" -name "*.elc" -type f -delete || true
	@[ -d "$(USER_EMACS_DIR)" ] && find "$(USER_EMACS_DIR)" -name "*.eln" -type f -delete || true
	@echo "Cleaning .tar.gz files in the repo..."
	@rm -f "$(REPO_DIR)"/*.tar.gz

# Create elpa.tar.gz archive
elpa:
	@echo "Creating elpa.tar.gz archive..."
	@cd "$(USER_EMACS_DIR)" && find . -name "*.elc" -type f -delete
	@cd "$(USER_EMACS_DIR)" && tar czf elpa.tar.gz elpa
	@mv "$(USER_EMACS_DIR)/elpa.tar.gz" "$(REPO_DIR)"

# Create standalone emacs.d-standalone.tar.gz
standalone:
	@echo "Creating standalone emacs.d-standalone.tar.gz..."
	@TEMP_DIR=$$(mktemp -d); \
	echo "Repo directory: $(REPO_DIR)"; \
	echo "Temp directory: $$TEMP_DIR"; \
	cp -r "$(REPO_DIR)" "$$TEMP_DIR/.emacs.d"; \
	rm -rf "$$TEMP_DIR/.emacs.d/.git"; \
	rm -rf "$$TEMP_DIR"/.emacs.d/*.tar.gz; \
	cd "$(USER_EMACS_DIR)" && find . -name "*.elc" -type f -delete; \
	cp -r "$(USER_EMACS_DIR)/elpa" "$$TEMP_DIR/.emacs.d"; \
	cd "$$TEMP_DIR" && tar czf emacs.d-standalone.tar.gz .emacs.d; \
	mv "$$TEMP_DIR/emacs.d-standalone.tar.gz" "$(REPO_DIR)"; \
	rm -rf "$$TEMP_DIR"

# Run Emacs with debug init
debug:
	@echo "Running Emacs with debug init..."
	emacs --debug-init

# Run Emacs
run:
	@echo "Running Emacs..."
	emacs
