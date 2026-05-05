# nvim_code_review

A Neovim plugin for reviewing uncommitted git changes. Opens a dedicated tab with full syntax-highlighted files and a changes browser, designed for efficient pre-commit review workflows.

## Features

- Full file view with syntax highlighting (not raw diff output)
- Gutter signs marking changed/deleted lines
- Side-by-side diff toggle showing the base version with synced scrolling
- Changes browser with per-file stats (chunks, lines added/removed)
- Multi-repository workspace support (auto-discovers git repos under cwd)
- Branch comparison: `:CodeReview main` to review changes against any ref
- Untracked file support
- Hunk-by-hunk navigation with wrap-around
- Progress tracking: viewed chunks per file, viewed file dimming
- `<Space>` advance flow: walk through all changes with a single key
- Parallel git loading for fast startup in multi-repo workspaces
- Auto-refresh on focus
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

## Keybindings

| Key | Action |
|-----|--------|
| `<Space>` | Advance: next hunk, or mark file + next file at end |
| `d` | Toggle side-by-side diff with base version |
| `]c` / `[c` | Next / previous hunk |
| `]f` / `[f` | Next / previous file |
| `m` | Mark current file as fully viewed |
| `M` | Mark all files as viewed |
| `<Tab>` | Mark current file as viewed + next file |
| `<CR>` / `l` | Open file under cursor (in browser pane) |
| `q` | Close review |

## Configuration

All options are optional — defaults work out of the box:

```lua
require("code_review").setup({
  browser_height = 12,
  signs = { change = "│", delete = "▁" },
  show_untracked = true,
  auto_refresh = true,
  keys = {
    advance = "<Space>",
    next_hunk = "]c",
    prev_hunk = "[c",
    next_file = "]f",
    prev_file = "[f",
    toggle_diff = "d",
    mark_file = "m",
    mark_all = "M",
    mark_and_next = "<Tab>",
    quit = "q",
  },
})
```

## Browser pane

```
 5 files changed across 2 repos  +62 -23       <Space>: advance  d: diff  ...
──────────────────────────────────────────────────────────────────────────────────
 ┌ service-a/
  [U]  src/handler.lua       2/3     chunks  +20   -5
  [S]  src/utils.lua         0/1     chunks  +8    -3
 ┌ service-b/
  [SU] lib/client.ts         1/4     chunks  +30   -10
  [N]  new_file.ts           0/0     chunks  +0    -0
```

- `[S]` staged, `[U]` unstaged, `[SU]` both, `[N]` new/untracked, `[M]` modified (branch diff)
- Chunk progress updates as you navigate hunks
- Viewed files are dimmed; current file is highlighted
- File type icons shown if nvim-web-devicons is installed

## Multi-repo support

If your cwd is not a git repo, the plugin scans immediate subdirectories for `.git` folders and aggregates changes across all of them. No configuration needed.

## Requirements

- Neovim >= 0.10
- git
- Optional: nvim-web-devicons (for file icons)
