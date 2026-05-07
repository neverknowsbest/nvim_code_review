local git = require("code_review.git")
local layout = require("code_review.layout")
local browser = require("code_review.browser")
local viewer = require("code_review.viewer")
local config = require("code_review.config")
local log = require("code_review.log")
local session = require("code_review.session")
local state = require("code_review.state")

local M = {}
local augroup = nil
local _stats_gen = 0
local _refreshing = false

function M.setup(opts)
  config.apply(opts)

  local function hl_attr(name, attr)
    local hl = vim.api.nvim_get_hl(0, { name = name, link = false })
    return hl[attr]
  end

  local change_fg = hl_attr("DiffAdd", "fg") or hl_attr("String", "fg") or 0x859900
  local delete_fg = hl_attr("DiffDelete", "fg") or hl_attr("Error", "fg") or 0xdc322f
  local change_bg = hl_attr("Visual", "bg") or hl_attr("DiffChange", "bg") or 0xeef6d6
  local delete_bg = hl_attr("DiffDelete", "bg") or hl_attr("Visual", "bg") or 0xf6d6d6

  vim.api.nvim_set_hl(0, "CodeReviewChange", { fg = change_fg, default = true })
  vim.api.nvim_set_hl(0, "CodeReviewDelete", { fg = delete_fg, default = true })
  vim.api.nvim_set_hl(0, "CodeReviewChangeLine", { bg = change_bg, default = true })
  vim.api.nvim_set_hl(0, "CodeReviewDeleteLine", { bg = delete_bg, default = true })

  -- Winbar highlights
  local bar_bg = hl_attr("WinBar", "bg") or hl_attr("StatusLine", "bg") or hl_attr("Normal", "bg")
  vim.api.nvim_set_hl(0, "CodeReviewBar", { bg = bar_bg, default = true })
  vim.api.nvim_set_hl(0, "CodeReviewBarBold", { bg = bar_bg, bold = true, default = true })
  vim.api.nvim_set_hl(0, "CodeReviewBarAdd", { fg = change_fg, bg = bar_bg, bold = true, default = true })
  vim.api.nvim_set_hl(0, "CodeReviewBarDel", { fg = delete_fg, bg = bar_bg, bold = true, default = true })

  vim.api.nvim_create_user_command("CodeReview", function(cmd_opts)
    M.open(cmd_opts.args ~= "" and cmd_opts.args or nil)
  end, { nargs = "?" })
  vim.api.nvim_create_user_command("CodeReviewClose", function() M.close() end, {})
  vim.api.nvim_create_user_command("CodeReviewReload", function()
    for name, _ in pairs(package.loaded) do
      if name:match("^code_review") then
        package.loaded[name] = nil
      end
    end
    require("code_review").setup(config.current)
    vim.notify("CodeReview reloaded", vim.log.levels.INFO)
  end, {})

  -- Save session on nvim exit
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("CodeReviewSave", { clear = true }),
    callback = function()
      local s = require("code_review.state")
      local files = s.get("files")
      if files and #files > 0 then
        require("code_review.session").save()
      end
    end,
  })
end

function M._setup_keymaps()
  require("code_review.keymaps").setup_viewer(layout.state.viewer_buf)
end

local function validate_and_load(base_ref)
  if base_ref then
    if not git.set_base(base_ref) then return nil, nil end
  else
    git.set_base(nil)
  end
  git.clear_cache()

  local repos = git.find_repos()
  if #repos == 0 then
    vim.notify("No git repositories found", vim.log.levels.WARN)
    return nil, nil
  end

  -- Skip numstat for fast initial load; stats loaded in background
  local all_files = git.load_all_repos(repos)
  if #all_files == 0 and not config.current.log.show_on_open then
    vim.notify("No uncommitted changes found", vim.log.levels.INFO)
    return nil, nil
  end

  return repos, all_files
end

local function compute_stats(all_files)
  local stats = {}
  for i, entry in ipairs(all_files) do
    local added, removed = git.get_file_stats(entry.path, entry.repo)
    stats[i] = { added = added, removed = removed, chunks = nil }
  end
  return stats
end

local function populate_state(repos, all_files, stats)
  state.batch(function()
    state.set("repos", repos)
    state.set("stats", stats)
    state.set("files", all_files)
  end)
end

