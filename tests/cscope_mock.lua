-- Mock cscope (text index): verify it mirrors real cscope for multidef.c —
-- find_definitions('impl') sees both #ifdef branches (2 definitions) and
-- query('caller','callout') / callin('impl') reach impl / caller. Requires NO
-- cscope binary (config.mock_cscope = true).
-- Run: nvim --headless -u NONE -l tests/cscope_mock.lua

local here = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fn.fnamemodify(here, ':h:h')
vim.opt.runtimepath:append(root)

local config = require('callgraph.config')
local cscope = require('callgraph.source.cscope')

config.set({ mock_cscope = true, mock_cscope_dir = root .. '/tests', sources = { 'cscope' } })

local failed = 0
local function check(name, cond, detail)
  if cond then print('PASS ' .. name) else failed = failed + 1; print('FAIL ' .. name .. (detail and (' :: ' .. tostring(detail)) or '')) end
end

cscope.find_definitions('impl'):next(function(defs)
  check('impl has 2 definitions (ifdef branches)', #defs == 2, tostring(#defs))
  cscope.query('caller', 'callout'):next(function(calls)
    local names = {}
    for _, c in ipairs(calls) do names[c.item.name] = true end
    check('caller callees include impl', names.impl == true, table.concat(vim.tbl_keys(names), ', '))
    cscope.query('impl', 'callin'):next(function(callers)
      local cn = {}
      for _, c in ipairs(callers) do cn[c.item.name] = true end
      check('impl callers include caller', cn.caller == true, table.concat(vim.tbl_keys(cn), ', '))
      os.exit(failed == 0 and 0 or 1)
    end)
  end)
end)

vim.wait(5000, function() return false end)
print('TIMEOUT')
os.exit(1)
