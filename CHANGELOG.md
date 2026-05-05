# Changelog

## v0.2.0 (2026-05-05)

### Features
- Side-by-side diff toggle (`d`) showing base version with synced scrolling
- `:CodeReview <branch>` to diff against a specific branch/ref
- Untracked files shown with `[N]` status
- `<Space>` advance flow: walks through all hunks then marks and moves to next file
- `<Tab>` mark file as viewed and move to next file
- `m`/`M` mark current/all files as viewed
- Viewed chunk progress tracking per file (e.g. `2/5 chunks`)
- Viewed files dimmed in browser
- Multi-repo workspace support (auto-discovers git repos under cwd)
- File type icons via nvim-web-devicons (optional)
- Parallel git loading for fast startup
- Auto-refresh on FocusGained (only when on review tab)
- Configurable keybindings, signs, browser height, and behavior via `setup()`
- Browser auto-scrolls when navigating files

### Bug Fixes
- Fixed highlight showing wrong file on initial load
- Fixed `<Tab>` highlighting two lines simultaneously
- Fixed `:` command lag caused by URI-scheme buffer name triggering plugins
- Fixed diff mode overriding custom line highlight colors
- Fixed click/focus resetting to first file (preserve state on refresh)
- Fixed column alignment with multi-byte Unicode icons (use strdisplaywidth)

### Code Quality
- Error checking on all git commands
- File handle leak fix (pcall around io.lines)
- Bounds checking on cursor positions
- Single-instance guard (prevents corrupted state)
- Removed duplicate staged+unstaged hunks (uses `git diff HEAD`)
- Replaced deprecated `nvim_win_set_option` with `vim.wo[]`
- O(1) reverse map for line lookups
- Extracted shared helpers to reduce repetition
- Removed dead code paths
- Base ref validation via `git rev-parse`

## v0.1.0 (2026-05-05)

- Initial release
- Full file viewer with syntax highlighting and diff gutter signs
- Changes browser with file list and stats
- Hunk navigation with `]c`/`[c`
- File navigation with `]f`/`[f`
