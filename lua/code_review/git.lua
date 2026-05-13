-- Git data layer for nvim_code_review
local M = {}

-- New data layer
M._repo_data = {}   -- repo_path -> RepoData
M._repo_list = nil  -- cached find_repos result
M._repo_refs = {}   -- repo_path -> { base, head }
M._base_ref = nil
M._head_override = nil
M._watchers = {}

-- ==========================================================================
-- Parsing helpers (private)
-- ==========================================================================

local function parse_numstat(lines)
  local stats = {}
  for _, line in ipairs(lines) do
    local a, r, f = line:match("^(%d+)%s+(%d+)%s+(.+)$")
    if a then
      stats[f] = { added = tonumber(a), removed = tonumber(r) }
    end
  end
  return stats
end

local function parse_hunks(lines)
  local hunks = {}
  for _, line in ipairs(lines) do
    local start, count = line:match("^@@ %-%d+,?%d* %+(%d+),?(%d*) @@")
    if start then
      start = tonumber(start)
      count = tonumber(count) or 1
      if count == 0 then
        table.insert(hunks, { start = start, count = 0, type = "delete" })
      else
        table.insert(hunks, { start = start, count = count, type = "change" })
      end
    end
  end
  return hunks
end

local function parse_name_status(lines)
  local files = {}
  local deleted = {}
  for _, line in ipairs(lines) do
    local status, path = line:match("^(%S)\t(.+)$")
    if status and path then
      table.insert(files, path)
      if status == "D" then deleted[path] = true end
    end
  end
  return files, deleted
end

local function lines_to_set(lines)
  local set = {}
  if not lines then return set end
  for _, f in ipairs(lines) do
    if f ~= "" then set[f] = true end
  end
  return set
end

-- ==========================================================================
-- Ref management
-- ==========================================================================

function M.set_base(ref)
  if ref then
    local repos = M.find_repos()
    local repo_path = repos[1] and repos[1].path or vim.fn.getcwd()
    vim.fn.systemlist("git -C " .. vim.fn.shellescape(repo_path) .. " rev-parse --verify " .. vim.fn.shellescape(ref))
    if vim.v.shell_error ~= 0 then
      vim.notify("Invalid git ref: " .. ref, vim.log.levels.ERROR)
      return false
    end
  end
  M._base_ref = ref
  return true
end

function M.set_repo_ref(repo_path, ref, head_override)
  if ref == nil and head_override == nil then
    M._repo_refs[repo_path] = nil
  else
    M._repo_refs[repo_path] = { base = ref, head = head_override }
  end
end

function M.get_ref_for_repo(repo_path)
  local rr = M._repo_refs[repo_path]
  if rr then return rr.base, rr.head end
  return M._base_ref, M._head_override
end

local function get_diff_range(repo_path)
  local base_ref, head_override = M.get_ref_for_repo(repo_path)
  if base_ref then
    return head_override and (base_ref .. ".." .. head_override) or base_ref, true
  end
  return "HEAD", false
end

-- ==========================================================================
-- Repo discovery
-- ==========================================================================

function M.find_repos()
  if M._repo_list then return M._repo_list end
  local cwd = vim.fn.getcwd()
  if vim.fn.isdirectory(cwd .. "/.git") == 1 then
    M._repo_list = { { path = cwd, name = vim.fn.fnamemodify(cwd, ":t") } }
    return M._repo_list
  end
  local repos = {}
  local entries = vim.fn.readdir(cwd)
  for _, entry in ipairs(entries) do
    local full = cwd .. "/" .. entry
    if vim.fn.isdirectory(full .. "/.git") == 1 then
      table.insert(repos, { path = full, name = entry })
    end
  end
  table.sort(repos, function(a, b) return a.name < b.name end)
  M._repo_list = repos
  return M._repo_list
end

-- ==========================================================================
-- Utilities
-- ==========================================================================

function M.count_file_lines(filepath)
  local count = 0
  local fh = io.open(filepath, "r")
  if fh then
    local ok, _ = pcall(function()
      for _ in fh:lines() do count = count + 1 end
    end)
    fh:close()
    if not ok then return 0 end
  end
  return count
end

-- ==========================================================================
-- Core: load_repo (async)
-- ==========================================================================

