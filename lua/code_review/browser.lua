local layout = require("code_review.layout")
local git = require("code_review.git")
local util = require("code_review.util")
local state = require("code_review.state")

local M = {}
M._keymaps_set = false

local has_devicons, devicons = pcall(require, "nvim-web-devicons")
local ns_hl = vim.api.nvim_create_namespace("code_review_browser_hl")
local ns_stats = vim.api.nvim_create_namespace("code_review_browser_stats")

local hl_scheduled = false
local function schedule_highlight()
  if hl_scheduled then return end
  hl_scheduled = true
  vim.schedule(function()
    hl_scheduled = false
    M.highlight_current()
  end)
end
M.schedule_highlight = schedule_highlight

local function get_keys_help()
  local k = require("code_review.config").current.keys
  return string.format(
    "%s: advance  %s: diff  %s: mark+next  %s: refresh  g?: help  %s: close ",
    k.advance, k.toggle_diff, k.mark_and_next, k.refresh, k.quit
  )
end

local function get_icon(filepath)
  if not has_devicons then return "" end
  local icon, _ = devicons.get_icon(filepath, vim.fn.fnamemodify(filepath, ":e"), { default = true })
  return (icon or "") .. " "
end

local function format_stat_str(stats, viewed_hunks, idx)
  local seen = viewed_hunks[idx] and vim.tbl_count(viewed_hunks[idx]) or 0
  local total = stats and stats.chunks
  if total then seen = math.min(seen, total) end
  local chunk_str = total and string.format("%d/%d", seen, total) or "-"
  return string.format("%-5s h  +%-4d -%-4d", chunk_str, stats and stats.added or 0, stats and stats.removed or 0)
end

local function format_file_line(entry, stats, viewed_hunks, idx, available_width)
  local icon = get_icon(entry.path)
  local stat = format_stat_str(stats, viewed_hunks, idx)
  local stat_width = vim.fn.strdisplaywidth(stat)

  -- Build prefix: [status] icon path
  local status_prefix = string.format("  [%s] %s", entry.status, icon)
  local prefix_width = vim.fn.strdisplaywidth(status_prefix)
  local path = entry.path

  -- Available space for path = total width - prefix - stat - padding
  local path_space = available_width - prefix_width - stat_width - 2
  if path_space < 4 then path_space = 4 end

  -- Truncate path from the LEFT to keep filename visible
  if vim.fn.strdisplaywidth(path) > path_space then
    while vim.fn.strdisplaywidth(path) > path_space - 1 and vim.fn.strchars(path) > 1 do
      path = vim.fn.strcharpart(path, 1)
    end
    path = "…" .. path
  end

  local path_display = path
  local pad = string.rep(" ", math.max(1, available_width - prefix_width - vim.fn.strdisplaywidth(path_display) - stat_width))
  return status_prefix .. path_display .. pad .. stat
end

local function build_header(file_count, repos, total_added, total_removed)
  local repo_label = #repos > 1 and string.format(" across %d repos", #repos) or ""
  local left = string.format(
    "%%#CodeReviewBar# %%#CodeReviewBarBold#%d files changed%%#CodeReviewBar#%s  %%#CodeReviewBarAdd#+%d %%#CodeReviewBarDel#-%d%%#CodeReviewBar#",
    file_count, repo_label, total_added, total_removed
  )
  local help = get_keys_help()
  return left .. "%=" .. "%#CodeReviewBar#" .. help
end

M._loading_gen = 0

