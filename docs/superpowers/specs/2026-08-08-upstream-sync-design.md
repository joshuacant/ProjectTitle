# Upstream Sync Design — ProjectTitle fork

**Date:** 2026-08-08  
**Status:** Approved  
**Target KOReader:** 2026.07.02 (`202607020000`)

## Problem

This fork (`just1jray/ProjectTitle`) diverged from `joshuacant/ProjectTitle` at `62003cc` (2026.03). After KOReader updated to 2026.07.02, the fork’s single `safe_version = 202603000000` gate rejects the new build and the plugin fails to load. Upstream already supports 2026.07.x and has additional fixes/features.

## Goal

Merge `upstream/master` into local `master` so the plugin works on KOReader 2026.07.02, while preserving all local custom functionality and uncommitted WIP.

## Approach

**A — Commit WIP → merge `upstream/master` → resolve conflicts.**

Do not rebase or rewrite historical commits. Do not push unless explicitly requested.

## Local functionality to preserve

Configurable titlebar system and related WIP:

- Slot tap/hold configuration (`left1`–`left3`, `center`, `right3`, `right2`; `right1` reserved for plus menu)
- Actions: `home`, `favorites`, `show_favorites`, `history`, `last_document`, `go_up`, `go_root`, `collections`, `meta_browse`, `exit`, `manga`, `annas`, `zlib`, `appstore`, `opds`, `none`
- “Always use hero icon for center” setting
- Plus-menu show/hide toggles for plugin actions
- Custom icons: `go_root`, `tab_*`, updated `hero.svg`
- WIP: numeric `config_version` migration comparisons; restore `FileManager.getPlusDialogButtons` on teardown

Primary files: `main.lua`, `covermenu.lua`, `ptutil.lua`, `icons/*`

## Conflict resolution policy

| Area | Prefer |
|------|--------|
| Version check / `safe_versions` / 2026.07 API / upstream sorts & stock menus | Upstream |
| Titlebar registry, settings menu, plus-menu plugin toggles, custom icons | Ours |
| Shared functions (`setupLayout`, init/teardown hooks) | Combine both |

Files with no local changes (`bookinfomanager.lua`, `mosaicmenu.lua`, README, `_meta.lua`, l10n, userpatches, etc.): take upstream.

## Workflow

1. Commit all WIP (icons + `main.lua` tweaks). Exclude `.claude/`. Include this design/plan docs as appropriate.
2. `git merge upstream/master`
3. Resolve conflicts per policy above.
4. Verify: no conflict markers; `safe_versions` includes `202607020000`; titlebar constants/actions/menu still present; icon install list still includes custom icons.
5. Device smoke-test on KOReader 2026.07.02 (operator).

## Out of scope

- Pushing to GitHub
- Rewriting misleading historical commit messages
- New features beyond a correct merge

## Success criteria

- Plugin loads on KOReader 2026.07.02 without the unsupported-version empty plugin path
- All preserved local titlebar/plugin/icon behavior still present in code
- Upstream 2026.07 compatibility and non-conflicting upstream improvements retained
