# nvim_code_review

A Neovim plugin for reviewing git changes. Opens a dedicated tab with full syntax-highlighted files, a changes browser, and a git log panel — designed for efficient code review workflows.

## Features

- Full file view with syntax highlighting (not raw diff output)
- Gutter signs marking changed/deleted lines
- Side-by-side diff toggle showing the base version with synced scrolling
- Changes browser with per-file stats (hunks, lines added/removed)
- Git log panel with commit selection and range/single-commit modes
- Multi-repository workspace support (auto-discovers git repos under cwd)
- Branch/commit comparison: `:CodeReview main` or select commits in the log
- Untracked file support with `[N]` status, committed changes with `[C]`
- Hunk-by-hunk navigation with wrap-around
- Progress tracking: viewed hunks per file, viewed file dimming
- `<CR>` advance flow: walk through all changes with a single key (skips deleted files)
- Parallel git loading for fast startup in multi-repo workspaces
- Fully async refresh — no UI blocking on reload
- Skip-render optimization (no buffer rewrite when display unchanged)
- Background async hunk loading (non-blocking)
- Log data cached per-repo (instant switching between repos)
- Zero `vim.fn` calls in rendering hot path
- Structured git data layer with lazy accessors and per-repo storage
- Session persistence: resume reviews where you left off (scoped by git ref)
- Auto-refresh on focus
- Floating winbar headers (always visible when scrolling)
- `g?` keyboard shortcuts modal
- Hot reload with `:CodeReviewReload` during development
- Fully configurable keybindings, signs, and behavior

## Installation

### lazy.nvim

```lua
{
  "neverknowsbest/nvim_code_review",
  opts = {},
  config = function(_, opts)
    require("code_review").setup(opts)
  end,
  keys = {
    { "<leader>cr", "<cmd>CodeReview<cr>", desc = "Code Review" },
    { "<leader>cb", "<cmd>CodeReviewBrowse<cr>", desc = "Code Review (browse)" },
  },
}
```

### Local development

```bash
./install.sh --dev   # symlinks to source, changes are live
./install.sh         # copies files for standalone install
```

## Usage

- `:CodeReview` — review uncommitted changes (tab mode)
- `:CodeReview main` — review changes against a branch
- `:CodeReviewBrowse` — open browse mode (real buffers + browser panel)
- `:CodeReviewClose` — close the review session
- `:CodeReviewReload` — hot reload plugin (picks up code changes without restart)

## Modes

### Tab mode (`:CodeReview` / `<leader>cr`)

Opens a dedicated tab with a read-only viewer, file browser, and git log. Full keyset available — optimized for focused review sessions.

### Browse mode (`:CodeReviewBrowse` / `<leader>cb`)

Opens the file browser and log as bottom splits in your current tab. Files open as real vim buffers with LSP, undo, and full editing. Signs mark changed lines. Optimized for review-while-editing.

Press `<C-t>` from any pane to toggle between modes (preserves position and progress). Calling `:CodeReview` while in browse mode switches to tab mode, and vice versa.

## Keybindings

### Tab mode — Viewer

| Key | Action |
|-----|--------|
| `<CR>` | Advance: next hunk, or mark file + next file at end |
| `<S-CR>` | Reverse: previous hunk, or previous file |
| `]c` / `[c` | Next / previous hunk (advances across files) |
| `]f` / `[f` | Next / previous file (skips deleted files) |
| `gs` | Toggle side-by-side diff with base version |
| `m` | Toggle current file viewed |
| `M` | Toggle all files viewed |
| `<Tab>` | Mark current file as viewed + next file |
| `<S-Tab>` | Previous file |
| `L` | Toggle git log panel |
| `r` | Refresh file list |
| `<C-t>` | Switch to browse mode |
| `g?` | Show keyboard shortcuts |
| `q` | Close review |

### Browse mode — File buffer

