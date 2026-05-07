local M = {}

local function opts(buf)
  return { buffer = buf, nowait = true, silent = true }
end

function M.setup_viewer(buf)
  local o = opts(buf)
  local keys = require("code_review.config").current.keys
  local cr = require("code_review")
  local viewer = require("code_review.viewer")
  local log = require("code_review.log")
  local state = require("code_review.state")

  vim.keymap.set("n", keys.next_hunk, function() viewer.next_hunk() end, o)
  vim.keymap.set("n", keys.prev_hunk, function() viewer.prev_hunk() end, o)
  vim.keymap.set("n", keys.next_file, function() cr.next_file() end, o)
  vim.keymap.set("n", keys.prev_file, function() cr.prev_file() end, o)
  vim.keymap.set("n", keys.toggle_diff, function() viewer.toggle_diff() end, o)
  vim.keymap.set("n", keys.mark_file, function() cr.mark_file_viewed() end, o)
  vim.keymap.set("n", keys.mark_all, function() cr.mark_all_viewed() end, o)
  vim.keymap.set("n", keys.mark_and_next, function() cr.mark_and_next() end, o)
  vim.keymap.set("n", keys.prev_file_alt, function() cr.prev_file() end, o)
  vim.keymap.set("n", keys.advance, function() cr.advance() end, o)
  vim.keymap.set("n", keys.reverse_advance, function() cr.reverse_advance() end, o)
  vim.keymap.set("n", keys.toggle_log, function() log.toggle() end, o)
  vim.keymap.set("n", keys.refresh, function() cr.refresh() end, o)
  vim.keymap.set("n", keys.edit, function()
    if state.data.editing then viewer.unedit() else viewer.edit() end
  end, o)
  vim.keymap.set("n", "g?", function() require("code_review.help").toggle() end, o)
  vim.keymap.set("n", keys.quit, function() cr.close() end, o)
  M.setup_nav(buf)
end

function M.setup_browser(buf)
  local o = opts(buf)
  local keys = require("code_review.config").current.keys
  local cr = require("code_review")
  local log = require("code_review.log")
  local browser = require("code_review.browser")

  vim.keymap.set("n", keys.reverse_advance, function() cr.reverse_advance() end, o)
  vim.keymap.set("n", keys.next_file, function() cr.next_file() end, o)
  vim.keymap.set("n", keys.prev_file, function() cr.prev_file() end, o)
  vim.keymap.set("n", keys.mark_and_next, function() cr.mark_and_next() end, o)
  vim.keymap.set("n", keys.prev_file_alt, function() cr.prev_file() end, o)
  vim.keymap.set("n", keys.mark_file, function() cr.mark_file_viewed() end, o)
  vim.keymap.set("n", keys.mark_all, function() cr.mark_all_viewed() end, o)
  vim.keymap.set("n", keys.toggle_log, function() log.toggle() end, o)
  vim.keymap.set("n", keys.refresh, function() cr.refresh() end, o)
  vim.keymap.set("n", "g?", function() require("code_review.help").toggle() end, o)
  vim.keymap.set("n", keys.quit, function() cr.close() end, o)
  -- <CR> last so it overrides advance if same key
  vim.keymap.set("n", "<CR>", function() browser.select() end, o)
  M.setup_nav(buf)
end

function M.setup_log(buf)
  local o = opts(buf)
  local log = require("code_review.log")

  vim.keymap.set("n", "<CR>", function() log.select() end, o)
  vim.keymap.set("n", "s", function() log.toggle_mode() end, o)
  vim.keymap.set("n", "<Tab>", function() log.cycle_repo() end, o)
  vim.keymap.set("n", "<S-Tab>", function() log.cycle_repo_back() end, o)
  vim.keymap.set("n", "q", function() require("code_review").close() end, o)
  M.setup_nav(buf)
end

function M.setup_nav(buf)
  local o = opts(buf)
  local layout = require("code_review.layout")
  local log = require("code_review.log")
  local state = require("code_review.state")

  vim.keymap.set("n", "gv", function()
    local viewer = require("code_review.viewer")
    if state.data.editing then viewer.unedit() end
    local s = layout.state
    if s.viewer_win and vim.api.nvim_win_is_valid(s.viewer_win) then
      vim.api.nvim_set_current_win(s.viewer_win)
    end
  end, o)
  vim.keymap.set("n", "gf", function()
    local s = layout.state
    if s.browser_win and vim.api.nvim_win_is_valid(s.browser_win) then
      vim.api.nvim_set_current_win(s.browser_win)
    end
  end, o)
  vim.keymap.set("n", "gl", function()
    if log.is_open() then vim.api.nvim_set_current_win(log._win) else log.toggle() end
  end, o)
end

return M
