local git = require("code_review.git")
local layout = require("code_review.layout")

local M = {}

M._win = nil
M._buf = nil
M._commits = {}
M._selected = 0
M._single_commit_mode = nil
M._keymaps_set = false
M._repo_idx = 1

local ns = vim.api.nvim_create_namespace("code_review_log")

function M.is_open()
  return M._win and vim.api.nvim_win_is_valid(M._win)
end

function M.toggle()
  if M.is_open() then
    M.close()
    local browser = require("code_review.browser")
    browser.render()
  else
    M.open()
    local browser = require("code_review.browser")
    browser.render()
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
  if M._selected == 0 then
    M._selected = 1
  end
  M._highlight()

  -- Keymaps (set once per buffer)
  if not M._keymaps_set then
    require("code_review.keymaps").setup_log(M._buf)
    M._keymaps_set = true
  end

  -- Focus log panel
  vim.api.nvim_set_current_win(M._win)
end

-- Alias for opening without triggering browser re-render
M.open_panel = M.open

function M.close()
  if M._win and vim.api.nvim_win_is_valid(M._win) then
    vim.api.nvim_win_close(M._win, true)
  end
  M._win = nil
  M._buf = nil
end

M._log_cache = {}  -- repo_path -> { commits, entries }

function M.clear_cache()
  M._log_cache = {}
end

function M.refresh()
  if not M._buf or not vim.api.nvim_buf_is_valid(M._buf) then
    return
  end
  -- Invalidate cache for current repo and re-fetch
  local repos = git.find_repos()
  if #repos == 0 then return end
  local repo = repos[M._repo_idx] and repos[M._repo_idx].path or repos[1].path
  M._log_cache[repo] = nil
  M._render_log(repos, repo)
end

function M.render_cached()
  if not M._buf or not vim.api.nvim_buf_is_valid(M._buf) then
    return
  end
  local repos = git.find_repos()
  if #repos == 0 then return end
  local repo = repos[M._repo_idx] and repos[M._repo_idx].path or repos[1].path
  M._render_log(repos, repo)
end

function M._fetch_log_data(repo)
  local cfg = require("code_review.config").current.log
  local max = tostring(cfg.max_commits)

  local result = vim.system(
    { "git", "-C", repo, "log", "--format=%h %s", "--abbrev=8", "-" .. max }
  ):wait(5000)
  local output = result and result.code == 0 and vim.split(result.stdout or "", "\n", { trimempty = true }) or {}

  local stat_result = vim.system(
    { "git", "-C", repo, "log", "--format=%h", "--shortstat", "--abbrev=8", "-" .. max }
  ):wait(5000)
  local stat_output = stat_result and stat_result.code == 0 and vim.split(stat_result.stdout or "", "\n", { trimempty = true }) or {}

  local commit_stats = {}
  local current_hash = nil
  for _, line in ipairs(stat_output) do
    local hash = line:match("^(%S+)$")
    if hash and #hash >= 7 then
      current_hash = hash
    elseif current_hash and line:match("file") then
      commit_stats[current_hash] = {
        files = line:match("(%d+) file") or "0",
        ins = line:match("(%d+) insertion") or "0",
        del = line:match("(%d+) deletion") or "0",
      }
      current_hash = nil
    end
  end

  -- Uncommitted stats
  local uc_files, uc_ins, uc_del = 0, 0, 0
  local uc_result = vim.system({ "git", "-C", repo, "diff", "--shortstat", "HEAD" }):wait(5000)
  if uc_result and uc_result.code == 0 and uc_result.stdout and #uc_result.stdout > 0 then
    uc_files = tonumber(uc_result.stdout:match("(%d+) file")) or 0
    uc_ins = tonumber(uc_result.stdout:match("(%d+) insertion")) or 0
    uc_del = tonumber(uc_result.stdout:match("(%d+) deletion")) or 0
  end

  -- Build entries
  local commits = { { hash = nil, msg = "uncommitted" } }
  local entries = { { prefix = "  ●        uncommitted changes", files = tostring(uc_files), ins = tostring(uc_ins), del = tostring(uc_del) } }
  for _, line in ipairs(output) do
    local hash, msg = line:match("^(%S+)%s+(.*)$")
    if hash then
      table.insert(commits, { hash = hash, msg = msg })
      local s = commit_stats[hash] or { files = "0", ins = "0", del = "0" }
      table.insert(entries, { prefix = "  " .. hash .. " " .. msg, files = s.files, ins = s.ins, del = s.del })
    end
  end

  return { commits = commits, entries = entries }
end

