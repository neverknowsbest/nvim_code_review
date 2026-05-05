local git = require("code_review.git")
local layout = require("code_review.layout")
local browser = require("code_review.browser")
local viewer = require("code_review.viewer")

local M = {}
local augroup = nil

function M.setup()
  local function hl_bg(name)
    local hl = vim.api.nvim_get_hl(0, { name = name, link = false })
    return hl.bg
  end

  local change_bg = hl_bg("DiffChange") or hl_bg("Visual") or 0xeef6d6
  local delete_bg = hl_bg("DiffDelete") or hl_bg("Visual") or 0xf6d6d6

  vim.api.nvim_set_hl(0, "CodeReviewChange", { fg = "#859900", default = true })
  vim.api.nvim_set_hl(0, "CodeReviewDelete", { fg = "#dc322f", default = true })
  vim.api.nvim_set_hl(0, "CodeReviewChangeLine", { bg = change_bg, default = true })
  vim.api.nvim_set_hl(0, "CodeReviewDeleteLine", { bg = delete_bg, default = true })

  vim.api.nvim_create_user_command("CodeReview", function() M.open() end, {})
  vim.api.nvim_create_user_command("CodeReviewClose", function() M.close() end, {})
end

function M.open()
  local repos = git.find_repos()
  if #repos == 0 then
    vim.notify("No git repositories found", vim.log.levels.WARN)
    return
  end

  -- Parallel load all repos
  local all_files = git.load_all_repos(repos)

  if #all_files == 0 then
    vim.notify("No uncommitted changes found", vim.log.levels.INFO)
    return
  end

  layout.open()

  local state = layout.state
  local opts = { buffer = state.viewer_buf, nowait = true, silent = true }
  vim.keymap.set("n", "]c", function() viewer.next_hunk() end, opts)
  vim.keymap.set("n", "[c", function() viewer.prev_hunk() end, opts)
  vim.keymap.set("n", "]f", function() M.next_file() end, opts)
  vim.keymap.set("n", "[f", function() M.prev_file() end, opts)
  vim.keymap.set("n", "m", function() M.mark_file_viewed() end, opts)
  vim.keymap.set("n", "M", function() M.mark_all_viewed() end, opts)
  vim.keymap.set("n", "<Tab>", function() M.mark_and_next() end, opts)
  vim.keymap.set("n", "<Space>", function() M.advance() end, opts)
  vim.keymap.set("n", "q", function() M.close() end, opts)

  browser.populate(all_files, repos)
  -- Focus viewer (file pane)
  vim.api.nvim_set_current_win(state.viewer_win)

  -- Auto-refresh on focus
  augroup = vim.api.nvim_create_augroup("CodeReviewAutoRefresh", { clear = true })
  vim.api.nvim_create_autocmd("FocusGained", {
    group = augroup,
    callback = function()
      if layout.state.tab and vim.api.nvim_tabpage_is_valid(layout.state.tab) then
        M.refresh()
      end
    end,
  })
end

function M.refresh()
  git.clear_cache()
  local repos = git.find_repos()
  local all_files = git.load_all_repos(repos)
  if #all_files == 0 then
    vim.notify("No uncommitted changes", vim.log.levels.INFO)
    return
  end
  browser.populate(all_files, repos)
end

function M.next_file()
  local idx = browser.current_idx + 1
  if idx > #browser.files then idx = 1 end
  browser.current_idx = idx
  viewer.show_file(browser.files[idx].path, browser.files[idx].repo)
  browser.highlight_current()
  local state = layout.state
  if state.browser_win and vim.api.nvim_win_is_valid(state.browser_win) then
    vim.api.nvim_win_set_cursor(state.browser_win, { browser.line_for_idx(idx), 0 })
  end
end

function M.prev_file()
  local idx = browser.current_idx - 1
  if idx < 1 then idx = #browser.files end
  browser.current_idx = idx
  viewer.show_file(browser.files[idx].path, browser.files[idx].repo)
  browser.highlight_current()
  local state = layout.state
  if state.browser_win and vim.api.nvim_win_is_valid(state.browser_win) then
    vim.api.nvim_win_set_cursor(state.browser_win, { browser.line_for_idx(idx), 0 })
  end
end

function M.mark_file_viewed()
  local idx = browser.current_idx
  local entry = browser.files[idx]
  if not entry then return end
  local hunks = git.get_hunks(entry.path, entry.repo)
  if not browser.viewed_hunks[idx] then
    browser.viewed_hunks[idx] = {}
  end
  for _, hunk in ipairs(hunks) do
    browser.viewed_hunks[idx][hunk.start] = true
  end
  browser.viewed[idx] = true
  browser.update_file_line(idx)
  browser.highlight_current()
end

function M.mark_and_next()
  local idx = browser.current_idx
  local entry = browser.files[idx]
  if not entry then return end
  local hunks = git.get_hunks(entry.path, entry.repo)
  if not browser.viewed_hunks[idx] then
    browser.viewed_hunks[idx] = {}
  end
  for _, hunk in ipairs(hunks) do
    browser.viewed_hunks[idx][hunk.start] = true
  end
  browser.viewed[idx] = true
  browser.update_file_line(idx)
  M.next_file()
end

function M.advance()
  local state = layout.state
  if not state.viewer_buf or not vim.api.nvim_buf_is_valid(state.viewer_buf) then
    return
  end
  local idx = browser.current_idx
  local entry = browser.files[idx]
  if not entry then return end
  local hunks = git.get_hunks(entry.path, entry.repo)
  if #hunks == 0 then
    M.mark_and_next()
    return
  end

  local cursor = vim.api.nvim_win_get_cursor(state.viewer_win)[1]
  -- Check if there's a next hunk ahead
  for _, hunk in ipairs(hunks) do
    if hunk.start > cursor then
      viewer.next_hunk()
      return
    end
  end

  -- We're at or past the last hunk — mark and move to next file
  M.mark_and_next()
end

function M.mark_all_viewed()
  for i, entry in ipairs(browser.files) do
    local hunks = git.get_hunks(entry.path, entry.repo)
    if not browser.viewed_hunks[i] then
      browser.viewed_hunks[i] = {}
    end
    for _, hunk in ipairs(hunks) do
      browser.viewed_hunks[i][hunk.start] = true
    end
    browser.viewed[i] = true
    browser.update_file_line(i)
  end
  browser.highlight_current()
end

function M.close()
  if augroup then
    vim.api.nvim_del_augroup_by_id(augroup)
    augroup = nil
  end
  layout.close()
end

return M
