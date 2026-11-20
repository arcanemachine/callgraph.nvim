-- Opening from the code starts fresh (the graphs so far and their history
-- go); the open commands run inside the view close it; :CallgraphToggle
-- closes the view or brings it back as it was left, and with no graph yet
-- opens one on the function under the cursor.
-- Run: nvim --headless -u NONE -l tests/toggle.lua

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
local I = { a = item('a', 10), b = item('b', 20), x = item('x', 30) }
local calls = { a = { I.b } }
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
-- The function "under the cursor" in the code.
local under_cursor = I.a
source_mod.check_available = function() end
source_mod.resolve_root = function()
  if under_cursor then return under_cursor, 'utf-16', { name = 'fake' } end
  vim.notify('Callgraph: no function under the cursor')
end

local function settle() vim.wait(200, function() return false end) end
local function press(keys)
  vim.api.nvim_feedkeys(vim.keycode(keys), 'x', false)
  settle()
end
-- The view window (the one with a winbar), or nil.
local function view_win()
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(w).relative == '' and (vim.wo[w].winbar or '') ~= '' then return w end
  end
end
local function labels()
  local w = view_win()
  local wb = w and vim.wo[w].winbar or ''
  local out = {}
  for label in wb:gmatch('%%#.-#(.-)%%%*') do out[#out + 1] = label end
  return table.concat(out, '|')
end

config.set({ show_call_site = false })
vim.cmd('edit ' .. root .. '/tests/test.c')
local code = vim.api.nvim_get_current_win()

-- 1. Opening from the code; `.` adds a tab.
view.open('both'); settle()
press('l'); press('.')
check('a, then b with `.`: two tabs', select(2, labels():gsub('|', '')) == 1, labels())

-- 2. Opening again from the code starts fresh: one tab, no history.
vim.api.nvim_set_current_win(code)
under_cursor = I.x
view.open('both'); settle()
check('opening from the code starts fresh', select(2, labels():gsub('|', '')) == 0 and labels():find('x', 1, true), labels())
press('[')
check('no history left to go back to', labels():find('x', 1, true) ~= nil, labels())

-- 3. Inside the view, the open commands close it, and focus returns to the code.
press('l')
vim.cmd('Callin'); settle()
check('an open command inside the view closes it', view_win() == nil)
check('focus back in the code', vim.api.nvim_get_current_win() == code)

-- 4. The toggle brings it back as it was left; from inside it, closes it.
under_cursor = I.a
vim.cmd('CallgraphToggle'); settle()
check('toggle brings the view back as it was', view_win() ~= nil and labels():find('x', 1, true) ~= nil
  and not labels():find('a', 1, true), labels())
press('l') -- the keys work in the new buffer
vim.cmd('CallgraphToggle'); settle()
check('toggle inside the view closes it', view_win() == nil)

-- 5. After `:q` on the view, the toggle brings it back too, with its history.
under_cursor = I.a
view.open('both'); settle()
press('l'); press('.')
vim.cmd('q'); settle()
check(':q closes the view', view_win() == nil)
vim.cmd('CallgraphToggle'); settle()
check('toggle after :q brings both tabs back', select(2, labels():gsub('|', '')) == 1, labels())
press('[')
check('and their history', labels():match('%[') ~= nil and labels():sub(1, 1) == '[', labels())

-- 6. Closing the last tab leaves nothing: the toggle opens a new graph on
--    the function under the cursor.
press('q'); press('q')
check('q on the last tab closes the view', view_win() == nil)
under_cursor = I.x
vim.cmd('CallgraphToggle'); settle()
check('with no graph, toggle opens one on the function under the cursor', labels():find('x', 1, true) ~= nil, labels())

-- 7. With no graph and no function under the cursor, nothing opens.
vim.cmd('CallgraphToggle'); settle() -- close, x kept
vim.cmd('CallgraphToggle'); settle() -- back, focus in the view
press('q') -- the last tab: nothing left
under_cursor = nil
vim.cmd('CallgraphToggle'); settle()
check('no graph, no function: nothing opens', view_win() == nil)

-- 8. A slow build: closing before it ends, then reopening, shows the graph
--    once it is built; reopening while it builds waits for it.
local slow = true
local real_fetch = source_mod.make_fetch
source_mod.make_fetch = function()
  local f = real_fetch()
  return function(node, direction)
    if not slow then return f(node, direction) end
    local d = util.Deferred.new()
    vim.defer_fn(function() f(node, direction):next(function(r) d:resolve(r) end) end, 300)
    return d
  end
end
local errors = {}
local real_notify = vim.notify
vim.notify = function(msg, level)
  if level == vim.log.levels.ERROR then errors[#errors + 1] = msg end
end
under_cursor = I.a
view.open('both')
vim.wait(50, function() return false end)
vim.cmd('CallgraphToggle') -- close while building
vim.wait(3000, function() return false end) -- the build ends meanwhile
check('a build ending after the view closed raises no error', #errors == 0, errors[1])
vim.cmd('CallgraphToggle'); settle()
check('reopened, it shows the finished graph', labels():find('a', 1, true) ~= nil and vim.fn.search('\\<b\\>', 'n') > 0, labels())
vim.api.nvim_set_current_win(code)
under_cursor = I.x
view.open('both')
vim.wait(50, function() return false end)
vim.cmd('CallgraphToggle') -- close while x builds
vim.cmd('CallgraphToggle') -- reopen while it still builds
vim.wait(3000, function() return labels() ~= '' end)
check('reopening while it builds raises no error and shows it once built', #errors == 0
  and labels():find('x', 1, true) ~= nil, errors[1] or labels())
vim.notify = real_notify
slow = false

-- 9. With the pane it was opened from closed, a jump opens in another pane,
--    and the view stays.
vim.cmd('CallgraphToggle'); settle() -- close
vim.api.nvim_set_current_win(code)
vim.cmd('vsplit')
local pane = vim.api.nvim_get_current_win()
under_cursor = I.a
view.open('both'); settle()
local vw = view_win()
vim.api.nvim_win_close(pane, true)
vim.api.nvim_set_current_win(vw)
local jumped
require('callgraph.lsp').jump_to_location = function() jumped = vim.api.nvim_get_current_win() end
press('<CR>')
check('the jump lands in another pane', jumped and jumped ~= vw and jumped ~= pane, tostring(jumped))
check('the view stays', view_win() == vw and labels():find('a', 1, true) ~= nil, labels())

-- 10. From the help float, an open command closes the view.
vim.api.nvim_set_current_win(vw)
press('?')
vim.cmd('Callgraph'); settle()
check('an open command from the help float closes the view', view_win() == nil)

print('---')
if failed == 0 then print('TOGGLE OK') else print('TOGGLE FAILED: ' .. failed) end
os.exit(failed == 0 and 0 or 1)
