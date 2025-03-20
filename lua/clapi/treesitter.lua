local utils = require("clapi.utils")
local parsers = require("nvim-treesitter.parsers")
local async = require("plenary.async")
-- Treesitter Parser Module
local M = {}

---@param opts table
M.parse_file = async.wrap(function(opts, callback)
	if opts.filename and opts.bufnr then
		utils.notify("parse_file", {
			msg = "filename and bufnr params can't be used at the same time",
			level = "ERROR",
		})
		callback(nil)
	end

	if opts.filename then
		opts.bufnr = vim.fn.bufadd(opts.filename)
	end

	if opts.bufnr then
		opts.filename = vim.api.nvim_buf_get_name(opts.bufnr)
	end

	if not opts.filetype then
		local filetype = utils.get_file_extension(opts.filename)
		if not filetype then
			utils.notify("parse_file", {
				msg = "Couldn't get the file extension",
				level = "ERROR",
			})
			callback(nil)
		end
		opts.filetype = filetype
	end

	if opts.filetype == "" then
		utils.notify("parse_file", {
			msg = "No language detected",
			level = "ERROR",
		})
		callback(nil)
	end

	opts.query_str = opts.query_str or M.get_query(opts.filetype, "locals")

	if not opts.query_str then
		utils.notify("parse_file", {
			msg = string.format("Language not supported (%s)", opts.filetype),
			level = "ERROR",
		})
		callback(nil)
	end

	-- Ensure buffer is loaded
	if not vim.api.nvim_buf_is_loaded(opts.bufnr) and vim.fn.filereadable(opts.filename) == 1 then
		vim.fn.bufload(opts.bufnr)
	end

	-- Load the treesitter parser for the language
	local treesitter_filetype = parsers.get_buf_lang(opts.bufnr)
	local parser = vim.treesitter.get_parser(opts.bufnr, treesitter_filetype)
	if not parser then
		utils.notify("treesitter.parse_file", {
			msg = "No parser for the current buffer",
			level = "ERROR",
		})
		callback(nil)
	end

	-- Parse the query
	local query = vim.treesitter.query.parse(opts.filetype, opts.query_str)
	if not query then
		utils.notify("treesitter.parse_file", {
			msg = "Failed to parse query",
			level = "ERROR",
		})
		callback(nil)
	end

	-- Parse the content
	-- TODO: nil check
	local tree = parser:parse()
	if not tree then
		utils.notify("treesitter.parse_file", {
			msg = "Failed to parse buffer content",
			level = "ERROR",
		})
		callback(nil)
	end

	tree = tree[1]

	local root = tree:root()

	-- Execute the query and collect results
	local result = {}
	local methods = {}
	local properties = {}
	local visibilities = {}

	-- First pass - collect all captures
	for id, node, metadata in query:iter_captures(root, opts.bufnr) do
		local capture_name = query.captures[id]
		local text = vim.treesitter.get_node_text(node, opts.bufnr)
		local start_row, start_col, _, _ = node:range()

		if capture_name == "method_name" then
			table.insert(methods, {
				name = text,
				node = node,
				row = start_row + 1,
				col = start_col + 1,
			})
		elseif capture_name == "prop_name" then
			table.insert(properties, {
				name = text,
				node = node,
				row = start_row + 1,
				col = start_col + 1,
			})
		elseif capture_name == "visibility" then
			table.insert(visibilities, {
				value = text,
				node = node,
				row = start_row + 1,
				col = start_col + 1,
			})
		end
	end

	-- Process methods and associate them with visibilities
	for _, method in ipairs(methods) do
		local parent = method.node:parent()
		local visibility = "public" -- Default visibility

		-- Find the closest visibility modifier
		for _, vis in ipairs(visibilities) do
			local vis_parent = vis.node:parent()
			if vis_parent == parent then
				visibility = vis.value
				break
			end
		end

		table.insert(result, {
			col = method.col,
			filename = opts.filename,
			visibility = visibility,
			kind = "Method",
			lnum = method.row,
			text = "[Method] " .. method.name,
		})
	end

	-- Process properties and associate them with visibilities
	for _, prop in ipairs(properties) do
		local parent = prop.node:parent()
		local prop_parent = parent

		-- Find the parent property declaration or promotion parameter
		while
			prop_parent
			and prop_parent:type() ~= "property_declaration"
			and prop_parent:type() ~= "property_promotion_parameter"
		do
			prop_parent = prop_parent:parent()
		end

		local visibility = "private" -- Default visibility

		-- Find the closest visibility modifier
		for _, vis in ipairs(visibilities) do
			local vis_parent = vis.node:parent()
			if vis_parent == prop_parent then
				visibility = vis.value
				break
			end
		end

		table.insert(result, {
			col = prop.col,
			filename = opts.filename,
			visibility = visibility,
			kind = "Property",
			lnum = prop.row,
			text = "[Property] " .. prop.name,
		})
	end

	async.run(function()
		local parent_defs = M.get_parent_file({ bufnr = opts.bufnr })
		if not parent_defs then
			-- error already printed somewhere
			callback(result)
		end
		for key, value in pairs(parent_defs) do
			table.insert(result, value)
		end

		callback(result)
	end)
end, 2)

