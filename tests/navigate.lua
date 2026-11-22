-- Navigation rules on a combined graph, both orientations. Across levels
-- (h/l, or j/k when vertical) the selection goes to the nearest level,
-- preferring its parent or child, then a box level with it, then the
-- nearest; within a level it stops at the level's end. A remembered move
-- counts only along a call edge or to undo the move just made.
-- Run: nvim --headless -u NONE -l tests/navigate.lua

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
-- Horizontal, the levels are:
--   router | init retry create | place | total mailer charge stock | add rate tax post
-- create (level with router) sits two rows below place; tax, third child of
-- total, sits one row above mailer and two below total.
local L = {}
for i, n in ipairs({ 'place', 'total', 'mailer', 'charge', 'stock', 'add', 'rate', 'tax', 'post', 'init', 'retry', 'create', 'router' }) do
  L[n] = item(n, i * 10)
end
local out = { place = { L.total, L.mailer, L.charge, L.stock }, total = { L.add, L.rate, L.tax }, charge = { L.post } }
local inc = { place = { L.init, L.retry, L.create }, create = { L.router } }
source_mod.make_fetch = function()
  return function(node, direction)
    local d = util.Deferred.new()
    local list = {}
    for _, it in ipairs(((direction == 'callin') and inc or out)[node.name] or {}) do
      list[#list + 1] = { item = it, call_site = { uri = U, line = 1 } }
    end
    d:resolve(list)
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
local function open(orientation, style)
  config.set({ show_call_site = false, window = { style = style, orientation = orientation } })
  vim.cmd('edit ' .. root .. '/tests/test.c')
  view.open_with_root(L.place, 'both', 'utf-16', { name = 'fake' })
  vim.wait(50, function() return false end)
end

for _, style in ipairs({ 'dense', 'boxed' }) do
  -- Horizontal: h/l cross levels, j/k stay in the column.
  open('horizontal', style)
  local path = walk({ 'left', 'down', 'down', 'left' })
  check(style .. ': to router', path == 'init retry create router', path)
  path = walk({ 'right', 'right' })
  check(style .. ': l never skips a column: create -> place, not mailer', path == 'create place', path)
  check(style .. ': j/k on the root, alone in its column, do not move', walk({ 'down', 'up' }) == 'place place')
  path = walk({ 'right', 'down', 'down', 'down', 'down' })
  check(style .. ': j stops at the column end', path == 'total mailer charge stock stock', path)
  check(style .. ': h from a later child goes to its parent', walk({ 'left' }) == 'place')
  -- place remembers stock, the child it was left from.
  path = walk({ 'right', 'up', 'up', 'up', 'right', 'down', 'down', 'left' })
  check(style .. ': h from tax goes to its parent total, not to mailer, nearer below',
    path == 'stock charge mailer total add rate tax total', path)
  -- From a leaf, l goes to the nearest box in the next column (ties: the upper).
  path = walk({ 'down', 'right' })
  check(style .. ': l from a leaf goes to the nearest box in the next column', path == 'mailer tax', path)
  -- tax remembers mailer, but neither an edge nor the last move: h goes to
  -- tax's parent.
  path = walk({ 'up', 'down', 'left' })
  check(style .. ': a stale remembered move is ignored', path == 'rate tax total', path)
  -- Undoing the last move returns, edge or not.
  path = walk({ 'down', 'right', 'left' })
  check(style .. ': undoing the last move returns, edge or not', path == 'mailer tax mailer', path)
  view.close()

  -- Vertical: j/k cross levels, h/l stay in the row.
  open('vertical', style)
  path = walk({ 'up', 'right', 'right', 'up' })
  check(style .. ': vertical: k to the callers, l along them, k to router', path == 'init retry create router', path)
  path = walk({ 'down', 'down' })
  check(style .. ': vertical: j never skips a row', path == 'create place', path)
  check(style .. ': vertical: h/l on the root do not move', walk({ 'left', 'right' }) == 'place place')
  path = walk({ 'down', 'right', 'right', 'up', 'down' })
  check(style .. ': vertical: along the callees, k to the parent, j back to the child it was left from',
    path == 'total mailer charge place charge', path)
  view.close()
end

print('---')
if failed == 0 then print('NAVIGATE OK') else print('NAVIGATE FAILED: ' .. failed) end
os.exit(failed == 0 and 0 or 1)
