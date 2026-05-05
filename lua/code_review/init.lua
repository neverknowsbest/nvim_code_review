local git = require("code_review.git")
local layout = require("code_review.layout")
local browser = require("code_review.browser")
local viewer = require("code_review.viewer")
local config = require("code_review.config")
local log = require("code_review.log")

local M = {}
local augroup = nil

function M.setup(opts)
  config.apply(opts)

  local function hl_attr(name, attr)
    local hl = vim.api.nvim_get_hl(0, { name = name, link = false })
    return hl[attr]
  end

  local change_fg = hl_attr("DiffAdd", "fg") or hl_attr("String", "fg") or 0x859900
  local delete_fg = hl_attr("DiffDelete", "fg") or hl_attr("Error", "fg") or 0xdc322f
  local change_bg = hl_attr("DiffChange", "bg") or hl_attr("Visual", "bg") or 0xeef6d6
  local delete_bg = hl_attr("DiffDelete", "bg") or hl_attr("Visual", "bg") or 0xf6d6d6

  vim.api.nvim_set_hl(0, "CodeReviewChange", { fg = change_fg, default = true })
  vim.api.nvim_set_hl(0, "CodeReviewDelete", { fg = delete_fg, default = true })
  vim.api.nvim_set_hl(0, "CodeReviewChangeLine", { bg = change_bg, default = true })
  vim.api.nvim_set_hl(0, "CodeReviewDeleteLine", { bg = delete_bg, default = true })

  vim.api.nvim_create_user_command("CodeReview", function(cmd_opts)
    M.open(cmd_opts.args ~= "" and cmd_opts.args or nil)
  end, { nargs = "?" })
  vim.api.nvim_create_user_command("CodeReviewClose", function()
    M.close()
  end, {})
  vim.api.nvim_create_user_command("CodeReviewReload", function()
    for name, _ in pairs(package.loaded) do
      if name:match("^code_review") then
        package.loaded[name] = nil
      end
    end
    require("code_review").setup(config.current)
    vim.notify("CodeReview reloaded", vim.log.levels.INFO)
  end, {})
end

function M._setup_keymaps()
  local state = layout.state
  local opts = { buffer = state.viewer_buf, nowait = true, silent = true }
  local keys = config.current.keys
  vim.keymap.set("n", keys.next_hunk, function() viewer.next_hunk() end, opts)
  vim.keymap.set("n", keys.prev_hunk, function() viewer.prev_hunk() end, opts)
  vim.keymap.set("n", keys.next_file, function() M.next_file() end, opts)
  vim.keymap.set("n", keys.prev_file, function() M.prev_file() end, opts)
  vim.keymap.set("n", keys.toggle_diff, function() viewer.toggle_diff() end, opts)
  vim.keymap.set("n", keys.mark_file, function() M.mark_file_viewed() end, opts)
  vim.keymap.set("n", keys.mark_all, function() M.mark_all_viewed() end, opts)
  vim.keymap.set("n", keys.mark_and_next, function() M.mark_and_next() end, opts)
  vim.keymap.set("n", keys.advance, function() M.advance() end, opts)
  vim.keymap.set("n", keys.toggle_log, function() log.toggle() end, opts)
  vim.keymap.set("n", keys.refresh, function() M.refresh() end, opts)
  vim.keymap.set("n", keys.edit, function()
    if viewer._editing then viewer.unedit() else viewer.edit() end
  end, opts)
  vim.keymap.set("n", keys.quit, function() M.close() end, opts)
  require("code_review.util").set_nav_keymaps(state.viewer_buf)
end

function M.open(base_ref)
  -- Guard against multiple sessions
  if layout.state.tab and vim.api.nvim_tabpage_is_valid(layout.state.tab) then
    vim.notify("A code review session is already open. Close it first with :CodeReviewClose", vim.log.levels.WARN)
    return
  end

  if base_ref then
    if not git.set_base(base_ref) then
      return
    end
  else
    git.set_base(nil)
  end
  git.clear_cache()

  local repos = git.find_repos()
  if #repos == 0 then
    vim.notify("No git repositories found", vim.log.levels.WARN)
    return
  end

  local all_files = git.load_all_repos(repos)

  if #all_files == 0 then
    vim.notify("No uncommitted changes found", vim.log.levels.INFO)
    return
  end

  layout.open()

  M._setup_keymaps()

  -- Open log panel if configured (before populating browser so width is correct)
  if config.current.log.show_on_open then
    log.open()
  end

  browser.populate(all_files, repos)

  -- Focus viewer (file pane)
  vim.api.nvim_set_current_win(layout.state.viewer_win)

  -- Auto-refresh on focus (only when on review tab)
  if config.current.auto_refresh then
    augroup = vim.api.nvim_create_augroup("CodeReviewAutoRefresh", { clear = true })
    local function try_refresh()
      if
        layout.state.tab
        and vim.api.nvim_tabpage_is_valid(layout.state.tab)
        and vim.api.nvim_get_current_tabpage() == layout.state.tab
      then
        M.refresh()
      end
    end
    vim.api.nvim_create_autocmd({ "FocusGained", "TabEnter" }, {
      group = augroup,
      callback = try_refresh,
    })
  end
