-- Top-to-bottom orientation: levels are rows (callers above, callees below),
-- siblings side by side in their own widths, edges down into the callee;
-- v flips the view.
-- Run: nvim --headless -u NONE -l tests/vertical.lua

local here = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fn.fnamemodify(here, ':h:h')
vim.opt.runtimepath:append(root)
vim.cmd('runtime! plugin/callgraph.lua')

local util = require('callgraph.util')
local config = require('callgraph.config')
local graph_mod = require('callgraph.graph')
local layout_mod = require('callgraph.layout')
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
    selectionRange = { start = { line = line, character = 0 }, ['end'] = { line = line, character = 3 } },
  }
end
-- A wide parent over narrow children, next to a sibling subtree: the parent
-- must not overlap the sibling.
local R = item('Shop.Orders.place_order_with_a_long_name/1', 10)
local A = item('Shop.Orders.a/0', 20)
local B = item('b/0', 30)
local calls = {
  [R.name] = { A, B },
  [A.name] = { item('x/0', 1) },
}
local function fetch(node)
  local d = util.Deferred.new()
  local out = {}
  for _, it in ipairs(calls[node.name] or {}) do out[#out + 1] = { item = it, call_site = { uri = U, line = 1 } } end
  d:resolve(out)
  return d
end
local function overlaps(a, b)
  return a.row < b.row + b.height and b.row < a.row + a.height and a.col < b.col + b.width and b.col < a.col + a.width
end
local function no_overlap(lay)
  for ia, a in pairs(lay.boxes) do
    for ib, b in pairs(lay.boxes) do
      if ia < ib and overlaps(a, b) then return false end
    end
  end
  return true
end

config.set({ show_call_site = true, window = { max_name_width = 60 } })
for _, style in ipairs({ 'boxed', 'dense' }) do
  for _, dir in ipairs({ 'callout', 'callin' }) do
    local g = graph_mod.build(R, dir, { max_depth = 2 }, fetch).value
    local lay = layout_mod.layout(g, config.get(), { direction = dir, orientation = 'vertical', style = style })
    local function box(name)
      for id, n in pairs(g.nodes) do
        if n.name == name then return lay.boxes[id] end
      end
    end
    local tag = style .. ' ' .. dir
    local rb, ab, bb = box(R.name), box(A.name), box(B.name)
    if dir == 'callout' then
      check(tag .. ': callees below the root', ab.row > rb.row and bb.row > rb.row)
    else
      check(tag .. ': callers above the root', ab.row < rb.row and bb.row < rb.row)
    end
    check(tag .. ': siblings side by side on one row', ab.row == bb.row and bb.col > ab.col)
    check(tag .. ': boxes keep their own width', ab.width ~= rb.width)
    check(tag .. ': no boxes overlap', no_overlap(lay))
    local down = true
    for _, e in ipairs(lay.edges) do
      local lower
      for _, b in pairs(lay.boxes) do
        if b.row == e.arrow.row + 1 and e.arrow.col >= b.col and e.arrow.col < b.col + b.width then lower = b end
      end
      if e.arrow.dir ~= 'd' or not lower then down = false end
    end
    check(tag .. ': every arrow points down into a box', down and #lay.edges == 3, #lay.edges)
  end
end

-- Combined view: callers above the root, callees below.
local both_calls = { callin = { [R.name] = { A } }, callout = { [R.name] = { B } } }
local function both_fetch(node, dir)
  local d = util.Deferred.new()
  local out = {}
  for _, it in ipairs(both_calls[dir][node.name] or {}) do out[#out + 1] = { item = it, call_site = { uri = U, line = 1 } } end
  d:resolve(out)
  return d
end
local bg = graph_mod.build(R, 'both', { max_depth = 2 }, both_fetch).value
local bl = layout_mod.layout(bg, config.get(), { direction = 'both', orientation = 'vertical' })
local rows = {}
for id, n in pairs(bg.nodes) do rows[n.name] = bl.boxes[id].row end
check('both: caller above, root, callee below', rows[A.name] < rows[R.name] and rows[R.name] < rows[B.name])

-- v flips the view.
source_mod.make_fetch = function() return fetch end
vim.cmd('edit ' .. root .. '/tests/test.c')
view.open_with_root(R, 'callout', 'utf-16', { name = 'fake' })
vim.wait(50, function() return false end)
local function root_row_and_child_row()
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local r_row, a_row
  for i, l in ipairs(lines) do
    if l:find('place_order_with', 1, true) then r_row = r_row or i end
    if l:find('a/0', 1, true) then a_row = a_row or i end
  end
  return r_row, a_row
end
local r1, a1 = root_row_and_child_row()
check('starts left to right (callee on the root row)', r1 == a1, vim.inspect({ r1, a1 }))
view.flip()
local r2, a2 = root_row_and_child_row()
check('v flips to top to bottom (callee below)', a2 > r2, vim.inspect({ r2, a2 }))
view.flip()
local r3, a3 = root_row_and_child_row()
check('v flips back', r3 == a3, vim.inspect({ r3, a3 }))

print('---')
if failed == 0 then print('VERTICAL OK') else print('VERTICAL FAILED: ' .. failed) end
os.exit(failed == 0 and 0 or 1)
