# Upstream Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Merge `joshuacant/ProjectTitle` upstream into this fork so ProjectTitle loads on KOReader 2026.07.02 while keeping the configurable titlebar and all local WIP.

**Architecture:** Commit dirty WIP, merge `upstream/master` into `master`, resolve the three overlap files by taking upstream KOReader/API changes and keeping our titlebar system, then verify with static checks.

**Tech Stack:** Lua (KOReader plugin), git

## Global Constraints

- Target KOReader version: `2026.07.02` / `202607020000`
- Preserve all local titlebar customization and WIP icons/`main.lua` tweaks
- Prefer upstream for version check, sorts, stock API; prefer ours for titlebar
- Do not push; do not rewrite old commit history
- Exclude `.claude/` from commits

---

### Task 1: Commit WIP and design docs

**Files:**
- Modify: `main.lua`, `icons/hero.svg`
- Create/add: `icons/go_root.svg`, `icons/tab_*.svg`, `docs/superpowers/specs/2026-08-08-upstream-sync-design.md`, `docs/superpowers/plans/2026-08-08-upstream-sync.md`

- [ ] **Step 1: Stage WIP + docs (exclude `.claude/`)**

```bash
git add main.lua icons/hero.svg icons/go_root.svg icons/tab_*.svg \
  docs/superpowers/specs/2026-08-08-upstream-sync-design.md \
  docs/superpowers/plans/2026-08-08-upstream-sync.md
git status
```

- [ ] **Step 2: Commit**

```bash
git commit -m "$(cat <<'EOF'
chore: preserve WIP icons and config tweaks before upstream sync

Include titlebar icons, hero update, config_version migration fix,
plus-dialog teardown restore, and sync design/plan docs.
EOF
)"
```

---

### Task 2: Merge upstream/master

**Files:**
- Merge may touch: `main.lua`, `covermenu.lua`, `ptutil.lua`, plus upstream-only files

- [ ] **Step 1: Ensure upstream is fetched**

```bash
git fetch upstream
git log --oneline -3 upstream/master
```

Expected: tip includes 2026.07 compatibility commits (e.g. `f29b532` or newer).

- [ ] **Step 2: Start merge**

```bash
git merge upstream/master -m "$(cat <<'EOF'
Merge upstream/master for KOReader 2026.07 compatibility

Bring in safe_versions for 2026.07.x and upstream fixes while
retaining configurable titlebar customization.
EOF
)"
```

- [ ] **Step 3: List conflicts**

```bash
git status
```

Expected conflicts concentrated in `main.lua`, `covermenu.lua`, `ptutil.lua`.

---

### Task 3: Resolve conflicts

**Files:**
- Modify: `main.lua`, `covermenu.lua`, `ptutil.lua` (and any other conflicted files)

**Resolution rules:**
1. `safe_versions` → upstream list including `202607020000`
2. Keep our `TITLEBAR_*` / `PLUS_MENU_*` in `ptutil.lua`; keep upstream new helpers
3. Keep our `TITLEBAR_ACTIONS` + configurable `setupLayout` wiring in `covermenu.lua`; keep any upstream menu/layout fixes outside that system
4. Keep our titlebar settings submenu + plus-menu toggles in `main.lua`; keep upstream sort menus / API changes
5. Keep WIP: numeric config_version checks; `getPlusDialogButtons` orig save/restore if still used
6. Remove all conflict markers

- [ ] **Step 1: Resolve each conflicted file per rules above**

- [ ] **Step 2: Static verification**

```bash
rg -n '<<<<<<<|=======|>>>>>>>' main.lua covermenu.lua ptutil.lua || echo 'no markers'
rg -n 'safe_versions|202607020000' main.lua
rg -n 'TITLEBAR_ACTIONS|TITLEBAR_SLOTS|PLUS_MENU_PLUGIN_IDS' covermenu.lua ptutil.lua main.lua
rg -n 'go_root|tab_exit|tab_favorites|tab_manga' ptutil.lua
```

Expected: no markers; `202607020000` present; titlebar symbols present; custom icons listed.

- [ ] **Step 3: Complete merge commit**

```bash
git add main.lua covermenu.lua ptutil.lua
# also add any other resolved/auto-merged files from the merge
git status
git commit --no-edit   # if merge commit already started; else use merge message from Task 2
```

If the merge commit was aborted or needs a new commit after manual fix:

```bash
git commit -m "$(cat <<'EOF'
Merge upstream/master for KOReader 2026.07 compatibility

Bring in safe_versions for 2026.07.x and upstream fixes while
retaining configurable titlebar customization.
EOF
)"
```

---

### Task 4: Final verification

- [ ] **Step 1: Confirm branch state**

```bash
git status
git log --oneline -8
rg -n 'safe_versions' -A6 main.lua
```

- [ ] **Step 2: Device checklist (operator)**

On KOReader 2026.07.02:
1. Plugin loads (no unsupported-version empty plugin)
2. Title bar settings menu appears
3. At least one custom action (e.g. exit / go_root / plugin shortcut) works
4. Plus-menu plugin toggles still appear
