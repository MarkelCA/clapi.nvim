local conf = require("telescope.config").values
local finders = require("telescope.finders")
local pickers = require("telescope.pickers")
local make_entry = require("clapi.make_entry")
local treesitter = require("clapi.treesitter")
local async = require("plenary.async")
local utils = require("clapi.utils")

local M = {}

-- Main function that gets called directly
function M.builtin(opts)
	opts = opts or {}
	opts.bufnr = opts.bufnr or 0
	opts.path_display = { "hidden" }

	-- Create a picker with a processing message
	local picker = pickers.new(opts, {
		prompt_title = "Module Interface (Loading...)",
		finder = finders.new_table({
			results = {},
			entry_maker = opts.entry_maker or make_entry.gen_from_lsp_symbols(opts),
		}),
		previewer = conf.qflist_previewer(opts),
		sorter = conf.prefilter_sorter({
			tag = "symbol_type",
			sorter = conf.generic_sorter(opts),
		}),
		push_cursor_on_edit = true,
		push_tagstack_on_edit = true,
	})

	-- Show the picker first
	picker:find()

	-- Then fetch results asynchronously
	treesitter.parse_file(opts, function(results)
		if not results then
			-- Just leave the empty picker as is
			-- Error notification already shown by parse_file
			return
		end

		-- Update the picker with actual results
		picker:refresh(finders.new_table({
			results = results,
			entry_maker = opts.entry_maker or make_entry.gen_from_lsp_symbols(opts),
		}))
	end)

	return picker
end

return M