| Key | Action |
|-----|--------|
| `]c` / `[c` | Next / previous hunk (advances across files) |
| `]f` / `[f` | Next / previous file |
| `gs` | Toggle side-by-side diff |
| `gv` | Go to editor window |
| `gb` | Go to file browser |
| `gl` | Go to git log |
| `g?` | Show keyboard shortcuts |

### Browse mode — Browser pane

| Key | Action |
|-----|--------|
| `<CR>` | Open file under cursor |
| `m` / `M` | Toggle file / all files viewed |
| `<Tab>` | Mark file + next |
| `gs` | Toggle diff |
| `L` | Toggle git log |
| `r` | Refresh |
| `<C-t>` | Switch to tab mode |
| `q` | Close review |

### Git log

| Key | Action |
|-----|--------|
| `<CR>` | Select commit (sets review range) |
| `s` | Toggle range/single-commit mode |
| `<Tab>` / `<S-Tab>` | Next / previous repo |
| `q` | Close review |

### Navigation (all panes, both modes)

| Key | Action |
|-----|--------|
| `gv` | Go to viewer (tab) / editor (browse) |
| `gb` | Go to file browser |
| `gl` | Go to git log (opens if closed) |
| `<Esc>` | Return to viewer/editor from browser or log |

## Configuration

All options are optional — defaults work out of the box:

```lua
require("code_review").setup({
  browser_height = 12,
  signs = { change = "│", delete = "▁" },
  show_untracked = true,
  persist_session = true,
  auto_refresh = true,
  log = {
    show_on_open = true,
    max_commits = 20,
    default_mode = "range",  -- "range" or "single"
  },
  browse = {
    signs_on_enter = true,  -- auto-place signs when entering tracked files
  },
  keys = {
    advance = "<CR>",
    next_hunk = "]c",
    prev_hunk = "[c",
    next_file = "]f",
    prev_file = "[f",
    toggle_diff = "gs",
    toggle_log = "L",
    refresh = "r",
    switch_mode = "<C-t>",
    mark_file = "m",
    mark_all = "M",
    mark_and_next = "<Tab>",
    quit = "q",
  },
})
```

## Browser pane

```
 5 files changed across 2 repos  +62 -23       <CR>: advance  d: diff  ...
──────────────────────────────────────────────────────────────────────────────────
 ┌ service-a/
  [U]  src/handler.lua              2/3 h  +20  -5
  [S]  src/utils.lua                0/1 h  +8   -3
 ▶ service-b/
```

- `[S]` staged, `[U]` unstaged, `[SU]` both, `[N]` new/untracked, `[UD]` deleted
- `[C]` committed, `[CU]` committed + uncommitted changes
- `<CR>` on a repo header collapses/expands that repo's files
- Hunk progress updates as you navigate hunks
- Viewed files are dimmed; current file is highlighted
- File paths truncated from left to fit window (keeps filename visible)
- Stats right-justified with aligned columns
- File type icons shown if nvim-web-devicons is installed

## Git log panel

```
 Git Log [range to HEAD]                    <CR>: select  s: mode  q: close
──────────────────────────────────────────────────────────────────────────────
  ●        uncommitted changes   3f   +42   -10
  a575861  feat: v0.2.0          8f   +536  -335
  d4595d4  Initial commit        10f  +1169 -0
```

- Select a commit to set the review base (shows all changes from that commit to HEAD)
- Toggle single-commit mode with `s` to review just one commit
- "uncommitted changes" entry resets to default mode

## Multi-repo support

If your cwd is not a git repo, the plugin scans immediate subdirectories for `.git` folders and aggregates changes across all of them. Use `<Tab>` in the git log panel to cycle between repos. No configuration needed.

## Session persistence

Review progress (viewed files, viewed hunks, current position) is saved to `~/.local/state/nvim/code_review/` when you close the review or exit nvim. Re-opening `:CodeReview` restores your progress. Sessions are scoped by git ref — if you change which commits are selected, hunk-level progress resets while file-level viewed status is preserved.

## Requirements

- Neovim >= 0.10
- git
- Optional: nvim-web-devicons (for file icons)
