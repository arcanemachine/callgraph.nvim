-- ? opens a float listing the keys as configured; ?, q or Esc closes it.
-- The tab bar ends with a clickable "? keys" hint that opens it too.
-- Run: nvim --headless -u NONE -l tests/help.lua

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
local main = {
  name = 'main', kind = 12, uri = U,
  range = { start = { line = 32, character = 0 }, ['end'] = { line = 36, character = 0 } },
  selectionRange = { start = { line = 32, character = 0 }, ['end'] = { line = 32, character = 4 } },
}
local helper = vim.deepcopy(main)
helper.name = 'helper'
helper.selectionRange.start.line, helper.range.start.line = 20, 20
source_mod.make_fetch = function()
  return function(node)
    local d = util.Deferred.new()
    d:resolve(node.name == 'main' and { { item = helper, call_site = { uri = U, line = 33 } } } or {})
    return d
  end
end
local function press(keys) vim.api.nvim_feedkeys(vim.keycode(keys), 'x', false) end
local function help_win()
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    local c = vim.api.nvim_win_get_config(w)
    if c.relative ~= '' then
      local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, -1, false)
      if table.concat(lines, '\n'):find('this help', 1, true) then return w, lines end
    end
  end
end
local function has_row(lines, keys, what)
  for _, l in ipairs(lines or {}) do
    if l:match('^ ' .. vim.pesc(keys) .. '%s+' .. vim.pesc(what)) then return true end
  end
  return false
end

-- A remapped key shows as configured; a disabled one is left out.
config.set({ show_call_site = false, keymaps = { reroot = 'gr', refresh = '' } })
vim.cmd('edit ' .. root .. '/tests/test.c')
view.open_with_root(main, 'callout', 'utf-16', { name = 'fake' })
vim.wait(200, function() return false end)
local graph_win = vim.api.nvim_get_current_win()

local wb = vim.wo[graph_win].winbar
check('tab bar ends with a clickable ? keys hint', wb:find('%@v:lua.callgraph_help_click@? keys%X', 1, true) ~= nil, wb)

for _, key in ipairs({ '?', 'q', '<Esc>' }) do
  press('?')
  local w, lines = help_win()
  check('? opens the help (then ' .. key .. ')', w ~= nil and vim.api.nvim_get_current_win() == w)
  if key == '?' then
    check('the help lists the keys as configured', has_row(lines, 'h j k l', 'move the selection')
      and has_row(lines, 'gr', 'new graph on the selected function') and has_row(lines, 'K', 'docs'), table.concat(lines or {}, '\n'))
    check('a disabled key is left out', not table.concat(lines or {}, '\n'):find('refresh', 1, true))
  end
  press(key)
  check(key .. ' closes the help, back in the view', help_win() == nil and vim.api.nvim_get_current_win() == graph_win
    and vim.api.nvim_win_is_valid(graph_win))
end

-- Leaving the help closes it.
press('?')
vim.api.nvim_set_current_win(graph_win)
check('leaving the help closes it', help_win() == nil)

-- Clicks with the view focused go through its own mouse mapping.
local real_pos = vim.fn.getmousepos
local function click(pos)
  vim.api.nvim_set_current_win(graph_win)
  vim.fn.getmousepos = function() return vim.tbl_extend('keep', pos, { winid = graph_win, line = 0, column = 0 }) end
  view.on_mouse(1)
  vim.fn.getmousepos = real_pos
end
click({ winrow = 1, wincol = vim.api.nvim_win_get_width(graph_win) })
check('a click on the hint opens the help', help_win() ~= nil)
press('q')
local before = vim.fn.expand('<cword>')
click({ winrow = 1, wincol = 2 })
check('a click on the tabs opens nothing and keeps the selection',
  help_win() == nil and vim.fn.expand('<cword>') == before, vim.fn.expand('<cword>'))
local lnum = vim.fn.search('helper', 'n')
local col = vim.fn.charidx(vim.fn.getline(lnum), vim.fn.match(vim.fn.getline(lnum), 'helper')) + 1
click({ winrow = 2, line = lnum, column = col })
check('a click below the tab bar still selects a box', vim.fn.expand('<cword>') == 'helper', vim.fn.expand('<cword>'))

-- From another window the click goes through the %@ handler; a second
-- click (a double-click) keeps the help open.
_G.callgraph_help_click()
_G.callgraph_help_click()
check('clicking the hint twice leaves the help open', help_win() ~= nil)

print('---')
if failed == 0 then print('HELP OK') else print('HELP FAILED: ' .. failed) end
os.exit(failed == 0 and 0 or 1)
