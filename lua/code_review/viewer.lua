local git = require("code_review.git")
local layout = require("code_review.layout")

local M = {}

M._current_file = nil
M._current_repo = nil

local ns = vim.api.nvim_create_namespace("code_review_signs")

function M.show_file(filepath, repo_path)
  M._current_file = filepath
  M._current_repo = repo_path
  local state = layout.state
  if not state.viewer_buf or not vim.api.nvim_buf_is_valid(state.viewer_buf) then
    return
  end

  -- Read file contents
  local abs_path = repo_path .. "/" .. filepath
  local lines = {}
  local f = io.open(abs_path, "r")
  if f then
    for line in f:lines() do
      table.insert(lines, line)
    end
    f:close()
  else
    lines = { "-- Unable to read file: " .. filepath }
  end

  -- Set buffer contents
  vim.bo[state.viewer_buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.viewer_buf, 0, -1, false, lines)
  vim.bo[state.viewer_buf].modifiable = false

  -- Set filetype for syntax highlighting (without triggering LSP/other plugins)
  local ft = vim.filetype.match({ filename = filepath, buf = state.viewer_buf })
  if ft and ft ~= "" then
    vim.bo[state.viewer_buf].filetype = ft
  end

  -- Detach any LSP clients that auto-attached
  vim.schedule(function()
    if vim.api.nvim_buf_is_valid(state.viewer_buf) then
      for _, client in ipairs(vim.lsp.get_clients({ bufnr = state.viewer_buf })) do
        vim.lsp.buf_detach_client(state.viewer_buf, client.id)
      end
    end
  end)

  -- Set buffer name for window title
  local name = "[review] " .. filepath
  pcall(vim.api.nvim_buf_set_name, state.viewer_buf, "")
  pcall(vim.api.nvim_buf_set_name, state.viewer_buf, name)
  vim.wo[state.viewer_win].winbar = " " .. filepath

  -- Place diff signs
  vim.api.nvim_buf_clear_namespace(state.viewer_buf, ns, 0, -1)
  local hunks = git.get_hunks(filepath, repo_path)
  for _, hunk in ipairs(hunks) do
    if hunk.type == "delete" then
      local lnum = math.max(0, hunk.start - 1)
      vim.api.nvim_buf_set_extmark(state.viewer_buf, ns, lnum, 0, {
        sign_text = "▁",
        sign_hl_group = "CodeReviewDelete",
        line_hl_group = "CodeReviewDeleteLine",
      })
    else
      for i = 0, hunk.count - 1 do
        local lnum = hunk.start - 1 + i
        if lnum < #lines then
          vim.api.nvim_buf_set_extmark(state.viewer_buf, ns, lnum, 0, {
            sign_text = "│",
            sign_hl_group = "CodeReviewChange",
            line_hl_group = "CodeReviewChangeLine",
          })
        end
      end
    end
  end

  -- Focus viewer and go to first hunk
  vim.api.nvim_set_current_win(state.viewer_win)
  if #hunks > 0 then
    vim.api.nvim_win_set_cursor(state.viewer_win, { hunks[1].start, 0 })
    vim.cmd("normal! zz")
    local browser = require("code_review.browser")
    browser.mark_hunk_viewed(browser.current_idx, hunks[1].start)
  else
    vim.api.nvim_win_set_cursor(state.viewer_win, { 1, 0 })
  end
end

function M.next_hunk()
  local state = layout.state
  if not state.viewer_buf or not vim.api.nvim_buf_is_valid(state.viewer_buf) then
    return
  end
  local hunks = git.get_hunks(M._current_file or "", M._current_repo or "")
  if #hunks == 0 then return end
  local cursor = vim.api.nvim_win_get_cursor(state.viewer_win)[1]
  local browser = require("code_review.browser")
  for _, hunk in ipairs(hunks) do
    if hunk.start > cursor then
      vim.api.nvim_win_set_cursor(state.viewer_win, { hunk.start, 0 })
      vim.api.nvim_win_call(state.viewer_win, function() vim.cmd("normal! zz") end)
      browser.mark_hunk_viewed(browser.current_idx, hunk.start)
      return
    end
  end
  -- Wrap to first hunk
  vim.api.nvim_win_set_cursor(state.viewer_win, { hunks[1].start, 0 })
  vim.api.nvim_win_call(state.viewer_win, function() vim.cmd("normal! zz") end)
  browser.mark_hunk_viewed(browser.current_idx, hunks[1].start)
end

function M.prev_hunk()
  local state = layout.state
  if not state.viewer_buf or not vim.api.nvim_buf_is_valid(state.viewer_buf) then
    return
  end
  local hunks = git.get_hunks(M._current_file or "", M._current_repo or "")
  if #hunks == 0 then return end
  local cursor = vim.api.nvim_win_get_cursor(state.viewer_win)[1]
  local browser = require("code_review.browser")
  for i = #hunks, 1, -1 do
    if hunks[i].start < cursor then
      vim.api.nvim_win_set_cursor(state.viewer_win, { hunks[i].start, 0 })
      vim.api.nvim_win_call(state.viewer_win, function() vim.cmd("normal! zz") end)
      browser.mark_hunk_viewed(browser.current_idx, hunks[i].start)
      return
    end
  end
  -- Wrap to last hunk
  vim.api.nvim_win_set_cursor(state.viewer_win, { hunks[#hunks].start, 0 })
  vim.api.nvim_win_call(state.viewer_win, function() vim.cmd("normal! zz") end)
  browser.mark_hunk_viewed(browser.current_idx, hunks[#hunks].start)
end

return M
