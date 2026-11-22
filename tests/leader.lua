-- With <Space> as the leader, leader mappings work inside the view: no view
-- key takes <Space> by default.
-- Run: nvim --headless -u NONE -l tests/leader.lua

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

local U = 'file://' .. root .. '/tests/test.c'
local a = {
  name = 'a', kind = 12, uri = U,
  range = { start = { line = 10, character = 0 }, ['end'] = { line = 14, character = 0 } },
  selectionRange = { start = { line = 10, character = 0 }, ['end'] = { line = 10, character = 1 } },
}
source_mod.make_fetch = function()
  return function()
    local d = util.Deferred.new()
    d:resolve({})
    return d
  end
end
source_mod.check_available = function() end
source_mod.resolve_root = function() return a, 'utf-16', { name = 'fake' } end

vim.g.mapleader = ' '
local ran = false
vim.keymap.set('n', '<leader>z', function() ran = true end)

config.set({ show_call_site = false })
vim.cmd('edit ' .. root .. '/tests/test.c')
view.open('both')
vim.wait(200, function() return false end)
check('in the view', vim.wo.winbar ~= '')
-- A buffer map on <Space> with nowait fires before a leader mapping can.
local m = vim.fn.maparg(' ', 'n', false, true)
check('the view maps nothing on <Space>', m.buffer ~= 1, vim.inspect(m))
vim.api.nvim_feedkeys(vim.keycode('<leader>z'), 'x', false)
check('a <Space> leader mapping runs inside the view', ran)

print('---')
if failed == 0 then print('LEADER OK') else print('LEADER FAILED: ' .. failed) end
os.exit(failed == 0 and 0 or 1)
