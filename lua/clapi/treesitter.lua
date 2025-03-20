local utils = require("clapi.utils")
local parsers = require("nvim-treesitter.parsers")
-- Treesitter Parser Module
local M = {}

---@param opts table
function M.parse_file(opts)
	if opts.filename and opts.bufnr then
		utils.notify("parse_file", {
			msg = "filename and bufnr params can't be used at the same time",
			level = "ERROR",
		})
		return
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
			return
		end
		opts.filetype = filetype
	end

	if opts.filetype == "" then
		utils.notify("parse_file", {
			msg = "No language detected",
			level = "ERROR",
		})
		return
	end

	opts.query_str = opts.query_str or M.get_query(opts.filetype, "locals")

	if not opts.query_str then
		utils.notify("parse_file", {
			msg = string.format("Language not supported (%s)", opts.filetype),
			level = "ERROR",
		})
		return
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
		return
	end

	-- Parse the query
	local query = vim.treesitter.query.parse(opts.filetype, opts.query_str)
	if not query then
		utils.notify("treesitter.parse_file", {
			msg = "Failed to parse query",
			level = "ERROR",
		})
		return {}
	end

	-- Parse the content
	-- TODO: nil check
	local tree = parser:parse()
	if not tree then
		utils.notify("treesitter.parse_file", {
			msg = "Failed to parse buffer content",
			level = "ERROR",
		})
		return
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

	local parent_defs = M.get_parent_file({ bufnr = opts.bufnr })
	if not parent_defs then
		-- error already printed somewhere
		return result
	end
	for key, value in pairs(parent_defs) do
		table.insert(result, value)
	end

	return result
end

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
---@param callback fun(err: string|nil, result: any)
function M.get_file_from_position(opts, callback)
	opts = opts or {}
	opts.bufnr = opts.bufnr or 0

	if not opts.position then
		utils.notify("get_file_from_position", {
			msg = "Position not provided",
			level = "ERROR",
		})
		return
	end

	-- TODO: use callback instead of sync function
	local params = {
		position = opts.position,
		textDocument = {
			uri = string.format("file://%s", vim.api.nvim_buf_get_name(opts.bufnr)),
		},
	}
	vim.lsp.buf_request(opts.bufnr, "textDocument/definition", params, function(err, results)
		if err then
			callback(err.message, nil)
			return
		end

		if not results then
			utils.notify("get_parent_file", {
				msg = "Couldn't get the file for the parent class",
				level = "ERROR",
			})
			return
		end

		for _, result in pairs(results) do
			-- Handle different LSP response formats
			local uri

			-- Handle array of results (typical for "textDocument/definition")
			if type(result) == "table" then
				if result.uri then
					uri = result.uri
				elseif result.targetUri then
					uri = result.targetUri
				end
			-- Handle single result
			elseif type(result) == "table" and result.uri then
				uri = result.uri
			-- Handle phpactor-style nested result
			elseif type(result) == "table" and result.result and result.result.uri then
				uri = result.result.uri
			end

			if uri then
				local path = uri:gsub("file://", "")
				callback(nil, path)
				return
			end
		end
	end)
end

---@param opts table
---@param callback fun(err: string|nil, result: any)
function M.get_parent_file(opts, callback)
	opts = opts or {}
	opts.bufnr = opts.bufnr or 0

	local filetype = parsers.get_buf_lang(opts.bufnr)
	local parser = vim.treesitter.get_parser(opts.bufnr, filetype)
	if not parser then
		utils.notify("get_parent_file", {
			msg = "No parser for the current buffer",
			level = "ERROR",
		})
		return
	end

	-- Parse the query
	-- WARNING: might have to use vim.bo.filetype instead of treesitter filetype
	local query_str = M.get_query(filetype, "parent")
	if not query_str then
		utils.notify("get_parent_file", {
			msg = string.format("Language not supported (%s)", filetype),
			level = "ERROR",
		})
		return
	end

	local query = vim.treesitter.query.parse(filetype, query_str)

	if not query then
		utils.notify("get_parent_file", {
			msg = "Failed to parse query",
			level = "ERROR",
		})
		return
	end

	-- Parse the content
	-- TODO: nil check
	local tree = parser:parse()
	if not tree then
		utils.notify("get_parent_file", {
			msg = "Failed to parse buffer content",
			level = "ERROR",
		})
		return
	end

	tree = tree[1]

	local root = tree:root()

	local result = {}

	for id, node, metadata in query:iter_captures(root, opts.bufnr) do
		local capture_name = query.captures[id]
		if capture_name == "parent" then
			local line, char = node:start()

			M.get_file_from_position(
				{ bufnr = opts.bufnr, position = { character = char, line = line } },
				function(err, filepath)
					if not filepath or filepath == "" then
						-- error already printed in get_file_from_position
						return
					end
					local defs = M.parse_file({ filename = filepath })
					for _, value in pairs(defs) do
						if value["visibility"] ~= "private" then
							table.insert(result, value)
						end
					end
				end
			)
		end
	end
	return result
end

return M
