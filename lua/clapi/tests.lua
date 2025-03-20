local ts = require("clapi.treesitter")

ts.get_file_from_position({ bufnr = 3, position = { character = 27, line = 9 } }, function(err, file)
	print("path:", file)
end)
