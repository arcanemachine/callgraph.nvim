-- Dense style: one borderless row per box (`container.name ❯`), edges from
-- each text's end into the column's shared channel, the cursor on the name,
-- a one-row float over a shortened box, and D switching styles.
-- Run: nvim --headless -u NONE -l tests/dense.lua

local here = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fn.fnamemodify(here, ':h:h')
vim.opt.runtimepath:append(root)
vim.cmd('runtime! plugin/callgraph.lua')

local util = require('callgraph.util')
local config = require('callgraph.config')
local graph_mod = require('callgraph.graph')
local layout_mod = require('callgraph.layout')
local render_mod = require('callgraph.render')
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
-- Callers of different lengths into one function (callin).
local R = item('Shop.Orders.place/1', 10)
local callers = {
  [R.name] = { item('ShopWeb.OrderController.create/2', 20), item('Shop.Jobs.retry/1', 30), item('Cli.run/0', 40) },
}
local function fetch(node)
  local d = util.Deferred.new()
  local out = {}
  for _, it in ipairs(callers[node.name] or {}) do out[#out + 1] = { item = it, call_site = { uri = U, line = 1 } } end
  d:resolve(out)
  return d
end
local g = graph_mod.build(R, 'callin', { max_depth = 2 }, fetch).value
config.set({ show_call_site = true, window = { style = 'dense', max_name_width = 40 } })
local lay = layout_mod.layout(g, config.get(), { direction = 'callin' })

local function box_of(name)
  for id, n in pairs(g.nodes) do
    if n.name == name then return lay.boxes[id] end
  end
end
local create, retry, run, place = box_of('ShopWeb.OrderController.create/2'), box_of('Shop.Jobs.retry/1'), box_of('Cli.run/0'), box_of(R.name)
check('a dense box is one row', create.height == 1 and place.height == 1)
check('dense text is container.name', create.text == 'ShopWeb.OrderController.create/2', create.text)
check('name offset skips the container and separator', create.name_offset == #'ShopWeb.OrderController.', create.name_offset)
check('siblings stack on consecutive rows', retry.row == create.row + 1 and run.row == retry.row + 1)
check('boxes in a column share its width', create.width == retry.width and retry.width == run.width)

-- Each caller's edge starts one blank after its own text and meets the
-- others in the column's channel.
local starts, channel = {}, {}
for _, e in ipairs(lay.edges) do
  local first = e.segments[1]
  starts[first.r1] = first.c1
  for _, s in ipairs(e.segments) do
    if s.dir == 'v' then channel[s.c1] = true end
  end
end
check('edge starts one blank after the text', starts[create.row] == create.text_end + 2 and starts[run.row] == run.text_end + 2,
  vim.inspect({ starts, create.text_end, run.text_end }))
check('all edges turn in one shared channel', vim.tbl_count(channel) == 1, vim.inspect(channel))

-- Render: the anchor (cursor) sits on the name, after the container.
local buf = vim.api.nvim_create_buf(false, true)
render_mod.render(buf, lay, g, { selected_id = g.root.id, highlights = config.get().highlights })
local create_id
for id, n in pairs(g.nodes) do
  if n.name == 'ShopWeb.OrderController.create/2' then create_id = id end
end
local mark = lay.box_marks[create_id]
local pos = vim.api.nvim_buf_get_extmark_by_id(buf, render_mod.anchor_ns, mark, {})
local line = vim.api.nvim_buf_get_lines(buf, pos[1], pos[1] + 1, false)[1]
check('anchor on the name', line:sub(pos[2] + 1, pos[2] + #'create/2') == 'create/2', line)
local text_line = vim.api.nvim_buf_get_lines(buf, create.row - 1, create.row, false)[1]
check('text and line drawn with a blank between', text_line:find('create/2 ─', 1, true) ~= nil, text_line)

-- View: the float over a shortened dense box is one row with no border.
source_mod.make_fetch = function() return fetch end
vim.cmd('edit ' .. root .. '/tests/test.c')
config.set({ show_call_site = true, window = { style = 'dense', max_name_width = 10, position = 'bottom', fixed_height = 20 } })
view.open_with_root(R, 'callin', 'utf-16', { name = 'fake' })
vim.wait(200, function() return false end)
local function zoom_win()
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    local c = vim.api.nvim_win_get_config(w)
    if c.relative ~= '' and c.zindex == 50 then return w end
  end
end
-- The root `Shop.Orders.place/1` fits 10 (`Shop.Orders` is 11 → `S.Orders`):
-- shortened. Move to `Cli.run/0`: fits, and its hidden location alone
-- doesn't count.
local zw = zoom_win()
check('float on a shortened dense box', zw ~= nil)
if zw then
  local c = vim.api.nvim_win_get_config(zw)
  local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(zw), 0, -1, false)
  check('dense float is one row, no border', c.height == 1 and (c.border == nil or c.border == 'none' or vim.tbl_isempty(c.border)
    or vim.tbl_isempty(vim.tbl_filter(function(x) return x ~= '' end, c.border))), vim.inspect(c.border))
  check('dense float shows the full name', lines[1] == 'Shop.Orders.place/1', lines[1])
  check('dense float anchored on the text start', c.bufpos and c.row == 0 and c.col == 0)
end
for _ = 1, 3 do
  view.move('left')
  local cur = vim.api.nvim_get_current_line()
  if cur:find('Cli.run/0', 1, true) then break end
end
for _ = 1, 3 do
  if vim.api.nvim_get_current_line():find('Cli.run/0', 1, true) and vim.fn.expand('<cWORD>'):find('run/0', 1, true) then break end
  view.move('down')
end
check('no float on an unshortened dense box (location alone does not count)', zoom_win() == nil,
  vim.api.nvim_get_current_line())

-- D switches the view to boxed and back.
view.toggle_style()
local boxed_line = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
check('D switches to boxed', boxed_line:find('╭', 1, true) ~= nil)
view.toggle_style()
local dense_line = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
check('D switches back to dense', dense_line:find('╭', 1, true) == nil and dense_line:find('Cli.run/0', 1, true) ~= nil)

print('---')
if failed == 0 then print('DENSE OK') else print('DENSE FAILED: ' .. failed) end
os.exit(failed == 0 and 0 or 1)
