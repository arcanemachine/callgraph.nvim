-- The view opens along the editor's edge, whichever pane it is opened from:
-- the bottom at full width, or the right at full height.
-- Run: nvim --headless -u NONE -l tests/placement.lua

local here = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fn.fnamemodify(here, ':h:h')
vim.opt.runtimepath:append(root)
vim.cmd('runtime! plugin/callgraph.lua')

local util = require('callgraph.util')
local config = require('callgraph.config')
local source_mod = require('callgraph.source')
local view = require('callgraph.view')

local failed = 0
local function check(name, cond, detail)
  if cond then print('PASS ' .. name) else failed = failed + 1; print('FAIL ' .. name .. (detail and (' :: ' .. tostring(detail)) or '')) end
end

-- Every other split window (not floats): { top, left, height, width }.
local function others(view_win)
  local out = {}
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if w ~= view_win and vim.api.nvim_win_get_config(w).relative == '' then
      local p = vim.api.nvim_win_get_position(w)
      out[#out + 1] = { p[1], p[2], vim.api.nvim_win_get_height(w), vim.api.nvim_win_get_width(w) }
    end
  end
  return out
end
local function all(list, pred)
  for _, x in ipairs(list) do if not pred(x) then return false end end
  return #list > 0
end

local U = 'file://' .. root .. '/tests/test.c'
local main = {
  name = 'main', kind = 12, uri = U,
  range = { start = { line = 32, character = 0 }, ['end'] = { line = 36, character = 0 } },
  selectionRange = { start = { line = 32, character = 0 }, ['end'] = { line = 32, character = 4 } },
}
source_mod.make_fetch = function()
  return function()
    local d = util.Deferred.new()
    d:resolve({})
    return d
  end
end

vim.cmd('edit ' .. root .. '/tests/test.c')
vim.cmd('vsplit') -- two panes side by side; open from the left one
local pane = vim.api.nvim_get_current_win()

config.set({ window = { position = 'bottom', fixed_height = 10 } })
view.open_with_root(main, 'callout', 'utf-16', { name = 'fake' })
vim.wait(50, function() return false end)
local w = vim.api.nvim_get_current_win()
local pos = vim.api.nvim_win_get_position(w)
check('bottom: full width', vim.api.nvim_win_get_width(w) == vim.o.columns, vim.api.nvim_win_get_width(w))
check('bottom: below both panes', all(others(w), function(o) return o[1] + o[3] <= pos[1] end), vim.inspect(others(w)))
check('bottom: its height', vim.api.nvim_win_get_height(w) == 10, vim.api.nvim_win_get_height(w))
view.close()

vim.api.nvim_set_current_win(pane)
config.set({ window = { position = 'right', fixed_width = 30 } })
view.open_with_root(main, 'callout', 'utf-16', { name = 'fake' })
vim.wait(50, function() return false end)
w = vim.api.nvim_get_current_win()
pos = vim.api.nvim_win_get_position(w)
check('right: right of both panes, as tall as they are', all(others(w), function(o)
  return o[2] + o[4] <= pos[2] and o[3] <= vim.api.nvim_win_get_height(w)
end), vim.inspect(others(w)))
check('right: along the right edge', pos[2] + vim.api.nvim_win_get_width(w) == vim.o.columns, vim.inspect(pos))

print('---')
if failed == 0 then print('PLACEMENT OK') else print('PLACEMENT FAILED: ' .. failed) end
os.exit(failed == 0 and 0 or 1)
