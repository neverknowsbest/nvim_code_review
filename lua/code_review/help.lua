local M = {}

local help_win = nil

function M.toggle()
	if help_win and vim.api.nvim_win_is_valid(help_win) then
		vim.api.nvim_win_close(help_win, true)
		help_win = nil
		return
	end

	local keys = require("code_review.config").current.keys
	local layout = require("code_review.layout")
	local is_browse = layout.state.mode == "browse"

	local lines
	if is_browse then
		lines = {
			" Code Review Shortcuts (browse mode)",
			" ─────────────────────────────────────",
			"",
			" File Buffer",
			string.format("   %-10s next hunk", keys.next_hunk),
			string.format("   %-10s previous hunk", keys.prev_hunk),
			string.format("   %-10s next file", keys.next_file),
			string.format("   %-10s previous file", keys.prev_file),
			string.format("   %-10s toggle side-by-side diff", keys.toggle_diff),
			"",
			" Browser Pane",
			string.format("   %-10s toggle file viewed", keys.mark_file),
			string.format("   %-10s toggle all files viewed", keys.mark_all),
			string.format("   %-10s mark file + next", keys.mark_and_next),
			string.format("   %-10s refresh", keys.refresh),
			string.format("   %-10s toggle git log", keys.toggle_log),
			string.format("   %-10s switch to tab mode", keys.switch_mode),
			string.format("   %-10s close review", keys.quit),
			"",
			" Navigation",
			"   gv         go to editor",
			"   gb         go to file browser",
			"   gl         go to git log",
			"",
			" Git Log",
			"   <CR>       select commit",
			"   s          toggle range/single mode",
			"   <Tab>      next repo",
			"   <S-Tab>    previous repo",
			"",
			"   g?         toggle this help",
			"   :CodeReviewClose to close",
		}
	else
		lines = {
			" Code Review Shortcuts (tab mode)",
			" ─────────────────────────────────────",
			"",
			" Viewer",
			string.format("   %-10s advance (next hunk or next file)", keys.advance),
			string.format("   %-10s reverse advance (prev hunk or prev file)", keys.reverse_advance),
			string.format("   %-10s next hunk", keys.next_hunk),
			string.format("   %-10s previous hunk", keys.prev_hunk),
			string.format("   %-10s next file", keys.next_file),
			string.format("   %-10s previous file", keys.prev_file),
			string.format("   %-10s toggle side-by-side diff", keys.toggle_diff),
			string.format("   %-10s switch to browse mode", keys.switch_mode),
			string.format("   %-10s toggle file viewed", keys.mark_file),
			string.format("   %-10s toggle all files viewed", keys.mark_all),
			string.format("   %-10s mark file + next", keys.mark_and_next),
			string.format("   %-10s previous file", keys.prev_file_alt),
			string.format("   %-10s refresh", keys.refresh),
			string.format("   %-10s toggle git log", keys.toggle_log),
			"",
			" Navigation",
			"   gv         go to viewer",
			"   gb         go to file browser",
			"   gl         go to git log",
			"",
			" Git Log",
			"   <CR>       select commit",
			"   s          toggle range/single mode",
			"   <Tab>      next repo",
			"   <S-Tab>    previous repo",
			"",
			string.format("   %-10s close review", keys.quit),
			"   g?         toggle this help",
		}
	end

	local width = 44
	local height = #lines
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false
	vim.bo[buf].bufhidden = "wipe"

	local uis = vim.api.nvim_list_uis()
	if #uis == 0 then
		return
	end
	local ui = uis[1]
	help_win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = width,
		height = height,
		col = math.floor((ui.width - width) / 2),
		row = math.floor((ui.height - height) / 2),
		style = "minimal",
		border = "rounded",
	})

	local close = function()
		if help_win and vim.api.nvim_win_is_valid(help_win) then
			vim.api.nvim_win_close(help_win, true)
			help_win = nil
		end
	end
	vim.keymap.set("n", "q", close, { buffer = buf, nowait = true })
	vim.keymap.set("n", "<Esc>", close, { buffer = buf, nowait = true })
	vim.keymap.set("n", "g?", close, { buffer = buf, nowait = true })
end

return M
