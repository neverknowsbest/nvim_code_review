local M = {}

local SESSION_FILE = ".code_review_session.json"

function M.path()
  return vim.fn.getcwd() .. "/" .. SESSION_FILE
end

function M.save(browser)
  local config = require("code_review.config")
  if not config.current.persist_session then return end

  -- Convert sparse numeric keys to string keys for JSON compatibility
  local viewed = {}
  for k, v in pairs(browser.viewed) do
    viewed[tostring(k)] = v
  end

  local viewed_hunks = {}
  for file_idx, hunks in pairs(browser.viewed_hunks) do
    local h = {}
    for line_num, v in pairs(hunks) do
      h[tostring(line_num)] = v
    end
    viewed_hunks[tostring(file_idx)] = h
  end

  local data = {
    current_idx = browser.current_idx,
    viewed = viewed,
    viewed_hunks = viewed_hunks,
    files = {},
  }
  for i, entry in ipairs(browser.files) do
    data.files[i] = entry.repo .. ":" .. entry.path
  end

  local json = vim.fn.json_encode(data)
  local f, err = io.open(M.path(), "w")
  if f then
    f:write(json)
    f:close()
  else
    vim.notify("Failed to save review session: " .. (err or "unknown"), vim.log.levels.WARN)
  end
end

function M.restore(browser)
  local config = require("code_review.config")
  if not config.current.persist_session then return end

  local f = io.open(M.path(), "r")
  if not f then return end
  local content = f:read("*a")
  f:close()

  local ok, data = pcall(vim.fn.json_decode, content)
  if not ok or not data then return end

  -- Build lookup of saved file keys
  local saved_files = data.files or {}

  -- Match saved state to current file list by path
  local path_to_saved_idx = {}
  for i, key in ipairs(saved_files) do
    path_to_saved_idx[key] = i
  end

  -- Restore viewed and viewed_hunks by matching paths
  for i, entry in ipairs(browser.files) do
    local key = entry.repo .. ":" .. entry.path
    local saved_idx = path_to_saved_idx[key]
    if saved_idx then
      if data.viewed and data.viewed[tostring(saved_idx)] then
        browser.viewed[i] = true
      end
      if data.viewed_hunks and data.viewed_hunks[tostring(saved_idx)] then
        browser.viewed_hunks[i] = {}
        for k, v in pairs(data.viewed_hunks[tostring(saved_idx)]) do
          browser.viewed_hunks[i][tonumber(k)] = v
        end
        -- Fill chunk count from viewed hunks count as minimum
        if browser.stats[i] and not browser.stats[i].chunks then
          local git = require("code_review.git")
          local hunks = git.get_hunks(entry.path, entry.repo)
          browser.stats[i].chunks = #hunks
        end
      end
    end
  end

  -- Restore position (only if file at that index matches)
  if data.current_idx and data.current_idx <= #browser.files then
    local saved_key = saved_files[data.current_idx]
    local entry = browser.files[data.current_idx]
    local actual_key = entry and (entry.repo .. ":" .. entry.path)
    if saved_key == actual_key then
      browser.current_idx = data.current_idx
    end
  end
end

function M.clear()
  os.remove(M.path())
end

return M
