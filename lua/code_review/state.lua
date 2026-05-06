local M = {}

local listeners = {}
local batch_depth = 0
local pending_keys = {}
local notifying = {}

M.data = {
  files = {},
  stats = {},
  repos = {},
  current_idx = 1,
  viewed = {},
  viewed_hunks = {},
  log_repo_idx = 1,
  log_selected = 0,
  single_commit_mode = false,
  diff_active = false,
  editing = false,
  current_file = nil,
  current_repo = nil,
}

local defaults = vim.deepcopy(M.data)

function M.set(key, value)
  M.data[key] = value
  if batch_depth > 0 then
    pending_keys[key] = true
  else
    M._notify(key)
  end
end

function M.get(key)
  return M.data[key]
end

function M.batch(fn)
  batch_depth = batch_depth + 1
  fn()
  batch_depth = batch_depth - 1
  if batch_depth == 0 then
    for key, _ in pairs(pending_keys) do
      M._notify(key)
    end
    pending_keys = {}
  end
end

function M.on(key, fn, priority)
  priority = priority or 50
  listeners[key] = listeners[key] or {}
  table.insert(listeners[key], { fn = fn, priority = priority })
  table.sort(listeners[key], function(a, b) return a.priority < b.priority end)
end

function M._notify(key)
  if notifying[key] then return end
  notifying[key] = true
  for _, entry in ipairs(listeners[key] or {}) do
    entry.fn(M.data[key])
  end
  notifying[key] = nil
end

function M.reset()
  M.data = vim.deepcopy(defaults)
  listeners = {}
end

function M.snapshot()
  return vim.deepcopy(M.data)
end

function M.restore(snapshot)
  for k, v in pairs(snapshot) do
    M.data[k] = v
  end
end

return M
