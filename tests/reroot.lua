-- `.` opens a graph rooted on the selected function in a new tab with the
-- current tab's direction; on the root it does nothing; closing the new tab
-- returns to the one it came from, its selection kept.
-- Run: nvim --headless -u NONE -l tests/reroot.lua

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
    data = { tag = name }, -- opaque server data must reach the new root's requests
  }
end
local place, total, tax = item('place', 10), item('total', 20), item('tax', 30)
local callees = { place = { total }, total = { tax } }
local asked = {}
source_mod.make_fetch = function()
  return function(node, direction)
    asked[#asked + 1] = { name = node.name, direction = direction, data = node.item and node.item.data }
    local d = util.Deferred.new()
    local out = {}
    if direction == 'callout' then
      for _, it in ipairs(callees[node.name] or {}) do out[#out + 1] = { item = it, call_site = { uri = U, line = 1 } } end
    end
    d:resolve(out)
    return d
  end
end

local arr = config.get().window.arrows.right
local function labels()
  local wb = vim.wo[vim.api.nvim_get_current_win()].winbar or ''
  local out = {}
  for label in wb:gmatch('%%#.-#(.-)%%%*') do out[#out + 1] = label end
  return table.concat(out, '|')
end
local function press(keys) vim.api.nvim_feedkeys(vim.keycode(keys), 'x', false) end
local function word() return vim.fn.expand('<cword>') end

config.set({ show_call_site = false })
vim.cmd('edit ' .. root .. '/tests/test.c')
view.open_with_root(place, 'callout', 'utf-16', { name = 'fake' })
vim.wait(200, function() return false end)

-- 1. On the root, `.` does nothing.
press('.')
vim.wait(200, function() return false end)
check('. on the root opens nothing', labels() == '[place' .. arr .. ']', labels())

-- 2. On a callee, `.` opens its graph in a new tab, same direction.
press('l')
check('selected total', word() == 'total', word())
asked = {}
press('.')
vim.wait(200, function() return false end)
check('. opens a new tab on the selection', labels() == 'place' .. arr .. '|[total' .. arr .. ']', labels())
press('h')
check('the new graph is rooted on it (nothing left of it)', word() == 'total', word())
check('the new root is asked with its own item', asked[1] and asked[1].name == 'total'
  and asked[1].direction == 'callout' and asked[1].data and asked[1].data.tag == 'total', vim.inspect(asked[1]))
press('l')
check('its callee is drawn', word() == 'tax', word())

-- 3. `.` on a function that already has a tab switches to it.
press('h')
press('<Tab>')
vim.wait(200, function() return false end)
press('.')
vim.wait(200, function() return false end)
check('. reuses an open tab for the same function', labels() == 'place' .. arr .. '|[total' .. arr .. ']', labels())

-- 4. Closing it returns to the tab it came from, selection kept.
press('q')
vim.wait(200, function() return false end)
check('q returns to the first tab', labels() == '[place' .. arr .. ']', labels())
check('its selection is kept', word() == 'total', word())

-- 5. A combined (:Callgraph) tab opens a combined tab.
view.close()
view.open_with_root(place, 'both', 'utf-16', { name = 'fake' })
vim.wait(200, function() return false end)
press('l')
press('.')
vim.wait(200, function() return false end)
check('combined tab opens a combined tab', labels() == arr .. 'place' .. arr .. '|[' .. arr .. 'total' .. arr .. ']', labels())

print('---')
if failed == 0 then print('REROOT OK') else print('REROOT FAILED: ' .. failed) end
os.exit(failed == 0 and 0 or 1)
