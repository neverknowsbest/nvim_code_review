local M = {}

M._cache = {}
M._base_ref = nil
M._head_override = nil
M._repos = nil
M._repo_refs = {}

-- State management

function M.clear_cache()
  M._cache = {}
  M._repos = nil
end

function M.reset()
  M._cache = {}
  M._repos = nil
  M._base_ref = nil
  M._head_override = nil
  M._repo_refs = {}
end

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

-- Utilities

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

function M.find_repos()
  if M._repos then return M._repos end
  local cwd = vim.fn.getcwd()
  if vim.fn.isdirectory(cwd .. "/.git") == 1 then
    M._repos = { { path = cwd, name = vim.fn.fnamemodify(cwd, ":t") } }
    return M._repos
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
  M._repos = repos
  return M._repos
end

-- Diff range helpers

local function get_diff_range(repo_path)
  local base_ref, head_override = M.get_ref_for_repo(repo_path)
  if base_ref then
    return head_override and (base_ref .. ".." .. head_override) or base_ref, true
  end
  return "HEAD", false
end

-- Numstat parsing

local function parse_numstat(lines)
  local stats = {}
  for _, line in ipairs(lines) do
    local a, r, f = line:match("^(%d+)%s+(%d+)%s+(.+)$")
    if a then
      stats[f] = stats[f] or { added = 0, removed = 0 }
      stats[f].added = stats[f].added + tonumber(a)
      stats[f].removed = stats[f].removed + tonumber(r)
    end
  end
  return stats
end

-- Hunk parsing

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

-- File list to set conversion

local function lines_to_set(lines)
  local set = {}
  for _, f in ipairs(lines) do
    if f ~= "" then set[f] = true end
  end
  return set
end

-- Status determination

local function determine_status_with_ref(f, deleted_set, repo_head, committed_set, uncommitted_set)
  if deleted_set[f] then return "UD" end
  if repo_head then return "C" end
  if committed_set[f] and uncommitted_set[f] then return "CU" end
  if committed_set[f] then return "C" end
  return "U"
end

local function determine_status_uncommitted(f, deleted_set, staged_set, unstaged_set)
  if deleted_set[f] then return "UD" end
  if staged_set[f] and unstaged_set[f] then return "SU" end
  if staged_set[f] then return "S" end
  return "U"
end

-- Public: get_all_stats

function M.get_all_stats(repo_path)
  local cmd = "git -C " .. vim.fn.shellescape(repo_path)
  local diff_range, has_base = get_diff_range(repo_path)

  local output
  if has_base then
    output = vim.fn.systemlist(cmd .. " diff --numstat " .. vim.fn.shellescape(diff_range))
  else
    output = vim.fn.systemlist(cmd .. " diff --numstat HEAD")
    if vim.v.shell_error ~= 0 then
      output = vim.fn.systemlist(cmd .. " diff --numstat")
    end
  end

  if vim.v.shell_error ~= 0 then return {} end
  return parse_numstat(output)
end

function M.get_file_stats(filepath, repo_path)
  local key = repo_path .. ":" .. filepath .. ":stats"
  if M._cache[key] then
    return M._cache[key].added, M._cache[key].removed
  end
  local all = M.get_all_stats(repo_path)
  for f, s in pairs(all) do
    M._cache[repo_path .. ":" .. f .. ":stats"] = s
  end
  local s = M._cache[key] or { added = 0, removed = 0 }
  M._cache[key] = s
  return s.added, s.removed
end

-- Public: get_hunks

function M.get_hunks(filepath, repo_path)
  local key = repo_path .. ":" .. filepath .. ":hunks"
  if M._cache[key] then return M._cache[key] end

  local cmd = "git -C " .. vim.fn.shellescape(repo_path)
  local diff_range, has_base = get_diff_range(repo_path)
  local output

  if has_base then
    output = vim.fn.systemlist(cmd .. " diff -U0 " .. vim.fn.shellescape(diff_range) .. " -- " .. vim.fn.shellescape(filepath))
  else
    output = vim.fn.systemlist(cmd .. " diff -U0 HEAD -- " .. vim.fn.shellescape(filepath))
    if vim.v.shell_error ~= 0 then
      output = vim.fn.systemlist(cmd .. " diff -U0 -- " .. vim.fn.shellescape(filepath))
    end
  end

  local hunks = (vim.v.shell_error == 0) and parse_hunks(output) or {}
  M._cache[key] = hunks
  return hunks
end

-- Parallel load: job building

