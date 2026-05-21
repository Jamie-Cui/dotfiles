# Repository Guidelines

## Project Structure & Module Organization

This repository is a personal dotfiles collection. Top-level files configure shared tools (`.vimrc`, `.tmux.conf`, `.Xresources`, `README.org`, `Makefile`). Tool-specific configuration lives in directories such as `nvim/`, `hypr/`, `i3/`, `waybar/`, `kitty/`, `rime/`, `dunst/`, `aerospace/`, and `i3blocks/`.

Template files ending in `.in` are the source of generated local configs, for example `hypr/hyprland.conf.in`, `i3/config.in`, and `kitty/kitty.conf.in`. Generated outputs are ignored by Git and should usually not be committed. Visual assets are under `i3/`.

## Build, Test, and Development Commands

- `make help`: list supported Make targets and the active font size.
- `make all`: regenerate configs from `*.in` templates, replacing `@FONT_SIZE@` using `../config.toml` or `FONT_SIZE`.
- `make all FONT_SIZE=12`: regenerate configs with an explicit font size.
- `make clean`: remove generated configs and return to template-only state.

There is no single app build. After editing a tool config, validate with that tool where possible: `i3 -C -c i3/config`, `bash -n i3/rofi-drun.sh`, or `nvim --headless "+checkhealth" +qa`.

## Coding Style & Naming Conventions

Preserve each file's native format and indentation. Use tabs only where required, such as Makefile recipes. Keep shell scripts executable, start them with `#!/bin/bash`, and prefer lowercase variable names. Name new tool directories after the upstream application.

For C/C++ helper files, follow the checked-in `.clang-format` Google style. Keep generated configs derived from templates; edit the `.in` source instead of the ignored output when both exist.

## Testing Guidelines

No formal test framework or coverage target exists. Treat validation as tool-specific smoke testing. Run `make all` after template changes, syntax-check scripts with `bash -n path/to/script.sh`, and reload or dry-run affected desktop components when available. For UI-visible changes to Waybar, i3, Hyprland, Kitty, or Dunst, verify visually.

## Commit & Pull Request Guidelines

The current history uses Conventional Commit style, for example `feat: add comprehensive dotfiles configuration`. Continue with concise subjects such as `fix: correct waybar bluetooth state` or `chore: update rime schema`.

Pull requests should describe the affected tools, list validation commands run, and note any required local dependencies or host-specific assumptions. Include screenshots or short notes for visual changes to bars, window managers, terminals, or notifications.

## Security & Configuration Tips

Do not commit machine-specific secrets, proxy credentials, private keys, generated Rime user data, or local build/cache directories. Keep host-specific values in local config files outside the repository when possible.
