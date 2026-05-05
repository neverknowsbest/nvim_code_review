# Plan 001: Nvim Code Review Plugin

## Implementation Checklist

| # | Task | Status | Comments | Completed |
|---|------|--------|----------|-----------|
| 1 | Create plugin directory structure and boilerplate | Done | lua/code_review/ | 2026-05-05 09:44 |
| 2 | Implement git integration module | Done | Get uncommitted changed files list | 2026-05-05 09:44 |
| 3 | Implement tab/window layout module | Done | New tab, bottom split for browser | 2026-05-05 09:44 |
| 4 | Implement changes browser (bottom pane) | Done | List of changed files, navigation | 2026-05-05 09:44 |
| 5 | Implement file viewer (top pane) | Done | Full file with highlighting + diff markers | 2026-05-05 09:44 |
| 6 | Implement diff sign/highlight integration | Done | Mark changed lines in the full file view | 2026-05-05 09:44 |
| 7 | Add user commands and keybindings | Done | :CodeReview, navigation keys | 2026-05-05 09:44 |
| 8 | Update documentation (README, AGENTS.md) | Done | | 2026-05-05 09:44 |
| 9 | Code review | Not Started | ft-reviewer | |

## Overview

A Neovim plugin written in Lua that opens a dedicated code review tab showing all uncommitted changes.
The top pane displays the full file with syntax highlighting and gutter signs marking changed lines.
The bottom pane is a navigable list of changed files.

## Architecture

```
lua/
  code_review/
    init.lua          -- Plugin entry point, commands
    git.lua           -- Git operations (changed files, diff hunks)
    layout.lua        -- Tab/window management
    browser.lua       -- Bottom pane: file list
    viewer.lua        -- Top pane: file display with diff markers
plugin/
  code_review.vim     -- VimL bootstrap (calls lua setup)
```

## Implementation Details

### Phase 1: Git Integration (`git.lua`)

- Run `git diff --name-only` and `git diff --cached --name-only` to get list of uncommitted changed files
- Run `git diff -U0 <file>` to get changed line ranges (hunks) per file
- Parse hunk headers (`@@ -a,b +c,d @@`) to extract added/modified/deleted line numbers
- Return structured data: `{ filepath, hunks: [{ start, count, type }] }`

### Phase 2: Layout (`layout.lua`)

- Open a new tab with `:tabnew`
- Split horizontally at the bottom (`:botright split`) with a fixed height (~10 lines)
- Bottom window holds the browser buffer; top window holds the file viewer buffer
- Both buffers are scratch (`buftype=nofile`, `noswapfile`, `bufhidden=wipe`)

### Phase 3: Changes Browser (`browser.lua`)

- Populate bottom buffer with the list of changed file paths
- Set filetype to `code_review_browser` for potential highlighting
- Keybindings:
  - `<CR>` / `l` — open selected file in viewer pane
  - `j`/`k` — navigate list
  - `q` — close the review tab
- Highlight the currently selected/viewed file

### Phase 4: File Viewer (`viewer.lua`)

- When a file is selected, read its contents into the top buffer
- Set the buffer's filetype based on file extension (for treesitter/syntax highlighting)
- Place signs or extmarks on lines identified as changed by the git module
- Sign types:
  - `CodeReviewAdd` (green gutter) — added lines
  - `CodeReviewChange` (yellow gutter) — modified lines
  - `CodeReviewDelete` (red gutter) — deleted lines (shown on the line after deletion)
- Keybindings in viewer:
  - `]c` — jump to next changed hunk
  - `[c` — jump to previous changed hunk

### Phase 5: Commands and Setup (`init.lua`)

- `:CodeReview` — open the review tab
- `:CodeReviewClose` — close the review tab
- `setup({})` function for user configuration (sign characters, browser height, etc.)

## Parallelization

```
Phase 1 (git.lua)  ──┐
                     ├──▶ Phase 3 (browser) ──┐
Phase 2 (layout)  ──┘                         ├──▶ Phase 5 (commands) ──▶ Phase 8 (tests)
                     ┌──▶ Phase 4 (viewer)  ──┘                           ──▶ Phase 9 (docs)
Phase 1 (git.lua)  ──┘                                                    ──▶ Phase 10 (review)
```

| Group | Steps | Agent | Dependencies |
|-------|-------|-------|--------------|
| A | 1 (structure) | default | None |
| B | 2 (git), 3 (layout) | default | A |
| C | 4 (browser), 5 (viewer) | default | B |
| D | 6 (diff signs) | default | C |
| E | 7 (commands) | default | D |
| F | 8 (docs), 9 (review) | default, ft-reviewer | E |
