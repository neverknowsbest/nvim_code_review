local git = require("code_review.git")
local layout = require("code_review.layout")
local browser = require("code_review.browser")
local config = require("code_review.config")
local log = require("code_review.log")
local session = require("code_review.session")
local state = require("code_review.state")
local util = require("code_review.util")

local M = {}
local augroup = nil
local _refreshing = false

local ns = vim.api.nvim_create_namespace("code_review_browse_signs")
local _signed_bufs = {}

-- ==========================================================================
-- Sign management
-- ==========================================================================

local function place_signs_on_buf(buf, filepath, repo_path)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  local hunks = git.get_hunks(filepath, repo_path)
  local line_count = vim.api.nvim_buf_line_count(buf)
  util.place_signs(buf, ns, hunks, line_count)
  _signed_bufs[buf] = true
end

local function clear_all_signs()
  for buf, _ in pairs(_signed_bufs) do
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    end
  end
  _signed_bufs = {}
end

-- ==========================================================================
-- File matching
-- ==========================================================================

local function match_buffer_to_file(buf)
  local bufname = vim.api.nvim_buf_get_name(buf)
  if bufname == "" then return nil, nil end
  local files = state.get("files")
  for i, entry in ipairs(files) do
    local abs = entry.repo .. "/" .. entry.path
    if bufname == abs or vim.fn.resolve(bufname) == vim.fn.resolve(abs) then
      return i, entry
    end
  end
  return nil, nil
end

-- ==========================================================================
-- Keymaps on file buffers
-- ==========================================================================

local _keymap_bufs = {}

local function setup_buffer_keymaps(buf)
  if _keymap_bufs[buf] then return end
  require("code_review.keymaps").setup_browse_buffer(buf)
  _keymap_bufs[buf] = true
end

-- ==========================================================================
-- File open
-- ==========================================================================

function M.open_file(idx)
  local files = state.get("files")
  local entry = files[idx]
  if not entry then return end

  if state.data.diff_active then
    M.close_diff()
    state.data.diff_active = false
  end

  local win = layout.get_target_win()
  if not win then return end

  state.data.current_idx = idx
  state.data.current_file = entry.path
  state.data.current_repo = entry.repo

  local abs_path = entry.repo .. "/" .. entry.path
  vim.api.nvim_set_current_win(win)
  vim.cmd("edit " .. vim.fn.fnameescape(abs_path))

  local buf = vim.api.nvim_win_get_buf(win)
  place_signs_on_buf(buf, entry.path, entry.repo)
  setup_buffer_keymaps(buf)

  -- Ensure file visible in browser
  local collapsed = state.get("collapsed_repos")
  if collapsed[entry.repo] then
    collapsed[entry.repo] = nil
    browser.render()
  end

  browser.schedule_highlight()
  local s = layout.state
  if s.browser_win and vim.api.nvim_win_is_valid(s.browser_win) then
    local line = browser.line_for_idx(idx)
    pcall(vim.api.nvim_win_set_cursor, s.browser_win, { line, 0 })
  end
end

-- ==========================================================================
-- File navigation
-- ==========================================================================

local function file_exists(entry)
  local path = entry.repo .. "/" .. entry.path
  return vim.fn.filereadable(path) == 1
end

