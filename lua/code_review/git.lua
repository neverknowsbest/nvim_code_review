local M = {}

M._cache = {}

function M.clear_cache()
  M._cache = {}
end

function M.find_repos()
  local cwd = vim.fn.getcwd()
  if vim.fn.isdirectory(cwd .. "/.git") == 1 then
    return { { path = cwd, name = vim.fn.fnamemodify(cwd, ":t") } }
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
  return repos
end

function M.get_changed_files(repo_path)
  local files = {}
  local seen = {}

  local staged = vim.fn.systemlist("git -C " .. vim.fn.shellescape(repo_path) .. " diff --cached --name-only")
  for _, f in ipairs(staged) do
    if f ~= "" and not seen[f] then
      seen[f] = { staged = true, unstaged = false }
      table.insert(files, f)
    end
  end

  local unstaged = vim.fn.systemlist("git -C " .. vim.fn.shellescape(repo_path) .. " diff --name-only")
  for _, f in ipairs(unstaged) do
    if f ~= "" then
      if seen[f] then
        seen[f].unstaged = true
      else
        seen[f] = { staged = false, unstaged = true }
        table.insert(files, f)
      end
    end
  end

  local result = {}
  for _, f in ipairs(files) do
    local s = seen[f]
    local status = s.staged and s.unstaged and "SU" or s.staged and "S" or "U"
    table.insert(result, { path = f, status = status, repo = repo_path })
  end
  return result
end

-- Batch stats: one git call for all files in a repo
function M.get_all_stats(repo_path)
  local stats = {}
  local cmd = "git -C " .. vim.fn.shellescape(repo_path)
  local output = vim.fn.systemlist(cmd .. " diff --numstat")
  local staged = vim.fn.systemlist(cmd .. " diff --cached --numstat")
  for _, line in ipairs(output) do
    local a, r, f = line:match("^(%d+)%s+(%d+)%s+(.+)$")
    if a then
      stats[f] = stats[f] or { added = 0, removed = 0 }
      stats[f].added = stats[f].added + tonumber(a)
      stats[f].removed = stats[f].removed + tonumber(r)
    end
  end
  for _, line in ipairs(staged) do
    local a, r, f = line:match("^(%d+)%s+(%d+)%s+(.+)$")
    if a then
      stats[f] = stats[f] or { added = 0, removed = 0 }
      stats[f].added = stats[f].added + tonumber(a)
      stats[f].removed = stats[f].removed + tonumber(r)
    end
  end
  return stats
end

function M.get_file_stats(filepath, repo_path)
  local key = repo_path .. ":" .. filepath .. ":stats"
  if M._cache[key] then
    return M._cache[key].added, M._cache[key].removed
  end
  -- Populate cache for all files in this repo at once
  local all = M.get_all_stats(repo_path)
  for f, s in pairs(all) do
    M._cache[repo_path .. ":" .. f .. ":stats"] = s
  end
  local s = M._cache[key] or { added = 0, removed = 0 }
  M._cache[key] = s
  return s.added, s.removed
end

function M.get_hunks(filepath, repo_path)
  local key = repo_path .. ":" .. filepath .. ":hunks"
  if M._cache[key] then
    return M._cache[key]
  end

  local cmd = "git -C " .. vim.fn.shellescape(repo_path)
  local hunks = {}
  local output = vim.fn.systemlist(cmd .. " diff -U0 -- " .. vim.fn.shellescape(filepath))
  local staged = vim.fn.systemlist(cmd .. " diff --cached -U0 -- " .. vim.fn.shellescape(filepath))
  for _, line in ipairs(staged) do
    table.insert(output, line)
  end

  for _, line in ipairs(output) do
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

  M._cache[key] = hunks
  return hunks
end

-- Parallel load: spawn all git commands across repos simultaneously
function M.load_all_repos(repos)
  local jobs = {}
  for _, repo in ipairs(repos) do
    local rp = repo.path
    -- 4 commands per repo, launched in parallel
    table.insert(jobs, { cmd = { "git", "-C", rp, "diff", "--cached", "--name-only" }, repo = rp, kind = "staged" })
    table.insert(jobs, { cmd = { "git", "-C", rp, "diff", "--name-only" }, repo = rp, kind = "unstaged" })
    table.insert(jobs, { cmd = { "git", "-C", rp, "diff", "--numstat" }, repo = rp, kind = "numstat" })
    table.insert(jobs, { cmd = { "git", "-C", rp, "diff", "--cached", "--numstat" }, repo = rp, kind = "numstat_staged" })
  end

  -- Launch all
  local handles = {}
  for i, job in ipairs(jobs) do
    handles[i] = vim.system(job.cmd)
  end

  -- Collect results
  local results = {}
  for i, handle in ipairs(handles) do
    local out = handle:wait()
    results[i] = { lines = vim.split(out.stdout or "", "\n", { trimempty = true }), job = jobs[i] }
  end

  -- Process into files and stats
  local all_files = {}
  for _, repo in ipairs(repos) do
    local rp = repo.path
    local staged_files = {}
    local unstaged_files = {}
    local repo_stats = {}

    for _, r in ipairs(results) do
      if r.job.repo == rp then
        if r.job.kind == "staged" then
          staged_files = r.lines
        elseif r.job.kind == "unstaged" then
          unstaged_files = r.lines
        elseif r.job.kind == "numstat" then
          for _, line in ipairs(r.lines) do
            local a, rm, f = line:match("^(%d+)%s+(%d+)%s+(.+)$")
            if a then
              repo_stats[f] = repo_stats[f] or { added = 0, removed = 0 }
              repo_stats[f].added = repo_stats[f].added + tonumber(a)
              repo_stats[f].removed = repo_stats[f].removed + tonumber(rm)
            end
          end
        elseif r.job.kind == "numstat_staged" then
          for _, line in ipairs(r.lines) do
            local a, rm, f = line:match("^(%d+)%s+(%d+)%s+(.+)$")
            if a then
              repo_stats[f] = repo_stats[f] or { added = 0, removed = 0 }
              repo_stats[f].added = repo_stats[f].added + tonumber(a)
              repo_stats[f].removed = repo_stats[f].removed + tonumber(rm)
            end
          end
        end
      end
    end

    -- Build file entries
    local seen = {}
    local files = {}
    for _, f in ipairs(staged_files) do
      if f ~= "" and not seen[f] then
        seen[f] = { staged = true, unstaged = false }
        table.insert(files, f)
      end
    end
    for _, f in ipairs(unstaged_files) do
      if f ~= "" then
        if seen[f] then
          seen[f].unstaged = true
        else
          seen[f] = { staged = false, unstaged = true }
          table.insert(files, f)
        end
      end
    end

    for _, f in ipairs(files) do
      local s = seen[f]
      local status = s.staged and s.unstaged and "SU" or s.staged and "S" or "U"
      table.insert(all_files, { path = f, status = status, repo = rp })
      -- Cache stats
      local st = repo_stats[f] or { added = 0, removed = 0 }
      M._cache[rp .. ":" .. f .. ":stats"] = st
    end
  end

  return all_files
end

return M
