local M = {}

local function opts(buf) return { buffer = buf, nowait = true, silent = true } end

local function setup_shared(buf)
  local o = opts(buf)
  local keys = require("code_review.config").current.keys
  local cr = require("code_review")
  local log = require("code_review.log")

  vim.keymap.set("n", keys.next_file, function() cr.next_file() end, o)
  vim.keymap.set("n", keys.prev_file, function() cr.prev_file() end, o)
  vim.keymap.set("n", keys.prev_file_alt, function() cr.prev_file() end, o)
  vim.keymap.set("n", keys.mark_file, function() cr.mark_file_viewed() end, o)
  vim.keymap.set("n", keys.mark_all, function() cr.mark_all_viewed() end, o)
  vim.keymap.set("n", keys.mark_and_next, function() cr.mark_and_next() end, o)
  vim.keymap.set("n", keys.reverse_advance, function() cr.reverse_advance() end, o)
  vim.keymap.set("n", keys.toggle_diff, function() cr.toggle_diff() end, o)
  vim.keymap.set("n", keys.switch_mode, function() cr.switch_mode() end, o)
  vim.keymap.set("n", keys.toggle_log, function() log.toggle() end, o)
  vim.keymap.set("n", keys.refresh, function() cr.refresh() end, o)
  vim.keymap.set("n", "g?", function() require("code_review.help").toggle() end, o)
  vim.keymap.set("n", keys.quit, function() cr.close() end, o)
  M.setup_nav(buf)
end

function M.setup_viewer(buf)
  setup_shared(buf)
  local o = opts(buf)
  local keys = require("code_review.config").current.keys
  local cr = require("code_review")
  local viewer = require("code_review.viewer")

  vim.keymap.set("n", keys.next_hunk, function() viewer.next_hunk() end, o)
  vim.keymap.set("n", keys.prev_hunk, function() viewer.prev_hunk() end, o)
  vim.keymap.set("n", keys.advance, function() cr.advance() end, o)
end

function M.setup_browser(buf)
  setup_shared(buf)
  local o = opts(buf)
  local browser = require("code_review.browser")
  vim.keymap.set("n", "<CR>", function() browser.select() end, o)
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

  vim.keymap.set("n", "gv", function()
    local s = layout.state
    if s.mode == "browse" then
      local win = layout.get_target_win()
      if win then vim.api.nvim_set_current_win(win) end
    elseif s.viewer_win and vim.api.nvim_win_is_valid(s.viewer_win) then
      vim.api.nvim_set_current_win(s.viewer_win)
    end
  end, o)
  vim.keymap.set("n", "gb", function()
    local s = layout.state
    if s.browser_win and vim.api.nvim_win_is_valid(s.browser_win) then vim.api.nvim_set_current_win(s.browser_win) end
  end, o)
  vim.keymap.set("n", "gl", function()
    if log.is_open() then
      vim.api.nvim_set_current_win(log._win)
    else
      log.toggle()
    end
  end, o)
  vim.keymap.set("n", "<Esc>", function()
    local s = layout.state
    if s.mode == "browse" then
      local win = layout.get_target_win()
      if win then vim.api.nvim_set_current_win(win) end
    elseif s.viewer_win and vim.api.nvim_win_is_valid(s.viewer_win) then
      vim.api.nvim_set_current_win(s.viewer_win)
    end
  end, o)
end

function M.setup_browse_buffer(buf)
  local o = opts(buf)
  local keys = require("code_review.config").current.keys
  local cr = require("code_review")

  vim.keymap.set("n", keys.next_hunk, function() cr.next_hunk() end, o)
  vim.keymap.set("n", keys.prev_hunk, function() cr.prev_hunk() end, o)
  vim.keymap.set("n", keys.next_file, function() cr.next_file() end, o)
  vim.keymap.set("n", keys.prev_file, function() cr.prev_file() end, o)
  vim.keymap.set("n", keys.toggle_diff, function() cr.toggle_diff() end, o)
  vim.keymap.set("n", "g?", function() require("code_review.help").toggle() end, o)
  M.setup_nav(buf)
end

return M
