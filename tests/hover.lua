-- K: LSP hover docs for the selected node, shown in a float; a late answer
-- (selection moved) is dropped; no docs or no server only notify.
-- Run: nvim --headless -u NONE -l tests/hover.lua

local here = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fn.fnamemodify(here, ':h:h')
vim.opt.runtimepath:append(root)
vim.cmd('runtime! plugin/callgraph.lua')

local util = require('callgraph.util')
local config = require('callgraph.config')
local source_mod = require('callgraph.source')
local view = require('callgraph.view')

config.set({ show_call_site = true })

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
local main, helper = item('main', 32), item('helper', 20)
source_mod.make_fetch = function()
  return function(node)
    local d = util.Deferred.new()
    d:resolve(node.name == 'main' and { { item = helper, call_site = { uri = U, line = 33 } } } or {})
    return d
  end
end

-- A fake client: answers hover at once, or holds the callback when `hold` is set.
local requests, held = {}, nil
local client = { id = 9999, stopped = false, hold = false, answer = nil }
function client:request(method, params, cb)
  requests[#requests + 1] = { method = method, params = params }
  if self.hold then held = cb else cb(nil, self.answer) end
  return true, 1
end
function client:is_stopped() return self.stopped end
-- The fake isn't a registered client: report it attached to every buffer.
vim.lsp.get_clients = function() return { client } end

local notes = {}
vim.notify = function(msg) notes[#notes + 1] = msg end

local function doc_float()
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(w).relative ~= '' then
      local text = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, -1, false), '\n')
      if text:find('Docs for', 1, true) then return w, text end
    end
  end
end
local function close_doc_float()
  local w = doc_float()
  if w then vim.api.nvim_win_close(w, true) end
end

vim.cmd('edit ' .. root .. '/tests/test.c')
view.open_with_root(main, 'callout', 'utf-16', client)
vim.wait(50, function() return false end)

-- 1. Docs come back: a float shows them; the request asks at the node's name.
client.answer = { contents = { kind = 'markdown', value = 'Docs for **main**' } }
view.hover_docs()
local w, text = doc_float()
check('K opens a float with the docs', w ~= nil and text:find('Docs for **main**', 1, true), text)
local req = requests[#requests]
check('K asks textDocument/hover at the selection range', req and req.method == 'textDocument/hover'
  and req.params.position.line == 32 and req.params.position.character == 4 and req.params.textDocument.uri == U)
close_doc_float()

-- 2. A late answer after the selection moved is dropped.
client.hold = true
view.hover_docs()
view.move('right')
held(nil, { contents = { kind = 'markdown', value = 'Docs for main (late)' } })
check('late answer after moving is dropped', doc_float() == nil)
client.hold = false

-- 3. No docs: a notice, no float.
client.answer = nil
view.hover_docs()
check('no docs notifies', doc_float() == nil and notes[#notes] and notes[#notes]:find('no docs', 1, true), notes[#notes])

-- 4. Stopped server: a notice, no request.
client.stopped = true
local n = #requests
view.hover_docs()
check('stopped server notifies without asking', #requests == n and notes[#notes]:find('no language server', 1, true), notes[#notes])

print('---')
if failed == 0 then print('HOVER OK') else print('HOVER FAILED: ' .. failed) end
os.exit(failed == 0 and 0 or 1)
