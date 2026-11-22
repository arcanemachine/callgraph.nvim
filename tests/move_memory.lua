-- Moving back the way the selection came returns to the box it came from,
-- not to the nearest one; a click, a rebuild or a flip forgets the moves.
-- Run: nvim --headless -u NONE -l tests/move_memory.lua

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
local function item(name, line)
  return {
    name = name, kind = 12, uri = U,
    range = { start = { line = line, character = 0 }, ['end'] = { line = line + 4, character = 0 } },
    selectionRange = { start = { line = line, character = 0 }, ['end'] = { line = line, character = #name } },
  }
end
-- Callers of x: p1..p4 in one column; q calls p3 from the column before.
-- Laid out right to left: q | p1..p4 | x, with x level with p1.
local callers = {
  x = { item('p1', 10), item('p2', 20), item('p3', 30), item('p4', 40) },
  p3 = { item('q', 50) },
}
source_mod.make_fetch = function()
  return function(node)
    local d = util.Deferred.new()
    local out = {}
    for _, it in ipairs(callers[node.name] or {}) do out[#out + 1] = { item = it, call_site = { uri = U, line = 1 } } end
    d:resolve(out)
    return d
  end
end
local function word() return vim.fn.expand('<cword>') end
local function walk(keys)
  local seen = {}
  for _, k in ipairs(keys) do
    view.move(k)
    seen[#seen + 1] = word()
  end
  return table.concat(seen, ' ')
end

for _, style in ipairs({ 'boxed', 'dense' }) do
  config.set({ show_call_site = false, window = { style = style } })
  vim.cmd('edit ' .. root .. '/tests/test.c')
  view.open_with_root(item('x', 1), 'callin', 'utf-16', { name = 'fake' })
  vim.wait(50, function() return false end)

  -- Without memory, left from x lands on p1, the box level with it.
  check(style .. ': left from x, fresh, goes to p1', walk({ 'left' }) == 'p1', word())
  -- From q: right to p3, right to x, then back left twice retraces the path.
  local path = walk({ 'down', 'down', 'left', 'right', 'right', 'left', 'left' })
  check(style .. ': right, right, left, left retraces the path', path == 'p2 p3 q p3 x p3 q', path)

  -- A parent remembers the child it was left from: right to x, then left
  -- returns to p3, not to p1 level with x.
  path = walk({ 'right', 'right', 'left' })
  check(style .. ': a parent returns to the child it was left from', path == 'p3 x p3', path)
  walk({ 'right' })

  -- The selection jumping some other way forgets the moves: a flip there
  -- and back, a rebuild (r, + / -), a click.
  local function forgets(what, jump)
    walk({ 'left', 'down', 'right' }) -- x remembers a child below p1
    jump()
    check(style .. ': ' .. what .. ' forgets the moves', walk({ 'left' }) == 'p1', word())
    walk({ 'right' })
  end
  forgets('flip', function() view.flip(); view.flip() end)
  forgets('rebuild', function()
    view.rebuild()
    vim.wait(50, function() return false end)
  end)
  forgets('click', function()
    local lnum = vim.fn.search('\\<x\\>', 'n')
    local line = vim.fn.getline(lnum)
    local col = vim.fn.charidx(line, vim.fn.match(line, '\\<x\\>')) + 1
    local real = vim.fn.getmousepos
    vim.fn.getmousepos = function() return { line = lnum, column = col } end
    view.on_mouse(1)
    vim.fn.getmousepos = real
  end)
  view.close()
end

print('---')
if failed == 0 then print('MOVE MEMORY OK') else print('MOVE MEMORY FAILED: ' .. failed) end
os.exit(failed == 0 and 0 or 1)
