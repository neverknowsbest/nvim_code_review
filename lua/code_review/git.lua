local M = {}

M._cache = {}
M._base_ref = nil       -- global base ref (from :CodeReview <ref>)
M._head_override = nil  -- for single commit mode
M._repos = nil
M._repo_refs = {}       -- per-repo base refs (from log selection)

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
  if rr then
    return rr.base, rr.head
  end
  return M._base_ref, M._head_override
end

function M.count_file_lines(filepath)
  local count = 0
  local fh = io.open(filepath, "r")
  if fh then
    for _ in fh:lines() do count = count + 1 end
    fh:close()
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

function M.get_all_stats(repo_path)
  local stats = {}
  local cmd = "git -C " .. vim.fn.shellescape(repo_path)
  local base_ref, head_override = M.get_ref_for_repo(repo_path)

  if base_ref then
    local diff_range = head_override
      and (base_ref .. ".." .. head_override)
      or base_ref
    local output = vim.fn.systemlist(cmd .. " diff --numstat " .. vim.fn.shellescape(diff_range))
    if vim.v.shell_error ~= 0 then return stats end
    for _, line in ipairs(output) do
      local a, r, f = line:match("^(%d+)%s+(%d+)%s+(.+)$")
      if a then
        stats[f] = stats[f] or { added = 0, removed = 0 }
        stats[f].added = stats[f].added + tonumber(a)
        stats[f].removed = stats[f].removed + tonumber(r)
      end
    end
  else
    local output = vim.fn.systemlist(cmd .. " diff --numstat HEAD")
    if vim.v.shell_error ~= 0 then
      -- Fallback for repos with no commits
      output = vim.fn.systemlist(cmd .. " diff --numstat")
    end
    for _, line in ipairs(output) do
      local a, r, f = line:match("^(%d+)%s+(%d+)%s+(.+)$")
      if a then
        stats[f] = stats[f] or { added = 0, removed = 0 }
        stats[f].added = stats[f].added + tonumber(a)
        stats[f].removed = stats[f].removed + tonumber(r)
      end
    end
  end
  return stats
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