function M._load_hunks_async()
  M._loading_gen = M._loading_gen + 1
  local gen = M._loading_gen
  local files = state.get("files")
  local stats = state.get("stats")
  local i = 0

  local function load_next()
    if gen ~= M._loading_gen then return end
    i = i + 1
    if i > #files then return end
    if stats[i] and stats[i].chunks then
      vim.defer_fn(load_next, 0)
      return
    end
    local entry = files[i]
    if entry then
      local hunks = git.get_hunks(entry.path, entry.repo)
      if stats[i] then
        stats[i].chunks = #hunks
        local s = layout.state
        if s.browser_buf and vim.api.nvim_buf_is_valid(s.browser_buf) and gen == M._loading_gen then
          local line_nr = M.line_for_idx(i)
          if line_nr then
            local viewed_hunks = state.get("viewed_hunks")
            local new_line = format_file_line(entry, stats[i], viewed_hunks, i, M._max_name_len or 0)
            vim.bo[s.browser_buf].modifiable = true
            vim.api.nvim_buf_set_lines(s.browser_buf, line_nr - 1, line_nr, false, { new_line })
            vim.bo[s.browser_buf].modifiable = false
            schedule_highlight()
          end
        end
      end
    end
    vim.defer_fn(load_next, 10)
  end

  vim.defer_fn(load_next, 50)
end

local function sum_stats(stats)
  local added, removed = 0, 0
  for _, st in ipairs(stats) do
    added = added + (st.added or 0)
    removed = removed + (st.removed or 0)
  end
  return added, removed
end

