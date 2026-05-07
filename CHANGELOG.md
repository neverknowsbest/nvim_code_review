# Changelog

## v0.7.1 (2026-05-07)

### Bug Fixes
- Fixed stats showing +0/-0 for all files (skip_numstat cached zeros poisoning real stats)
- Fixed `--no-renames` missing from numstat jobs in parallel loader (filename key mismatch)
- Fixed inconsistent line highlight across machines (use `Visual` bg instead of `DiffChange`)

## v0.7.0 (2026-05-07)

### Features
- Repo-aware navigation sync: log auto-switches when navigating files across repos
- Log → browser sync: `<Tab>`/`<S-Tab>` scrolls browser to the active repo
- Collapsible repos skip during navigation (only navigates visible files)
- Repo headers shown in single-repo mode (collapsible)
- `<S-CR>` lands on last hunk of previous file when reversing
- Shared keybindings between viewer and browser panes
- Centralized keymap definitions (`keymaps.lua`)
- Log data cached per-repo (instant repo switching, no re-fetch)
- Two-phase initial load: UI appears instantly, stats fill in background
- Single `git diff --name-status` per repo on initial load (was 5-6 commands)
- Working directory change detection with reload prompt
- Repo headers highlighted with `Directory` color
- Handles renamed/copied files in git diffs

### Performance
- Icon cache by extension/filename (eliminates pcall per file)
- Zero `vim.fn` calls in file line formatting hot path
- Active repo count computed during file list build (no extra iteration)
- Async hunk loader batches 5 files per tick at 100ms intervals
- Deferred auto-refresh (100ms delay so UI renders first)
- Log `render_cached()` for repo switching (no git calls)
- Non-blocking stats load: one repo at a time with input yielding
- Smart cache invalidation: only hunks cleared on refresh, stats updated in-place
- Viewed state/chunks preserved across refreshes (no visual flash)
- Full view saved/restored on refresh (no scroll reset)

### Bug Fixes
- Fixed truncation breaking column alignment (uses `<` instead of multi-byte `…`)
- Fixed icon cache giving wrong icons for extensionless files (Makefile, etc.)
- Fixed `_render_log` crash on closed window (validity check)
- Fixed `next_file`/`prev_file` crash on empty file list
- Fixed async hunk loader overwriting repo headers (collapsed file fallback)
- Fixed `<Tab>` in browser triggering nvim's default window switch
- Fixed cursor blink from rapid async loader redraws
- Fixed `:` command delay (non-blocking background stats)
- Fixed background stats loader race condition (generation counter)
- Fixed renamed files silently dropped from review
- Fixed single-repo collapse inconsistency with navigation
- Fixed viewer scroll resetting on auto-refresh (winsaveview)
- Removed dead `is_file_visible` function

### Code Quality
- Orchestrator pattern applied to `M.open`, `M.refresh`, `_render_log`
- Extracted: `validate_and_load`, `compute_stats`, `populate_state`, `restore_and_render`, `setup_auto_refresh`
- Extracted: `build_log_winbar`, `format_log_line`, `build_log_display`
- Extracted: `refresh_log`, `refresh_browser_and_viewer`
- `build_jobs_for_repo` accepts `skip_numstat` for fast initial load
- `parse_name_status` combines file list + deleted detection in one parse

## v0.6.0 (2026-05-06)

### Features
- Collapsible repo sections in file browser (`<CR>` on repo header toggles)
- Deleted files shown as `[UD]` status in both uncommitted and branch-diff modes
- Right-justified stats with aligned columns in both browser and log
- File paths truncated from left (keeps filename visible)
- Commit messages truncated from right (keeps start visible)
- Collapsed repo state persisted in session

### Bug Fixes
- Fixed UTF-8 corruption in path/commit truncation (uses `strcharpart`)
- Fixed collapsed state hiding files in single-repo mode (guard with `multi`)
- Fixed `count_file_lines` crash on directories ("Is a directory" error)
- Fixed session not saving on `:qa` (VimLeavePre guard was too strict)
- Fixed `VimLeavePre` loading modules unnecessarily when plugin unused
- Fixed `stat_width` using byte length instead of display width
- Fixed hard-coded `r` in browser cheatsheet (now uses config key)
- Made collapse toggle logic explicit for readability

## v0.5.0 (2026-05-06)

