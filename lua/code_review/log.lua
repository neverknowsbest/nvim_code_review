local git = require("code_review.git")
local layout = require("code_review.layout")

local M = {}

M._win = nil
M._buf = nil
M._commits = {}
M._selected = 0
M._single_commit_mode = nil

local ns = vim.api.nvim_create_namespace("code_review_log")

function M.is_open()
  return M._win and vim.api.nvim_win_is_valid(M._win)
end

function M.toggle()
  if M.is_open() then
    M.close()
    local browser = require("code_review.browser")
    browser.refresh_display()
  else
    M.open()
    local browser = require("code_review.browser")
    browser.refresh_display()
  end
end

function M.open()
  local state = layout.state
  if not state.browser_win or not vim.api.nvim_win_is_valid(state.browser_win) then
    return
  end

  local cfg = require("code_review.config").current.log
  if M._single_commit_mode == nil then
    M._single_commit_mode = (cfg.default_mode == "single")
  end

  -- Split browser pane vertically (log on right)
  vim.api.nvim_set_current_win(state.browser_win)
  vim.cmd("rightbelow vsplit")
  M._buf = vim.api.nvim_create_buf(false, true)
  M._win = vim.api.nvim_get_current_win()
  vim.api.nvim_set_current_buf(M._buf)

  local util = require("code_review.util")
  util.setup_scratch_buf(M._buf)
  util.setup_list_win(M._win)

  M.refresh()
  M._selected = 1
  M._highlight()

  -- Keymaps (set once per buffer)
  if not M._keymaps_set then
    local opts = { buffer = M._buf, nowait = true, silent = true }
    vim.keymap.set("n", "<CR>", function() M.select() end, opts)
    vim.keymap.set("n", "s", function() M.toggle_mode() end, opts)
    vim.keymap.set("n", "q", function() require("code_review").close() end, opts)
    util.set_nav_keymaps(M._buf)
    M._keymaps_set = true
  end

  -- Focus log panel
  vim.api.nvim_set_current_win(M._win)
end

function M.close()
  if M._win and vim.api.nvim_win_is_valid(M._win) then
    vim.api.nvim_win_close(M._win, true)
  end
  M._win = nil
  M._buf = nil
end

