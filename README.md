# nvim-code-review

A Neovim plugin for reviewing uncommitted git changes. Opens a dedicated tab with full syntax-highlighted files and a changes browser, designed for efficient pre-commit review workflows.

## Features

- Full file view with syntax highlighting (not raw diff output)
- Gutter signs marking changed/deleted lines
- Changes browser with per-file stats (chunks, lines added/removed)
- Multi-repository workspace support (auto-discovers git repos under cwd)
- Hunk-by-hunk navigation with wrap-around
- Progress tracking: viewed chunks per file, viewed file dimming
- `<Space>` advance flow: walk through all changes with a single key
- Parallel git loading for fast startup in multi-repo workspaces
- Auto-refresh on focus

## Installation

### lazy.nvim

```lua
{
  "neverknowsbest/nvim-code-review",
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

Open with `:CodeReview` or `<leader>cr` (if configured). Close with `q`.

## Keybindings

| Key | Action |
|-----|--------|
| `<Space>` | Advance: next hunk, or mark file + next file at end |
| `]c` / `[c` | Next / previous hunk |
| `]f` / `[f` | Next / previous file |
| `m` | Mark current file as fully viewed |
| `M` | Mark all files as viewed |
| `<Tab>` | Mark current file as viewed + next file |
| `<CR>` / `l` | Open file under cursor (in browser pane) |
| `q` | Close review |

## Browser pane

Shows a summary of all changes:

```
 5 files changed across 2 repos  +62 -23       <Space>: advance  ]c/[c: hunk  ...
──────────────────────────────────────────────────────────────────────────────────
 ┌ service-a/
  [U]  src/handler.lua       2/3 chunks  +20  -5
  [S]  src/utils.lua         0/1 chunks  +8   -3
 ┌ service-b/
  [SU] lib/client.ts         1/4 chunks  +30  -10
  [U]  README.md             0/1 chunks  +4   -5
```

- `[S]` staged, `[U]` unstaged, `[SU]` both
- Chunk progress updates as you navigate hunks
- Viewed files are dimmed; current file is highlighted
- File type icons shown if nvim-web-devicons is installed

## Multi-repo support

If your cwd is not a git repo, the plugin scans immediate subdirectories for `.git` folders and aggregates changes across all of them. No configuration needed.

## Requirements

- Neovim >= 0.10
- git
- Optional: nvim-web-devicons (for file icons)