local function restore_and_render()
  session.restore()
  browser.render()
  local files = state.get("files")
  local s = layout.state
  if s.browser_win and vim.api.nvim_win_is_valid(s.browser_win) then
    vim.api.nvim_win_call(s.browser_win, function() vim.cmd("normal! gg") end)
    local line = browser.line_for_idx(state.get("current_idx"))
    pcall(vim.api.nvim_win_set_cursor, s.browser_win, { line, 0 })
  end
  local entry = files[state.get("current_idx")]
  if entry then
    viewer.show_file(entry.path, entry.repo)
  end
end

local function setup_auto_refresh()
  augroup = vim.api.nvim_create_augroup("CodeReviewAutoRefresh", { clear = true })
  if config.current.auto_refresh then
    vim.api.nvim_create_autocmd("FocusGained", {
      group = augroup,
      callback = function()
        if layout.state.tab
          and vim.api.nvim_tabpage_is_valid(layout.state.tab)
          and vim.api.nvim_get_current_tabpage() == layout.state.tab then
          if not _refreshing then M.refresh() end
        end
      end,
    })
  end
  vim.api.nvim_create_autocmd("DirChanged", {
    group = augroup,
    callback = function()
      if not layout.state.tab or not vim.api.nvim_tabpage_is_valid(layout.state.tab) then return end
      vim.schedule(function()
        vim.ui.input({ prompt = "Working directory changed. Reload code review? (Y/n): " }, function(input)
          if not input or input:lower() == "n" then return end
          git._repo_list = nil
          git._repo_data = {}
          M.refresh()
          vim.cmd("echo ''")
        end)
      end)
    end,
  })
end

function M.open(base_ref)
  if layout.state.tab and vim.api.nvim_tabpage_is_valid(layout.state.tab) then
    vim.notify("A code review session is already open. Close it first with :CodeReviewClose", vim.log.levels.WARN)
    return
  end

  local repos, all_files = validate_and_load(base_ref)
  if not repos then return end

  layout.open()
  M._setup_keymaps()

  populate_state(repos, all_files, compute_stats(all_files))

  if config.current.log.show_on_open then
    log.open_panel()
  end

  restore_and_render()
  vim.api.nvim_set_current_win(layout.state.viewer_win)
  setup_auto_refresh()
end

local function refresh_log()
  log.clear_cache()
  if log.is_open() then log.refresh() end
end

