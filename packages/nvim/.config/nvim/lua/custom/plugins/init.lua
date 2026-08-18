local function create_empty_file()
	local directory = require("oil").get_current_dir()
	if not directory then
		return
	end

	vim.ui.input({ prompt = "Create empty file: " }, function(name)
		if not name or name == "" then
			return
		end

		local path = vim.startswith(name, "/") and name or vim.fs.joinpath(directory, name)
		if vim.uv.fs_stat(path) then
			vim.notify("File already exists: " .. path, vim.log.levels.WARN)
			return
		end

		local file, error_message = vim.uv.fs_open(path, "wx", 420)
		if not file then
			vim.notify(error_message or ("Could not create: " .. path), vim.log.levels.ERROR)
			return
		end

		vim.uv.fs_close(file)
		require("oil.actions").refresh.callback()
	end)
end

---@module 'lazy'
---@type LazySpec
return {
	{
		"stevearc/oil.nvim",
		version = "*",
		lazy = false,
		dependencies = { "nvim-tree/nvim-web-devicons" },
		---@module 'oil'
		---@type oil.SetupOpts
		opts = {
			default_file_explorer = true,
			columns = { "icon", "permissions", "size", "mtime" },
			keymaps = {
				h = { "actions.parent", mode = "n" },
				l = "actions.select",
				["<Tab>"] = "actions.preview",
				q = { "actions.close", mode = "n" },
				T = { callback = create_empty_file, desc = "Create empty file", mode = "n" },
			},
			view_options = { show_hidden = true },
		},
	},
	{
		"jake-stewart/multicursor.nvim",
		branch = "1.0",
		keys = {
			{
				"<M-d>",
				function()
					require("multicursor-nvim").matchAddCursor(1)
				end,
				mode = { "n", "x" },
				desc = "Add cursor at next match",
			},
		},
		config = function()
			local multicursor = require("multicursor-nvim")
			multicursor.setup()
			multicursor.addKeymapLayer(function(layer_map)
				layer_map({ "n", "x" }, "<Esc>", function()
					if multicursor.cursorsEnabled() then
						multicursor.clearCursors()
					else
						multicursor.enableCursors()
					end
				end)
				layer_map({ "n", "x" }, "<C-g>", function()
					multicursor.clearCursors()
				end)
				layer_map("i", "<C-g>", function()
					multicursor.clearCursors()
					vim.cmd.stopinsert()
				end)
			end)
		end,
	},
}
