# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

A Neovim plugin (Lua) for reviewing git changes in a dedicated tab with syntax-highlighted file viewing, a changes browser, and git log panel. Requires Neovim >= 0.10.

## Development

```bash
./install.sh --dev   # symlinks plugin to source dir for live editing
```

Hot reload during development (no nvim restart needed):
```
:CodeReviewReload
```

There is no test suite or linter configured. Verify changes manually in nvim.

## Architecture

The plugin uses a **tab-based layout** with three panes: viewer (top), browser (bottom), and optional log (side). All modules live in `lua/code_review/`.

### Data flow

1. **`git.lua`** — async git data layer. Runs git commands via `vim.system()`, stores results in `M._repo_data[repo_path]` (a `RepoData` struct with file_list, files, commits, loaded flags). Provides lazy sync accessors (`get_hunks`, `get_stats`) that fetch on first access for immediate UI needs.

2. **`state.lua`** — reactive state store. Single `state.data` table holds all review state (files, stats, viewed, current_idx, etc.). Supports `state.set(key, value)` for reactive updates with listener notification, `state.batch(fn)` to group mutations, and direct `state.data.key = value` for silent updates.

3. **`init.lua`** — orchestrator. Coordinates open/close/refresh flows, file navigation (`next_file`, `prev_file`, `advance`), and mark-viewed logic. The `refresh()` function reloads git data async and remaps viewed/hunk state to new file indices.

4. **`browser.lua`** — bottom pane showing file list with stats. Owns two highlight namespaces (`ns_hl` for line highlights, `ns_stats` for +/- coloring). Uses skip-render optimization (compares old vs new lines before rewriting buffer). Loads hunk counts asynchronously in background batches.

5. **`viewer.lua`** — top pane showing full file content with gutter signs. Handles diff toggle (side-by-side via `:diffthis`), edit mode (opens real file with LSP), and hunk navigation.

6. **`layout.lua`** — creates/destroys the tab + windows. Holds `layout.state` (window/buffer handles).

7. **`keymaps.lua`** — all key bindings. Reads from `config.current.keys`; no hard-coded key strings.

8. **`session.lua`** — persistence to `~/.local/state/nvim/code_review/`. Saves/restores viewed state, position, collapsed repos. Sessions scoped by cwd hash; hunk-level progress resets when git refs change.

9. **`config.lua`** — user options with defaults. `config.apply(opts)` merges user config.

10. **`log.lua`** — git log panel with commit selection and range/single-commit modes.

### Key patterns

- **Orchestration over mega-functions**: each module has orchestrator functions that call small helpers. Helpers are pure where possible.
- **Async git operations**: `git.load_repo()` and `git.load_all()` use `vim.system()` callbacks. UI refreshes happen inside `vim.schedule()` from those callbacks.
- **Highlight coalescing**: `schedule_highlight()` in browser.lua defers via `vim.schedule` to avoid redundant redraws.
- **Winbar headers**: use `vim.wo[win].winbar` (not buffer lines) with `%#HlGroup#` syntax for inline colors.
- **Multi-repo**: if cwd has no `.git`, scans immediate subdirectories. Files carry `entry.repo` to track which repo they belong to.

### Module-local vs shared state

- Shared review state: `state.lua` (`state.data.*`)
- Window/buffer handles: `layout.state.*`
- UI-only flags (keymaps_set, loading_gen): module-local variables
