local utils = require("clapi.utils")
local async = require("plenary.async")
local parsers = require("nvim-treesitter.parsers")
-- Treesitter Parser Module
local M = {}

local async = require("plenary.async")

---@param opts table
---@param callback function|nil Optional callback function
---@return function|nil Async function when no callback is provided
function M.parse_file(opts, callback)
	local function execute(cb)
		if opts.filename and opts.bufnr then
			utils.notify("parse_file", {
				msg = "filename and bufnr params can't be used at the same time",
				level = "ERROR",
			})
			cb(nil)
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
				cb(nil)
				return
			end
			opts.filetype = filetype
		end

		if opts.filetype == "" then
			utils.notify("parse_file", {
				msg = "No language detected",
				level = "ERROR",
			})
			cb(nil)
			return
		end

		opts.query_str = opts.query_str or M.get_query(opts.filetype, "locals")

		if not opts.query_str then
			utils.notify("parse_file", {
				msg = string.format("Language not supported (%s)", opts.filetype),
				level = "ERROR",
			})
			cb(nil)
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
			cb(nil)
			return
		end

		-- Parse the query
		local query = vim.treesitter.query.parse(opts.filetype, opts.query_str)
		if not query then
			utils.notify("treesitter.parse_file", {
				msg = "Failed to parse query",
				level = "ERROR",
			})
			cb({})
			return
		end

		-- Parse the content
		local tree = parser:parse()
		if not tree then
			utils.notify("treesitter.parse_file", {
				msg = "Failed to parse buffer content",
				level = "ERROR",
			})
			cb(nil)
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

		-- This is where we use the async get_parent_file
		M.get_parent_file({ bufnr = opts.bufnr }, function(parent_defs)
			if parent_defs then
				for _, value in pairs(parent_defs) do
					table.insert(result, value)
				end
			end
			-- Return the final result with parent definitions included
			cb(result)
		end)
	end

	-- If callback is provided, execute directly
	if callback then
		execute(callback)
		return nil
	end

	-- Otherwise return an async function that can be awaited
	return async.wrap(execute, 1)
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
---@param callback function|nil Optional callback function
---@return function|nil Async function when no callback is provided
function M.get_file_from_position(opts, callback)
	opts = opts or {}
	opts.bufnr = opts.bufnr or 0

	local function process_result(result)
		if not result then
			return nil
		end

		for _, server_result in pairs(result) do
			-- Handle different LSP response formats
			local uri
			local res = server_result.result

			-- Handle array of results (typical for "textDocument/definition")
			if type(res) == "table" and res[1] ~= nil then
				if res[1].uri then
					uri = res[1].uri
				elseif res[1].targetUri then
					uri = res[1].targetUri
				end
			-- Handle single result
			elseif type(res) == "table" and res.uri then
				uri = res.uri
			-- Handle phpactor-style nested result
			elseif type(res) == "table" and res.result and res.result.uri then
				uri = res.result.uri
			end

			if uri then
				return uri:gsub("file://", "")
			end
		end

		return nil
	end

	local function execute(cb)
		if not opts.position then
			utils.notify("get_file_from_position", {
				msg = "Position not provided",
				level = "ERROR",
			})
			cb(nil)
			return
		end

		local params = {
			position = opts.position,
			textDocument = {
				uri = string.format("file://%s", vim.api.nvim_buf_get_name(opts.bufnr)),
			},
		}

		vim.lsp.buf_request(opts.bufnr, "textDocument/definition", params, function(err, result, _, _)
			if err or not result then
				utils.notify("get_parent_file", {
					msg = "Couldn't get the file for the parent class",
					level = "ERROR",
				})
				cb(nil)
				return
			end

			local file_path = process_result(result)
			cb(file_path)
		end)
	end

	-- If callback is provided, execute directly
	if callback then
		execute(callback)
		return nil
	end

	-- Otherwise return an async function that can be awaited
	return async.wrap(execute, 1)
end

---@param opts table
---@param callback function|nil Optional callback function
---@return function|nil Async function when no callback is provided
function M.get_parent_file(opts, callback)
	opts = opts or {}
	opts.bufnr = opts.bufnr or 0

	local function execute(cb)
		local filetype = parsers.get_buf_lang(opts.bufnr)
		local parser = vim.treesitter.get_parser(opts.bufnr, filetype)
		if not parser then
			utils.notify("get_parent_file", {
				msg = "No parser for the current buffer",
				level = "ERROR",
			})
			cb(nil)
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
			cb(nil)
			return
		end

		local query = vim.treesitter.query.parse(filetype, query_str)

		if not query then
			utils.notify("get_parent_file", {
				msg = "Failed to parse query",
				level = "ERROR",
			})
			cb(nil)
			return
		end

		-- Parse the content
		local tree = parser:parse()
		if not tree then
			utils.notify("get_parent_file", {
				msg = "Failed to parse buffer content",
				level = "ERROR",
			})
			cb(nil)
			return
		end

		tree = tree[1]
		local root = tree:root()

		-- We'll use this to track our async operations
		local pending_operations = 0
		local result = {}
		local has_error = false

		-- If no captures are found, we still want to call the callback
		local has_captures = false

		for id, node, metadata in query:iter_captures(root, opts.bufnr) do
			local capture_name = query.captures[id]
			if capture_name == "parent" then
				has_captures = true
				local line, char = node:start()

				pending_operations = pending_operations + 1

				-- Call the async version of get_file_from_position
				M.get_file_from_position({
					bufnr = opts.bufnr,
					position = { character = char, line = line },
				}, function(p)
					if has_error then
						-- Skip processing if we already encountered an error
						pending_operations = pending_operations - 1
						if pending_operations == 0 then
							cb(nil)
						end
						return
					end

					if not p or p == "" then
						-- Error already printed in get_file_from_position
						has_error = true
						pending_operations = pending_operations - 1
						if pending_operations == 0 then
							cb(nil)
						end
						return
					end

					local defs = M.parse_file({ filename = p })
					for _, value in pairs(defs) do
						if value["visibility"] ~= "private" then
							table.insert(result, value)
						end
					end

					pending_operations = pending_operations - 1
					if pending_operations == 0 then
						cb(result)
					end
				end)
			end
		end

		-- If no captures were found, return an empty result
		if not has_captures then
			cb({})
		end
	end

	-- If callback is provided, execute directly
	if callback then
		execute(callback)
		return nil
	end

	-- Otherwise return an async function that can be awaited
	return async.wrap(execute, 1)
end

-- -- Async version that works with plenary.async.run
-- M.get_parent_file_async = async.void(function(opts)
-- 	return async.await(M.get_parent_file(opts))
-- end)

return M