local function build_commands(rp, opts)
  local cmds = {}
  local diff_range = opts.diff_range or get_diff_range(rp)
  local has_base = diff_range ~= "HEAD"

  -- File list (always)
  table.insert(cmds, { cmd = { "git", "-C", rp, "diff", "--no-renames", "--name-status", diff_range }, kind = "name_status" })

  -- Stats (optional)
  if not opts.skip_stats then
    table.insert(cmds, { cmd = { "git", "-C", rp, "diff", "--no-renames", "--numstat", diff_range }, kind = "numstat" })
  end

  -- Status detection commands
  if has_base then
    local base_part = diff_range:match("(.-)%.%.") or diff_range
    table.insert(cmds, { cmd = { "git", "-C", rp, "diff", "--no-renames", "--name-status", base_part .. "..HEAD" }, kind = "committed_status" })
    table.insert(cmds, { cmd = { "git", "-C", rp, "diff", "--name-only", "HEAD" }, kind = "uncommitted" })
  else
    table.insert(cmds, { cmd = { "git", "-C", rp, "diff", "--cached", "--name-only" }, kind = "staged" })
    table.insert(cmds, { cmd = { "git", "-C", rp, "diff", "--name-only" }, kind = "unstaged" })
  end

  -- Untracked (optional)
  if opts.include_untracked then
    table.insert(cmds, { cmd = { "git", "-C", rp, "ls-files", "--others", "--exclude-standard" }, kind = "untracked" })
  end

  return cmds, has_base, diff_range
end

local function collect_raw_results(cmd_results)
  local raw = {}
  for _, r in ipairs(cmd_results) do
    raw[r.kind] = r.code == 0 and r.lines or {}
  end
  return raw
end

local function determine_status_ref(f, deleted_set, committed_set, uncommitted_set, head_override)
  if deleted_set[f] then return "UD" end
  if head_override then return "C" end
  if committed_set[f] and uncommitted_set[f] then return "CU" end
  if committed_set[f] then return "C" end
  return "U"
end

local function determine_status_noref(f, deleted_set, staged_set, unstaged_set)
  if deleted_set[f] then return "UD" end
  if staged_set[f] and unstaged_set[f] then return "SU" end
  if staged_set[f] then return "S" end
  return "U"
end

local function make_file_entry(stats_map, f)
  local s = stats_map[f]
  return {
    status = nil,
    added = s and s.added or nil,
    removed = s and s.removed or nil,
    hunks = nil,
    commits = nil,
  }
end

local function build_tracked_files(file_list_raw, deleted_set, stats_map, raw, rp, has_base)
  local file_list = {}
  local files = {}

  if has_base then
    local committed_set = lines_to_set(raw.committed_status and parse_name_status(raw.committed_status))
    local uncommitted_set = lines_to_set(raw.uncommitted)
    local _, head_override = M.get_ref_for_repo(rp)
    for _, f in ipairs(file_list_raw) do
      if not files[f] then
        local entry = make_file_entry(stats_map, f)
        entry.status = determine_status_ref(f, deleted_set, committed_set, uncommitted_set, head_override)
        files[f] = entry
        table.insert(file_list, f)
      end
    end
  else
    local staged_set = lines_to_set(raw.staged)
    local unstaged_set = lines_to_set(raw.unstaged)
    for _, f in ipairs(file_list_raw) do
      if not files[f] then
        local entry = make_file_entry(stats_map, f)
        entry.status = determine_status_noref(f, deleted_set, staged_set, unstaged_set)
        files[f] = entry
        table.insert(file_list, f)
      end
    end
  end

  return file_list, files
end

local function add_untracked_files(raw, rp, file_list, files)
  if not raw.untracked then return end
  for _, f in ipairs(raw.untracked) do
    if f ~= "" and not files[f] then
      local line_count = M.count_file_lines(rp .. "/" .. f)
      files[f] = {
        status = "N",
        added = line_count,
        removed = 0,
        hunks = line_count > 0 and { { start = 1, count = line_count, type = "change" } } or {},
        commits = nil,
      }
      table.insert(file_list, f)
    end
  end
end

local function build_repo_from_results(rp, opts, cmd_results, has_base, diff_range)
  local raw = collect_raw_results(cmd_results)
  local file_list_raw, deleted_set = parse_name_status(raw.name_status or {})
  local stats_map = parse_numstat(raw.numstat or {})

  local file_list, files = build_tracked_files(file_list_raw, deleted_set, stats_map, raw, rp, has_base)
  add_untracked_files(raw, rp, file_list, files)
  table.sort(file_list)

  return {
    file_list = file_list,
    files = files,
    commits = {},
    commit_order = {},
    opts = { diff_range = diff_range, include_untracked = opts.include_untracked or false },
    loaded = {
      files = true,
      stats = not opts.skip_stats,
      hunks = {},
      commits = false,
      commit_files = {},
    },
  }
end

function M.load_repo(rp, opts, callback)
  opts = opts or {}
  local cmds, has_base, diff_range = build_commands(rp, opts)

  local pending = #cmds
  local cmd_results = {}

  for i, c in ipairs(cmds) do
    vim.system(c.cmd, {}, function(out)
      cmd_results[i] = {
        kind = c.kind,
        lines = vim.split(out.stdout or "", "\n", { trimempty = true }),
        code = out.code,
      }
      pending = pending - 1
      if pending == 0 then
        vim.schedule(function()
          M._repo_data[rp] = build_repo_from_results(rp, opts, cmd_results, has_base, diff_range)
          if callback then callback(M._repo_data[rp]) end
        end)
      end
    end)
  end
