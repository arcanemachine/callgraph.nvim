-- The root (the function the graph was opened on) has its name marked with
-- the root group, on top of its color, in both styles and color modes and
-- in the focus float; no other box gets it.
-- Run: nvim --headless -u NONE -l tests/root_mark.lua

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
local place = item('Shop.Orders.place/1', 10)
local calls = {
  [place.name] = { item('Shop.Cart.total/1', 20), item('Shop.Mail.send/1', 30) },
}
local function fetch(node)
  local d = util.Deferred.new()
  local out = {}
  for _, it in ipairs(calls[node.name] or {}) do out[#out + 1] = { item = it, call_site = { uri = U, line = 1 } } end
  d:resolve(out)
  return d
end

require('callgraph').setup({})
local hl_def = vim.api.nvim_get_hl(0, { name = 'CallgraphRoot' })
check('root group is bold and underlined, with no color of its own',
  hl_def.bold and hl_def.underline and hl_def.fg == nil, vim.inspect(hl_def))

-- The root marks in `buf`: { row, start, end } per mark.
local function root_marks(buf)
  local out = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, render_mod.ns, 0, -1, { details = true })) do
    if m[4].hl_group == 'CallgraphRoot' then out[#out + 1] = { m[2], m[3], m[4].end_col } end
  end
  return out
end

local g = graph_mod.build_sync(place, 'callout', { max_depth = 2 }, fetch)
local child_id
for id, n in pairs(g.nodes) do
  if n.name == 'Shop.Cart.total/1' then child_id = id end
end
for _, style in ipairs({ 'boxed', 'dense' }) do
  for _, mode in ipairs({ 'off', 'auto' }) do
    config.set({ show_call_site = true, colors = { mode = mode } })
    local opts = config.get()
    local lay = layout_mod.layout(g, opts, { style = style })
    local buf = vim.api.nvim_create_buf(false, true)
    -- Another box selected: the root keeps its mark.
    render_mod.render(buf, lay, g, {
      selected_id = child_id, highlight = true, highlights = opts.highlights,
      colors = mode ~= 'off' and config.resolve_colors() or nil,
    })
    local marks = root_marks(buf)
    local b = lay.boxes[g.root.id]
    local line = vim.api.nvim_buf_get_lines(buf, marks[1] and marks[1][1] or 0, (marks[1] and marks[1][1] or 0) + 1, false)[1]
    local marked = marks[1] and line:sub(marks[1][2] + 1, marks[1][3]) or nil
    check(style .. '/' .. mode .. ': one root mark, on the root name only', #marks == 1 and marked == 'place/1'
      and marks[1][1] == b.row + b.name_row - 1, vim.inspect({ marks, marked }))
  end
end

-- Focus float: the root's full name carries the mark; another box's does not.
source_mod.make_fetch = function() return fetch end
vim.cmd('edit ' .. root .. '/tests/test.c')
local function zoom_root_marks()
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    local c = vim.api.nvim_win_get_config(w)
    if c.relative ~= '' and c.zindex == 50 then
      local zbuf = vim.api.nvim_win_get_buf(w)
      local n = 0
      for _, m in ipairs(vim.api.nvim_buf_get_extmarks(zbuf, -1, 0, -1, { details = true })) do
        if m[4].hl_group == 'CallgraphRoot' then n = n + 1 end
      end
      return n
    end
  end
end
for _, style in ipairs({ 'boxed', 'dense' }) do
  config.set({ show_call_site = true, colors = { mode = 'off' }, window = { max_name_width = 6, style = style } })
  view.open_with_root(place, 'callout', 'utf-16', { name = 'fake' })
  vim.wait(50, function() return false end)
  check(style .. ': focus float on the root carries the mark', zoom_root_marks() == 1, zoom_root_marks())
  view.move('right')
  check(style .. ': focus float on another box has no mark', zoom_root_marks() == 0, zoom_root_marks())
  view.close()
end

print('---')
if failed == 0 then print('ROOT MARK OK') else print('ROOT MARK FAILED: ' .. failed) end
os.exit(failed == 0 and 0 or 1)
