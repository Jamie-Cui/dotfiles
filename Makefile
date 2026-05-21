.DEFAULT_GOAL := all

.PHONY: all clean help

CONFIG ?= ../config.toml
FONT_SIZE ?= $(shell awk -F'=' '/^\[dotfiles\]/{s=1} s && /^font_size/{match($$2, /[0-9]+/); print substr($$2, RSTART, RLENGTH); exit}' "$(CONFIG)" 2>/dev/null)
FONT_SIZE := $(or $(strip $(FONT_SIZE)),10)

# -- Help ---------------------------------------------------------------------

help: ## Show this help message
	@echo "Available targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "Dotfiles font size: $(FONT_SIZE)  (edit [dotfiles] font_size in $(CONFIG) to change)"

# -- Dotfiles -----------------------------------------------------------------

all: ## Generate dotfiles from .in templates with FONT_SIZE from config.toml
	@find . -type f -name "*.in" -not -path "./.git/*" \
		-exec sh -c 'for f; do out=$${f%.in}; sed "s/@FONT_SIZE@/$(FONT_SIZE)/g" "$$f" > "$$out"; done' _ {} \;
	@echo "Generated dotfiles with font_size=$(FONT_SIZE)"

clean: ## Remove generated dotfiles (restore to template-only state)
	@find . -type f -name "*.in" -not -path "./.git/*" \
		-exec sh -c 'for f; do out=$${f%.in}; rm -f "$$out"; done' _ {} \;
	@echo "Cleaned generated dotfiles"
