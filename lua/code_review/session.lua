local M = {}

local SESSION_DIR = vim.fn.stdpath("state") .. "/code_review"

function M.path()
  local cwd = vim.fn.resolve(vim.fn.getcwd())
  local hash = vim.fn.sha256(cwd):sub(1, 12)
  vim.fn.mkdir(SESSION_DIR, "p")
  return SESSION_DIR .. "/" .. hash .. ".json"
end

-- Serialization helpers

local function stringify_keys(tbl)
  local out = {}
  for k, v in pairs(tbl) do
    out[tostring(k)] = v
  end
  return out
end

local function stringify_nested_keys(tbl)
  local out = {}
  for file_idx, hunks in pairs(tbl) do
    out[tostring(file_idx)] = stringify_keys(hunks)
  end
  return out
end

local function build_file_keys(files)
  local keys = {}
  for i, entry in ipairs(files) do
    keys[i] = entry.repo .. ":" .. entry.path
  end
  return keys
end

local function build_repo_refs(git)
  local refs = {}
  for repo_path, ref_data in pairs(git._repo_refs) do
    refs[repo_path] = ref_data.base
  end
  return refs
end

-- Deserialization helpers

local function normalize_nil(val)
  if val == vim.NIL then return nil end
  return val
end

local function normalize_data(data)
  data.base_ref = normalize_nil(data.base_ref)
  data.repo_refs = normalize_nil(data.repo_refs)
  data.viewed = normalize_nil(data.viewed)
  data.viewed_hunks = normalize_nil(data.viewed_hunks)
  data.files = normalize_nil(data.files)
  return data
end

local function build_path_index(saved_files)
  local index = {}
  for i, key in ipairs(saved_files or {}) do
    index[key] = i
  end
  return index
end

-- Ref matching

local function refs_match(data, git)
  if data.base_ref ~= git._base_ref then return false end
  local saved = data.repo_refs or {}
  for repo_path, saved_ref in pairs(saved) do
    local current = git._repo_refs[repo_path]
    if saved_ref ~= (current and current.base) then return false end
  end
  for repo_path, ref_data in pairs(git._repo_refs) do
    if not saved[repo_path] and ref_data.base then return false end
  end
  return true
end

-- Restore helpers

local function restore_viewed(files, data, path_index, viewed)
  if not data.viewed then return end
  for i, entry in ipairs(files) do
    local key = entry.repo .. ":" .. entry.path
    local saved_idx = path_index[key]
    if saved_idx and data.viewed[tostring(saved_idx)] then
      viewed[i] = true
    end
  end
end

local function restore_hunks(files, data, path_index, viewed, viewed_hunks, stats, git)
  if not data.viewed_hunks then return end
  for i, entry in ipairs(files) do
    local key = entry.repo .. ":" .. entry.path
    local saved_idx = path_index[key]
    if not saved_idx then goto continue end

    if data.viewed and data.viewed[tostring(saved_idx)] then
      viewed[i] = true
    end

    local saved = data.viewed_hunks[tostring(saved_idx)]
    if saved then
      local hunks = git.get_hunks(entry.path, entry.repo)
      local valid_starts = {}
      for _, h in ipairs(hunks) do valid_starts[h.start] = true end

      viewed_hunks[i] = {}
      for k, v in pairs(saved) do
        local num = tonumber(k)
        if num and valid_starts[num] then
          viewed_hunks[i][num] = v
        end
      end

      if stats[i] and not stats[i].chunks then
        stats[i].chunks = #hunks
      end
    end

    ::continue::
  end
end

local function restore_position(data, files, saved_files, state)
  if not data.current_idx or data.current_idx > #files then return end
  local saved_key = (saved_files or {})[data.current_idx]
  local entry = files[data.current_idx]
  if entry and saved_key == (entry.repo .. ":" .. entry.path) then
    state.data.current_idx = data.current_idx
  end
end

-- Public API

function M.save()
  local config = require("code_review.config")
  if not config.current.persist_session then return end

  local state = require("code_review.state")
  local git = require("code_review.git")
  local files = state.get("files")
  if not files or #files == 0 then return end

  local data = {
    current_idx = state.get("current_idx"),
    viewed = stringify_keys(state.get("viewed")),
    viewed_hunks = stringify_nested_keys(state.get("viewed_hunks")),
    files = build_file_keys(files),
    base_ref = git._base_ref,
    repo_refs = build_repo_refs(git),
  }

  local json = vim.fn.json_encode(data)
  local f, err = io.open(M.path(), "w")
  if f then
    f:write(json)
    f:close()
  else
    vim.notify("Failed to save review session: " .. (err or "unknown"), vim.log.levels.WARN)
  end
end

function M.restore()
  local config = require("code_review.config")
  if not config.current.persist_session then return end

  local f = io.open(M.path(), "r")
  if not f then return end
  local content = f:read("*a")
  f:close()

  local ok, data = pcall(vim.fn.json_decode, content)
  if not ok or not data then return end
  data = normalize_data(data)

  local state = require("code_review.state")
  local git = require("code_review.git")
  local files = state.get("files")
  local path_index = build_path_index(data.files)

  if not refs_match(data, git) then
    restore_viewed(files, data, path_index, state.get("viewed"))
    return
  end

  restore_hunks(files, data, path_index, state.get("viewed"), state.get("viewed_hunks"), state.get("stats"), git)
  restore_viewed(files, data, path_index, state.get("viewed"))
  restore_position(data, files, data.files, state)
end

function M.clear()
  os.remove(M.path())
end

return M