local function refresh_browser_and_viewer(all_files, prev_idx)
  if #all_files > 0 then
    local idx = math.min(prev_idx, #all_files)
    state.data.current_idx = idx
    browser.render()
    local s = layout.state
    if s.browser_win and vim.api.nvim_win_is_valid(s.browser_win) then
      pcall(vim.api.nvim_win_set_cursor, s.browser_win, { browser.line_for_idx(idx), 0 })
    end
    local entry = all_files[idx]
    if entry and s.viewer_win and vim.api.nvim_win_is_valid(s.viewer_win) then
      -- Only refresh diff signs, don't reload file or change viewed state
      viewer.refresh_diff()
    end
  else
    browser.render()
    local s = layout.state
    if s.viewer_buf and vim.api.nvim_buf_is_valid(s.viewer_buf) then
      vim.bo[s.viewer_buf].modifiable = true
      vim.api.nvim_buf_set_lines(s.viewer_buf, 0, -1, false, { "  No changes to review" })
      vim.bo[s.viewer_buf].modifiable = false
    end
  end
end

local _soft_refresh_timer = nil
function M.soft_refresh()
  -- Only auto-refresh from index watcher (commit/stage/reset)
  -- FocusGained and BufWritePost are too noisy for full refresh
end

function M.refresh()
  if _refreshing then return end
  _refreshing = true
  _stats_gen = _stats_gen + 1
  git._repo_list = nil
  refresh_log()
  local repos = git.find_repos()
  local prev_idx = state.get("current_idx")
  local old_files = state.get("files")
  local old_stats = state.get("stats")
  local old_viewed = state.get("viewed")
  local old_viewed_hunks = state.get("viewed_hunks")

  local opts = { include_untracked = config.current.show_untracked }
  git.load_all(repos, opts, nil, function()
    -- All repos loaded — build flat file list from repo data
    local all_files = {}
    for _, repo in ipairs(repos) do
      local rd = git.get_repo_data(repo.path)
      if rd then
        for _, f in ipairs(rd.file_list) do
          table.insert(all_files, { path = f, status = rd.files[f].status, repo = repo.path })
        end
      end
    end

    local new_stats = compute_stats(all_files)

    -- Remap viewed/viewed_hunks, clearing if stats changed
    if #old_files > 0 then
      local old_index = {}
      for i, f in ipairs(old_files) do
        old_index[f.repo .. ":" .. f.path] = i
      end
      local new_viewed = {}
      local new_viewed_hunks = {}
      for i, entry in ipairs(all_files) do
        local old_i = old_index[entry.repo .. ":" .. entry.path]
        if old_i then
          local os = old_stats[old_i]
          local ns = new_stats[i]
          local changed = not os or os.added ~= ns.added or os.removed ~= ns.removed
          if not changed then
            if old_viewed[old_i] then new_viewed[i] = true end
            if old_viewed_hunks[old_i] then new_viewed_hunks[i] = old_viewed_hunks[old_i] end
            if os and os.chunks then ns.chunks = os.chunks end
          end
        end
      end
      state.data.viewed = new_viewed
      state.data.viewed_hunks = new_viewed_hunks
    end

    populate_state(repos, all_files, new_stats)
    refresh_browser_and_viewer(all_files, prev_idx)
    _refreshing = false
  end)
end

local function mark_file(idx)
  local files = state.get("files")
  local entry = files[idx]
  if not entry then return end
  local hunks = git.get_hunks(entry.path, entry.repo)
  local viewed_hunks = state.get("viewed_hunks")
  if not viewed_hunks[idx] then
    viewed_hunks[idx] = {}
  end
  for _, hunk in ipairs(hunks) do
    viewed_hunks[idx][hunk.start] = true
  end
  local viewed = state.get("viewed")
  viewed[idx] = true
  browser.update_file_line(idx)
end

local function file_exists(entry)
  local _, head_override = git.get_ref_for_repo(entry.repo)
  if head_override then
    local cmd = "git -C " .. vim.fn.shellescape(entry.repo)
      .. " cat-file -e " .. vim.fn.shellescape(head_override .. ":" .. entry.path)
    vim.fn.system(cmd)
    return vim.v.shell_error == 0
  end
  local path = entry.repo .. "/" .. entry.path
  return vim.fn.filereadable(path) == 1
end

local _syncing = false

local function sync_log_to_repo(repo_path)
  if _syncing or not log.is_open() then return end
  local repos = git.find_repos()
  if #repos <= 1 then return end
  for i, repo in ipairs(repos) do
    if repo.path == repo_path and log._repo_idx ~= i then
      _syncing = true
      log._repo_idx = i
      vim.schedule(function()
        log.render_cached()
        _syncing = false
      end)
      break
    end
  end
end

local function ensure_file_visible(entry)
  local collapsed = state.get("collapsed_repos")
  if collapsed[entry.repo] then
    collapsed[entry.repo] = nil
    browser.render()
  end
end

local function goto_file(idx)
  local files = state.get("files")
  viewer.close_diff()
  state.data.current_idx = idx
  local entry = files[idx]
  if entry then
    ensure_file_visible(entry)
    viewer.show_file(entry.path, entry.repo)
    -- Sync log to this file's repo
    if state.data.active_repo ~= entry.repo then
      state.data.active_repo = entry.repo
      sync_log_to_repo(entry.repo)
    end
  end
  viewer.refresh_diff()
  browser.schedule_highlight()
  local s = layout.state
  if s.browser_win and vim.api.nvim_win_is_valid(s.browser_win) then
    local line = browser.line_for_idx(idx)
    pcall(vim.api.nvim_win_set_cursor, s.browser_win, { line, 0 })
    vim.api.nvim_win_call(s.browser_win, function() vim.cmd("normal! zz") end)
  end
end

function M._goto_file(idx)
  goto_file(idx)
end

function M.next_file()
  local files = state.get("files")
  if #files == 0 then return end
  local start = math.min(state.get("current_idx"), #files)
  local collapsed = state.get("collapsed_repos")
  local idx = start
  repeat
    idx = idx + 1
    if idx > #files then idx = 1 end
    local visible = not collapsed[files[idx].repo]
    if visible and file_exists(files[idx]) then
      goto_file(idx)
      return
    end
  until idx == start
  -- No visible file found — apply wrap_navigation
  local action = config.current.wrap_navigation
  if action == "stop" then return end
  if action == "expand" then
    -- Expand next collapsed repo
    idx = start
    repeat
      idx = idx + 1
      if idx > #files then idx = 1 end
      if collapsed[files[idx].repo] then
        collapsed[files[idx].repo] = nil
        state.data.collapsed_repos = collapsed
        browser.render()
        goto_file(idx)
        return
      end
    until idx == start
  else -- "loop"
    -- Wrap: find first visible file from the beginning
    for j = 1, #files do
      if not collapsed[files[j].repo] then
        goto_file(j)
        return
      end
    end
  end
end

function M.prev_file()
  local files = state.get("files")
  if #files == 0 then return end
  local start = math.min(state.get("current_idx"), #files)
  local collapsed = state.get("collapsed_repos")
  local idx = start
  repeat
    idx = idx - 1
    if idx < 1 then idx = #files end
    local visible = not collapsed[files[idx].repo]
    if visible and file_exists(files[idx]) then
      goto_file(idx)
      return
    end
  until idx == start
  local action = config.current.wrap_navigation
  if action == "stop" then return end
  if action == "expand" then
    idx = start
    repeat
      idx = idx - 1
      if idx < 1 then idx = #files end
      if collapsed[files[idx].repo] then
        collapsed[files[idx].repo] = nil
        state.data.collapsed_repos = collapsed
        browser.render()
        goto_file(idx)
        return
      end
    until idx == start
  else -- "loop"
    for j = #files, 1, -1 do
      if not collapsed[files[j].repo] then
        goto_file(j)
        return
      end
    end
  end
end

function M.mark_file_viewed()
  local idx = state.get("current_idx")
  local viewed = state.get("viewed")
  if viewed[idx] then
    -- Unmark
    viewed[idx] = nil
    local viewed_hunks = state.get("viewed_hunks")
    viewed_hunks[idx] = nil
    browser.update_file_line(idx)
  else
    mark_file(idx)
  end
end

function M.mark_all_viewed()
  local files = state.get("files")
  local viewed = state.get("viewed")
  -- Toggle: if all viewed, unmark all; otherwise mark all
  local all_viewed = true
  for i, _ in ipairs(files) do
    if not viewed[i] then all_viewed = false; break end
  end
  if all_viewed then
    state.data.viewed = {}
    state.data.viewed_hunks = {}
    for i, _ in ipairs(files) do
      browser.update_file_line(i)
    end
  else
    for i, _ in ipairs(files) do
      mark_file(i)
    end
  end
end

function M.mark_and_next()
  mark_file(state.get("current_idx"))
  M.next_file()
end

function M.advance()
  local s = layout.state
  if not s.viewer_buf or not vim.api.nvim_buf_is_valid(s.viewer_buf) then
    return
  end
  local files = state.get("files")
  local idx = state.get("current_idx")
  local entry = files[idx]
  if not entry then return end
  local hunks = git.get_hunks(entry.path, entry.repo)
  if #hunks == 0 then
    M.mark_and_next()
    return
  end

  local cursor = vim.api.nvim_win_get_cursor(s.viewer_win)[1]
  for _, hunk in ipairs(hunks) do
    if hunk.start > cursor then
      viewer.next_hunk()
      return
    end
  end

  M.mark_and_next()
end

function M.reverse_advance()
  local s = layout.state
  if not s.viewer_buf or not vim.api.nvim_buf_is_valid(s.viewer_buf) then
    return
  end
  local files = state.get("files")
  local idx = state.get("current_idx")
  local entry = files[idx]
  if not entry then return end
  local hunks = git.get_hunks(entry.path, entry.repo)
  if #hunks == 0 then
    M.prev_file()
    return
  end

  local cursor = vim.api.nvim_win_get_cursor(s.viewer_win)[1]
  for i = #hunks, 1, -1 do
    if hunks[i].start < cursor then
      viewer.prev_hunk()
      return
    end
  end

  -- At or before first hunk — go to last hunk of previous file
  M.prev_file()
  local new_entry = files[state.get("current_idx")]
  if new_entry then
    local new_hunks = git.get_hunks(new_entry.path, new_entry.repo)
    if #new_hunks > 0 then
      local line_count = vim.api.nvim_buf_line_count(s.viewer_buf)
      local target = math.max(1, math.min(new_hunks[#new_hunks].start, line_count))
      vim.api.nvim_win_set_cursor(s.viewer_win, { target, 0 })
      vim.api.nvim_win_call(s.viewer_win, function() vim.cmd("normal! zz") end)
    end
  end
end

function M.close()
  session.save()
  if augroup then
    vim.api.nvim_del_augroup_by_id(augroup)
    augroup = nil
  end
  log.close()
  log.reset()
  viewer.close_diff()
  viewer.reset()
  git.reset()
  state.reset()
  layout.close()
  browser._keymaps_set = false
end

return M
