-- Combined view ('both'): callers fan out left of the root, callees right;
-- each side expands in its own direction.
-- Run: nvim --headless -u NONE -l tests/both.lua

local here = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fn.fnamemodify(here, ':h:h')
vim.opt.runtimepath:append(root)

local util = require('callgraph.util')
local config = require('callgraph.config')
local graph_mod = require('callgraph.graph')
local layout_mod = require('callgraph.layout')

local failed = 0
local function check(name, cond, detail)
  if cond then print('PASS ' .. name) else failed = failed + 1; print('FAIL ' .. name .. (detail and (' :: ' .. tostring(detail)) or '')) end
end

local function item(name, line)
  return {
    name = name, kind = 12, uri = 'file:///proj/lib/x.ex',
    range = { start = { line = line, character = 0 }, ['end'] = { line = line + 4, character = 0 } },
    selectionRange = { start = { line = line, character = 0 }, ['end'] = { line = line, character = 3 } },
  }
end
-- place/1 is called by create/2 and retry/1, and calls insert/1 and retry/1:
-- retry/1 sits on both sides (mutual recursion).
local R = item('Shop.Orders.place/1', 10)
local callers = {
  [R.name] = { item('ShopWeb.OrderController.create/2', 20), item('Shop.Jobs.retry/1', 30) },
  ['ShopWeb.OrderController.create/2'] = { item('ShopWeb.Router.call/2', 5) },
  ['ShopWeb.Router.call/2'] = { item('Plug.Conn.run/1', 1) },
}
local callees = {
  [R.name] = { item('Shop.Repo.insert/1', 40), item('Shop.Jobs.retry/1', 30) },
  ['Shop.Repo.insert/1'] = { item('Ecto.Repo.insert/2', 1) },
}
local asked = {}
local function fetch(node, dir)
  asked[#asked + 1] = node.name .. ' ' .. dir
  local d = util.Deferred.new()
  local out = {}
  for _, it in ipairs((dir == 'callin' and callers or callees)[node.name] or {}) do
    out[#out + 1] = { item = it, call_site = { uri = it.uri, line = 1 } }
  end
  d:resolve(out)
  return d
end

local g = graph_mod.build(R, 'both', { max_depth = 2 }, fetch).value
local function find(name, side)
  for _, n in pairs(g.nodes) do
    if n.name == name and n.side == side then return n end
  end
end

check('root fetches both directions', vim.tbl_contains(asked, R.name .. ' callin') and vim.tbl_contains(asked, R.name .. ' callout'))
check('callers are on the callin side', find('ShopWeb.OrderController.create/2', 'callin') ~= nil)
check('callees are on the callout side', find('Shop.Repo.insert/1', 'callout') ~= nil)
local r_in, r_out = find('Shop.Jobs.retry/1', 'callin'), find('Shop.Jobs.retry/1', 'callout')
check('a caller that is also a callee gets one node per side', r_in and r_out and r_in.id ~= r_out.id)
check('a side expands in its own direction',
  vim.tbl_contains(asked, 'ShopWeb.OrderController.create/2 callin') and vim.tbl_contains(asked, 'Shop.Repo.insert/1 callout')
  and not vim.tbl_contains(asked, 'Shop.Repo.insert/1 callin'))
check('descendants inherit the side', find('ShopWeb.Router.call/2', 'callin') ~= nil and find('Ecto.Repo.insert/2', 'callout') ~= nil)
check('depth counts per side', g.max_visible_in == 2 and g.max_visible_out == 2, vim.inspect({ g.max_visible_in, g.max_visible_out }))
check('nodes past the depth are hidden', not find('Plug.Conn.run/1', 'callin').visible)

config.set({ show_call_site = true })
local lay = layout_mod.layout(g, config.get(), { direction = 'both' })
local function box(name, side)
  local n = name == R.name and g.root or find(name, side)
  return lay.boxes[n.id]
end
local rb = box(R.name)
check('callers are left of the root', box('ShopWeb.OrderController.create/2', 'callin').col < rb.col)
check('callers of callers are further left',
  box('ShopWeb.Router.call/2', 'callin').col < box('ShopWeb.OrderController.create/2', 'callin').col)
check('callees are right of the root', box('Shop.Repo.insert/1', 'callout').col > rb.col)
check('both sides start at the root row', box('ShopWeb.OrderController.create/2', 'callin').row == rb.row
  and box('Shop.Repo.insert/1', 'callout').row == rb.row)
local function overlaps(a, b)
  return a.row < b.row + b.height and b.row < a.row + a.height and a.col < b.col + b.width and b.col < a.col + a.width
end
local clash
for ia, a in pairs(lay.boxes) do
  for ib, b in pairs(lay.boxes) do
    if ia < ib and overlaps(a, b) then clash = ia .. ' / ' .. ib end
  end
end
check('no boxes overlap', clash == nil, clash)
local arrows_right = true
for _, e in ipairs(lay.edges) do
  if e.arrow.dir ~= 'r' then arrows_right = false end
end
check('every arrow points right, at the callee', arrows_right and #lay.edges == 6, #lay.edges)

-- Expanding the root's hidden side: collapse then expand toggles both sides.
graph_mod.collapse_subtree(g, g.root)
check('collapsing the root hides both sides', not find('ShopWeb.OrderController.create/2', 'callin').visible
  and not find('Shop.Repo.insert/1', 'callout').visible)
graph_mod.expand_sync(g, g.root, fetch)
check('expanding the root shows both sides', find('ShopWeb.OrderController.create/2', 'callin').visible
  and find('Shop.Repo.insert/1', 'callout').visible)

-- A directly recursive root is its own caller and callee: a cycle leaf on each side.
local loop = item('Shop.Tree.walk/1', 60)
local function self_fetch()
  local d = util.Deferred.new()
  d:resolve({ { item = loop, call_site = { uri = loop.uri, line = 61 } } })
  return d
end
local lg = graph_mod.build(loop, 'both', { max_depth = 2 }, self_fetch).value
local cyc_sides = {}
for _, n in pairs(lg.nodes) do
  if n.is_cycle then cyc_sides[#cyc_sides + 1] = n.side end
end
table.sort(cyc_sides)
check('a recursive root gets a cycle leaf on each side', vim.deep_equal(cyc_sides, { 'callin', 'callout' }), vim.inspect(cyc_sides))

print('---')
if failed == 0 then print('BOTH OK') else print('BOTH FAILED: ' .. failed) end
os.exit(failed == 0 and 0 or 1)