end

-- ==========================================================================
-- Core: load_all (progressive multi-repo)
-- ==========================================================================

function M.load_all(repo_list, opts, on_each, on_done)
  local i = 0
  local function next_repo()
    i = i + 1
    if i > #repo_list then
      if on_done then on_done() end
      return
    end
    local rp = repo_list[i].path
    M.load_repo(rp, opts, function(repo_data)
      if on_each then on_each(rp, repo_data) end
      vim.defer_fn(next_repo, 5)
    end)
  end
  next_repo()
end

-- ==========================================================================
-- Core: reload functions (overwrite in place, async)
-- ==========================================================================

function M.reload_repo(rp, opts, callback)
  M.load_repo(rp, opts, callback)
end

function M.reload_stats(rp, callback)
  local repo = M._repo_data[rp]
  if not repo then if callback then callback() end return end
  local cmd = { "git", "-C", rp, "diff", "--no-renames", "--numstat", repo.opts.diff_range }
  vim.system(cmd, {}, function(out)
    vim.schedule(function()
      local fresh = parse_numstat(vim.split(out.stdout or "", "\n", { trimempty = true }))
      for path, f in pairs(repo.files) do
        local s = fresh[path]
        if s then
          f.added = s.added
          f.removed = s.removed
        end
      end
      repo.loaded.stats = true
      if callback then callback() end
    end)
  end)
end

function M.reload_hunks(rp, path, callback)
  local repo = M._repo_data[rp]
  if not repo or not repo.files[path] then if callback then callback() end return end
  local cmd = { "git", "-C", rp, "diff", "--no-renames", "-U0", repo.opts.diff_range, "--", path }
  vim.system(cmd, {}, function(out)
    vim.schedule(function()
      repo.files[path].hunks = parse_hunks(vim.split(out.stdout or "", "\n", { trimempty = true }))
      repo.loaded.hunks[path] = true
      if callback then callback() end
    end)
  end)
end

function M.reload_file_list(rp, callback)
  local repo = M._repo_data[rp]
  if not repo then if callback then callback({}) end return end
  local cmd = { "git", "-C", rp, "diff", "--no-renames", "--name-status", repo.opts.diff_range }
  vim.system(cmd, {}, function(out)
    vim.schedule(function()
      local new_files, _ = parse_name_status(vim.split(out.stdout or "", "\n", { trimempty = true }))
      if callback then callback(new_files) end
    end)
  end)
end

-- ==========================================================================
-- Accessors (lazy, sync fallback for immediate UI need)
-- ==========================================================================

function M.get_repo_data(rp)
  return M._repo_data[rp]
end

function M.get_file(rp, path)
  local repo = M._repo_data[rp]
  return repo and repo.files[path]
end

function M.get_stats(rp, path)
  local repo = M._repo_data[rp]
  if not repo then return 0, 0 end
  local f = repo.files[path]
  if not f then return 0, 0 end
  if f.added == nil and not repo.loaded.stats then
    -- Sync fallback: batch fetch for whole repo
    local output = vim.fn.systemlist({ "git", "-C", rp, "diff", "--no-renames", "--numstat", repo.opts.diff_range })
    local fresh = parse_numstat(output)
    for p, file in pairs(repo.files) do
      local s = fresh[p]
      if s then
        file.added = s.added
        file.removed = s.removed
      else
        file.added = 0
        file.removed = 0
      end
    end
    repo.loaded.stats = true
  end
  return f.added or 0, f.removed or 0
end

function M.get_hunks(filepath, rp)
  local repo = M._repo_data[rp]
  if not repo then return {} end
  local f = repo.files[filepath]
  if not f then return {} end
  if f.hunks == nil then
    -- Sync fetch for one file (viewer needs it immediately)
    local output = vim.fn.systemlist({ "git", "-C", rp, "diff", "--no-renames", "-U0", repo.opts.diff_range, "--", filepath })
    f.hunks = (vim.v.shell_error == 0) and parse_hunks(output) or {}
    repo.loaded.hunks[filepath] = true
  end
  return f.hunks
end

function M.get_all_stats(rp)
  local repo = M._repo_data[rp]
  if not repo then return end
  if repo.loaded.stats then return end
  local output = vim.fn.systemlist({ "git", "-C", rp, "diff", "--no-renames", "--numstat", repo.opts.diff_range })
  local fresh = parse_numstat(output)
  for path, f in pairs(repo.files) do
    local s = fresh[path]
    if s then
      f.added = s.added
      f.removed = s.removed
    else
      f.added = 0
      f.removed = 0
    end
  end
  repo.loaded.stats = true