local function step_file(direction)
  local files = state.get("files")
  if #files == 0 then return end
  local start = math.min(state.get("current_idx"), #files)
  local collapsed = state.get("collapsed_repos")
  local idx = start
  repeat
    idx = idx + direction
    if idx > #files then idx = 1 end
    if idx < 1 then idx = #files end
    if not collapsed[files[idx].repo] and file_exists(files[idx]) then
      M.open_file(idx)
      return
    end
  until idx == start
end

function M.next_file() step_file(1) end
function M.prev_file() step_file(-1) end

-- ==========================================================================
-- Hunk navigation
-- ==========================================================================

function M.next_hunk()
  local win = layout.get_target_win()
  if not win or not vim.api.nvim_win_is_valid(win) then return end
  local file = state.data.current_file
  local repo = state.data.current_repo
  if not file or not repo then return end
  local hunks = git.get_hunks(file, repo)
  local cr = require("code_review")
  if #hunks == 0 then
    cr.mark_and_next()
    return
  end

  local buf = vim.api.nvim_win_get_buf(win)
  local cursor = vim.api.nvim_win_get_cursor(win)[1]
  local line_count = vim.api.nvim_buf_line_count(buf)
  local idx = state.get("current_idx")

  for _, hunk in ipairs(hunks) do
    if hunk.start > cursor then
      local target = math.max(1, math.min(hunk.start, line_count))
      vim.api.nvim_win_set_cursor(win, { target, 0 })
      vim.api.nvim_win_call(win, function() vim.cmd("normal! zz") end)
      browser.mark_hunk_viewed(idx, hunk.start)
      return
    end
  end
  cr.mark_and_next()
end

function M.prev_hunk()
  local win = layout.get_target_win()
  if not win or not vim.api.nvim_win_is_valid(win) then return end
  local file = state.data.current_file
  local repo = state.data.current_repo
  if not file or not repo then return end
  local hunks = git.get_hunks(file, repo)
  if #hunks == 0 then
    M.prev_file()
    return
  end

  local buf = vim.api.nvim_win_get_buf(win)
  local cursor = vim.api.nvim_win_get_cursor(win)[1]
  local line_count = vim.api.nvim_buf_line_count(buf)
  local idx = state.get("current_idx")

  for i = #hunks, 1, -1 do
    if hunks[i].start < cursor then
      local target = math.max(1, math.min(hunks[i].start, line_count))
      vim.api.nvim_win_set_cursor(win, { target, 0 })
      vim.api.nvim_win_call(win, function() vim.cmd("normal! zz") end)
      browser.mark_hunk_viewed(idx, hunks[i].start)
      return
    end
  end
  -- At or before first hunk — go to previous file's last hunk
  M.prev_file()
  local new_win = layout.get_target_win()
  if not new_win or not vim.api.nvim_win_is_valid(new_win) then return end
  local new_file = state.data.current_file
  local new_repo = state.data.current_repo
  if new_file and new_repo then
    local new_hunks = git.get_hunks(new_file, new_repo)
    if #new_hunks > 0 then
      local new_buf = vim.api.nvim_win_get_buf(new_win)
      local new_line_count = vim.api.nvim_buf_line_count(new_buf)
      local target = math.max(1, math.min(new_hunks[#new_hunks].start, new_line_count))
      vim.api.nvim_win_set_cursor(new_win, { target, 0 })
      vim.api.nvim_win_call(new_win, function() vim.cmd("normal! zz") end)
    end
  end
end

-- ==========================================================================
-- Mark viewed
-- ==========================================================================


-- ==========================================================================
-- Diff toggle
-- ==========================================================================

M._diff_win = nil
M._diff_buf = nil

function M.toggle_diff()
  local win = layout.get_target_win()
  if not win or not vim.api.nvim_win_is_valid(win) then return end
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
  local win = layout.get_target_win()
  if not win or not vim.api.nvim_win_is_valid(win) then return end
  local file = state.data.current_file
  local repo = state.data.current_repo
  if not file or not repo then return end

  local base_ref, _ = git.get_ref_for_repo(repo)
  local ref = base_ref or "HEAD"
  local cmd = "git -C " .. vim.fn.shellescape(repo)
    .. " show " .. vim.fn.shellescape(ref) .. ":" .. vim.fn.shellescape(file)
  local lines = vim.fn.systemlist(cmd)
  if vim.v.shell_error ~= 0 then
    lines = { "-- Unable to read file at " .. ref .. ": " .. file }
  end

  vim.api.nvim_set_current_win(win)
  vim.cmd("rightbelow vsplit")
  M._diff_buf = vim.api.nvim_create_buf(false, true)
  M._diff_win = vim.api.nvim_get_current_win()
  vim.api.nvim_set_current_buf(M._diff_buf)

  util.setup_scratch_buf(M._diff_buf)
  vim.api.nvim_buf_set_lines(M._diff_buf, 0, -1, false, lines)
  vim.bo[M._diff_buf].modifiable = false

  local ft = vim.filetype.match({ filename = file, buf = M._diff_buf })
  if ft and ft ~= "" then vim.bo[M._diff_buf].filetype = ft end
  vim.wo[M._diff_win].winbar = " " .. ref .. ": " .. file

  vim.api.nvim_win_call(M._diff_win, function() vim.cmd("diffthis") end)
  vim.api.nvim_win_call(win, function() vim.cmd("diffthis") end)

  vim.wo[M._diff_win].foldenable = false
  vim.wo[win].foldenable = false
  vim.wo[win].winhl =
    "DiffAdd:CodeReviewChangeLine,DiffChange:CodeReviewChangeLine,DiffDelete:CodeReviewDeleteLine,DiffText:CodeReviewChangeLine"

  vim.keymap.set("n", "<Esc>", function() M.toggle_diff() end, { buffer = M._diff_buf, nowait = true, silent = true })
  vim.api.nvim_set_current_win(win)
end

function M.close_diff()
  if M._diff_win and vim.api.nvim_win_is_valid(M._diff_win) then
    vim.api.nvim_win_close(M._diff_win, true)
    M._diff_win = nil
    M._diff_buf = nil
    local win = layout.get_target_win()
    if win and vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_call(win, function() vim.cmd("diffoff") end)
      vim.wo[win].winhl = ""
    end
  end
end

-- ==========================================================================
-- Refresh
-- ==========================================================================

local function refresh_signs(all_files)
  local win = layout.get_target_win()
  if not win or not vim.api.nvim_win_is_valid(win) then return end
  local buf = vim.api.nvim_win_get_buf(win)
  local file_idx, _ = match_buffer_to_file(buf)
  if file_idx then
    local entry = all_files[file_idx]
    place_signs_on_buf(buf, entry.path, entry.repo)
  end
end

local function refresh_browser_position(prev_idx, all_files)
  local idx = math.min(prev_idx, #all_files)
  state.data.current_idx = idx
  browser.render()
  local s = layout.state
  if s.browser_win and vim.api.nvim_win_is_valid(s.browser_win) then
    pcall(vim.api.nvim_win_set_cursor, s.browser_win, { browser.line_for_idx(idx), 0 })
  end
end

function M.refresh()
  if _refreshing then return end
  _refreshing = true
  git._repo_list = nil
  log.clear_cache()
  if log.is_open() then log.refresh() end

  local repos = git.find_repos()
  local prev_idx = state.get("current_idx")
  local old_files = state.get("files")
  local old_stats = state.get("stats")
  local old_viewed = state.get("viewed")
  local old_viewed_hunks = state.get("viewed_hunks")
  local cr = require("code_review")

  local opts = { include_untracked = config.current.show_untracked }
  git.load_all(repos, opts, nil, function()
    local all_files = cr.build_file_list(repos)
    local new_stats = cr.compute_stats(all_files)
    cr.remap_viewed(old_files, old_stats, old_viewed, old_viewed_hunks, all_files, new_stats)
    cr.populate_state(repos, all_files, new_stats)

    if #all_files > 0 then
      refresh_browser_position(prev_idx, all_files)
      refresh_signs(all_files)
    else
      browser.render()
    end

    _refreshing = false
  end)
end

-- ==========================================================================
-- Autocmds
-- ==========================================================================

local function setup_autocmds()
  augroup = vim.api.nvim_create_augroup("CodeReviewBrowse", { clear = true })

  if config.current.auto_refresh then
    vim.api.nvim_create_autocmd("FocusGained", {
      group = augroup,
      callback = function()
        if layout.state.mode == "browse" and not _refreshing then
          M.refresh()
        end
      end,
    })
  end

  vim.api.nvim_create_autocmd("BufWritePost", {
    group = augroup,
    callback = function(ev)
      if layout.state.mode ~= "browse" then return end
      local file_idx, entry = match_buffer_to_file(ev.buf)
      if not file_idx or not entry then return end
      -- Invalidate hunk and stats cache
      local rd = git.get_repo_data(entry.repo)
      if rd and rd.files[entry.path] then
        rd.files[entry.path].hunks = nil
        rd.files[entry.path].added = nil
        rd.files[entry.path].removed = nil
        rd.loaded.hunks[entry.path] = nil
        rd.loaded.stats = false
      end
      place_signs_on_buf(ev.buf, entry.path, entry.repo)
      -- Update browser stats for this file
      local stats = state.get("stats")
      if stats[file_idx] then
        local added, removed = git.get_file_stats(entry.path, entry.repo)
        local hunks = git.get_hunks(entry.path, entry.repo)
        stats[file_idx].added = added
        stats[file_idx].removed = removed
        stats[file_idx].chunks = #hunks
      end
      browser.update_file_line(file_idx)
    end,
  })

  vim.api.nvim_create_autocmd("BufEnter", {
    group = augroup,
    callback = function(ev)
      if layout.state.mode ~= "browse" then return end
      local win = vim.api.nvim_get_current_win()
      local s = layout.state
      if win == s.browser_win then return end
      if log.is_open() and win == log._win then return end

      setup_buffer_keymaps(ev.buf)

      if config.current.browse.signs_on_enter then
        local file_idx, entry = match_buffer_to_file(ev.buf)
        if file_idx and entry then
          state.data.current_idx = file_idx
          state.data.current_file = entry.path
          state.data.current_repo = entry.repo
          place_signs_on_buf(ev.buf, entry.path, entry.repo)
          browser.schedule_highlight()
        end
      end
    end,
  })
end

-- ==========================================================================
-- Open / Close
-- ==========================================================================

function M.open(base_ref)
  if layout.state.mode == "tab" then
    require("code_review").switch_to_browse()
    return
  elseif layout.state.mode == "browse" then
    vim.notify("Browse mode already open", vim.log.levels.INFO)
    return
  end

  local cr = require("code_review")
  local repos, all_files = cr.validate_and_load(base_ref)
  if not repos then return end

  layout.open_browse()

  cr.populate_state(repos, all_files, cr.compute_stats(all_files))

  if config.current.log.show_on_open then
    log.open_panel()
  end

  session.restore()
  browser.render()

  local s = layout.state
  if s.browser_win and vim.api.nvim_win_is_valid(s.browser_win) then
    vim.api.nvim_win_call(s.browser_win, function() vim.cmd("normal! gg") end)
    local line = browser.line_for_idx(state.get("current_idx"))
    pcall(vim.api.nvim_win_set_cursor, s.browser_win, { line, 0 })
  end

  -- Set up keymaps and signs on current buffer
  local win = layout.get_target_win()
  if win and vim.api.nvim_win_is_valid(win) then
    local buf = vim.api.nvim_win_get_buf(win)
    setup_buffer_keymaps(buf)
    local file_idx, entry = match_buffer_to_file(buf)
    if file_idx and entry then
      state.data.current_idx = file_idx
      state.data.current_file = entry.path
      state.data.current_repo = entry.repo
      place_signs_on_buf(buf, entry.path, entry.repo)
    end
  end

  setup_autocmds()
  local focus_win = layout.get_target_win() or s.browser_win
  if focus_win and vim.api.nvim_win_is_valid(focus_win) then
    vim.api.nvim_set_current_win(focus_win)
  end
end

function M.close()
  session.save()
  if augroup then
    vim.api.nvim_del_augroup_by_id(augroup)
    augroup = nil
  end
  M.close_diff()
  clear_all_signs()
  _keymap_bufs = {}
  log.close()
  log.reset()
  git.reset()
  state.reset()
  layout.close()
  browser._keymaps_set = false
end

function M.close_ui_only()
  if augroup then
    vim.api.nvim_del_augroup_by_id(augroup)
    augroup = nil
  end
  M.close_diff()
  clear_all_signs()
  _keymap_bufs = {}
  log.close()
  layout.close()
  browser._keymaps_set = false
end

function M.open_with_state(current_file, current_repo, current_idx)
  layout.open_browse()

  if config.current.log.show_on_open then
    log.open_panel()
  end

  browser.render()
  local s = layout.state
  if s.browser_win and vim.api.nvim_win_is_valid(s.browser_win) then
    vim.api.nvim_win_call(s.browser_win, function() vim.cmd("normal! gg") end)
    local line = browser.line_for_idx(current_idx)
    pcall(vim.api.nvim_win_set_cursor, s.browser_win, { line, 0 })
  end

  -- Open the current file in the target window
  local win = layout.get_target_win()
  if win and vim.api.nvim_win_is_valid(win) and current_file and current_repo then
    local abs_path = current_repo .. "/" .. current_file
    vim.api.nvim_set_current_win(win)
    vim.cmd("edit " .. vim.fn.fnameescape(abs_path))
    local buf = vim.api.nvim_win_get_buf(win)
    place_signs_on_buf(buf, current_file, current_repo)
    setup_buffer_keymaps(buf)
  elseif win then
    local buf = vim.api.nvim_win_get_buf(win)
    setup_buffer_keymaps(buf)
    vim.api.nvim_set_current_win(win)
  end

  setup_autocmds()
end

return M
