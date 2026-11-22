-- The function under the cursor is the one in the current window, even with
-- the file open in several panes whose cursors sit elsewhere; with none there,
-- a warning says so.
-- Run: nvim --headless -u NONE -l tests/resolve_pane.lua

local here = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fn.fnamemodify(here, ':h:h')
vim.opt.runtimepath:append(root)
vim.cmd('runtime! plugin/callgraph.lua')

local util = require('callgraph.util')
local lsp_mod = require('callgraph.lsp')

local failed = 0
local function check(name, cond, detail)
  if cond then print('PASS ' .. name) else failed = failed + 1; print('FAIL ' .. name .. (detail and (' :: ' .. tostring(detail)) or '')) end
end

-- A fake server: answers prepareCallHierarchy with a function named after
-- the line asked about.
local asked
local client = { id = 9999, offset_encoding = 'utf-16' }
function client:supports_method() return true end
local nothing = false -- answer every request with no result
function client:request(_, params, cb)
  if nothing then cb(nil, nil); return true, 1 end
  asked = params.position
  cb(nil, { { name = 'line' .. params.position.line, kind = 12, uri = params.textDocument.uri,
    range = { start = params.position, ['end'] = params.position },
    selectionRange = { start = params.position, ['end'] = params.position } } })
  return true, 1
end
vim.lsp.get_clients = function() return { client } end

vim.cmd('edit ' .. root .. '/tests/test.c')
local buf = vim.api.nvim_get_current_buf()
vim.api.nvim_win_set_cursor(0, { 3, 0 })
vim.cmd('vsplit') -- the new pane comes first; move its cursor elsewhere
vim.api.nvim_win_set_cursor(0, { 10, 0 })
local first = vim.api.nvim_get_current_win()
vim.cmd('wincmd l')
check('in the second pane, at line 3', vim.api.nvim_get_current_win() ~= first and vim.api.nvim_win_get_cursor(0)[1] == 3)

local item
util.async_start(function() item = lsp_mod.resolve_root(buf) end)
vim.wait(500, function() return item ~= nil end)
check('the function under the current pane\'s cursor', asked and asked.line == 2 and item and item.name == 'line2',
  vim.inspect(asked))

-- No function at the cursor (no call hierarchy item, no enclosing symbol):
-- a warning says so.
nothing = true
local msgs = {}
vim.notify = function(msg) msgs[#msgs + 1] = msg end
local done, got = false, nil
util.async_start(function() got = lsp_mod.resolve_root(buf); done = true end)
vim.wait(500, function() return done end)
check('no function: nothing resolves and a warning says so', got == nil
  and msgs[1] == 'Callgraph: no function under the cursor', vim.inspect(msgs))

print('---')
if failed == 0 then print('RESOLVE PANE OK') else print('RESOLVE PANE FAILED: ' .. failed) end
os.exit(failed == 0 and 0 or 1)
