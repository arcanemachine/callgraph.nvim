-- Box labels in the layout: the name row's own width limit (max_func_width).
-- Run: nvim --headless -u NONE -l tests/labels.lua

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

local function item(name, file, line)
  return {
    name = name, kind = 12, uri = 'file:///proj/lib/' .. file,
    range = { start = { line = line, character = 0 }, ['end'] = { line = line + 4, character = 0 } },
    selectionRange = { start = { line = line, character = 0 }, ['end'] = { line = line, character = 3 } },
  }
end

local long_fn = 'MyApp.Accounts.update_account_preferences_for_user/2' -- last part: 37 chars
local root_item = item('MyApp.Orders.place/1', 'my_app/orders.ex', 10)
local caller = item(long_fn, 'my_app/accounts.ex', 20)
local function fetch(node)
  local d = util.Deferred.new()
  d:resolve(node.name == root_item.name and { { item = caller, call_site = { uri = caller.uri, line = 21 } } } or {})
  return d
end
local graph = graph_mod.build(root_item, 'callin', { max_depth = 4 }, fetch).value

local function caller_box(opts)
  config.set(opts)
  local lay = layout_mod.layout(graph, config.get(), { direction = 'callin' })
  for id, b in pairs(lay.boxes) do
    if graph.nodes[id].name == long_fn then return b end
  end
end

local b = caller_box({ window = { max_name_width = 20 } })
check('name row falls back to max_name_width', b and b.text:match('^…') ~= nil, b and b.text)
b = caller_box({ window = { max_name_width = 20, max_func_width = 40 } })
check('max_func_width keeps a long name whole', b and b.text:match('^update_account_preferences_for_user/2') ~= nil, b and b.text)
check('max_func_width leaves the container to max_name_width', b and b.line1:match('^MyApp.Accounts') ~= nil, b and b.line1)

print('---')
if failed == 0 then print('LABELS OK') else print('LABELS FAILED: ' .. failed) end
os.exit(failed == 0 and 0 or 1)