end

-- ==========================================================================
-- Commit accessors
-- ==========================================================================

function M.get_commits(rp)
  local repo = M._repo_data[rp]
  if not repo then return {} end
  if not repo.loaded.commits then
    local output = vim.fn.systemlist({ "git", "-C", rp, "log", "--format=%H|%an|%ad|%s", "--date=short", repo.opts.diff_range })
    repo.commit_order = {}
    repo.commits = {}
    for _, line in ipairs(output) do
      local hash, author, date, subject = line:match("^([^|]+)|([^|]*)|([^|]*)|(.+)$")
      if hash then
        table.insert(repo.commit_order, hash)
        repo.commits[hash] = { hash = hash, subject = subject, author = author, date = date, files = nil }
      end
    end
    repo.loaded.commits = true
  end
  return repo.commit_order
end

function M.get_commit(rp, hash)
  local repo = M._repo_data[rp]
  return repo and repo.commits[hash]
end

function M.get_commit_files(rp, hash)
  local repo = M._repo_data[rp]
  if not repo or not repo.commits[hash] then return {} end
  local commit = repo.commits[hash]
  if commit.files == nil then
    if hash == "__working_tree__" then return commit.files or {} end
    local output = vim.fn.systemlist({ "git", "-C", rp, "diff", "--no-renames", "--numstat", hash .. "~1.." .. hash })
    commit.files = {}
    for _, line in ipairs(output) do
      local a, r, f = line:match("^(%d+)%s+(%d+)%s+(.+)$")
      if a then
        commit.files[f] = { added = tonumber(a), removed = tonumber(r), hunks = nil }
      end
    end
    repo.loaded.commit_files[hash] = true
  end
  return commit.files
end

function M.get_file_commits(rp, path)
  local repo = M._repo_data[rp]
  if not repo then return {} end
  local f = repo.files[path]
  return f and f.commits or {}
end

-- ==========================================================================
-- File watchers
-- ==========================================================================

local _watch_timers = {}

function M.watch_repo(rp, on_change)
  -- Watch .git/index (commit, stage, reset)
  local idx_path = rp .. "/.git/index"
  if vim.uv.fs_stat(idx_path) then
    local w = vim.uv.new_fs_event()
    w:start(idx_path, {}, function()
      if _watch_timers[rp] then return end
      _watch_timers[rp] = true
      vim.schedule(function()
        vim.defer_fn(function()
          _watch_timers[rp] = nil
          on_change(rp)
        end, 500)
      end)
    end)
    M._watchers[rp .. ":index"] = w
  end
end

function M.unwatch_all()
  for _, w in pairs(M._watchers) do
    pcall(function() w:stop(); w:close() end)
  end
  M._watchers = {}
  _watch_timers = {}
end

-- ==========================================================================
-- State management
-- ==========================================================================

function M.reset()
  M._repo_data = {}
  M._repo_list = nil
  M._base_ref = nil
  M._head_override = nil
  M._repo_refs = {}
  M.unwatch_all()
end

-- ==========================================================================
-- Legacy compat (to be removed after migration)
-- ==========================================================================

M._cache = {}

function M.clear_cache()
  M._cache = {}
  M._repo_list = nil
  M._repo_data = {}
end

function M.get_file_stats(filepath, repo_path)
  local f = M.get_file(repo_path, filepath)
  if f and f.added ~= nil then return f.added, f.removed end
  -- Fallback to old cache during migration
  local key = repo_path .. ":" .. filepath .. ":stats"
  if M._cache[key] then return M._cache[key].added, M._cache[key].removed end
  return M.get_stats(repo_path, filepath)
end

function M.load_all_repos(repos, skip_numstat)
  -- Sync compat wrapper — builds jobs, runs them, returns flat file list
  local all_files = {}
  for _, repo in ipairs(repos) do
    local rp = repo.path
    local opts = { skip_stats = skip_numstat, include_untracked = require("code_review.config").current.show_untracked }
    local cmds, has_base, diff_range = build_commands(rp, opts)

    -- Run sync
    local cmd_results = {}
    for i, c in ipairs(cmds) do
      local out = vim.system(c.cmd):wait()
      cmd_results[i] = {
        kind = c.kind,
        lines = vim.split(out.stdout or "", "\n", { trimempty = true }),
        code = out.code,
      }
    end

    M._repo_data[rp] = build_repo_from_results(rp, opts, cmd_results, has_base, diff_range)
    local repo_data = M._repo_data[rp]
    for _, f in ipairs(repo_data.file_list) do
      table.insert(all_files, { path = f, status = repo_data.files[f].status, repo = rp })
    end
  end
  return all_files
end

return M
