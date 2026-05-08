local util = require("code_review.util")
local M = {}

M.state = {
  mode = nil,
  tab = nil,
  target_win = nil,
  viewer_win = nil,
  viewer_buf = nil,
  browser_win = nil,
  browser_buf = nil,
}

function M.open()
  vim.cmd("tabnew")
  M.state.mode = "tab"
  M.state.tab = vim.api.nvim_get_current_tabpage()

  -- Top pane: viewer
  M.state.viewer_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(M.state.viewer_buf)
  M.state.viewer_win = vim.api.nvim_get_current_win()
  util.setup_scratch_buf(M.state.viewer_buf, true)
  vim.b[M.state.viewer_buf].lsp_disabled = true

  -- Bottom pane: browser
  local config = require("code_review.config")
  vim.cmd("botright " .. config.current.browser_height .. "split")
  M.state.browser_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(M.state.browser_buf)
  M.state.browser_win = vim.api.nvim_get_current_win()
  util.setup_scratch_buf(M.state.browser_buf)

  return M.state
end

function M.open_browse()
  M.state.mode = "browse"
  M.state.target_win = vim.api.nvim_get_current_win()

  local config = require("code_review.config")
  vim.cmd("botright " .. config.current.browser_height .. "split")
  M.state.browser_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(M.state.browser_buf)
  M.state.browser_win = vim.api.nvim_get_current_win()
  util.setup_scratch_buf(M.state.browser_buf)

  return M.state
end

function M.close()
  if M.state.mode == "tab" then
    if M.state.tab and vim.api.nvim_tabpage_is_valid(M.state.tab) then
      local tabnr = vim.api.nvim_tabpage_get_number(M.state.tab)
      vim.cmd("tabclose " .. tabnr)
    end
  elseif M.state.mode == "browse" then
    if M.state.browser_win and vim.api.nvim_win_is_valid(M.state.browser_win) then
      vim.api.nvim_win_close(M.state.browser_win, true)
    end
  end
  M.state = { mode = nil, tab = nil, target_win = nil, viewer_win = nil, viewer_buf = nil, browser_win = nil, browser_buf = nil }
end

function M.get_target_win()
  if M.state.target_win and vim.api.nvim_win_is_valid(M.state.target_win) then
    return M.state.target_win
  end
  local log = require("code_review.log")
  local browse = require("code_review.browse")
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if win ~= M.state.browser_win
      and (not log.is_open() or win ~= log._win)
      and win ~= browse._diff_win then
      M.state.target_win = win
      return win
    end
  end
  return nil
end

return M