end

function M.refresh()
  git.clear_cache()
  local repos = git.find_repos()
  local all_files = git.load_all_repos(repos)
  if #all_files == 0 then
    vim.notify("No uncommitted changes", vim.log.levels.INFO)
    return
  end

  -- Check if file list changed
  local same = #all_files == #browser.files
  if same then
    for i, f in ipairs(all_files) do
      if f.path ~= browser.files[i].path or f.repo ~= browser.files[i].repo then
        same = false
        break
      end
    end
  end

  if same then
    -- File list unchanged, just update stats without resetting progress
    browser.repos = repos
    local stats = {}
    for i, entry in ipairs(all_files) do
      local added, removed = git.get_file_stats(entry.path, entry.repo)
      local hunks = git.get_hunks(entry.path, entry.repo)
      stats[i] = { added = added, removed = removed, chunks = #hunks }
    end
    browser.stats = stats
    browser.highlight_current()
    -- Re-render current file preserving cursor
    local entry = browser.files[browser.current_idx]
    if entry then
      local state = layout.state
      local cursor = vim.api.nvim_win_get_cursor(state.viewer_win)
      viewer.show_file(entry.path, entry.repo)
      pcall(vim.api.nvim_win_set_cursor, state.viewer_win, cursor)
    end
  else
    -- File list changed, full reset but preserve position
    local prev_idx = math.min(browser.current_idx, #all_files)
    browser.populate(all_files, repos)
    if prev_idx > 1 and prev_idx <= #browser.files then
      browser.current_idx = prev_idx
      browser.highlight_current()
    end
  end
end

local function goto_file(idx)
  browser.current_idx = idx
  viewer.close_diff()
  viewer.show_file(browser.files[idx].path, browser.files[idx].repo)
  viewer.refresh_diff()
  browser.highlight_current()
  local state = layout.state
  if state.browser_win and vim.api.nvim_win_is_valid(state.browser_win) then
    local line = browser.line_for_idx(idx)
    vim.api.nvim_win_set_cursor(state.browser_win, { line, 0 })
    vim.api.nvim_win_call(state.browser_win, function()
      vim.cmd("normal! zz")
    end)
  end
end

function M.next_file()
  local idx = browser.current_idx + 1
  if idx > #browser.files then
    idx = 1
  end
  goto_file(idx)
end

function M.prev_file()
  local idx = browser.current_idx - 1
  if idx < 1 then
    idx = #browser.files
  end
  goto_file(idx)
end

local function mark_file(idx)
  local entry = browser.files[idx]
  if not entry then
    return
  end
  local hunks = git.get_hunks(entry.path, entry.repo)
  if not browser.viewed_hunks[idx] then
    browser.viewed_hunks[idx] = {}
  end
  for _, hunk in ipairs(hunks) do
    browser.viewed_hunks[idx][hunk.start] = true
  end
  browser.viewed[idx] = true
  browser.update_file_line(idx)
end

function M.mark_file_viewed()
  mark_file(browser.current_idx)
  browser.highlight_current()
end

function M.mark_all_viewed()
  for i, _ in ipairs(browser.files) do
    mark_file(i)
  end
  browser.highlight_current()
end

function M.mark_and_next()
  mark_file(browser.current_idx)
  M.next_file()
end

function M.advance()
  local state = layout.state
  if not state.viewer_buf or not vim.api.nvim_buf_is_valid(state.viewer_buf) then
    return
  end
  local idx = browser.current_idx
  local entry = browser.files[idx]
  if not entry then
    return
  end
  local hunks = git.get_hunks(entry.path, entry.repo)
  if #hunks == 0 then
    M.mark_and_next()
    return
  end

  local cursor = vim.api.nvim_win_get_cursor(state.viewer_win)[1]
  for _, hunk in ipairs(hunks) do
    if hunk.start > cursor then
      viewer.next_hunk()
      return
    end
  end

  -- At or past last hunk — mark and move
  M.mark_and_next()
end

function M.close()
  if augroup then
    vim.api.nvim_del_augroup_by_id(augroup)
    augroup = nil
  end
  log.close()
  log.reset()
  viewer.close_diff()
  viewer.reset()
  git.reset()
  layout.close()
  browser._keymaps_set = false
end

return M
