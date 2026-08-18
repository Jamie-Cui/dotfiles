local M = {}

local function current_directory()
	if vim.bo.filetype == "oil" then
		local ok, oil = pcall(require, "oil")
		if ok then
			local directory = oil.get_current_dir()
			if directory then
				return directory
			end
		end
	end

	local name = vim.api.nvim_buf_get_name(0)
	if name ~= "" then
		return vim.fs.dirname(name)
	end

	return vim.uv.cwd()
end

local function set_clipboard(text)
	vim.fn.setreg("+", text)
	vim.fn.setreg('"', text)
	vim.notify("Copied: " .. text:match("^[^\n]*"))
end

local function oil_entry_path()
	if vim.bo.filetype ~= "oil" then
		return nil
	end

	local oil = require("oil")
	local directory = oil.get_current_dir()
	local entry = oil.get_cursor_entry()
	if not directory or not entry then
		return directory
	end

	return vim.fs.joinpath(directory, entry.name)
end

function M.project_root()
	local directory = current_directory()
	return vim.fs.root(directory, ".git") or directory
end

function M.project_files()
	local builtin = require("telescope.builtin")
	local directory = current_directory()
	local root = vim.fs.root(directory, ".git")

	if root then
		builtin.git_files({ cwd = root, show_untracked = true })
	else
		builtin.find_files({ cwd = directory })
	end
end

function M.directory_files()
	require("telescope.builtin").find_files({ cwd = current_directory(), hidden = true })
end

function M.project_search()
	require("telescope.builtin").live_grep({ cwd = M.project_root() })
end

function M.document_symbols()
	local clients = vim.lsp.get_clients({ bufnr = 0, method = "textDocument/documentSymbol" })
	if #clients > 0 then
		require("telescope.builtin").lsp_document_symbols()
	else
		require("telescope.builtin").treesitter()
	end
end

function M.config_files()
	require("telescope.builtin").find_files({ cwd = vim.fn.stdpath("config"), hidden = true })
end

function M.save_current()
	if vim.bo.buftype ~= "" then
		vim.notify("This buffer cannot be written as a file", vim.log.levels.WARN)
		return
	end

	if vim.api.nvim_buf_get_name(0) == "" then
		local keys = vim.api.nvim_replace_termcodes(":write ", true, false, true)
		vim.api.nvim_feedkeys(keys, "n", false)
		return
	end

	local display_name = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":~:.")
	if not vim.bo.modified then
		vim.notify("No changes to save: " .. display_name, vim.log.levels.INFO)
		return
	end

	vim.cmd.update()
	vim.notify("Saved: " .. display_name, vim.log.levels.INFO)
end

function M.revert_current()
	if vim.api.nvim_buf_get_name(0) == "" then
		vim.notify("Buffer is not associated with a file", vim.log.levels.WARN)
		return
	end

	vim.cmd.edit({ bang = true })
end

function M.delete_buffer()
	require("mini.bufremove").delete(0, false)
end

function M.copy_file_name()
	local name = oil_entry_path() or vim.api.nvim_buf_get_name(0)
	if name == "" then
		vim.notify("Buffer is not associated with a file", vim.log.levels.WARN)
		return
	end

	set_clipboard(name)
end

function M.copy_buffer_identifier()
	local name = vim.api.nvim_buf_get_name(0)
	if name == "" then
		set_clipboard(string.format("vim.api.nvim_get_current_buf() -- %d", vim.api.nvim_get_current_buf()))
		return
	end

	set_clipboard(string.format("vim.fn.bufnr(%q)", name))
end

function M.copy_reference()
	if vim.bo.filetype == "oil" then
		local path = oil_entry_path()
		if not path then
			vim.notify("No file at point", vim.log.levels.WARN)
			return
		end

		set_clipboard(path)
		return
	end

	local name = vim.api.nvim_buf_get_name(0)
	if name == "" then
		name = "[No Name]"
	end

	local mode = vim.fn.mode()
	local first_line
	local last_line
	if mode == "v" or mode == "V" or mode == "\22" then
		first_line = vim.fn.getpos("v")[2]
		last_line = vim.fn.getpos(".")[2]
		if first_line > last_line then
			first_line, last_line = last_line, first_line
		end
	else
		first_line = vim.api.nvim_win_get_cursor(0)[1]
		last_line = first_line
	end

	local lines = vim.api.nvim_buf_get_lines(0, first_line - 1, last_line, false)
	if first_line ~= last_line then
		for index, line in ipairs(lines) do
			lines[index] = string.format("   %d: %s", first_line + index - 1, line)
		end
	end
	local reference = string.format("%s:%d-%d", name, first_line, last_line)
	set_clipboard(reference .. "\n\n" .. table.concat(lines, "\n"))
end

function M.open_external()
	local path = oil_entry_path() or vim.api.nvim_buf_get_name(0)
	if path == "" then
		path = current_directory()
	end

	local command
	if vim.fn.has("macunix") == 1 then
		command = { "open", "-R", path }
	elseif vim.fn.executable("xdg-open") == 1 then
		local target = vim.fn.isdirectory(path) == 1 and path or vim.fs.dirname(path)
		command = { "xdg-open", target }
	else
		vim.notify("No supported system file manager command found", vim.log.levels.ERROR)
		return
	end

	vim.system(command, { detach = true })
end

return M