local function build_log_winbar(repos, mode_label)
  local repo_label = #repos > 1
    and string.format(" %%#CodeReviewBarBold#%s%%#CodeReviewBar# (%d/%d)", repos[M._repo_idx].name, M._repo_idx, #repos)
    or ""
  local left = "%#CodeReviewBar# %#CodeReviewBarBold#Git Log%#CodeReviewBar# %#CodeReviewBarAdd#" .. mode_label .. "%#CodeReviewBar#" .. repo_label
  local right = #repos > 1
    and "<CR>: select  <Tab>: repo  s: mode  q: close "
    or "<CR>: select  s: mode  q: close "
  return left .. "%=%#CodeReviewBar#" .. right
end

local function format_log_line(prefix, stat, available, log_width)
  local stat_width = #stat
  local prefix_display = vim.fn.strdisplaywidth(prefix)
  if prefix_display > available then
    prefix = prefix:sub(1, available - 1) .. "<"
    prefix_display = available
  end
  local pad = string.rep(" ", math.max(1, log_width - prefix_display - stat_width))
  return prefix .. pad .. stat
end

local function build_log_display(entries, log_width)
  local util = require("code_review.util")
  local display = {}
  for _, e in ipairs(entries) do
    local stat = util.format_stat(e.files, e.ins, e.del)
    local available = log_width - #stat - 1
    table.insert(display, format_log_line(e.prefix, stat, available, log_width))
  end
  return display
end

function M._render_log(repos, repo)
  if not M._win or not vim.api.nvim_win_is_valid(M._win) then return end
  if not M._log_cache[repo] then
    M._log_cache[repo] = M._fetch_log_data(repo)
  end
  local cached = M._log_cache[repo]
  M._commits = cached.commits

  local mode_label = M._single_commit_mode and "[single commit]" or "[range to HEAD]"
  vim.wo[M._win].winbar = build_log_winbar(repos, mode_label)

  local log_width = vim.api.nvim_win_get_width(M._win)
  local display = build_log_display(cached.entries, log_width)

  vim.bo[M._buf].modifiable = true
  vim.api.nvim_buf_set_lines(M._buf, 0, -1, false, display)
  vim.bo[M._buf].modifiable = false

  require("code_review.util").apply_stat_highlights(M._buf, ns, display)
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
      local line = M._selected
      vim.api.nvim_buf_set_extmark(M._buf, ns, line - 1, 0, { line_hl_group = "CurSearch" })
    else
      for i = 1, M._selected do
        vim.api.nvim_buf_set_extmark(M._buf, ns, i - 1, 0, { line_hl_group = "CurSearch" })
      end
    end
  end
end

function M.select()
  if not M._win or not vim.api.nvim_win_is_valid(M._win) then
    return
  end
  local cursor = vim.api.nvim_win_get_cursor(M._win)
  local idx = cursor[1]  -- no header offset, winbar is separate
  if idx < 1 or idx > #M._commits then return end

  M._selected = idx
  M._highlight()

  local commit = M._commits[idx]
  local cr = require("code_review")
  local repos = git.find_repos()
  local repo_path = repos[M._repo_idx] and repos[M._repo_idx].path

  if commit.hash == nil then
    -- Uncommitted entry — clear ref for this repo
    if repo_path then
      git.set_repo_ref(repo_path, nil, nil)
    end
  elseif M._single_commit_mode then
    if repo_path then
      git.set_repo_ref(repo_path, commit.hash .. "~1", commit.hash)
    end
  else
    if repo_path then
      git.set_repo_ref(repo_path, commit.hash .. "~1", nil)
    end
  end

  git.clear_cache()
  -- In single-commit mode, clear viewed state since hunks are completely different per commit
  local s = require("code_review.state")
  if M._single_commit_mode then
    s.data.viewed = {}
    s.data.viewed_hunks = {}
  end
  cr.refresh()
  if #s.get("files") == 0 then
    vim.notify("No changes in selected range", vim.log.levels.INFO)
  end
end

function M.toggle_mode()
  M._single_commit_mode = not M._single_commit_mode
  M.refresh()
end

local function scroll_browser_to_repo(repo_path)
  local state = require("code_review.state")
  local browser = require("code_review.browser")
  local files = state.get("files")
  local s = layout.state
  if not s.browser_win or not vim.api.nvim_win_is_valid(s.browser_win) then return end

  -- Find first file from this repo
  for i, entry in ipairs(files) do
    if entry.repo == repo_path then
      local line = browser.line_for_idx(i)
      if line then
        pcall(vim.api.nvim_win_set_cursor, s.browser_win, { math.max(1, line - 1), 0 })
        vim.api.nvim_win_call(s.browser_win, function() vim.cmd("normal! zt") end)
      end
      return
    end
  end
end

function M.cycle_repo()
  local repos = git.find_repos()
  if #repos <= 1 then return end
  M._repo_idx = M._repo_idx + 1
  if M._repo_idx > #repos then M._repo_idx = 1 end
  M._selected = 1
  M.refresh()
  scroll_browser_to_repo(repos[M._repo_idx].path)
end

function M.cycle_repo_back()
  local repos = git.find_repos()
  if #repos <= 1 then return end
  M._repo_idx = M._repo_idx - 1
  if M._repo_idx < 1 then M._repo_idx = #repos end
  M._selected = 1
  M.refresh()
  scroll_browser_to_repo(repos[M._repo_idx].path)
end

function M.reset()
  M._commits = {}
  M._selected = 0
  M._single_commit_mode = nil
  M._keymaps_set = false
  M._repo_idx = 1
  M._log_cache = {}
end

return M
