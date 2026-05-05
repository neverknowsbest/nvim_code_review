local M = {}

M.defaults = {
  browser_height = 12,
  signs = { change = "│", delete = "▁" },
  show_untracked = true,
  auto_refresh = true,
  log = {
    show_on_open = true,
    max_commits = 20,
    default_mode = "range", -- "range" or "single"
  },
  keys = {
    advance = "<CR>",
    next_hunk = "]c",
    prev_hunk = "[c",
    next_file = "]f",
    prev_file = "[f",
    toggle_diff = "d",
    toggle_log = "L",
    refresh = "r",
    edit = "e",
    mark_file = "m",
    mark_all = "M",
    mark_and_next = "<Tab>",
    quit = "q",
  },
}

M.current = vim.deepcopy(M.defaults)

function M.apply(user_opts)
  M.current = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), user_opts or {})
  M.current.browser_height = math.max(3, math.min(50, tonumber(M.current.browser_height) or 12))
  M.current.log.max_commits = math.max(1, math.min(100, tonumber(M.current.log.max_commits) or 20))
  if M.current.log.default_mode ~= "range" and M.current.log.default_mode ~= "single" then
    M.current.log.default_mode = "range"
  end
end

return M
