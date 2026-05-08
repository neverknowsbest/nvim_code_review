local git = require("code_review.git")
local layout = require("code_review.layout")
local util = require("code_review.util")
local config = require("code_review.config")
local state = require("code_review.state")

local M = {}

local ns = vim.api.nvim_create_namespace("code_review_signs")

-- File reading

local function read_file_from_git(repo_path, ref, filepath)
  local cmd = "git -C " .. vim.fn.shellescape(repo_path)
    .. " show " .. vim.fn.shellescape(ref) .. ":" .. vim.fn.shellescape(filepath)
  local lines = vim.fn.systemlist(cmd)
  if vim.v.shell_error ~= 0 then
    return { "-- Unable to read file at " .. ref .. ": " .. filepath }
  end
  return lines
end

local function read_file_from_disk(repo_path, filepath)
  local abs_path = repo_path .. "/" .. filepath
  local lines = {}
  local f = io.open(abs_path, "r")
  if f then
    local ok, err = pcall(function()
      for line in f:lines() do
        table.insert(lines, line)
      end
    end)
    f:close()
    if not ok then
      return { "-- Error reading file: " .. (err or filepath) }
    end
  else
    return { "-- Deleted file: " .. filepath }
  end
  return lines
end

local function read_file(repo_path, filepath)
  local _, head_override = git.get_ref_for_repo(repo_path)
  if head_override then
    return read_file_from_git(repo_path, head_override, filepath)
  end
  return read_file_from_disk(repo_path, filepath)
end

-- Buffer setup

local function set_buffer_content(buf, lines)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
end

local function set_filetype(buf, filepath)
  local ft = vim.filetype.match({ filename = filepath, buf = buf })
  if ft and ft ~= "" then
    vim.bo[buf].filetype = ft
  end
end

local function detach_lsp(buf)
  vim.schedule(function()
    if vim.api.nvim_buf_is_valid(buf) then
      for _, client in ipairs(vim.lsp.get_clients({ bufnr = buf })) do
        vim.lsp.buf_detach_client(buf, client.id)
      end
    end
  end)
end

local function set_buffer_name(buf, win, filepath)
  pcall(vim.api.nvim_buf_set_name, buf, "")
  pcall(vim.api.nvim_buf_set_name, buf, "[review] " .. filepath)
  vim.wo[win].winbar = " " .. filepath
end

-- Diff signs

local function place_signs(buf, hunks, line_count)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  util.place_signs(buf, ns, hunks, line_count)
end

-- Cursor positioning

local function jump_to_first_unviewed_hunk(win, hunks, line_count)
  local browser = require("code_review.browser")
  local idx = state.get("current_idx")
  local viewed_set = state.get("viewed_hunks")[idx] or {}
  local target_hunk = hunks[1]
  for _, hunk in ipairs(hunks) do
    if not viewed_set[hunk.start] then
      target_hunk = hunk
      break
    end
  end
  local target = math.max(1, math.min(target_hunk.start, line_count))
  vim.api.nvim_win_set_cursor(win, { target, 0 })
  vim.api.nvim_win_call(win, function() vim.cmd("normal! zz") end)
  browser.mark_hunk_viewed(idx, target_hunk.start)
end

-- Main show_file

