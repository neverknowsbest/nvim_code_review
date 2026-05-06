local git = require("code_review.git")
local layout = require("code_review.layout")
local browser = require("code_review.browser")
local viewer = require("code_review.viewer")
local config = require("code_review.config")
local log = require("code_review.log")
local session = require("code_review.session")
local state = require("code_review.state")

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

  -- Winbar highlights
  local bar_bg = hl_attr("StatusLine", "bg") or hl_attr("WinBar", "bg") or 0x2c2c2c
  vim.api.nvim_set_hl(0, "CodeReviewBar", { bg = bar_bg, default = true })
  vim.api.nvim_set_hl(0, "CodeReviewBarBold", { bg = bar_bg, bold = true, default = true })
  vim.api.nvim_set_hl(0, "CodeReviewBarAdd", { fg = change_fg, bg = bar_bg, bold = true, default = true })
  vim.api.nvim_set_hl(0, "CodeReviewBarDel", { fg = delete_fg, bg = bar_bg, bold = true, default = true })

  vim.api.nvim_create_user_command("CodeReview", function(cmd_opts)
    M.open(cmd_opts.args ~= "" and cmd_opts.args or nil)
  end, { nargs = "?" })
  vim.api.nvim_create_user_command("CodeReviewClose", function() M.close() end, {})
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
  local s = layout.state
  local opts = { buffer = s.viewer_buf, nowait = true, silent = true }
  local keys = config.current.keys
  vim.keymap.set("n", keys.next_hunk, function() viewer.next_hunk() end, opts)
  vim.keymap.set("n", keys.prev_hunk, function() viewer.prev_hunk() end, opts)
  vim.keymap.set("n", keys.next_file, function() M.next_file() end, opts)
  vim.keymap.set("n", keys.prev_file, function() M.prev_file() end, opts)
  vim.keymap.set("n", keys.toggle_diff, function() viewer.toggle_diff() end, opts)
  vim.keymap.set("n", keys.mark_file, function() M.mark_file_viewed() end, opts)
  vim.keymap.set("n", keys.mark_all, function() M.mark_all_viewed() end, opts)
  vim.keymap.set("n", keys.mark_and_next, function() M.mark_and_next() end, opts)
  vim.keymap.set("n", keys.prev_file_alt, function() M.prev_file() end, opts)
  vim.keymap.set("n", keys.advance, function() M.advance() end, opts)
  vim.keymap.set("n", keys.reverse_advance, function() M.reverse_advance() end, opts)
  vim.keymap.set("n", keys.toggle_log, function() log.toggle() end, opts)
  vim.keymap.set("n", keys.refresh, function() M.refresh() end, opts)
  vim.keymap.set("n", keys.edit, function()
    if state.data.editing then viewer.unedit() else viewer.edit() end
  end, opts)
  vim.keymap.set("n", keys.quit, function() M.close() end, opts)
  vim.keymap.set("n", "g?", function() require("code_review.help").toggle() end, opts)
  require("code_review.util").set_nav_keymaps(s.viewer_buf)
end

