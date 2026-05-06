local M = {}

function M.format_stat(files, added, removed)
  return string.format("%-3sf  +%-4s -%-4s", files, added, removed)
end

function M.apply_stat_highlights(buf, ns, lines, start_line)
  start_line = start_line or 0
  for i, l in ipairs(lines) do
    local lnum = start_line + i - 1
    -- Search from the right to avoid matching commit message content
    local s, e = l:find("  %+%d+%s+%-%d+%s*$")
    if s then
      local ps, pe = l:find("%+%d+", s)
      if ps then
        vim.api.nvim_buf_set_extmark(buf, ns, lnum, ps - 1, { end_col = pe, hl_group = "DiffAdd" })
      end
      local ms, me = l:find("%-%d+", pe or s)
      if ms then
        vim.api.nvim_buf_set_extmark(buf, ns, lnum, ms - 1, { end_col = me, hl_group = "DiffDelete" })
      end
    end
  end
end

function M.setup_scratch_buf(buf, keep_alive)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = keep_alive and "hide" or "wipe"
  vim.bo[buf].swapfile = false
end

function M.setup_list_win(win)
  vim.wo[win].cursorline = true
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].wrap = false
end

function M.set_nav_keymaps(buf)
  local layout = require("code_review.layout")
  local log = require("code_review.log")
  local opts = { buffer = buf, nowait = true, silent = true }
  vim.keymap.set("n", "gv", function()
    local viewer = require("code_review.viewer")
    local s = require("code_review.state")
    if s.data.editing then viewer.unedit() end
    local state = layout.state
    if state.viewer_win and vim.api.nvim_win_is_valid(state.viewer_win) then
      vim.api.nvim_set_current_win(state.viewer_win)
    end
  end, opts)
  vim.keymap.set("n", "gf", function()
    local state = layout.state
    if state.browser_win and vim.api.nvim_win_is_valid(state.browser_win) then
      vim.api.nvim_set_current_win(state.browser_win)
    end
  end, opts)
  vim.keymap.set("n", "gl", function()
    if log.is_open() then vim.api.nvim_set_current_win(log._win) else log.toggle() end
  end, opts)
end

return M
