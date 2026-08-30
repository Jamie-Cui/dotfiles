# Repository Guidelines

## Project Structure & Module Organization

This repository is a GNU Stow-managed dotfiles collection.  Deployable content
lives under `packages/<package>/` and mirrors its destination below `$HOME`.
Examples include `packages/nvim/.config/nvim/`,
`packages/kitty/.config/kitty/`, and `packages/vim/.vimrc`.

`packages/emacs/.emacs.d/` contains the complete Emacs configuration source and
deploys managed files into `~/.emacs.d`; machine-local files and runtime state
remain ordinary, untracked files in that directory.

Repository metadata (`README.org`, `Makefile`, `.gitignore`, `LICENSE`, and this
file) stays at the root and is never stowed.  `packages/rime/` is special: the
Makefile deploys its files to a profile-specific Squirrel, IBus, or Fcitx5
directory.  Reference-only formatter and language-server configuration lives
under `templates/` and is never stowed.

`packages/skills/.agents/skills/` contains reusable Codex skills. Each skill
lives in a lowercase, hyphenated directory centered on `SKILL.md`; keep helper
scripts, references, assets, evals, licenses, and agent metadata beside the
skill that owns them.

Treat this repository as the source of truth for those managed skills.  Edit
the package source rather than files below `~/.agents/skills`.  Deployment is
Stow-only; do not add `npx skills add`, bundle publication, upstream-audit, or
separate installer machinery unless the user explicitly requests it.

Template files ending in `.in` are tracked sources.  Generated files live beside
their templates, are ignored by Git, and should not be edited directly.

## Build, Test, and Development Commands

- `make help`: list commands, profiles, and the active font size.
- `make generate FONT_SIZE=12`: render all `*.in` templates.
- `make list-profile`: show the auto-selected packages and Rime target.
- `make dry-run`: preview Stow operations without changing `$HOME`.
- `make stow`: generate, preflight, and deploy the auto-selected profile.
- `make bootstrap`: deploy the selected profile on a new machine.
- `make restow`: prune stale links and redeploy the selected profile.
- `make unstow`: remove links owned by the selected profile.
- `make verify`: test a complete stow/restow/unstow cycle in a
  temporary home directory.
- `rg --files -g 'SKILL.md' packages/skills/.agents/skills`: list managed skill
  entrypoints.
- `make clean`: remove generated files; unstow first to avoid dangling links.

Profiles are `macos` and `linux`; the Makefile selects one from `uname -s` by
default.  The Linux profile includes both i3 and Hyprland packages and targets
Fcitx5 Rime.  Set `PROFILE` only to override detection, set
`RIME_TARGET_linux = $(DEPLOY_HOME)/.config/ibus/rime` in `local.mk` for IBus,
use `EXTRA_PACKAGES="package-name"` for an opt-in package, and use `RIME=0`
to skip Rime.
The font size defaults to 10; run `./configure [--font SIZE]` to write the
ignored `local.mk` (with 10 as the default) for a persistent machine-local
override, or pass `FONT_SIZE` on the command line for a one-off override.

There is no application build.  After editing a tool config, validate with that
tool where possible, for example:

- `i3 -C -c packages/i3/.config/i3/config`
- `bash -n packages/rofi/.config/rofi/rofi-drun.sh`
- `bash -n packages/dunst/.config/dunst/reload-and-test.sh`
- `nvim --headless "+checkhealth" +qa`
- `make -C packages/emacs/.emacs.d compile`
- `make -C packages/emacs/.emacs.d smoke`

### Emacs Executable Discovery

The setup program builds Emacs from `~/opt/emacs-src`, and Codex must not assume
that `emacs` or `emacsclient` is present in its non-interactive `PATH`.  Probe
the platform-specific absolute paths below and use the first executable one:

- macOS `emacs`: `/usr/local/bin/emacs`,
  `/Applications/Emacs.app/Contents/MacOS/Emacs`, then
  `~/opt/emacs-src/src/emacs`.
- macOS `emacsclient`: `/usr/local/bin/emacsclient`,
  `/Applications/Emacs.app/Contents/MacOS/bin/emacsclient`, then
  `~/opt/emacs-src/lib-src/emacsclient`.
- Fedora/Linux `emacs`: `/usr/local/bin/emacs`, then
  `~/opt/emacs-src/src/emacs`.
- Fedora/Linux `emacsclient`: `/usr/local/bin/emacsclient`, then
  `~/opt/emacs-src/lib-src/emacsclient`.

The `/usr/local/bin` entries are the normal post-install commands.  On macOS
they are symlinks into `Emacs.app`; on Fedora/Linux they are installed directly
by the default-prefix `sudo make install`.  The build-tree paths are valid
fallbacks after compilation even when installation or CLI-link creation was
left as a manual setup step.

When a repository script invokes bare `emacs` and `command -v emacs` fails,
prepend the directory containing the selected lowercase `emacs` executable.
For example, the shared build-tree fallback is:

`env PATH="$HOME/opt/emacs-src/src:$PATH" make -C packages/emacs/.emacs.d compile`

Codex should treat the verified host-specific `emacs` and `emacsclient` paths
as durable context eligible for persistent local memory, and record them when
the client exposes memory generation or a memory-write action.  Memory is only
a recall aid: this checked-in section remains authoritative.

## Stow Safety

Use the Makefile rather than raw Stow commands so template exclusion,
`--no-folding`, Rime targets, and preflight checks stay consistent.  Always run
`dry-run` before changing a real home directory.  Do not use `stow --adopt`
during migration because it moves conflicting target files into the package
tree.  Remove an old manual link only after confirming its destination.

## Coding Style & Naming Conventions

Preserve each file's native format and indentation.  Use tabs only where
required, such as Makefile recipes.  Keep shell scripts executable, start them
with `#!/bin/bash` where that is the established convention, and prefer
lowercase variable names.  Name packages after the upstream application.

For C/C++ helper files, follow `templates/.clang-format`.  Edit the `.in`
source whenever a generated output exists.

## Testing Guidelines

Run `make verify PROFILE=<affected-profile>` for Stow or layout changes; verify
both `macos` and `linux` when changing shared Makefile behavior.  After
adding or removing a skill, run the matching `make dry-run` and `make restow`.
For a skill content change, validate the affected `SKILL.md` frontmatter and
inspect the rendered Markdown.  Run `make generate` after template changes and
syntax-check affected scripts.  For UI-visible changes to Waybar, i3, Hyprland,
Kitty, AeroSpace, or Dunst, also reload the component and verify visually.

## Commit & Pull Request Guidelines

Use concise Conventional Commit subjects, for example
`refactor: manage dotfiles with stow` or
`fix: correct waybar bluetooth state`.  Pull requests should identify affected
packages, list validation commands, and note host-specific assumptions.  Include
screenshots or short notes for visible desktop changes.

## Security & Configuration Tips

Do not commit plaintext machine-specific secrets, proxy credentials, private
keys, generated Rime user data, or local build/cache directories.  The sole
exception is public-key-encrypted ciphertext under `packages/secrets`; its
private key and recovery material must remain outside the repository.  Keep
host-specific values in local files outside the repository when possible.
