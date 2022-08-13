local M = {
	utils = require("ranger.action.utils"),
	transfer = require("ranger.action.transfer"),
	trash = require("ranger.action.trash"),
}
local Rifle = require("ranger.action.Rifle")
local Buffer = require("ranger.Buffer")
local vimfn = require("libp.utils.vimfn")
local path = require("libp.path")
local Stack = require("libp.datatype.Stack")
local Job = require("libp.Job")
local uv = require("libp.fs.uv")
local a = require("plenary.async")

local rifle
function M.setup(opts)
	vim.validate({ rifle_path = { opts.rifle_path, "s" } })
	rifle = Rifle(opts.rifle_path)
end

function M.toggle_expand()
	local buffer, node = M.utils.get_cur_buffer_and_node()
	buffer:toggle_expand_node(node)
end

function M.goto_parent()
	local buffer = M.utils.get_cur_buffer_and_node()
	if path.dirname(buffer.directory) == buffer.directory then
		return
	end
	local new_buffer, new = Buffer.open(path.dirname(buffer.directory), { open_cmd = "edit" })
	if new then
		local target_name = path.basename(buffer.directory)
		for i, new_node in ipairs(new_buffer:nodes()) do
			if new_node.name == target_name then
				if vim.api.nvim_get_current_buf() == new_buffer.id then
					vimfn.setrow(i)
				end
				break
			end
		end
	end
end

function M.open(open_cmd)
	vim.validate({ open_cmd = { open_cmd, "s", true } })
	open_cmd = open_cmd or "edit"
	local _, node = M.utils.get_cur_buffer_and_node()
	if node.type == "header" then
		return
	elseif node.type == "directory" then
		Buffer.open(node.abspath, { open_cmd = open_cmd })
	else
		local command = rifle:decide_open_cmd(node.abspath)
		if command then
			Job({ cmd = command:format(node.abspath), detached = true }):start()
		else
			vim.cmd(("%s %s"):format(open_cmd, node.abspath))
		end
	end
end

function M.rename()
	local buffer = M.utils.get_cur_buffer_and_node()
	buffer:edit({
		get_items = function()
			-- The result is the absolute path inferred by the node hierarchy
			-- based on the current buffer content (instead of nodes' stored
			-- absolute path). For e.g. having old and new on the left and right:
			-- a     newa
			--   b     newb
			-- The result for the old would be:
			--  {[0] = {'./a'}, [1] = {'./a/b'}}
			-- And the result for the new would be:
			--  {[0] = {'./newa'}, [1] = {'./newa/newb'}}
			local res = {}
			local lines = vim.api.nvim_buf_get_lines(buffer.id, 0, -1, true)
			local nodes = buffer.root:flatten_children()
			assert(#nodes == #lines)

			local stack = Stack({ buffer.directory })
			local level_stack = Stack({})
			for i = 1, #nodes do
				if nodes[i].type ~= "header" then
					local cur_level = nodes[i].level
					while not level_stack:empty() and level_stack:top() >= cur_level do
						stack:pop()
						level_stack:pop()
					end
					stack:push(vim.trim(lines[i]))
					level_stack:push(cur_level)
					res[cur_level] = res[cur_level] or {}
					table.insert(res[cur_level], path.join(unpack(stack)))
				end
			end
			return res
		end,
		update = function(ori_items, new_items)
			buffer:disable_fs_event_watcher()
			-- We start from the bottom level because otherwise the source path
			-- for bottom levels would become invalid when we rename the top
			-- levels.
			for level = #new_items, 0, -1 do
				-- Rename in two steps to avoid the case that the target name is in the same directory. For e.g.:
				-- `mv a b; mv b a` would not swap a and b. Instead, we should do:
				-- `mv a atmp; mv b btmp; mv atmp b; mv btmp a`.
				for _, ori_item in ipairs(ori_items[level]) do
					uv.fs_rename(ori_item, ori_item .. "copy")
				end

				-- For the target name, we don't use new_item directly as its
				-- directory name was inferred from the buffer lines while its
				-- ancestor nodes might also got renamed. In such case, the
				-- directory name is invalid at the point when we try to rename
				-- the new_item as we rename from bottom levels to top levels.
				for i, new_item in ipairs(new_items[level]) do
					uv.fs_rename(
						ori_items[level][i] .. "copy",
						path.join(path.dirname(ori_items[level][i]), path.basename(new_item))
					)
				end
			end
			buffer:enable_fs_event_watcher()
			buffer:rebuild_nodes()
			buffer:draw()
		end,
	})
end

return M
