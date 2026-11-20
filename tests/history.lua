-- Tab history, like a browser's: [ and <C-o> go back to the tab seen before,
-- ] forward again; any other switch adds to it and drops what lay ahead;
-- closing a tab lands where back would. <C-o> never leaves the view.
-- Run: nvim --headless -u NONE -l tests/history.lua

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
-- a calls b, b calls c, c calls d.
local I = { a = item('a', 10), b = item('b', 20), c = item('c', 30), d = item('d', 40) }
local calls = { a = { I.b }, b = { I.c }, c = { I.d } }
source_mod.make_fetch = function()
  return function(node, direction)
    local d = util.Deferred.new()
    local out = {}
    if direction == 'callout' then
      for _, it in ipairs(calls[node.name] or {}) do out[#out + 1] = { item = it, call_site = { uri = U, line = 1 } } end
    end
    d:resolve(out)
    return d
  end
end

local arr = config.get().window.arrows.right
-- The active tab's name ('a' for "a→"), from the winbar's [label].
local function active()
  local wb = vim.wo[vim.api.nvim_get_current_win()].winbar or ''
  return wb:match('%[(.-)' .. vim.pesc(arr) .. '%]')
end
local function count()
  local wb = vim.wo[vim.api.nvim_get_current_win()].winbar or ''
  local n = 0
  for _ in wb:gmatch('%%#.-#(.-)%%%*') do n = n + 1 end
  return n
end
local function press(keys)
  vim.api.nvim_feedkeys(vim.keycode(keys), 'x', false)
  vim.wait(100, function() return false end)
end
-- Open the graph of the selected callee: move right, then `.`.
local function dive() press('l'); press('.') end

config.set({ show_call_site = false })
vim.cmd('edit ' .. root .. '/tests/test.c')
view.open_with_root(I.a, 'callout', 'utf-16', { name = 'fake' })
vim.wait(200, function() return false end)
local graph_win = vim.api.nvim_get_current_win()
local graph_buf = vim.api.nvim_get_current_buf()

dive(); dive() -- a -> b -> c
check('three tabs, on c', count() == 3 and active() == 'c', active())
press('[')
check('[ goes back to b', active() == 'b', active())
press('<C-o>')
check('<C-o> goes back to a', active() == 'a', active())
press('[')
check('back at the start stays', active() == 'a', active())
press(']')
check('] goes forward to b', active() == 'b', active())
press(']')
check('] again goes forward to c', active() == 'c', active())
press(']')
check('forward at the end stays', active() == 'c', active())
check('<C-o> stays in the view', vim.api.nvim_get_current_win() == graph_win
  and vim.api.nvim_win_get_buf(graph_win) == graph_buf)

-- A new visit after going back drops what lay ahead.
press('['); press('['); press('<Tab>') -- a, then <Tab> to b
check('<Tab> is a visit', active() == 'b', active())
press(']')
check('a visit drops the forward steps', active() == 'b', active())
press('[')
check('back from b goes to a', active() == 'a', active())

-- Closing a tab lands where back would.
press(']') -- b
press('<Tab>') -- c
press('q')
check('closing c lands on b, seen before it', active() == 'b' and count() == 2, active())
press('[')
check('the closed tab is gone from the history', active() == 'a', active())

-- Closing a tab while back in the history keeps what lies ahead.
press('<Tab>') -- b
press('.') -- c again (b's selection is still on c): a, b, c
press('[') -- b
press('q')
check('closing b while back lands on a', active() == 'a', active())
press(']')
check('forward still reaches c after the close', active() == 'c', active())

-- Reopening the current tab from the code while back keeps what lies ahead.
press('[') -- a
view.open_with_root(I.a, 'callout', 'utf-16', { name = 'fake' })
vim.wait(200, function() return false end)
press(']')
check('forward still works after reopening the current tab', active() == 'c', active())

print('---')
if failed == 0 then print('HISTORY OK') else print('HISTORY FAILED: ' .. failed) end
os.exit(failed == 0 and 0 or 1)
