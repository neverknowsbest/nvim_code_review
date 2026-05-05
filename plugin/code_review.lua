if vim.g.loaded_code_review then
  return
end
vim.g.loaded_code_review = true

require("code_review").setup()