function M.get_hunks(filepath, repo_path)
  local key = repo_path .. ":" .. filepath .. ":hunks"
  if M._cache[key] then
    return M._cache[key]
  end

  local cmd = "git -C " .. vim.fn.shellescape(repo_path)
  local hunks = {}
  local output
  local base_ref, head_override = M.get_ref_for_repo(repo_path)

  if base_ref then
    local diff_range = head_override
      and (base_ref .. ".." .. head_override)
      or base_ref
    output = vim.fn.systemlist(cmd .. " diff -U0 " .. vim.fn.shellescape(diff_range) .. " -- " .. vim.fn.shellescape(filepath))
  else
    -- Use diff HEAD to combine staged+unstaged without duplicates
    output = vim.fn.systemlist(cmd .. " diff -U0 HEAD -- " .. vim.fn.shellescape(filepath))
    if vim.v.shell_error ~= 0 then
      -- Fallback for new repos or untracked files
      output = vim.fn.systemlist(cmd .. " diff -U0 -- " .. vim.fn.shellescape(filepath))
    end
  end

  if vim.v.shell_error ~= 0 then
    M._cache[key] = hunks
    return hunks
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
    local base_ref, head_override = M.get_ref_for_repo(rp)
    if base_ref then
      local diff_range = head_override
        and (base_ref .. ".." .. head_override)
        or base_ref
      table.insert(jobs, { cmd = { "git", "-C", rp, "diff", "--name-only", diff_range }, repo = rp, kind = "branch_files" })
      table.insert(jobs, { cmd = { "git", "-C", rp, "diff", "--numstat", diff_range }, repo = rp, kind = "numstat" })
      if not head_override then
        table.insert(jobs, { cmd = { "git", "-C", rp, "diff", "--name-only", base_ref .. "..HEAD" }, repo = rp, kind = "committed" })
        table.insert(jobs, { cmd = { "git", "-C", rp, "diff", "--name-only", "HEAD" }, repo = rp, kind = "uncommitted" })
      end
    else
      table.insert(jobs, { cmd = { "git", "-C", rp, "diff", "--name-only", "HEAD" }, repo = rp, kind = "changed" })
      table.insert(jobs, { cmd = { "git", "-C", rp, "diff", "--numstat", "HEAD" }, repo = rp, kind = "numstat" })
      table.insert(jobs, { cmd = { "git", "-C", rp, "diff", "--cached", "--name-only" }, repo = rp, kind = "staged" })
      table.insert(jobs, { cmd = { "git", "-C", rp, "diff", "--name-only" }, repo = rp, kind = "unstaged" })
      local cfg = require("code_review.config").current
      if cfg.show_untracked then
        table.insert(jobs, { cmd = { "git", "-C", rp, "ls-files", "--others", "--exclude-standard" }, repo = rp, kind = "untracked" })
      end
    end
  end

  local handles = {}
  for i, job in ipairs(jobs) do
    handles[i] = vim.system(job.cmd)
  end

  local results = {}
  for i, handle in ipairs(handles) do
    local out = handle:wait()
    results[i] = { lines = vim.split(out.stdout or "", "\n", { trimempty = true }), job = jobs[i], code = out.code }
  end

  local all_files = {}
  for _, repo in ipairs(repos) do
    local rp = repo.path
    local changed_files, staged_files, unstaged_files, untracked_files, branch_files = {}, {}, {}, {}, {}
    local repo_stats = {}

    for _, r in ipairs(results) do
      if r.job.repo == rp and r.code == 0 then
        if r.job.kind == "changed" then
          changed_files = r.lines
        elseif r.job.kind == "staged" then
          staged_files = r.lines
        elseif r.job.kind == "unstaged" then
          unstaged_files = r.lines
        elseif r.job.kind == "untracked" then
          untracked_files = r.lines
        elseif r.job.kind == "branch_files" then
          branch_files = r.lines
        elseif r.job.kind == "numstat" then
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

    local repo_base, repo_head = M.get_ref_for_repo(rp)
    if repo_base then
      local seen = {}
      local committed_set = {}
      local uncommitted_set = {}

      for _, r in ipairs(results) do
        if r.job.repo == rp and r.code == 0 then
          if r.job.kind == "committed" then
            for _, f in ipairs(r.lines) do committed_set[f] = true end
          elseif r.job.kind == "uncommitted" then
            for _, f in ipairs(r.lines) do uncommitted_set[f] = true end
          end
        end
      end

      for _, f in ipairs(branch_files) do
        if f ~= "" and not seen[f] then
          seen[f] = true
          local status
          if repo_head then
            status = "C"
          elseif committed_set[f] and uncommitted_set[f] then
            status = "CU"
          elseif committed_set[f] then
            status = "C"
          else
            status = "U"
          end
          table.insert(all_files, { path = f, status = status, repo = rp })
          M._cache[rp .. ":" .. f .. ":stats"] = repo_stats[f] or { added = 0, removed = 0 }
        end
      end
    else
      -- Determine status per file using staged/unstaged info
      local staged_set = {}
      for _, f in ipairs(staged_files) do staged_set[f] = true end
      local unstaged_set = {}
      for _, f in ipairs(unstaged_files) do unstaged_set[f] = true end

      local seen = {}
      -- Changed files (combined staged+unstaged from diff HEAD)
      for _, f in ipairs(changed_files) do
        if f ~= "" and not seen[f] then
          seen[f] = true
          local status
          if staged_set[f] and unstaged_set[f] then
            status = "SU"
          elseif staged_set[f] then
            status = "S"
          else
            status = "U"
          end
          table.insert(all_files, { path = f, status = status, repo = rp })
          M._cache[rp .. ":" .. f .. ":stats"] = repo_stats[f] or { added = 0, removed = 0 }
        end
      end

      -- Untracked files — count lines as additions
      for _, f in ipairs(untracked_files) do
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
  end

  return all_files
end

return M