local function build_file_list(files, stats, viewed_hunks, repos, available_width)
  local display = {}
  local line_map = {}
  local idx_to_line = {}
  local repo_line_map = {}  -- line -> repo_path (for collapse toggle)
  local multi = #repos > 1
  local current_repo = nil
  local collapsed = state.get("collapsed_repos")

  for i, entry in ipairs(files) do
    if multi and entry.repo ~= current_repo then
      current_repo = entry.repo
      local name = vim.fn.fnamemodify(entry.repo, ":t")
      local marker = collapsed[entry.repo] and " ▶ " or " ┌ "
      table.insert(display, marker .. name .. "/")
      repo_line_map[#display] = entry.repo
    end
    if not multi or not collapsed[entry.repo] then
      table.insert(display, format_file_line(entry, stats[i], viewed_hunks, i, available_width))
      line_map[#display] = i
      idx_to_line[i] = #display
    end
  end

  return display, line_map, idx_to_line, repo_line_map
end

function M._setup_keymaps(buf)
  if M._keymaps_set then return end
  local opts = { buffer = buf, nowait = true, silent = true }
  vim.keymap.set("n", "<CR>", function() M.select() end, opts)
  vim.keymap.set("n", "q", function() require("code_review").close() end, opts)
  util.set_nav_keymaps(buf)
  M._keymaps_set = true
end

function M.render()
  local s = layout.state
  if not s.browser_buf or not vim.api.nvim_buf_is_valid(s.browser_buf) then
    return
  end

  vim.api.nvim_buf_clear_namespace(s.browser_buf, ns_stats, 0, -1)

  M._load_hunks_async()

  local files = state.get("files")
  local stats = state.get("stats")
  local repos = state.get("repos")
  local viewed_hunks = state.get("viewed_hunks")

  local total_added, total_removed = sum_stats(stats)

  local header = build_header(#files, repos, total_added, total_removed)
  vim.wo[s.browser_win].winbar = header

  local available_width = vim.api.nvim_win_get_width(s.browser_win)
  local display, line_map, idx_to_line, repo_line_map = build_file_list(files, stats, viewed_hunks, repos, available_width)

  M._line_map = line_map
  M._idx_to_line = idx_to_line
  M._repo_line_map = repo_line_map
  M._header_lines = 0
  M._max_name_len = available_width

  vim.bo[s.browser_buf].modifiable = true
  vim.api.nvim_buf_set_lines(s.browser_buf, 0, -1, false, display)
  vim.bo[s.browser_buf].modifiable = false

  util.apply_stat_highlights(s.browser_buf, ns_stats, display)

  M._setup_keymaps(s.browser_buf)
  util.setup_list_win(s.browser_win)
  schedule_highlight()
end

function M.highlight_current()
  local s = layout.state
  if not s.browser_buf or not vim.api.nvim_buf_is_valid(s.browser_buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(s.browser_buf, ns_hl, 0, -1)

  local viewed = state.get("viewed")
  local current_idx = state.get("current_idx")

  for idx, _ in pairs(viewed) do
    local line = M.line_for_idx(idx)
    if line and idx ~= current_idx then
      vim.api.nvim_buf_set_extmark(s.browser_buf, ns_hl, line - 1, 0, { line_hl_group = "Comment" })
    end
  end

  local line = M.line_for_idx(current_idx)
  if line then
    vim.api.nvim_buf_set_extmark(s.browser_buf, ns_hl, line - 1, 0, { line_hl_group = "CurSearch" })
  end

  local lines = vim.api.nvim_buf_get_lines(s.browser_buf, 0, -1, false)
  util.apply_stat_highlights(s.browser_buf, ns_stats, lines)
end

function M.update_file_line(idx)
  local s = layout.state
  if not s.browser_buf or not vim.api.nvim_buf_is_valid(s.browser_buf) then
    return
  end
  local line_nr = M.line_for_idx(idx)
  if not line_nr then return end

  local files = state.get("files")
  local stats = state.get("stats")
  local viewed_hunks = state.get("viewed_hunks")
  local entry = files[idx]
  local st = stats[idx]
  if not entry or not st then return end

  local new_line = format_file_line(entry, st, viewed_hunks, idx, M._max_name_len or 0)

  vim.bo[s.browser_buf].modifiable = true
  vim.api.nvim_buf_set_lines(s.browser_buf, line_nr - 1, line_nr, false, { new_line })
  vim.bo[s.browser_buf].modifiable = false

  local lnum = line_nr - 1
  local ls, le = new_line:find("  %+%d+%s+%-%d+%s*$")
  if ls then
    local ps, pe = new_line:find("%+%d+", ls)
    if ps then
      vim.api.nvim_buf_set_extmark(s.browser_buf, ns_stats, lnum, ps - 1, { end_col = pe, hl_group = "DiffAdd" })
    end
    local ms, me = new_line:find("%-%d+", pe or ls)
    if ms then
      vim.api.nvim_buf_set_extmark(s.browser_buf, ns_stats, lnum, ms - 1, { end_col = me, hl_group = "DiffDelete" })
    end
  end
  schedule_highlight()
end

function M.select()
  local s = layout.state
  if not s.browser_win or not vim.api.nvim_win_is_valid(s.browser_win) then
    return
  end
  local cursor = vim.api.nvim_win_get_cursor(s.browser_win)
  local line = cursor[1]

  -- Check if this is a repo header line (toggle collapse)
  if M._repo_line_map and M._repo_line_map[line] then
    local repo_path = M._repo_line_map[line]
    local collapsed = state.get("collapsed_repos")
    if collapsed[repo_path] then
      collapsed[repo_path] = nil
    else
      collapsed[repo_path] = true
    end
    M.render()
    schedule_highlight()
    return
  end

  local idx = M._line_map and M._line_map[line]
  local files = state.get("files")
  if idx and idx >= 1 and idx <= #files then
    state.data.current_idx = idx
    local viewer = require("code_review.viewer")
    viewer.show_file(files[idx].path, files[idx].repo)
    schedule_highlight()
  end
end

function M.line_for_idx(idx)
  return M._idx_to_line and M._idx_to_line[idx] or 1
end

function M.mark_hunk_viewed(file_idx, hunk_start)
  local viewed_hunks = state.get("viewed_hunks")
  if not viewed_hunks[file_idx] then
    viewed_hunks[file_idx] = {}
  end
  if viewed_hunks[file_idx][hunk_start] then
    return
  end
  viewed_hunks[file_idx][hunk_start] = true

  -- Lazily fill chunk count
  local stats = state.get("stats")
  if stats[file_idx] and not stats[file_idx].chunks then
    local files = state.get("files")
    local entry = files[file_idx]
    local hunks = git.get_hunks(entry.path, entry.repo)
    stats[file_idx].chunks = #hunks
  end

  M.update_file_line(file_idx)
end

return M
