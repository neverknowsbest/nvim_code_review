local layout = require("code_review.layout")
local viewer = require("code_review.viewer")
local git = require("code_review.git")
local util = require("code_review.util")

local M = {}

M.files = {}
M.current_idx = 1
M.header_lines = 0
M.line_map = {}
M.idx_to_line = {}
M.viewed = {}
M.viewed_hunks = {}
M._keymaps_set = false

local has_devicons, devicons = pcall(require, "nvim-web-devicons")
local ns = vim.api.nvim_create_namespace("code_review_browser")

local function get_keys_help()
  local k = require("code_review.config").current.keys
  return string.format(
    "%s: advance  %s: diff  %s/%s: hunk  %s/%s: file  %s: mark+next  r: refresh  %s: close ",
    k.advance, k.toggle_diff, k.next_hunk, k.prev_hunk,
    k.next_file, k.prev_file, k.mark_and_next, k.quit
  )
end

local function get_icon(filepath)
  if not has_devicons then return "" end
  local icon, _ = devicons.get_icon(filepath, vim.fn.fnamemodify(filepath, ":e"), { default = true })
  return (icon or "") .. " "
end

local function format_file_line(entry, stats, viewed_hunks, idx, max_name_len)
  local icon = get_icon(entry.path)
  local prefix = string.format("  [%s] %s%s", entry.status, icon, entry.path)
  local display_width = vim.fn.strdisplaywidth(prefix)
  local pad = string.rep(" ", math.max(0, max_name_len - display_width + 2))
  local seen = viewed_hunks[idx] and vim.tbl_count(viewed_hunks[idx]) or 0
  local chunk_str = string.format("%d/%d", seen, stats.chunks)
  local stat_str = string.format("%-7s hunks  +%-4d -%-4d", chunk_str, stats.added, stats.removed)
  return prefix .. pad .. stat_str
end