function M.refresh()
  if not M._buf or not vim.api.nvim_buf_is_valid(M._buf) then
    return
  end

  -- Get git log from first repo
  local repos = git.find_repos()
  if #repos == 0 then return end
  local repo = repos[1].path

  local cfg = require("code_review.config").current.log
  local max = tostring(cfg.max_commits)
  local result = vim.system(
    { "git", "-C", repo, "log", "--format=%h %s", "--abbrev=8", "-" .. max }
  ):wait(5000)
  local output = result and result.code == 0 and vim.split(result.stdout or "", "\n", { trimempty = true }) or { "-- Unable to load git log" }

  -- Get stat info per commit
  local stat_result = vim.system(
    { "git", "-C", repo, "log", "--format=%h", "--shortstat", "--abbrev=8", "-" .. max }
  ):wait(5000)
  local stat_output = stat_result and stat_result.code == 0 and vim.split(stat_result.stdout or "", "\n", { trimempty = true }) or {}

  -- Parse stats into a map of hash -> {files, ins, del}
  local commit_stats = {}
  local current_hash = nil
  for _, line in ipairs(stat_output) do
    local hash = line:match("^(%S+)$")
    if hash and #hash >= 7 then
      current_hash = hash
    elseif current_hash and line:match("file") then
      local files = line:match("(%d+) file") or "0"
      local ins = line:match("(%d+) insertion") or "0"
      local del = line:match("(%d+) deletion") or "0"
      commit_stats[current_hash] = { files = files, ins = ins, del = del }
      current_hash = nil
    end
  end

  M._commits = {}
  local display = {}
  local mode_label = M._single_commit_mode and "[single commit]" or "[range to HEAD]"
  local left = " Git Log " .. mode_label
  local right = "<CR>: select  s: mode  q: close "
  local win_width = vim.api.nvim_win_get_width(M._win)
  local padding = math.max(1, win_width - #left - #right)
  table.insert(display, left .. string.rep(" ", padding) .. right)
  table.insert(display, string.rep("─", win_width))

  local util = require("code_review.util")

  -- Uncommitted entry (tracked + untracked)
  local uc_result = vim.system({ "git", "-C", repo, "diff", "--shortstat", "HEAD" }):wait(5000)
  local uc_files, uc_ins, uc_del = 0, 0, 0
  if uc_result and uc_result.code == 0 and uc_result.stdout and #uc_result.stdout > 0 then
    uc_files = tonumber(uc_result.stdout:match("(%d+) file")) or 0
    uc_ins = tonumber(uc_result.stdout:match("(%d+) insertion")) or 0
    uc_del = tonumber(uc_result.stdout:match("(%d+) deletion")) or 0
  end
  -- Add untracked files
  local ut_result = vim.system({ "git", "-C", repo, "ls-files", "--others", "--exclude-standard" }):wait(5000)
  if ut_result and ut_result.code == 0 and ut_result.stdout then
    local ut_files = vim.split(ut_result.stdout, "\n", { trimempty = true })
    for _, f in ipairs(ut_files) do
      uc_files = uc_files + 1
      uc_ins = uc_ins + git.count_file_lines(repo .. "/" .. f)
    end
  end
  table.insert(M._commits, { hash = nil, msg = "uncommitted" })

  -- Build commit entries
  local entries = {}
  table.insert(entries, { prefix = "  ●        uncommitted changes", files = tostring(uc_files), ins = tostring(uc_ins), del = tostring(uc_del) })
  for _, line in ipairs(output) do
    local hash, msg = line:match("^(%S+)%s+(.*)$")
    if hash then
      table.insert(M._commits, { hash = hash, msg = msg })
      local s = commit_stats[hash] or { files = "0", ins = "0", del = "0" }
      table.insert(entries, { prefix = "  " .. hash .. " " .. msg, files = s.files, ins = s.ins, del = s.del })
    end
  end

  -- Find max prefix width for alignment
  local max_prefix = 0
  for _, e in ipairs(entries) do
    local w = vim.fn.strdisplaywidth(e.prefix)
    if w > max_prefix then max_prefix = w end
  end

  for _, e in ipairs(entries) do
    local pad = string.rep(" ", max_prefix - vim.fn.strdisplaywidth(e.prefix) + 2)
    table.insert(display, e.prefix .. pad .. util.format_stat(e.files, e.ins, e.del))
  end

  vim.bo[M._buf].modifiable = true
  vim.api.nvim_buf_set_lines(M._buf, 0, -1, false, display)
  vim.bo[M._buf].modifiable = false

  -- Highlight stats
  util.apply_stat_highlights(M._buf, ns, display)

  -- Highlight selected commit
  M._highlight()
end

function M._highlight()
  if not M._buf or not vim.api.nvim_buf_is_valid(M._buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(M._buf, ns, 0, -1)

  -- Re-apply stat highlights
  local lines = vim.api.nvim_buf_get_lines(M._buf, 0, -1, false)
  local util = require("code_review.util")
  util.apply_stat_highlights(M._buf, ns, lines)

  -- Highlight selected commits
  if M._selected > 0 then
    if M._single_commit_mode then
      local line = M._selected + 2
      vim.api.nvim_buf_set_extmark(M._buf, ns, line - 1, 0, { line_hl_group = "CurSearch" })
    else
      for i = 1, M._selected do
        local line = i + 2
        vim.api.nvim_buf_set_extmark(M._buf, ns, line - 1, 0, { line_hl_group = "CurSearch" })
      end
    end
  end
end

function M.select()
  if not M._win or not vim.api.nvim_win_is_valid(M._win) then
    return
  end
  local cursor = vim.api.nvim_win_get_cursor(M._win)
  local idx = cursor[1] - 2 -- offset for header lines
  if idx < 1 or idx > #M._commits then return end

  M._selected = idx
  M._highlight()

  local commit = M._commits[idx]
  local cr = require("code_review")

  if commit.hash == nil then
    -- Uncommitted entry selected — reset to uncommitted only
    git.set_base(nil)
    git._head_override = nil
  elseif M._single_commit_mode then
    git.set_base(commit.hash .. "~1")
    git._head_override = commit.hash
  else
    git.set_base(commit.hash)
    git._head_override = nil
  end

  git.clear_cache()
  cr.refresh()
  local browser = require("code_review.browser")
  if #browser.files == 0 then
    vim.notify("No changes in selected range", vim.log.levels.INFO)
  end
end

function M.toggle_mode()
  M._single_commit_mode = not M._single_commit_mode
  M.refresh()
  if M._selected > 0 then
    M.select()
  end
end

function M.reset()
  M._selected = 0
  git.set_base(nil)
  git._head_override = nil
  git.clear_cache()
  M._highlight()
  require("code_review").refresh()
end

function M.reset()
  M._commits = {}
  M._selected = 0
  M._single_commit_mode = nil
  M._keymaps_set = false
end

return M