function M.open(base_ref)
  if layout.state.tab and vim.api.nvim_tabpage_is_valid(layout.state.tab) then
    vim.notify("A code review session is already open. Close it first with :CodeReviewClose", vim.log.levels.WARN)
    return
  end

  if base_ref then
    if not git.set_base(base_ref) then return end
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

  if #all_files == 0 and not config.current.log.show_on_open then
    vim.notify("No uncommitted changes found", vim.log.levels.INFO)
    return
  end

  layout.open()
  M._setup_keymaps()

  -- Compute stats
  local stats = {}
  local total_added, total_removed = 0, 0
  for i, entry in ipairs(all_files) do
    local added, removed = git.get_file_stats(entry.path, entry.repo)
    stats[i] = { added = added, removed = removed, chunks = nil }
    total_added = total_added + added
    total_removed = total_removed + removed
  end

  -- Set state (batch to avoid multiple renders)
  state.batch(function()
    state.set("repos", repos)
    state.set("stats", stats)
    state.set("files", all_files)  -- triggers browser.render
  end)

  -- Open log panel if configured
  if config.current.log.show_on_open then
    log.open_panel()  -- don't trigger browser re-render
  end

  -- Restore session
  session.restore()
  browser.render()
  local files = state.get("files")
  local entry = files[state.get("current_idx")]
  if entry then
    viewer.show_file(entry.path, entry.repo)
  end

  -- Focus viewer
  vim.api.nvim_set_current_win(layout.state.viewer_win)

  -- Auto-refresh
  if config.current.auto_refresh then
    augroup = vim.api.nvim_create_augroup("CodeReviewAutoRefresh", { clear = true })
    local function try_refresh()
      if layout.state.tab
        and vim.api.nvim_tabpage_is_valid(layout.state.tab)
        and vim.api.nvim_get_current_tabpage() == layout.state.tab then
        M.refresh()
      end
    end
    vim.api.nvim_create_autocmd({ "FocusGained", "TabEnter" }, {
      group = augroup,
      callback = try_refresh,
    })
  end

  -- Save session on nvim exit
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("CodeReviewSave", { clear = true }),
    callback = function()
      if layout.state.tab and vim.api.nvim_tabpage_is_valid(layout.state.tab) then
        session.save()
      end
    end,
  })
end