local function build_jobs_for_repo(rp)
  local jobs = {}
  local base_ref, head_override = M.get_ref_for_repo(rp)

  if base_ref then
    local diff_range = head_override and (base_ref .. ".." .. head_override) or base_ref
    table.insert(jobs, { cmd = { "git", "-C", rp, "diff", "--name-only", diff_range }, repo = rp, kind = "branch_files" })
    table.insert(jobs, { cmd = { "git", "-C", rp, "diff", "--diff-filter=D", "--name-only", diff_range }, repo = rp, kind = "deleted" })
    table.insert(jobs, { cmd = { "git", "-C", rp, "diff", "--numstat", diff_range }, repo = rp, kind = "numstat" })
    if not head_override then
      table.insert(jobs, { cmd = { "git", "-C", rp, "diff", "--name-only", base_ref .. "..HEAD" }, repo = rp, kind = "committed" })
      table.insert(jobs, { cmd = { "git", "-C", rp, "diff", "--name-only", "HEAD" }, repo = rp, kind = "uncommitted" })
    end
  else
    table.insert(jobs, { cmd = { "git", "-C", rp, "diff", "--name-only", "HEAD" }, repo = rp, kind = "changed" })
    table.insert(jobs, { cmd = { "git", "-C", rp, "diff", "--diff-filter=D", "--name-only", "HEAD" }, repo = rp, kind = "deleted" })
    table.insert(jobs, { cmd = { "git", "-C", rp, "diff", "--numstat", "HEAD" }, repo = rp, kind = "numstat" })
    table.insert(jobs, { cmd = { "git", "-C", rp, "diff", "--cached", "--name-only" }, repo = rp, kind = "staged" })
    table.insert(jobs, { cmd = { "git", "-C", rp, "diff", "--name-only" }, repo = rp, kind = "unstaged" })
    local cfg = require("code_review.config").current
    if cfg.show_untracked then
      table.insert(jobs, { cmd = { "git", "-C", rp, "ls-files", "--others", "--exclude-standard" }, repo = rp, kind = "untracked" })
    end
  end

  return jobs
end

-- Parallel load: execute jobs

local function run_jobs(jobs)
  local handles = {}
  for i, job in ipairs(jobs) do
    handles[i] = vim.system(job.cmd)
  end
  local results = {}
  for i, handle in ipairs(handles) do
    local out = handle:wait()
    results[i] = { lines = vim.split(out.stdout or "", "\n", { trimempty = true }), job = jobs[i], code = out.code }
  end
  return results
end

-- Parallel load: collect results for a repo

local function collect_repo_results(results, rp)
  local data = {
    changed = {}, staged = {}, unstaged = {},
    untracked = {}, branch_files = {}, deleted = {},
    committed = {}, uncommitted = {}, stats = {},
  }
  for _, r in ipairs(results) do
    if r.job.repo == rp and r.code == 0 then
      if r.job.kind == "numstat" then
        data.stats = parse_numstat(r.lines)
      else
        data[r.job.kind] = r.lines
      end
    end
  end
  return data
end

-- Parallel load: process repo with base ref

local function process_repo_with_ref(rp, data, repo_head, all_files)
  local deleted_set = lines_to_set(data.deleted)
  local committed_set = lines_to_set(data.committed)
  local uncommitted_set = lines_to_set(data.uncommitted)
  local seen = {}

  for _, f in ipairs(data.branch_files) do
    if f ~= "" and not seen[f] then
      seen[f] = true
      local status = determine_status_with_ref(f, deleted_set, repo_head, committed_set, uncommitted_set)
      table.insert(all_files, { path = f, status = status, repo = rp })
      M._cache[rp .. ":" .. f .. ":stats"] = data.stats[f] or { added = 0, removed = 0 }
    end
  end
end

-- Parallel load: process repo without base ref (uncommitted)

local function process_repo_uncommitted(rp, data, all_files)
  local staged_set = lines_to_set(data.staged)
  local unstaged_set = lines_to_set(data.unstaged)
  local deleted_set = lines_to_set(data.deleted)
  local seen = {}

  for _, f in ipairs(data.changed) do
    if f ~= "" and not seen[f] then
      seen[f] = true
      local status = determine_status_uncommitted(f, deleted_set, staged_set, unstaged_set)
      table.insert(all_files, { path = f, status = status, repo = rp })
      M._cache[rp .. ":" .. f .. ":stats"] = data.stats[f] or { added = 0, removed = 0 }
    end
  end

  for _, f in ipairs(data.untracked) do
    if f ~= "" and not seen[f] then
      seen[f] = true
      local line_count = M.count_file_lines(rp .. "/" .. f)
      table.insert(all_files, { path = f, status = "N", repo = rp })
      M._cache[rp .. ":" .. f .. ":stats"] = { added = line_count, removed = 0 }
      M._cache[rp .. ":" .. f .. ":hunks"] = line_count > 0
        and { { start = 1, count = line_count, type = "change" } } or {}
    end
  end
end

-- Public: load_all_repos (orchestrator)

function M.load_all_repos(repos)
  -- Build jobs for all repos
  local jobs = {}
  for _, repo in ipairs(repos) do
    local repo_jobs = build_jobs_for_repo(repo.path)
    for _, j in ipairs(repo_jobs) do
      table.insert(jobs, j)
    end
  end

  -- Execute all in parallel
  local results = run_jobs(jobs)

  -- Process each repo's results
  local all_files = {}
  for _, repo in ipairs(repos) do
    local rp = repo.path
    local data = collect_repo_results(results, rp)
    local repo_base, repo_head = M.get_ref_for_repo(rp)

    if repo_base then
      process_repo_with_ref(rp, data, repo_head, all_files)
    else
      process_repo_uncommitted(rp, data, all_files)
    end
  end

  return all_files
end

return M