local function load_file_into_viewer(filepath, repo_path)
  local s = layout.state
  if not s.viewer_buf or not vim.api.nvim_buf_is_valid(s.viewer_buf) then return nil end
  if not s.viewer_win or not vim.api.nvim_win_is_valid(s.viewer_win) then return nil end

  local lines = read_file(repo_path, filepath)
  set_buffer_content(s.viewer_buf, lines)
  set_filetype(s.viewer_buf, filepath)
  detach_lsp(s.viewer_buf)

  local hunks = git.get_hunks(filepath, repo_path)
  place_signs(s.viewer_buf, hunks, #lines)
  return hunks, #lines
end

function M.show_file(filepath, repo_path)
  state.data.current_file = filepath
  state.data.current_repo = repo_path
  local s = layout.state
  if not s.viewer_win or not vim.api.nvim_win_is_valid(s.viewer_win) then return end

  if vim.api.nvim_win_get_buf(s.viewer_win) ~= s.viewer_buf then
    vim.api.nvim_win_set_buf(s.viewer_win, s.viewer_buf)
  end

  local hunks, line_count = load_file_into_viewer(filepath, repo_path)
  if not hunks then return end
  set_buffer_name(s.viewer_buf, s.viewer_win, filepath)

  if #hunks > 0 then
    jump_to_first_unviewed_hunk(s.viewer_win, hunks, line_count)
  else
    vim.api.nvim_win_set_cursor(s.viewer_win, { 1, 0 })
  end
end

function M.refresh_file()
  local filepath = state.data.current_file
  local repo_path = state.data.current_repo
  if not filepath or not repo_path then return end

  local s = layout.state
  if not s.viewer_win or not vim.api.nvim_win_is_valid(s.viewer_win) then return end
  local cursor = vim.api.nvim_win_get_cursor(s.viewer_win)

  local _, line_count = load_file_into_viewer(filepath, repo_path)
  if not line_count then return end

  local safe_cursor = { math.min(cursor[1], line_count), cursor[2] }
  pcall(vim.api.nvim_win_set_cursor, s.viewer_win, safe_cursor)
end

-- Hunk navigation

function M.next_hunk()
  local s = layout.state
  if not s.viewer_buf or not vim.api.nvim_buf_is_valid(s.viewer_buf) then return end
  local file = state.data.current_file
  local repo = state.data.current_repo
  if not file or not repo then return end
  local hunks = git.get_hunks(file, repo)
  local cr = require("code_review")
  if #hunks == 0 then
    cr.mark_and_next()
    return
  end
  local cursor = vim.api.nvim_win_get_cursor(s.viewer_win)[1]
  local line_count = vim.api.nvim_buf_line_count(s.viewer_buf)
  local browser = require("code_review.browser")
  local idx = state.get("current_idx")
  for _, hunk in ipairs(hunks) do
    if hunk.start > cursor then
      local target = math.max(1, math.min(hunk.start, line_count))
      vim.api.nvim_win_set_cursor(s.viewer_win, { target, 0 })
      vim.api.nvim_win_call(s.viewer_win, function() vim.cmd("normal! zz") end)
      browser.mark_hunk_viewed(idx, hunk.start)
      return
    end
  end
  cr.mark_and_next()
end

function M.prev_hunk()
  local s = layout.state
  if not s.viewer_buf or not vim.api.nvim_buf_is_valid(s.viewer_buf) then return end
  local file = state.data.current_file
  local repo = state.data.current_repo
  if not file or not repo then return end
  local hunks = git.get_hunks(file, repo)
  local cr = require("code_review")
  if #hunks == 0 then
    cr.prev_file()
    return
  end
  local cursor = vim.api.nvim_win_get_cursor(s.viewer_win)[1]
  local line_count = vim.api.nvim_buf_line_count(s.viewer_buf)
  local browser = require("code_review.browser")
  local idx = state.get("current_idx")
  for i = #hunks, 1, -1 do
    if hunks[i].start < cursor then
      local target = math.max(1, math.min(hunks[i].start, line_count))
      vim.api.nvim_win_set_cursor(s.viewer_win, { target, 0 })
      vim.api.nvim_win_call(s.viewer_win, function() vim.cmd("normal! zz") end)
      browser.mark_hunk_viewed(idx, hunks[i].start)
      return
    end
  end
  -- At or before first hunk — go to previous file's last hunk
  cr.prev_file()
  s = layout.state
  if not s.viewer_win or not vim.api.nvim_win_is_valid(s.viewer_win) then return end
  local new_file = state.data.current_file
  local new_repo = state.data.current_repo
  if new_file and new_repo then
    local new_hunks = git.get_hunks(new_file, new_repo)
    if #new_hunks > 0 then
      local new_line_count = vim.api.nvim_buf_line_count(s.viewer_buf)
      local target = math.max(1, math.min(new_hunks[#new_hunks].start, new_line_count))
      vim.api.nvim_win_set_cursor(s.viewer_win, { target, 0 })
      vim.api.nvim_win_call(s.viewer_win, function() vim.cmd("normal! zz") end)
    end
  end
end

-- Diff toggle

M._diff_win = nil
M._diff_buf = nil

function M.toggle_diff()
  local s = layout.state
  if not s.viewer_win or not vim.api.nvim_win_is_valid(s.viewer_win) then return end
  if state.data.diff_active then
    M.close_diff()
    state.data.diff_active = false
  else
    M._open_diff()
    if M._diff_win and vim.api.nvim_win_is_valid(M._diff_win) then
      state.data.diff_active = true
    end
  end
end

function M._open_diff()
  local s = layout.state
  if not s.viewer_win or not vim.api.nvim_win_is_valid(s.viewer_win) then return end
  local file = state.data.current_file
  local repo = state.data.current_repo
  if not file or not repo then return end

  local base_ref, _ = git.get_ref_for_repo(repo)
  local ref = base_ref or "HEAD"
  local lines = read_file_from_git(repo, ref, file)

  vim.api.nvim_set_current_win(s.viewer_win)
  vim.cmd("rightbelow vsplit")
  M._diff_buf = vim.api.nvim_create_buf(false, true)
  M._diff_win = vim.api.nvim_get_current_win()
  vim.api.nvim_set_current_buf(M._diff_buf)

  util.setup_scratch_buf(M._diff_buf)
  vim.api.nvim_buf_set_lines(M._diff_buf, 0, -1, false, lines)
  vim.bo[M._diff_buf].modifiable = false

  set_filetype(M._diff_buf, file)
  vim.wo[M._diff_win].winbar = " " .. ref .. ": " .. file

  vim.api.nvim_win_call(M._diff_win, function() vim.cmd("diffthis") end)
  vim.api.nvim_win_call(s.viewer_win, function() vim.cmd("diffthis") end)

  vim.wo[M._diff_win].foldenable = false
  vim.wo[s.viewer_win].foldenable = false
  vim.wo[s.viewer_win].winhl =
    "DiffAdd:CodeReviewChangeLine,DiffChange:CodeReviewChangeLine,DiffDelete:CodeReviewDeleteLine,DiffText:CodeReviewChangeLine"

  vim.keymap.set("n", "<Esc>", function() M.toggle_diff() end, { buffer = M._diff_buf, nowait = true, silent = true })
  vim.api.nvim_set_current_win(s.viewer_win)
end

function M.close_diff()
  if M._diff_win and vim.api.nvim_win_is_valid(M._diff_win) then
    vim.api.nvim_win_close(M._diff_win, true)
    M._diff_win = nil
    M._diff_buf = nil
    local s = layout.state
    if s.viewer_win and vim.api.nvim_win_is_valid(s.viewer_win) then
      vim.api.nvim_win_call(s.viewer_win, function() vim.cmd("diffoff") end)
      vim.wo[s.viewer_win].winhl = ""
    end
  end
end

function M.refresh_diff()
  if not state.data.diff_active then return end
  M.close_diff()
  M._open_diff()
end

function M.reset()
  state.data.current_file = nil
  state.data.current_repo = nil
  state.data.diff_active = false
end

return M
