# AGENTS.md

## Code Patterns

### Orchestration over mega-functions

Each module should have one or more **orchestration functions** that coordinate calls to smaller helpers. Avoid large functions with inline loops, conditionals, and side effects mixed together.

**Orchestration functions** (e.g., `render()`, `show_file()`, `save()`, `restore()`):
- Read state/inputs
- Call helper functions in sequence
- Write outputs (buffer content, extmarks, files)
- Should be readable as a high-level summary of what happens

**Helper functions** (e.g., `read_file()`, `place_signs()`, `build_file_list()`):
- Do one thing
- Pure where possible (take inputs, return outputs)
- Side effects isolated to dedicated helpers (`set_buffer_content`, `detach_lsp`)
- Named for what they do, not when they run

**Example:**
```lua
-- Good: orchestrator calls helpers
function M.show_file(filepath, repo_path)
  local lines = read_file(repo_path, filepath)
  set_buffer_content(buf, lines)
  set_filetype(buf, filepath)
  detach_lsp(buf)
  place_signs(buf, hunks, #lines)
  jump_to_first_unviewed_hunk(win, hunks, #lines)
end

-- Bad: everything inline
function M.show_file(filepath, repo_path)
  local f = io.open(...)
  -- 80 lines of mixed reading, buffer ops, extmarks, cursor logic
end
```

### State management

- All review data lives in `state.lua` (`state.get(key)`, `state.data.key`)
- Mutations use `state.set(key, value)` for reactive updates or `state.data.key = value` for silent updates
- `state.batch(fn)` groups mutations to avoid intermediate notifications
- UI-only state (window handles, keymaps_set flags) stays module-local

### Reactive highlights

- Two namespaces: `ns_hl` (line highlights) and `ns_stats` (stat colors)
- `schedule_highlight()` is the single mechanism — coalesces via `vim.schedule`
- Any buffer modification that could affect highlights should call `schedule_highlight()`
- `highlight_current()` clears `ns_hl` entirely and re-applies — always consistent
- Never call `highlight_current()` directly from outside `browser.lua`

### Winbar headers

- Headers use `winbar` (not buffer lines) so they stay visible on scroll
- Use `%#HighlightGroup#` syntax for inline colors
- Use `%=` for right-alignment
- Gracefully omit help text if window is too narrow

### Keybindings

- All keys configurable via `config.current.keys`
- No hard-coded key strings in keymap.set calls
- Help modal (`help.lua`) reads from config to stay in sync