function M.refresh()
  git.clear_cache()
  if log.is_open() then log.refresh() end
  local repos = git.find_repos()
  local all_files = git.load_all_repos(repos)

  local stats = {}
  for i, entry in ipairs(all_files) do
    local added, removed = git.get_file_stats(entry.path, entry.repo)
    stats[i] = { added = added, removed = removed, chunks = nil }
  end

  local prev_idx = state.get("current_idx")

  state.batch(function()
    state.set("repos", repos)
    state.set("stats", stats)
    state.set("files", all_files)
  end)

  if #all_files > 0 then
    local idx = math.min(prev_idx, #all_files)
    state.data.current_idx = idx
    browser.render()
    local s = layout.state
    if s.browser_win and vim.api.nvim_win_is_valid(s.browser_win) then
      pcall(vim.api.nvim_win_set_cursor, s.browser_win, { browser.line_for_idx(idx), 0 })
    end
    local entry = all_files[idx]
    if entry and s.viewer_win and vim.api.nvim_win_is_valid(s.viewer_win) then
      local cursor = vim.api.nvim_win_get_cursor(s.viewer_win)
      viewer.show_file(entry.path, entry.repo)
      pcall(vim.api.nvim_win_set_cursor, s.viewer_win, cursor)
    end
  else
    browser.render()
    local s = layout.state
    if s.viewer_buf and vim.api.nvim_buf_is_valid(s.viewer_buf) then
      vim.bo[s.viewer_buf].modifiable = true
      vim.api.nvim_buf_set_lines(s.viewer_buf, 0, -1, false, { "  No changes to review" })
      vim.bo[s.viewer_buf].modifiable = false
    end
  end
end

local function mark_file(idx)
  local files = state.get("files")
  local entry = files[idx]
  if not entry then return end
  local hunks = git.get_hunks(entry.path, entry.repo)
  local viewed_hunks = state.get("viewed_hunks")
  if not viewed_hunks[idx] then
    viewed_hunks[idx] = {}
  end
  for _, hunk in ipairs(hunks) do
    viewed_hunks[idx][hunk.start] = true
  end
  local viewed = state.get("viewed")
  viewed[idx] = true
  browser.update_file_line(idx)
end

local function file_exists(entry)
  local _, head_override = git.get_ref_for_repo(entry.repo)
  if head_override then
    local cmd = "git -C " .. vim.fn.shellescape(entry.repo)
      .. " cat-file -e " .. vim.fn.shellescape(head_override .. ":" .. entry.path)
    vim.fn.system(cmd)
    return vim.v.shell_error == 0
  end
  local path = entry.repo .. "/" .. entry.path
  return vim.fn.filereadable(path) == 1
end

local function goto_file(idx)
  local files = state.get("files")
  viewer.close_diff()
  state.data.current_idx = idx
  local entry = files[idx]
  if entry then
    viewer.show_file(entry.path, entry.repo)
  end
  viewer.refresh_diff()
  browser.schedule_highlight()
  local s = layout.state
  if s.browser_win and vim.api.nvim_win_is_valid(s.browser_win) then
    local line = browser.line_for_idx(idx)
    pcall(vim.api.nvim_win_set_cursor, s.browser_win, { line, 0 })
    vim.api.nvim_win_call(s.browser_win, function() vim.cmd("normal! zz") end)
  end
end

function M.next_file()
  local files = state.get("files")
  local start = state.get("current_idx")
  local idx = start
  repeat
    idx = idx + 1
    if idx > #files then idx = 1 end
    if file_exists(files[idx]) then
      goto_file(idx)
      return
    end
    mark_file(idx)
  until idx == start
  goto_file(idx)
end

function M.prev_file()
  local files = state.get("files")
  local start = state.get("current_idx")
  local idx = start
  repeat
    idx = idx - 1
    if idx < 1 then idx = #files end
    if file_exists(files[idx]) then
      goto_file(idx)
      return
    end
    mark_file(idx)
  until idx == start
  goto_file(idx)
end

function M.mark_file_viewed()
  local idx = state.get("current_idx")
  local viewed = state.get("viewed")
  if viewed[idx] then
    -- Unmark
    viewed[idx] = nil
    local viewed_hunks = state.get("viewed_hunks")
    viewed_hunks[idx] = nil
    browser.update_file_line(idx)
  else
    mark_file(idx)
  end
end

function M.mark_all_viewed()
  local files = state.get("files")
  local viewed = state.get("viewed")
  -- Toggle: if all viewed, unmark all; otherwise mark all
  local all_viewed = true
  for i, _ in ipairs(files) do
    if not viewed[i] then all_viewed = false; break end
  end
  if all_viewed then
    state.data.viewed = {}
    state.data.viewed_hunks = {}
    for i, _ in ipairs(files) do
      browser.update_file_line(i)
    end
  else
    for i, _ in ipairs(files) do
      mark_file(i)
    end
  end
end

function M.mark_and_next()
  mark_file(state.get("current_idx"))
  M.next_file()
end

function M.advance()
  local s = layout.state
  if not s.viewer_buf or not vim.api.nvim_buf_is_valid(s.viewer_buf) then
    return
  end
  local files = state.get("files")
  local idx = state.get("current_idx")
  local entry = files[idx]
  if not entry then return end
  local hunks = git.get_hunks(entry.path, entry.repo)
  if #hunks == 0 then
    M.mark_and_next()
    return
  end

  local cursor = vim.api.nvim_win_get_cursor(s.viewer_win)[1]
  for _, hunk in ipairs(hunks) do
    if hunk.start > cursor then
      viewer.next_hunk()
      return
    end
  end

  M.mark_and_next()
end

function M.reverse_advance()
  local s = layout.state
  if not s.viewer_buf or not vim.api.nvim_buf_is_valid(s.viewer_buf) then
    return
  end
  local files = state.get("files")
  local idx = state.get("current_idx")
  local entry = files[idx]
  if not entry then return end
  local hunks = git.get_hunks(entry.path, entry.repo)
  if #hunks == 0 then
    M.prev_file()
    return
  end

  local cursor = vim.api.nvim_win_get_cursor(s.viewer_win)[1]
  for i = #hunks, 1, -1 do
    if hunks[i].start < cursor then
      viewer.prev_hunk()
      return
    end
  end

  -- At or before first hunk — go to previous file
  M.prev_file()
end

function M.close()
  session.save()
  if augroup then
    vim.api.nvim_del_augroup_by_id(augroup)
    augroup = nil
  end
  log.close()
  log.reset()
  viewer.close_diff()
  viewer.reset()
  git.reset()
  state.reset()
  layout.close()
  browser._keymaps_set = false
end

return M
