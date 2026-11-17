-- Focus float: a float over the selected box shows its shortened label in full
-- (same rows, marker kept), only when something is shortened; it closes when
-- the view is left or closed and comes back on re-entering.
-- Run: nvim --headless -u NONE -l tests/zoom.lua

local here = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fn.fnamemodify(here, ':h:h')
vim.opt.runtimepath:append(root)
vim.cmd('runtime! plugin/callgraph.lua')
vim.o.columns, vim.o.lines = 200, 50

local util = require('callgraph.util')
local config = require('callgraph.config')
local source_mod = require('callgraph.source')
local view = require('callgraph.view')

config.set({ show_call_site = true, window = { max_name_width = 12, position = 'bottom', fixed_height = 30 } })

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
-- main -> Shop.Orders.Checkout.place_order (shortened, expandable) -> leaf
local main = item('main', 32)
local long = item('Shop.Orders.Checkout.place_order', 20)
local leaf = item('leaf', 3)
local callees = { main = { long }, [long.name] = { leaf }, leaf = {} }
source_mod.make_fetch = function()
  return function(node)
    local d = util.Deferred.new()
    local out = {}
    for _, it in ipairs(callees[node.name] or {}) do out[#out + 1] = { item = it, call_site = { uri = U, line = 1 } } end
    d:resolve(out)
    return d
  end
end

vim.cmd('edit ' .. root .. '/tests/test.c')
local code_win = vim.api.nvim_get_current_win()
-- Depth 1 keeps `long` collapsed, so its box carries the expand marker.
config.set(vim.tbl_deep_extend('force', config.get(), { max_depth = 1 }))
view.open_with_root(main, 'callout', 'utf-16', { name = 'fake' })
vim.wait(200, function() return false end)
local graph_win = vim.api.nvim_get_current_win()

local function zoom_win()
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    local c = vim.api.nvim_win_get_config(w)
    if c.relative ~= '' and c.zindex == 50 then return w end
  end
end

-- main is not shortened: no float.
check('no float on an unshortened box', zoom_win() == nil)

-- Select the shortened box.
view.move('right')
local zw = zoom_win()
check('float on a shortened box', zw ~= nil)
if zw then
  local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(zw), 0, -1, false)
  check('row 1 has the full container and path', lines[1]:match('^Shop%.Orders%.Checkout') and lines[1]:match('tests/test%.c:21$'), lines[1])
  check('float does not wrap', vim.wo[zw].wrap == false)
  check('row 2 has the full name and the marker', lines[2]:match('^place_order') and lines[2]:match('❯$'), lines[2])

  -- Placement: the float's top-left corner (its border) is anchored on the
  -- box's top-left border cell, so border lands on border and text on text.
  -- (Headless Neovim composites no floats, so the screen itself can't be read
  -- here; the anchor is what decides the position.)
  local cfg = vim.api.nvim_win_get_config(zw)
  local buf_lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(graph_win), 0, -1, false)
  local top_row, top_byte
  for r, l in ipairs(buf_lines) do
    local s = l:find('S.O.Checkout', 1, true)
    if s then
      top_row = r - 2 -- 0-based buffer row of the border above the container row
      local border_line = buf_lines[top_row + 1]
      local border_char = vim.fn.strchars(l:sub(1, s - 1)) - 1 -- the │ left of the text
      top_byte = vim.str_byteindex(border_line, 'utf-32', border_char)
      break
    end
  end
  check('float anchored on the box top-left border',
    cfg.bufpos and cfg.bufpos[1] == top_row and cfg.bufpos[2] == top_byte and cfg.row == 0 and cfg.col == 0,
    vim.inspect({ cfg.bufpos, cfg.row, cfg.col, top_row, top_byte }))
  local border_line = buf_lines[top_row + 1]
  check('anchor cell is the box corner', border_line:sub(top_byte + 1, top_byte + 3) == '╭', border_line)
end

-- Leaving the view hides it; entering again brings it back.
vim.api.nvim_set_current_win(code_win)
check('float closes on leaving the view', zoom_win() == nil)
vim.api.nvim_set_current_win(graph_win)
check('float returns on entering the view', zoom_win() ~= nil)

-- Back to an unshortened box: gone.
view.move('left')
check('float closes on an unshortened box', zoom_win() == nil)

-- `:q` on the view closes the float with it.
view.move('right')
check('float back before :q', zoom_win() ~= nil)
vim.cmd('close')
check('float closes with the view window', zoom_win() == nil)

print('---')
if failed == 0 then print('ZOOM OK') else print('ZOOM FAILED: ' .. failed) end
os.exit(failed == 0 and 0 or 1)
