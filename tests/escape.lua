-- Esc closes the popups over the view (the docs float, the focus float) and
-- never the view itself; q still closes the tab. With close_alt set to the
-- same key, Esc closes the popups first, then the tab.
-- Run: nvim --headless -u NONE -l tests/escape.lua

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
    selectionRange = { start = { line = line, character = 4 }, ['end'] = { line = line, character = 8 } },
  }
end
local place, total = item('Shop.Orders.place_order/1', 32), item('total/1', 20)
source_mod.make_fetch = function()
  return function(node)
    local d = util.Deferred.new()
    d:resolve(node.name == place.name and { { item = total, call_site = { uri = U, line = 33 } } } or {})
    return d
  end
end

local client = { id = 9999 }
function client:request(_, _, cb)
  cb(nil, { contents = { kind = 'markdown', value = 'Docs for place_order' } })
  return true, 1
end
function client:is_stopped() return false end
vim.lsp.get_clients = function() return { client } end

local function press(keys)
  vim.api.nvim_feedkeys(vim.keycode(keys), 'x', false)
end
local function split_count()
  local n = 0
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(w).relative == '' then n = n + 1 end
  end
  return n
end
local function floats()
  local docs, zoom
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    local c = vim.api.nvim_win_get_config(w)
    if c.relative ~= '' then
      local text = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, -1, false), '\n')
      if text:find('Docs for', 1, true) then docs = w elseif c.zindex == 50 then zoom = w end
    end
  end
  return docs, zoom
end
local function open()
  vim.cmd('edit ' .. root .. '/tests/test.c')
  view.open_with_root(place, 'callout', 'utf-16', client)
  vim.wait(50, function() return false end)
end

-- The root's name is wider than the limit: its box is shortened, so the
-- focus float shows over it.
config.set({ show_call_site = true, window = { max_name_width = 8 } })
open()
local graph_win = vim.api.nvim_get_current_win()

-- 1. Esc with the focus float open closes it, and the view stays.
local _, zoom = floats()
check('focus float shown on the shortened root', zoom ~= nil)
press('<Esc>')
local docs
docs, zoom = floats()
check('Esc closes the focus float', zoom == nil)
check('Esc keeps the view open', split_count() == 2 and vim.api.nvim_win_is_valid(graph_win))

-- 2. Esc with nothing open does nothing.
press('<Esc>')
check('Esc with no popup keeps the view open', split_count() == 2 and vim.api.nvim_get_current_win() == graph_win)

-- 3. Esc closes the docs float (K) and keeps the view.
view.hover_docs()
docs = floats()
check('K opens the docs float', docs ~= nil)
press('<Esc>')
docs = floats()
check('Esc closes the docs float', docs == nil)
check('Esc after K keeps the view open', split_count() == 2)

-- 4. Inside the docs float (a second K enters it), Esc closes it and lands
--    back in the view.
view.hover_docs()
view.hover_docs()
docs = floats()
check('second K enters the docs float', docs ~= nil and vim.api.nvim_get_current_win() == docs)
press('<Esc>')
check('Esc inside the docs float closes it', floats() == nil)
check('focus returns to the view', vim.api.nvim_get_current_win() == graph_win)

-- 5. q still closes the tab (the last one closes the view).
press('q')
check('q closes the view', split_count() == 1)

-- 6. close_alt on the same key: popups first, then the tab.
config.set({ show_call_site = true, window = { max_name_width = 8 }, keymaps = { close_alt = '<Esc>' } })
open()
check('focus float shown again', select(2, floats()) ~= nil)
press('<Esc>')
check('shared key: first Esc closes the float only', select(2, floats()) == nil and split_count() == 2)
press('<Esc>')
check('shared key: next Esc closes the tab', split_count() == 1)

print('---')
if failed == 0 then print('ESCAPE OK') else print('ESCAPE FAILED: ' .. failed) end
os.exit(failed == 0 and 0 or 1)
