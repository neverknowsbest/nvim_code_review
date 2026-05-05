local util = require("code_review.util")
local M = {}

M.state = {
  tab = nil,
  viewer_win = nil,
  viewer_buf = nil,
  browser_win = nil,
  browser_buf = nil,
}

function M.open()
  vim.cmd("tabnew")
  M.state.tab = vim.api.nvim_get_current_tabpage()

  -- Top pane: viewer
  M.state.viewer_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(M.state.viewer_buf)
  M.state.viewer_win = vim.api.nvim_get_current_win()
  util.setup_scratch_buf(M.state.viewer_buf, true)  -- keep alive for edit mode
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

function M.close()
  if M.state.tab and vim.api.nvim_tabpage_is_valid(M.state.tab) then
    local tabnr = vim.api.nvim_tabpage_get_number(M.state.tab)
    vim.cmd("tabclose " .. tabnr)
  end
  M.state = { tab = nil, viewer_win = nil, viewer_buf = nil, browser_win = nil, browser_buf = nil }
end

return M
