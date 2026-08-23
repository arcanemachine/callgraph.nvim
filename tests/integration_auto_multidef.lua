-- Auto-source multi-definition trigger: builds multidef.c (conditionally
-- compiled `impl`) with sources={'auto'} and asserts `impl` is reached as a
-- call-site node (uri == call_site.uri) — the precondition for the definition
-- picker on expand. Skips (exit 0) when clangd is absent.
-- Run: nvim --headless -u NONE -l tests/integration_auto_multidef.lua
local here = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fn.fnamemodify(here, ':h:h')
vim.opt.runtimepath:append(root)
vim.cmd('runtime! plugin/callgraph.lua')

local config_mod = require('callgraph.config')
local lsp_mod = require('callgraph.lsp')
local source_mod = require('callgraph.source')
local graph_mod = require('callgraph.graph')

local clangd = vim.fn.exepath('clangd')
if clangd == '' then print('SKIP: no clangd'); os.exit(0) end
config_mod.set({ sources = { 'auto' }, show_call_site = true })
vim.cmd('edit ' .. root .. '/tests/multidef.c')
vim.lsp.start({
  name = 'clangd', cmd = { clangd, '--background-index' }, root_dir = root,
  capabilities = vim.lsp.protocol.make_client_capabilities(),
})
local attached = vim.wait(20000, function() return #vim.lsp.get_clients({ bufnr = 0 }) > 0 end)
if not attached then print('FAIL: clangd did not attach'); os.exit(1) end
vim.wait(3000, function() return false end)

local failed = 0
local function check(name, cond, detail)
  if cond then print('PASS ' .. name) else failed = failed + 1; print('FAIL ' .. name .. (detail and (' :: ' .. tostring(detail)) or '')) end
end

local util = require('callgraph.util')
util.async_start(function()
  local item, enc, client
  for attempt = 1, 10 do
    vim.api.nvim_win_set_cursor(0, { 31, 8 }) -- on `caller` (1-based line)
    item, enc, client = lsp_mod.resolve_root(vim.api.nvim_get_current_buf())
    if item and item.name == 'caller' then break end
    vim.wait(2000, function() return false end)
  end
  check('resolve root caller', item ~= nil and item.name == 'caller', item and item.name or 'nil')
  if not item then os.exit(1) end

  graph_mod.build(item, 'callout', { max_depth = 3 }, source_mod.make_fetch(enc, client, config_mod.get())):next(function(g)
    local names = {}
    for _, n in pairs(g.nodes) do names[n.name] = true end
    print('nodes: ' .. table.concat(vim.tbl_keys(names), ', '))
    check('graph reaches impl', names.impl == true)
    local impl
    for _, n in pairs(g.nodes) do
      if n.name == 'impl' and n.call_site then impl = n end
    end
    check('impl is call-site node (triggers picker)',
      impl ~= nil and impl.source == 'auto' and impl.uri == impl.call_site.uri,
      impl and (impl.source or 'nil') .. '/' .. tostring(impl.uri == impl.call_site.uri) or 'no impl call_site node')
    os.exit(failed == 0 and 0 or 1)
  end, function(e)
    print('FAIL build: ' .. tostring(e)); os.exit(1)
  end)
end)

vim.wait(30000, function() return false end)
print('TIMEOUT')
os.exit(1)
