local M = {}

function M.format_stat(files, added, removed)
	return string.format("%-3sf  +%-5s -%-5s", files, added, removed)
end

function M.apply_stat_highlights(buf, ns, lines, start_line)
	start_line = start_line or 0
	for i, l in ipairs(lines) do
		local lnum = start_line + i - 1
		-- Search from the right to avoid matching commit message content
		local s, e = l:find("  %+%d+%s+%-%d+%s*$")
		if s then
			local ps, pe = l:find("%+%d+", s)
			if ps then
				vim.api.nvim_buf_set_extmark(buf, ns, lnum, ps - 1, { end_col = pe, hl_group = "DiffAdd" })
			end
			local ms, me = l:find("%-%d+", pe or s)
			if ms then
				vim.api.nvim_buf_set_extmark(buf, ns, lnum, ms - 1, { end_col = me, hl_group = "DiffDelete" })
			end
		end
	end
end

function M.setup_scratch_buf(buf, keep_alive)
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = keep_alive and "hide" or "wipe"
	vim.bo[buf].swapfile = false
end

function M.setup_list_win(win)
	vim.wo[win].cursorline = true
	vim.wo[win].number = false
	vim.wo[win].relativenumber = false
	vim.wo[win].signcolumn = "no"
	vim.wo[win].wrap = false
end

function M.place_signs(buf, ns, hunks, line_count)
	local cfg = require("code_review.config").current
	for _, hunk in ipairs(hunks) do
		if hunk.type == "delete" then
			local lnum = math.min(math.max(0, hunk.start - 1), math.max(0, line_count - 1))
			vim.api.nvim_buf_set_extmark(buf, ns, lnum, 0, {
				sign_text = cfg.signs.delete,
				sign_hl_group = "CodeReviewDelete",
				line_hl_group = "CodeReviewDeleteLine",
			})
		else
			for i = 0, hunk.count - 1 do
				local lnum = hunk.start - 1 + i
				if lnum < line_count then
					vim.api.nvim_buf_set_extmark(buf, ns, lnum, 0, {
						sign_text = cfg.signs.change,
						sign_hl_group = "CodeReviewChange",
						line_hl_group = "CodeReviewChangeLine",
					})
				end
			end
		end
	end
end

return M
