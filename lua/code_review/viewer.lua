local git = require("code_review.git")
local layout = require("code_review.layout")
local util = require("code_review.util")
local config = require("code_review.config")

local M = {}

M._current_file = nil
M._current_repo = nil
M._diff_win = nil
M._diff_buf = nil
M._diff_active = false

local ns = vim.api.nvim_create_namespace("code_review_signs")

function M.show_file(filepath, repo_path)
  M._current_file = filepath
  M._current_repo = repo_path
  local state = layout.state
  if not state.viewer_buf or not vim.api.nvim_buf_is_valid(state.viewer_buf) then
    return
  end
  if not state.viewer_win or not vim.api.nvim_win_is_valid(state.viewer_win) then
    return
  end

  -- Ensure our buffer is displayed in the viewer window
  if vim.api.nvim_win_get_buf(state.viewer_win) ~= state.viewer_buf then
    vim.api.nvim_win_set_buf(state.viewer_win, state.viewer_buf)
  end

  -- Read file contents with safe handle management
  local abs_path = repo_path .. "/" .. filepath
  local lines = {}

  if git._head_override then
    -- Single commit mode: show file at the commit, not working tree
    local cmd = "git -C " .. vim.fn.shellescape(repo_path)
      .. " show " .. vim.fn.shellescape(git._head_override) .. ":" .. vim.fn.shellescape(filepath)
    lines = vim.fn.systemlist(cmd)
    if vim.v.shell_error ~= 0 then
      lines = { "-- Unable to read file at " .. git._head_override .. ": " .. filepath }
    end
  else
    local f = io.open(abs_path, "r")
    if f then
      local ok, err = pcall(function()
        for line in f:lines() do
          table.insert(lines, line)
        end
      end)
      f:close()
      if not ok then
        lines = { "-- Error reading file: " .. (err or filepath) }
      end
    else
      lines = { "-- Unable to read file: " .. filepath }
    end
  end

  -- Set buffer contents
  vim.bo[state.viewer_buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.viewer_buf, 0, -1, false, lines)
  vim.bo[state.viewer_buf].modifiable = false

  -- Set filetype for syntax highlighting
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

  -- Set buffer name and winbar
  pcall(vim.api.nvim_buf_set_name, state.viewer_buf, "")
  local ok = pcall(vim.api.nvim_buf_set_name, state.viewer_buf, "[review] " .. filepath)
  if not ok then
    -- Name conflict, winbar is the fallback
  end
  vim.wo[state.viewer_win].winbar = " " .. filepath

  -- Place diff signs
  vim.api.nvim_buf_clear_namespace(state.viewer_buf, ns, 0, -1)
  local hunks = git.get_hunks(filepath, repo_path)
  local line_count = #lines
  local cfg = config.current
  for _, hunk in ipairs(hunks) do
    if hunk.type == "delete" then
      local lnum = math.min(math.max(0, hunk.start - 1), math.max(0, line_count - 1))
      vim.api.nvim_buf_set_extmark(state.viewer_buf, ns, lnum, 0, {
        sign_text = cfg.signs.delete,
        sign_hl_group = "CodeReviewDelete",
        line_hl_group = "CodeReviewDeleteLine",
      })
    else
      for i = 0, hunk.count - 1 do
        local lnum = hunk.start - 1 + i
        if lnum < line_count then
          vim.api.nvim_buf_set_extmark(state.viewer_buf, ns, lnum, 0, {
            sign_text = cfg.signs.change,
            sign_hl_group = "CodeReviewChange",
            line_hl_group = "CodeReviewChangeLine",
          })
        end
      end
    end
  end

  -- Go to first hunk (with bounds check)
  if #hunks > 0 then
    local target = math.max(1, math.min(hunks[1].start, line_count))
    vim.api.nvim_win_set_cursor(state.viewer_win, { target, 0 })
    vim.api.nvim_win_call(state.viewer_win, function() vim.cmd("normal! zz") end)
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
  local line_count = vim.api.nvim_buf_line_count(state.viewer_buf)
  local browser = require("code_review.browser")
  for _, hunk in ipairs(hunks) do
    if hunk.start > cursor then
      local target = math.max(1, math.min(hunk.start, line_count))
      vim.api.nvim_win_set_cursor(state.viewer_win, { target, 0 })
      vim.api.nvim_win_call(state.viewer_win, function() vim.cmd("normal! zz") end)
      browser.mark_hunk_viewed(browser.current_idx, hunk.start)
      return
    end
  end
  -- Wrap to first hunk
  local target = math.max(1, math.min(hunks[1].start, line_count))
  vim.api.nvim_win_set_cursor(state.viewer_win, { target, 0 })
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
  local line_count = vim.api.nvim_buf_line_count(state.viewer_buf)
  local browser = require("code_review.browser")
  for i = #hunks, 1, -1 do
    if hunks[i].start < cursor then
      local target = math.max(1, math.min(hunks[i].start, line_count))
      vim.api.nvim_win_set_cursor(state.viewer_win, { target, 0 })
      vim.api.nvim_win_call(state.viewer_win, function() vim.cmd("normal! zz") end)
      browser.mark_hunk_viewed(browser.current_idx, hunks[i].start)
      return
    end
  end
  -- Wrap to last hunk
  local target = math.max(1, math.min(hunks[#hunks].start, line_count))
  vim.api.nvim_win_set_cursor(state.viewer_win, { target, 0 })
  vim.api.nvim_win_call(state.viewer_win, function() vim.cmd("normal! zz") end)
  browser.mark_hunk_viewed(browser.current_idx, hunks[#hunks].start)
end

function M.toggle_diff()
  local state = layout.state
  if not state.viewer_win or not vim.api.nvim_win_is_valid(state.viewer_win) then
    return
  end

  -- Close if already open
  if M._diff_win and vim.api.nvim_win_is_valid(M._diff_win) then
    vim.api.nvim_win_close(M._diff_win, true)
    M._diff_win = nil
    M._diff_buf = nil
    M._diff_active = false
    vim.api.nvim_win_call(state.viewer_win, function() vim.cmd("diffoff") end)
    vim.wo[state.viewer_win].winhl = ""
    return
  end

  M._diff_active = true
  M._open_diff()
end

function M._open_diff()
  local state = layout.state
  if not state.viewer_win or not vim.api.nvim_win_is_valid(state.viewer_win) then
    return
  end
  if not M._current_file or not M._current_repo then return end

  -- Get base version of the file
  local ref = git._base_ref or "HEAD"
  local cmd = "git -C " .. vim.fn.shellescape(M._current_repo)
    .. " show " .. vim.fn.shellescape(ref) .. ":" .. vim.fn.shellescape(M._current_file)
  local lines = vim.fn.systemlist(cmd)
  if vim.v.shell_error ~= 0 then
    lines = { "-- (new file, no previous version)" }
  end

  -- Create diff buffer and split to the right
  vim.api.nvim_set_current_win(state.viewer_win)
  vim.cmd("rightbelow vsplit")
  M._diff_buf = vim.api.nvim_create_buf(false, true)
  M._diff_win = vim.api.nvim_get_current_win()
  vim.api.nvim_set_current_buf(M._diff_buf)

  util.setup_scratch_buf(M._diff_buf)
  vim.api.nvim_buf_set_lines(M._diff_buf, 0, -1, false, lines)
  vim.bo[M._diff_buf].modifiable = false

  local ft = vim.filetype.match({ filename = M._current_file, buf = M._diff_buf })
  if ft and ft ~= "" then
    vim.bo[M._diff_buf].filetype = ft
  end

  vim.wo[M._diff_win].winbar = " " .. ref .. ": " .. M._current_file

  -- Enable diff mode on both windows
  vim.api.nvim_win_call(M._diff_win, function() vim.cmd("diffthis") end)
  vim.api.nvim_win_call(state.viewer_win, function() vim.cmd("diffthis") end)

  -- Show full file (disable diff folding)
  vim.wo[M._diff_win].foldenable = false
  vim.wo[state.viewer_win].foldenable = false

  -- Map diff highlights to our custom ones on the viewer
  vim.wo[state.viewer_win].winhl =
    "DiffAdd:CodeReviewChangeLine,DiffChange:CodeReviewChangeLine,DiffDelete:CodeReviewDeleteLine,DiffText:CodeReviewChangeLine"

  -- Return focus to viewer
  vim.api.nvim_set_current_win(state.viewer_win)
end

M._editing = false

function M.edit()
  local state = layout.state
  if not state.viewer_win or not vim.api.nvim_win_is_valid(state.viewer_win) then
    return
  end
  if not M._current_file or not M._current_repo then return end

  M.close_diff()

  -- Get cursor position to restore
  local cursor = vim.api.nvim_win_get_cursor(state.viewer_win)

  -- Open the real file in the viewer window
  local abs_path = M._current_repo .. "/" .. M._current_file
  vim.api.nvim_set_current_win(state.viewer_win)
  vim.cmd("edit " .. vim.fn.fnameescape(abs_path))

  -- Restore cursor position
  pcall(vim.api.nvim_win_set_cursor, state.viewer_win, cursor)
  M._editing = true

  -- Add nav keymaps on the real file buffer to return to review
  local edit_buf = vim.api.nvim_win_get_buf(state.viewer_win)
  require("code_review.util").set_nav_keymaps(edit_buf)
  vim.notify("Editing — gv to return to review", vim.log.levels.INFO)
end

function M.unedit()
  local state = layout.state
  if not state.viewer_win or not vim.api.nvim_win_is_valid(state.viewer_win) then
    return
  end
  if not M._editing then return end
  M._editing = false

  -- Restore review buffer and re-render
  vim.api.nvim_win_set_buf(state.viewer_win, state.viewer_buf)
  if M._current_file and M._current_repo then
    M.show_file(M._current_file, M._current_repo)
  end
end

function M.close_diff()
  if M._diff_win and vim.api.nvim_win_is_valid(M._diff_win) then
    vim.api.nvim_win_close(M._diff_win, true)
    M._diff_win = nil
    M._diff_buf = nil
    local state = layout.state
    if state.viewer_win and vim.api.nvim_win_is_valid(state.viewer_win) then
      vim.api.nvim_win_call(state.viewer_win, function() vim.cmd("diffoff") end)
      vim.wo[state.viewer_win].winhl = ""
    end
  end
end

function M.refresh_diff()
  if not M._diff_active then return end
  M.close_diff()
  M._open_diff()
end

function M.reset()
  M._current_file = nil
  M._current_repo = nil
  M._diff_active = false
  M._editing = false
end

return M