### Features
- Central state store (`state.lua`) with pub/sub infrastructure
- Reactive highlights via `schedule_highlight()` — no more manual wiring
- Floating winbar headers for file browser and git log (always visible)
- Winbar highlights: shaded background, bold numbers, colored +/-
- `g?` keyboard shortcuts modal
- `<S-CR>` reverse advance (previous hunk or previous file)
- `<S-Tab>` previous file in viewer, previous repo in log
- `m`/`M` now toggle viewed status
- Background async hunk loading with progress display
- Session stored in `~/.local/state/nvim/code_review/` (per-project hash)
- Session scoped by git ref — detects scope changes, partial restore on mismatch
- Single-commit mode clears viewed state on commit switch
- `VimLeavePre` autocmd saves session on `:qa`

### Bug Fixes
- Fixed stack overflow in async hunk loader (synchronous recursion)
- Fixed listener leak on re-open (state.reset clears listeners)
- Fixed `diff_active` set before diff window created
- Fixed `show_help` crash in headless nvim
- Fixed floating windows (LSP hover) persisting after leaving edit mode
- Fixed session not saving (wrong cwd, vim.NIL comparison)
- Fixed log `win_width` nil after winbar migration
- Fixed browser `line_for_idx` inconsistent fallback
- Removed dead highlight code in `update_file_line`

### Code Quality
- Separated highlight namespaces (`ns_hl` vs `ns_stats`) to prevent interference
- Session path normalized with `vim.fn.resolve()` for symlink consistency
- TOCTOU guard in async loader (re-checks generation)
- Removed header lines from buffer (winbar handles it)

## v0.4.0 (2026-05-05)

### Features
- Session persistence: review progress saved between nvim sessions (`.code_review_session.json`)
- Multi-repo log: `<Tab>` cycles between repos in the git log panel
- Per-repo commit selection: selecting a commit only affects that repo's files
- Skip deleted files in `<CR>` advance flow (auto-marks them as viewed)
- Viewer jumps to first *unviewed* hunk when opening a file
- Header gracefully hides help text when window is too narrow
- `nowrap` on browser/log panes for clean display

### Bug Fixes
- Fixed forward-reference crash (`mark_file` used before declaration)
- Fixed `set_repo_ref(nil, nil)` permanently shadowing global base ref
- Fixed redundant `find_repos()` call in log refresh
- Fixed `file_exists` always returning true in single-commit mode
- Fixed cursor position lost when returning from edit mode
- Fixed log losing selection state on close/reopen
- Fixed session restore not updating browser display
- Fixed stat highlights matching `+N` in commit messages
- Fixed extra `end` causing load error in viewer.lua

### Code Quality
- Session save notifies on write failure
- Session restore validates `current_idx` against actual file path
- Cursor bounds clamped in `unedit()`
- Consistent 2-space indentation in config.lua
- Commit message truncation in log to prevent stat overflow

## v0.3.0 (2026-05-05)

### Features
- Git log panel (`L`) with commit selection and range/single-commit modes
- Committed vs uncommitted file status indicators (`[C]`, `[CU]`)
- Edit mode (`e`) — open real file for editing, `gv` to return to review
- Pane navigation: `gv`/`gf`/`gl` to switch between viewer/browser/log
- `:CodeReviewReload` for hot-reloading during development
- Manual refresh (`r`) updates viewer and file list
- Auto-refresh on `TabEnter` in addition to `FocusGained`
- Untracked files show total line count as additions
- Uncommitted changes in log includes untracked file stats
- `log.show_on_open`, `log.max_commits`, `log.default_mode` config options
- Configurable `toggle_log`, `refresh`, `edit` keys

### Bug Fixes
- Fixed shell injection via unescaped git refs in viewer
- Fixed stale state after close preventing clean re-open (per-module `reset()`)
- Fixed buffer leak (`bufhidden=wipe` for scratch buffers, `hide` only for viewer)
- Fixed `vim.system():wait()` blocking indefinitely (5s timeout)
- Fixed diff pane remaining open when entering edit mode
- Fixed viewer losing keymaps after search modal replaced buffer
- Fixed auto-refresh resetting cursor position
- Fixed log panel double-highlighting file browser
- Fixed indentation inconsistency (all files now use 2 spaces)

### Code Quality
- Extracted shared utilities to `util.lua` (scratch buf, list win, nav keymaps, stat highlights)
- Per-module `reset()` methods replace cross-module state mutation
- Keymap guard in log panel prevents duplicate registration
- Config validation for `default_mode`, `max_commits`, `browser_height`
- `find_repos()` cached, invalidated on refresh
- `count_file_lines()` extracted as reusable function
- Renamed "chunks" to "hunks" throughout

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
