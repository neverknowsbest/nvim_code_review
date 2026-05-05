local layout = require("code_review.layout")
local viewer = require("code_review.viewer")
local git = require("code_review.git")

local M = {}

M.files = {}
M.current_idx = 1
M.header_lines = 0
M.line_map = {} -- maps display line number -> index in M.files
M.viewed = {} -- set of indices that have been viewed
M.viewed_hunks = {} -- idx -> set of hunk start lines visited

local has_devicons, devicons = pcall(require, "nvim-web-devicons")
local ns = vim.api.nvim_create_namespace("code_review_browser")

local function get_icon(filepath)
  if not has_devicons then return "" end
  local icon, _ = devicons.get_icon(filepath, vim.fn.fnamemodify(filepath, ":e"), { default = true })
  return (icon or "") .. " "
end

function M.populate(file_entries, repos)
  M.files = file_entries
  M.current_idx = 1
  M.line_map = {}
  M.viewed = {}
  M.viewed_hunks = {}
  M.stats = {}

  local state = layout.state
  if not state.browser_buf or not vim.api.nvim_buf_is_valid(state.browser_buf) then
    return
  end

  local display = {}
  local total_added, total_removed = 0, 0

  -- Pre-compute stats
  local stats = {}
  for i, entry in ipairs(file_entries) do
    local added, removed = git.get_file_stats(entry.path, entry.repo)
    local hunks = git.get_hunks(entry.path, entry.repo)
    stats[i] = { added = added, removed = removed, chunks = #hunks }
    total_added = total_added + added
    total_removed = total_removed + removed
  end
  M.stats = stats
  M.repos = repos

  -- Header
  local repo_label = #repos > 1 and string.format(" across %d repos", #repos) or ""
  local left = string.format(" %d files changed%s  +%d -%d", #file_entries, repo_label, total_added, total_removed)
  local keys = "<Space>: advance  ]c/[c: hunk  ]f/[f: file  m/M: mark  <Tab>: mark+next  q: close "
  local win_width = vim.api.nvim_win_get_width(state.browser_win)
  local padding = math.max(1, win_width - #left - #keys)
  local header = left .. string.rep(" ", padding) .. keys
  table.insert(display, header)
  table.insert(display, string.rep("─", win_width))
  M.header_lines = 2

  -- Group files by repo, build display with aligned columns
  local multi = #repos > 1
  local current_repo = nil

  -- Calculate max filename width for alignment
  local max_name_len = 0
  for _, entry in ipairs(file_entries) do
    local icon = get_icon(entry.path)
    local prefix = string.format("  [%s] %s%s", entry.status, icon, entry.path)
    if #prefix > max_name_len then max_name_len = #prefix end
  end
  M._max_name_len = max_name_len

  for i, entry in ipairs(file_entries) do
    if multi and entry.repo ~= current_repo then
      current_repo = entry.repo
      local repo_name = vim.fn.fnamemodify(entry.repo, ":t")
      table.insert(display, " ┌ " .. repo_name .. "/")
    end
    local icon = get_icon(entry.path)
    local s = stats[i]
    local prefix = string.format("  [%s] %s%s", entry.status, icon, entry.path)
    local padding = string.rep(" ", max_name_len - #prefix + 2)
    local seen = M.viewed_hunks[i] and vim.tbl_count(M.viewed_hunks[i]) or 0
    local stat_str = string.format("%d/%d chunks  +%-4d -%d", seen, s.chunks, s.added, s.removed)
    table.insert(display, prefix .. padding .. stat_str)
    M.line_map[#display] = i
  end

  vim.bo[state.browser_buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.browser_buf, 0, -1, false, display)
  vim.bo[state.browser_buf].modifiable = false

  -- Color-code +/- stats
  for lnum, line in ipairs(display) do
    -- Highlight +N in green
    local s, e = line:find("%+%d+")
    if s then
      vim.api.nvim_buf_set_extmark(state.browser_buf, ns, lnum - 1, s - 1, {
        end_col = e,
        hl_group = "DiffAdd",
      })
    end
    -- Highlight -N in red
    s, e = line:find("%-%d+", (e or 0) + 1)
    if s then
      vim.api.nvim_buf_set_extmark(state.browser_buf, ns, lnum - 1, s - 1, {
        end_col = e,
        hl_group = "DiffDelete",
      })
    end
  end

  -- Keymaps for browser
  local opts = { buffer = state.browser_buf, nowait = true, silent = true }
  vim.keymap.set("n", "<CR>", function() M.select() end, opts)
  vim.keymap.set("n", "l", function() M.select() end, opts)
  vim.keymap.set("n", "q", function() require("code_review").close() end, opts)

  -- Highlight current line
  vim.wo[state.browser_win].cursorline = true
  vim.wo[state.browser_win].number = false
  vim.wo[state.browser_win].relativenumber = false
  vim.wo[state.browser_win].signcolumn = "no"

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

  -- Mark viewed files
  M.viewed[M.current_idx] = true
  for idx, _ in pairs(M.viewed) do
    local line = M.line_for_idx(idx)
    if line and idx ~= M.current_idx then
      vim.api.nvim_buf_set_extmark(state.browser_buf, ns, line - 1, 0, {
        line_hl_group = "Comment",
      })
    end
  end

  -- Highlight current file
  local line = M.line_for_idx(M.current_idx)
  if line then
    vim.api.nvim_buf_set_extmark(state.browser_buf, ns, line - 1, 0, {
      line_hl_group = "CurSearch",
    })
  end

  -- Re-apply +/- color coding
  local lines = vim.api.nvim_buf_get_lines(state.browser_buf, 0, -1, false)
  for lnum, l in ipairs(lines) do
    local s, e = l:find("%+%d+")
    if s then
      vim.api.nvim_buf_set_extmark(state.browser_buf, ns, lnum - 1, s - 1, {
        end_col = e,
        hl_group = "DiffAdd",
      })
    end
    s, e = l:find("%-%d+", (e or 0) + 1)
    if s then
      vim.api.nvim_buf_set_extmark(state.browser_buf, ns, lnum - 1, s - 1, {
        end_col = e,
        hl_group = "DiffDelete",
      })
    end
  end
end

function M.line_for_idx(idx)
  for line, i in pairs(M.line_map) do
    if i == idx then return line end
  end
  return M.header_lines + 1
end

function M.mark_hunk_viewed(file_idx, hunk_start)
  if not M.viewed_hunks[file_idx] then
    M.viewed_hunks[file_idx] = {}
  end
  if M.viewed_hunks[file_idx][hunk_start] then
    return -- already tracked, skip update
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

  local icon = get_icon(entry.path)
  local prefix = string.format("  [%s] %s%s", entry.status, icon, entry.path)

  -- Recalculate max_name_len from stored value
  local pad = string.rep(" ", (M._max_name_len or 0) - #prefix + 2)
  local seen = M.viewed_hunks[idx] and vim.tbl_count(M.viewed_hunks[idx]) or 0
  local stat_str = string.format("%d/%d chunks  +%-4d -%d", seen, s.chunks, s.added, s.removed)
  local new_line = prefix .. pad .. stat_str

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

  -- Re-apply current file highlight if this is the current file
  if idx == M.current_idx then
    vim.api.nvim_buf_set_extmark(state.browser_buf, ns, lnum, 0, {
      line_hl_group = "CurSearch",
    })
  elseif M.viewed[idx] then
    vim.api.nvim_buf_set_extmark(state.browser_buf, ns, lnum, 0, {
      line_hl_group = "Comment",
    })
  end
end

function M.refresh_display()
  local state = layout.state
  if not state.browser_buf or not vim.api.nvim_buf_is_valid(state.browser_buf) then
    return
  end

  -- Rebuild file lines with updated chunk counts
  local display = {}
  local multi = M.repos and #M.repos > 1
  local current_repo = nil

  -- Header
  local total_added, total_removed = 0, 0
  for _, s in ipairs(M.stats) do
    total_added = total_added + s.added
    total_removed = total_removed + s.removed
  end
  local repo_label = multi and string.format(" across %d repos", #M.repos) or ""
  local left = string.format(" %d files changed%s  +%d -%d", #M.files, repo_label, total_added, total_removed)
  local keys = "<Space>: advance  ]c/[c: hunk  ]f/[f: file  m/M: mark  <Tab>: mark+next  q: close "
  local win_width = vim.api.nvim_win_get_width(state.browser_win)
  local padding = math.max(1, win_width - #left - #keys)
  table.insert(display, left .. string.rep(" ", padding) .. keys)
  table.insert(display, string.rep("─", win_width))
  M.header_lines = 2
  M.line_map = {}

  local max_name_len = 0
  for _, entry in ipairs(M.files) do
    local icon = get_icon(entry.path)
    local prefix = string.format("  [%s] %s%s", entry.status, icon, entry.path)
    if #prefix > max_name_len then max_name_len = #prefix end
  end

  for i, entry in ipairs(M.files) do
    if multi and entry.repo ~= current_repo then
      current_repo = entry.repo
      local repo_name = vim.fn.fnamemodify(entry.repo, ":t")
      table.insert(display, " ┌ " .. repo_name .. "/")
    end
    local icon = get_icon(entry.path)
    local s = M.stats[i]
    local prefix = string.format("  [%s] %s%s", entry.status, icon, entry.path)
    local pad = string.rep(" ", max_name_len - #prefix + 2)
    local seen = M.viewed_hunks[i] and vim.tbl_count(M.viewed_hunks[i]) or 0
    local stat_str = string.format("%d/%d chunks  +%-4d -%d", seen, s.chunks, s.added, s.removed)
    table.insert(display, prefix .. pad .. stat_str)
    M.line_map[#display] = i
  end

  vim.bo[state.browser_buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.browser_buf, 0, -1, false, display)
  vim.bo[state.browser_buf].modifiable = false

  M.highlight_current()
end

return M
