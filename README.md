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
- Background async hunk loading (non-blocking)
- Session persistence: resume reviews where you left off (scoped by git ref)
- Auto-refresh on focus and tab switch
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
  },
}
```

### Local development

```bash
./install.sh --dev   # symlinks to source, changes are live
./install.sh         # copies files for standalone install
```

## Usage

- `:CodeReview` — review uncommitted changes
- `:CodeReview main` — review changes against a branch
- `:CodeReviewClose` — close the review tab
- `:CodeReviewReload` — hot reload plugin (picks up code changes without restart)

## Keybindings

### Viewer (file pane)

| Key | Action |
|-----|--------|
| `<CR>` | Advance: next hunk, or mark file + next file at end |
| `<S-CR>` | Reverse: previous hunk, or previous file |
| `d` | Toggle side-by-side diff with base version |
| `e` | Enter edit mode (open real file for editing) |
| `]c` / `[c` | Next / previous hunk |
| `]f` / `[f` | Next / previous file (skips deleted files) |
| `m` | Toggle current file viewed |
| `M` | Toggle all files viewed |
| `<Tab>` | Mark current file as viewed + next file |
| `<S-Tab>` | Previous file |
| `L` | Toggle git log panel |
| `r` | Refresh file list |
| `g?` | Show keyboard shortcuts |
| `q` | Close review |

### Edit mode

Press `e` in the viewer to open the actual file for editing with full LSP, undo, and formatting support. Use `gv` to return to the review viewer (auto-refreshes diff signs).

### File browser

| Key | Action |
|-----|--------|
| `<CR>` | Open file under cursor |
| `q` | Close review |

### Git log

| Key | Action |
|-----|--------|
| `<CR>` | Select commit (sets review range) |
| `s` | Toggle range/single-commit mode |
| `q` | Close review |

### Navigation (all panes)

| Key | Action |
|-----|--------|
| `gv` | Go to viewer |
| `gf` | Go to file browser |
| `gl` | Go to git log (opens if closed) |

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
  keys = {
    advance = "<CR>",
    next_hunk = "]c",
    prev_hunk = "[c",
    next_file = "]f",
    prev_file = "[f",
    toggle_diff = "d",
    toggle_log = "L",
    refresh = "r",
    edit = "e",
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
  [U]  src/handler.lua       2/3     hunks  +20   -5
  [S]  src/utils.lua         0/1     hunks  +8    -3
 ┌ service-b/
  [CU] lib/client.ts         1/4     hunks  +30   -10
  [N]  new_file.ts           0/0     hunks  +0    -0
```

- `[S]` staged, `[U]` unstaged, `[SU]` both, `[N]` new/untracked
- `[C]` committed, `[CU]` committed + uncommitted changes
- Hunk progress updates as you navigate hunks
- Viewed files are dimmed; current file is highlighted
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