---@param lang string
---@param query_group string
function M.get_query(lang, query_group)
	-- TODO: nil check
	--
	local results = vim.api.nvim_get_runtime_file(string.format("queries/%s/%s.scm", lang, query_group), true)
	for i, value in ipairs(results) do
		if string.find(value, "clapi") then
			local fullpath = results[i]
			return utils.read_file(fullpath)
		end
	end
	return nil
end
--------------------------
--- Parent functions
--------------------------
--- Gets the full filepath given the position of an element in the file

---@param opts table
M.get_file_from_position = async.wrap(function(opts, callback)
	opts = opts or {}
	opts.bufnr = opts.bufnr or 0

	if not opts.position then
		utils.notify("get_file_from_position", {
			msg = "Position not provided",
			level = "ERROR",
		})
		callback(nil)
		return
	end

	vim.lsp.buf_request(opts.bufnr, "textDocument/definition", {
		position = opts.position,
		textDocument = {
			uri = string.format("file://%s", vim.api.nvim_buf_get_name(opts.bufnr)),
		},
	}, function(err, result, _, _)
		if err or not result then
			utils.notify("get_parent_file", {
				msg = "Couldn't get the file for the parent class",
				level = "ERROR",
			})
			callback(nil)
			return
		end

		for _, x in pairs(result) do
			-- Handle different LSP response formats
			local uri
			-- Handle array of results (typical for "textDocument/definition")
			if type(x) == "table" and x ~= nil then
				if x.uri then
					uri = x.uri
				elseif x.targetUri then
					uri = x.targetUri
				end
			-- Handle single result
			elseif type(x) == "table" and x.uri then
				uri = x.uri
			-- Handle phpactor-style nested result
			elseif type(x) == "table" and x.result and x.result.uri then
				uri = x.result.uri
			end

			if uri then
				callback(uri:gsub("file://", ""))
				return
			end
		end

		callback(nil)
	end)
end, 2)

---@param opts table
M.get_parent_file = async.wrap(function(opts, callback)
	opts = opts or {}
	opts.bufnr = opts.bufnr or 0

	local filetype = parsers.get_buf_lang(opts.bufnr)
	local parser = vim.treesitter.get_parser(opts.bufnr, filetype)
	if not parser then
		utils.notify("get_parent_file", {
			msg = "No parser for the current buffer",
			level = "ERROR",
		})
		callback(nil)
	end

	-- Parse the query
	-- WARNING: might have to use vim.bo.filetype instead of treesitter filetype
	local query_str = M.get_query(filetype, "parent")
	if not query_str then
		utils.notify("get_parent_file", {
			msg = string.format("Language not supported (%s)", filetype),
			level = "ERROR",
		})
		callback(nil)
	end

	local query = vim.treesitter.query.parse(filetype, query_str)

	if not query then
		utils.notify("get_parent_file", {
			msg = "Failed to parse query",
			level = "ERROR",
		})
		callback(nil)
	end

	-- Parse the content
	-- TODO: nil check
	local tree = parser:parse()
	if not tree then
		utils.notify("get_parent_file", {
			msg = "Failed to parse buffer content",
			level = "ERROR",
		})
		callback(nil)
	end

	tree = tree[1]

	local root = tree:root()

	local result = {}

	async.run(function()
		for id, node, metadata in query:iter_captures(root, opts.bufnr) do
			local capture_name = query.captures[id]
			if capture_name == "parent" then
				local line, char = node:start()

				local p = M.get_file_from_position({ bufnr = opts.bufnr, position = { character = char, line = line } })
				if not p or p == "" then
					-- error already printed in get_file_from_position
					callback(nil)
				end
				local defs = M.parse_file({ filename = p })
				for _, value in pairs(defs) do
					if value["visibility"] ~= "private" then
						table.insert(result, value)
					end
				end
			end
		end
		callback(result)
	end)
end, 2)

return M