local function build_header(file_count, repos, total_added, total_removed, win_width)
  local repo_label = #repos > 1 and string.format(" across %d repos", #repos) or ""
  local left = string.format(" %d files changed%s  +%d -%d", file_count, repo_label, total_added, total_removed)
  local help = get_keys_help()
  local padding = math.max(1, win_width - #left - #help)
  return {
    left .. string.rep(" ", padding) .. help,
    string.rep("─", win_width),
  }
end

local function apply_stat_highlights(buf, lines)
  util.apply_stat_highlights(buf, ns, lines)
end

local function calc_max_name_len(file_entries)
  local max = 0
  for _, entry in ipairs(file_entries) do
    local icon = get_icon(entry.path)
    local prefix = string.format("  [%s] %s%s", entry.status, icon, entry.path)
    local w = vim.fn.strdisplaywidth(prefix)
    if w > max then max = w end
  end
  return max
end

local function build_file_lines(file_entries, stats, viewed_hunks, repos, max_name_len)
  local lines = {}
  local line_map = {}
  local multi = #repos > 1
  local current_repo = nil

  for i, entry in ipairs(file_entries) do
    if multi and entry.repo ~= current_repo then
      current_repo = entry.repo
      table.insert(lines, " ┌ " .. vim.fn.fnamemodify(entry.repo, ":t") .. "/")
    end
    table.insert(lines, format_file_line(entry, stats[i], viewed_hunks, i, max_name_len))
    line_map[#lines] = i
  end

  return lines, line_map
end

function M.populate(file_entries, repos)
  M.files = file_entries
  M.current_idx = 1
  M.line_map = {}
  M.idx_to_line = {}
  M.viewed = {}
  M.viewed_hunks = {}
  M.stats = {}
  M.repos = repos

  local state = layout.state
  if not state.browser_buf or not vim.api.nvim_buf_is_valid(state.browser_buf) then
    return
  end

  -- Pre-compute stats
  local total_added, total_removed = 0, 0
  local stats = {}
  for i, entry in ipairs(file_entries) do
    local added, removed = git.get_file_stats(entry.path, entry.repo)
    local hunks = git.get_hunks(entry.path, entry.repo)
    stats[i] = { added = added, removed = removed, chunks = #hunks }
    total_added = total_added + added
    total_removed = total_removed + removed
  end
  M.stats = stats

  local win_width = vim.api.nvim_win_get_width(state.browser_win)
  local header = build_header(#file_entries, repos, total_added, total_removed, win_width)
  M.header_lines = #header

  M._max_name_len = calc_max_name_len(file_entries)
  local file_lines, line_map = build_file_lines(file_entries, stats, M.viewed_hunks, repos, M._max_name_len)

  -- Offset line_map by header lines and build reverse map
  M.line_map = {}
  M.idx_to_line = {}
  for line, idx in pairs(line_map) do
    local offset_line = line + M.header_lines
    M.line_map[offset_line] = idx
    M.idx_to_line[idx] = offset_line
  end

  local display = {}
  for _, l in ipairs(header) do table.insert(display, l) end
  for _, l in ipairs(file_lines) do table.insert(display, l) end

  vim.bo[state.browser_buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.browser_buf, 0, -1, false, display)
  vim.bo[state.browser_buf].modifiable = false

  apply_stat_highlights(state.browser_buf, display)

  -- Keymaps (set once per buffer)
  if not M._keymaps_set then
    local opts = { buffer = state.browser_buf, nowait = true, silent = true }
    vim.keymap.set("n", "<CR>", function() M.select() end, opts)
    vim.keymap.set("n", "q", function() require("code_review").close() end, opts)
    util.set_nav_keymaps(state.browser_buf)
    M._keymaps_set = true
  end

  util.setup_list_win(state.browser_win)

  -- Cursor on first file line
  local first_line = M.line_for_idx(1)
  vim.api.nvim_win_set_cursor(state.browser_win, { first_line, 0 })
  if #file_entries > 0 then
    viewer.show_file(file_entries[1].path, file_entries[1].repo)
    M.highlight_current()
  end
end

function M.select()
  local state = layout.state
  if not state.browser_win or not vim.api.nvim_win_is_valid(state.browser_win) then
    return
  end
  local cursor = vim.api.nvim_win_get_cursor(state.browser_win)
  local idx = M.line_map[cursor[1]]
  if idx and idx >= 1 and idx <= #M.files then
    M.current_idx = idx
    M.highlight_current()
    viewer.show_file(M.files[idx].path, M.files[idx].repo)
  end
end

function M.highlight_current()
  local state = layout.state
  if not state.browser_buf or not vim.api.nvim_buf_is_valid(state.browser_buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(state.browser_buf, ns, 0, -1)

  -- Mark viewed files (don't auto-mark current as viewed here)
  for idx, _ in pairs(M.viewed) do
    local line = M.line_for_idx(idx)
    if line and idx ~= M.current_idx then
      vim.api.nvim_buf_set_extmark(state.browser_buf, ns, line - 1, 0, { line_hl_group = "Comment" })
    end
  end

  -- Highlight current file
  local line = M.line_for_idx(M.current_idx)
  if line then
    vim.api.nvim_buf_set_extmark(state.browser_buf, ns, line - 1, 0, { line_hl_group = "CurSearch" })
  end

  -- Re-apply +/- color coding
  local lines = vim.api.nvim_buf_get_lines(state.browser_buf, 0, -1, false)
  apply_stat_highlights(state.browser_buf, lines)
end

function M.line_for_idx(idx)
  return M.idx_to_line[idx] or (M.header_lines + 1)
end

function M.mark_hunk_viewed(file_idx, hunk_start)
  if not M.viewed_hunks[file_idx] then
    M.viewed_hunks[file_idx] = {}
  end
  if M.viewed_hunks[file_idx][hunk_start] then
    return
  end
  M.viewed_hunks[file_idx][hunk_start] = true
  M.update_file_line(file_idx)
end

function M.update_file_line(idx)
  local state = layout.state
  if not state.browser_buf or not vim.api.nvim_buf_is_valid(state.browser_buf) then
    return
  end
  local line_nr = M.line_for_idx(idx)
  if not line_nr then return end

  local entry = M.files[idx]
  local s = M.stats[idx]
  if not entry or not s then return end

  local new_line = format_file_line(entry, s, M.viewed_hunks, idx, M._max_name_len or 0)

  vim.bo[state.browser_buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.browser_buf, line_nr - 1, line_nr, false, { new_line })
  vim.bo[state.browser_buf].modifiable = false

  -- Re-apply highlights for this line
  local lnum = line_nr - 1
  local ls, le = new_line:find("%+%d+")
  if ls then
    vim.api.nvim_buf_set_extmark(state.browser_buf, ns, lnum, ls - 1, { end_col = le, hl_group = "DiffAdd" })
  end
  ls, le = new_line:find("%-%d+", (le or 0) + 1)
  if ls then
    vim.api.nvim_buf_set_extmark(state.browser_buf, ns, lnum, ls - 1, { end_col = le, hl_group = "DiffDelete" })
  end

  if idx == M.current_idx then
    vim.api.nvim_buf_set_extmark(state.browser_buf, ns, lnum, 0, { line_hl_group = "CurSearch" })
  elseif M.viewed[idx] then
    vim.api.nvim_buf_set_extmark(state.browser_buf, ns, lnum, 0, { line_hl_group = "Comment" })
  end
end

function M.refresh_display()
  M._keymaps_set = false
  M.populate(M.files, M.repos)
end

return M
