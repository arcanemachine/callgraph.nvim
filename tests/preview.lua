-- `p` shows the selected function's code in the code pane and keeps focus in
-- the view, also when the definition comes from a slow lookup (cscope).
-- Run: nvim --headless -u NONE -l tests/preview.lua

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

local F = vim.fn.fnamemodify(root .. '/tests/test.c', ':p')
local U = vim.uri_from_fname(F)
local function item(name, line)
  return {
    name = name, kind = 12, uri = U,
    range = { start = { line = line, character = 0 }, ['end'] = { line = line + 2, character = 0 } },
    selectionRange = { start = { line = line, character = 0 }, ['end'] = { line = line, character = #name } },
  }
end
local a, b, c = item('a', 2), item('b', 12), item('c', 22)
source_mod.make_fetch = function()
  return function(node, direction)
    local d = util.Deferred.new()
    local out = {}
    if direction == 'callout' and node.name == 'a' then
      out[1] = { item = b, call_site = { uri = U, line = 3 } }
      -- A cscope call-site node: its definition comes from a lookup.
      out[2] = { item = c, call_site = { uri = U, line = 4 }, source = 'cscope' }
    end
    d:resolve(out)
    return d
  end
end
source_mod.check_available = function() end
source_mod.resolve_root = function() return a, 'utf-16', { name = 'fake' } end
-- A slow cscope definition lookup.
source_mod.provider = function()
  return {
    find_definition = function()
      local d = util.Deferred.new()
      vim.defer_fn(function() d:resolve({ uri = U, line = 30 }) end, 300)
      return d
    end,
  }
end

local function settle() vim.wait(200, function() return false end) end
local function press(keys)
  vim.api.nvim_feedkeys(vim.keycode(keys), 'x', false)
  settle()
end

config.set({ show_call_site = false })
vim.cmd('edit ' .. F)
local code = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_cursor(code, { 1, 0 })
view.open('callout'); settle()
local vw = vim.api.nvim_get_current_win()
check('in the view', vw ~= code)

-- 1. On b: the code pane shows b, focus stays in the view.
press('l')
press('p')
check('focus stays in the view', vim.api.nvim_get_current_win() == vw)
check('the code pane shows the function', vim.api.nvim_win_get_cursor(code)[1] == 13,
  vim.api.nvim_win_get_cursor(code)[1])

-- 2. On c (a slow lookup): the code lands in the code pane, not the view.
press('j')
local vbuf = vim.api.nvim_win_get_buf(vw)
press('p')
vim.wait(1000, function() return vim.api.nvim_win_get_cursor(code)[1] == 31 end)
check('a slow lookup lands in the code pane', vim.api.nvim_win_get_cursor(code)[1] == 31,
  vim.api.nvim_win_get_cursor(code)[1])
check('the view keeps its buffer and focus', vim.api.nvim_win_get_buf(vw) == vbuf
  and vim.api.nvim_get_current_win() == vw)

-- 3. <CR> still moves focus to the code.
press('k')
press('<CR>')
check('<CR> moves focus to the code', vim.api.nvim_get_current_win() == code)

print('---')
if failed == 0 then print('PREVIEW OK') else print('PREVIEW FAILED: ' .. failed) end
os.exit(failed == 0 and 0 or 1)
