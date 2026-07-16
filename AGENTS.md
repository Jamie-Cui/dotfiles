# Repository Guidelines

## Project Structure & Module Organization

This repository is a GNU Stow-managed dotfiles collection.  Deployable content
lives under `packages/<package>/` and mirrors its destination below `$HOME`.
Examples include `packages/nvim/.config/nvim/`,
`packages/kitty/.config/kitty/`, and `packages/vim/.vimrc`.

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
- `make list-profile PROFILE=macos`: show packages and the Rime target.
- `make dry-run PROFILE=macos`: preview Stow operations without changing `$HOME`.
- `make stow PROFILE=macos`: generate, preflight, and deploy a profile.
- `make restow PROFILE=macos`: prune stale links and redeploy a profile.
- `make unstow PROFILE=macos`: remove links owned by the profile.
- `make verify PROFILE=macos`: test a complete stow/restow/unstow cycle in a
  temporary home directory.
- `rg --files -g 'SKILL.md' packages/skills/.agents/skills`: list managed skill
  entrypoints.
- `make clean`: remove generated files; unstow first to avoid dangling links.

Profiles are `macos`, `linux-i3`, and `linux-hypr`.  Use
`EXTRA_PACKAGES="nvim tmux"` for opt-in packages and `RIME=0` to skip Rime.
The font size defaults to 10; copy `local.mk.example` to the ignored `local.mk`
for a persistent machine-local override, or pass `FONT_SIZE` on the command
line for a one-off override.

There is no application build.  After editing a tool config, validate with that
tool where possible, for example:

- `i3 -C -c packages/i3/.config/i3/config`
- `bash -n packages/rofi/.config/rofi/rofi-drun.sh`
- `bash -n packages/dunst/.config/dunst/reload-and-test.sh`
- `nvim --headless "+checkhealth" +qa`

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

Run `make verify PROFILE=<affected-profile>` for Stow or layout changes.  After
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

Do not commit machine-specific secrets, proxy credentials, private keys,
generated Rime user data, or local build/cache directories.  Keep host-specific
values in local files outside the repository when possible.
