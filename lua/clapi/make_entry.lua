-- This module reimplements the telescope.make_entry functions
-- to include the `visibility` column.

local make_entry = require("telescope.make_entry")
local utils = require("telescope.utils")
local entry_display = require("telescope.pickers.entry_display")

local M = {}

local lsp_type_highlight = {
	["Class"] = "TelescopeResultsClass",
	["Constant"] = "TelescopeResultsConstant",
	["Field"] = "TelescopeResultsField",
	["Function"] = "TelescopeResultsFunction",
	["Method"] = "TelescopeResultsMethod",
	["Property"] = "TelescopeResultsOperator",
	["Struct"] = "TelescopeResultsStruct",
	["Variable"] = "TelescopeResultsVariable",
}

local get_filename_fn = function()
	local bufnr_name_cache = {}
	return function(bufnr)
		bufnr = vim.F.if_nil(bufnr, 0)
		local c = bufnr_name_cache[bufnr]
		if c then
			return c
		end

		local n = vim.api.nvim_buf_get_name(bufnr)
		bufnr_name_cache[bufnr] = n
		return n
	end
end

function M.gen_from_lsp_symbols(opts)
	opts = opts or {}

	local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()

	-- Default we have two columns, symbol and type(unbound)
	-- If path is not hidden then its, filepath, symbol and type(still unbound)
	-- If show_line is also set, type is bound to len 8
	local display_items = {
		{ width = opts.symbol_width or 10 },
		{ width = opts.symbol_width or 10 },
		{ remaining = true },
	}

	local hidden = utils.is_path_hidden(opts)
	if not hidden then
		table.insert(display_items, 1, { width = vim.F.if_nil(opts.fname_width, 30) })
	end

	if opts.show_line then
		-- bound type to len 8 or custom
		table.insert(display_items, #display_items, { width = opts.symbol_type_width or 8 })
	end

	local displayer = entry_display.create({
		separator = " ",
		hl_chars = { ["["] = "TelescopeBorder", ["]"] = "TelescopeBorder" },
		items = display_items,
	})
	local type_highlight = vim.F.if_nil(opts.symbol_highlights or lsp_type_highlight)

	local make_display = function(entry)
		local msg

		if opts.show_line then
			msg = vim.trim(vim.F.if_nil(vim.api.nvim_buf_get_lines(bufnr, entry.lnum - 1, entry.lnum, false)[1], ""))
		end

		if hidden then
			return displayer({
				entry.visibility or "",
				{ entry.symbol_type:lower(), type_highlight[entry.symbol_type] },
				entry.symbol_name,
				msg,
			})
		else
			local display_path, path_style = utils.transform_path(opts, entry.filename)
			return displayer({
				{
					display_path,
					function()
						return path_style
					end,
				},
				entry.visibility or "",
				{ entry.symbol_type:lower(), type_highlight[entry.symbol_type] },
				entry.symbol_name,
				msg,
			})
		end
	end

	local get_filename = get_filename_fn()
	return function(entry)
		local filename = vim.F.if_nil(entry.filename, get_filename(entry.bufnr))
		local symbol_msg = entry.text
		local symbol_type, symbol_name = symbol_msg:match("%[(.+)%]%s+(.*)")
		local ordinal = ""
		if not hidden and filename then
			ordinal = filename .. " "
		end
		ordinal = ordinal .. entry.visibility .. symbol_name .. " " .. (symbol_type or "unknown")
		vim.print(entry)
		return make_entry.set_default_entry_mt({
			value = entry,
			ordinal = ordinal,
			display = make_display,
			visibility = entry.visibility,

			filename = filename,
			lnum = entry.lnum,
			col = entry.col,
			symbol_name = symbol_name,
			symbol_type = symbol_type,
			start = entry.start,
			finish = entry.finish,
		}, opts)
	end
end

return M
