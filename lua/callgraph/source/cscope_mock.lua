--- Mock cscope: a text index built with the scanner, so cscope scenarios can
--- be exercised without the `cscope` binary (Windows, CI). Enabled via
--- config.mock_cscope; meant for debugging / tests, not production accuracy.
--- Queries return the same shape as source/cscope.lua (Deferred -> calls of
--- { item, call_site }), and find_definitions sees conditionally-compiled
--- duplicates because the index is text-level.

local util = require('callgraph.util')

local M = {}

local index = nil -- { defs = name -> [{uri,line}], callees = name -> [{name,uri,line}] }

local function item(name, uri, line)
  return {
    name = name, kind = 12, uri = uri,
    range = { start = { line = line, character = 0 }, ['end'] = { line = line, character = 0 } },
    selectionRange = { start = { line = line, character = 0 }, ['end'] = { line = line, character = #name } },
  }
end

local function build_index()
  if index then return index end
  local config = require('callgraph.config')
  local scanner = require('callgraph.scanner')
  index = { defs = {}, callees = {} }
  local dir = config.get().mock_cscope_dir or ''
  local files
  if dir ~= '' then
    files = vim.fn.glob(dir .. '/**/*.{c,h}', false, true)
  else
    -- Default: index only the current buffer's file. Same-name functions in
    -- other files (e.g. several test `main`s) would otherwise pollute the
    -- graph — a minimal single-file mock keeps the scenario clean.
    local fname = vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf())
    if fname ~= '' then files = { fname } else files = {} end
  end
  for _, f in ipairs(files) do
    local abs = vim.fn.fnamemodify(f, ':p') -- glob may return relative paths
    local uri = vim.uri_from_fname(abs)
    local bufnr = vim.uri_to_bufnr(uri)
    vim.fn.bufload(bufnr)
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local text = table.concat(lines, '\n')
    local defs = scanner.enumerate_definitions(text)
    for i, d in ipairs(defs) do
      -- Register this definition.
      index.defs[d.name] = index.defs[d.name] or {}
      local dup = false
      for _, dd in ipairs(index.defs[d.name]) do
        if dd.uri == uri and dd.line == d.line then dup = true; break end
      end
      if not dup then index.defs[d.name][#index.defs[d.name] + 1] = { uri = uri, line = d.line } end
      -- Function body = this definition up to (not including) the next one
      -- (or EOF); scan it for callees (scan_calls starts after the first `{`).
      -- Stopping before the next definition keeps the next function's signature
      -- (e.g. `int main(`) out of this function's callees.
      local body_end = defs[i + 1] and defs[i + 1].line or #lines
      local body = table.concat(lines, '\n', d.line + 1, body_end)
      index.callees[d.name] = index.callees[d.name] or {}
      for _, c in ipairs(scanner.scan_calls(body)) do
        index.callees[d.name][#index.callees[d.name] + 1] = {
          name = c[3], uri = uri, line = d.line + c[1],
        }
      end
    end
  end
  return index
end

--- Available whenever the mock is on and an index can be built.
function M.available(opts)
  return build_index() ~= nil
end

--- Query callers/callees from the text index.
function M.query(funcname, direction, opts)
  local d = util.Deferred.new()
  local idx = build_index()
  local calls = {}
  if direction == 'callin' then
    -- Reverse index: find every definition that calls `funcname`.
    for name, cl in pairs(idx.callees) do
      for _, c in ipairs(cl) do
        if c.name == funcname then
          calls[#calls + 1] = {
            item = item(name, c.uri, c.line),
            call_site = { uri = c.uri, line = c.line },
          }
        end
      end
    end
  else
    for _, c in ipairs(idx.callees[funcname] or {}) do
      calls[#calls + 1] = {
        item = item(c.name, c.uri, c.line),
        call_site = { uri = c.uri, line = c.line },
      }
    end
  end
  d:resolve(calls)
  return d
end

--- All text-level definitions of `funcname` (multi-definition friendly).
function M.find_definitions(funcname)
  local d = util.Deferred.new()
  d:resolve(build_index().defs[funcname] or {})
  return d
end

function M.clear_cache()
  index = nil
end

return M
