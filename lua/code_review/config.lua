local M = {}

M.defaults = {
  browser_height = 12,
  signs = { change = "│", delete = "▁" },
  show_untracked = true,
  auto_refresh = true,
  keys = {
    advance = "<Space>",
    next_hunk = "]c",
    prev_hunk = "[c",
    next_file = "]f",
    prev_file = "[f",
    toggle_diff = "d",
    mark_file = "m",
    mark_all = "M",
    mark_and_next = "<Tab>",
    quit = "q",
  },
}

M.current = vim.deepcopy(M.defaults)

function M.apply(user_opts)
  M.current = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), user_opts or {})
end

return M
