--- Shared helpers: Deferred (thenable), coroutine-based async, and
--- LSP position <-> buffer byte conversions.

local M = {}

-- ---------------------------------------------------------------------------
-- Deferred: a minimal promise/thenable so LSP request chains read cleanly.
-- Resolving an already-resolved Deferred is a no-op; attaching :next() to a
-- resolved Deferred invokes the callback immediately (synchronous path), which
-- lets the headless smoke test run the whole graph build without an event loop.
-- ---------------------------------------------------------------------------

local Deferred = {}
Deferred.__index = Deferred

function Deferred.new()
  return setmetatable({ done = false, value = nil, error = nil, nexts = {} }, Deferred)
end

function Deferred:resolve(value)
  if self.done then return self end
  self.done = true
  self.value = value
  local nexts = self.nexts
  self.nexts = nil
  for _, fn in ipairs(nexts) do fn(value) end
  return self
end

function Deferred:reject(err)
  if self.done then return self end
  self.done = true
  self.error = err
  local nexts = self.nexts
  self.nexts = nil
  for _, fn in ipairs(nexts) do fn(nil, err) end
  return self
end

function Deferred:next(on_ok, on_err)
  if self.done then
    if self.error then
      if on_err then on_err(self.error) end
    elseif on_ok then
      on_ok(self.value)
    end
    return self
  end
  self.nexts[#self.nexts + 1] = function(value, err)
    if err ~= nil then
      if on_err then on_err(err) end
    elseif on_ok then
      on_ok(value)
    end
  end
  return self
end

M.Deferred = Deferred

-- ---------------------------------------------------------------------------
-- Coroutine async: run a body that may call M.await() on Deferreds.
-- ---------------------------------------------------------------------------

function M.async_start(fn)
  local co = coroutine.create(fn)
  local ok, err = coroutine.resume(co)
  if not ok then error(err, 0) end
end

function M.await(deferred)
  assert(deferred and deferred.next, 'await expects a Deferred')
  if deferred.done then
    if deferred.error then error(deferred.error, 0) end
    return deferred.value
  end
  local co = coroutine.running()
  assert(co, 'await must be called from a coroutine')
  local result
  deferred:next(
    function(value)
      result = { true, value }
      local ok, err = coroutine.resume(co)
      if not ok and err then
        vim.notify('Callgraph: ' .. tostring(err), vim.log.levels.ERROR)
      end
    end,
    function(err)
      result = { false, err }
      coroutine.resume(co)
    end
  )
  coroutine.yield()
  if not result[1] then error(result[2], 0) end
  return result[2]
end

-- ---------------------------------------------------------------------------
-- LSP position helpers. LSP positions are (line, character) where character is
-- in the negotiated offset encoding (clangd defaults to utf-16). Convert
-- between that and 0-based byte columns used by the Neovim buffer.
-- ---------------------------------------------------------------------------

--- 0-based byte column -> LSP character offset in the given encoding.
function M.byte_to_pos(line, byte_col, encoding)
  if encoding ~= 'utf-16' then return byte_col end
  local u, i = 0, 1
  local n = #line
  while i <= byte_col and i <= n do
    local b = string.byte(line, i)
    if b < 0x80 then
      u = u + 1; i = i + 1
    elseif b < 0xE0 then
      u = u + 1; i = i + 2
    elseif b < 0xF0 then
      u = u + 1; i = i + 3
    else
      u = u + 2; i = i + 4
    end
  end
  return u
end

--- LSP character offset (given encoding) -> 0-based byte column.
function M.pos_to_byte(line, pos_char, encoding)
  if encoding ~= 'utf-16' then return pos_char end
  local u, i = 0, 1
  local n = #line
  while u < pos_char and i <= n do
    local b = string.byte(line, i)
    if b < 0x80 then
      u = u + 1; i = i + 1
    elseif b < 0xE0 then
      u = u + 1; i = i + 2
    elseif b < 0xF0 then
      u = u + 1; i = i + 3
    else
      u = u + 2; i = i + 4
    end
  end
  return i - 1
end

-- ---------------------------------------------------------------------------
-- Buffer position helpers. nvim_win_set_cursor and nvim_buf_set_extmark take
-- BYTE columns, while our layout works in CHARACTER columns. Convert between
-- the two for a line of UTF-8 text.
-- ---------------------------------------------------------------------------

--- Byte column of the character at `char_col` (0-based both).
function M.char_to_byte(line, char_col)
  return #vim.fn.strcharpart(line, 0, char_col)
end

--- Character column (0-based) of the byte at `byte_col`.
function M.byte_to_char(line, byte_col)
  local i, chars = 1, 0
  local n = #line
  while i <= byte_col and i <= n do
    local b = string.byte(line, i)
    if b < 0x80 then
      i = i + 1
    elseif b < 0xE0 then
      i = i + 2
    elseif b < 0xF0 then
      i = i + 3
    else
      i = i + 4
    end
    chars = chars + 1
  end
  return chars
end

--- Resolve when all Deferreds resolve. Results are collected positionally;
--- a rejected Deferred contributes `nil` (never rejects the aggregate).
function M.all(deferreds)
  local d = M.Deferred.new()
  local n = #deferreds
  if n == 0 then d:resolve({}); return d end
  local results = {}
  local pending = n
  for i, dd in ipairs(deferreds) do
    dd:next(
      function(value)
        results[i] = value
        pending = pending - 1
        if pending == 0 then d:resolve(results) end
      end,
      function()
        results[i] = nil
        pending = pending - 1
        if pending == 0 then d:resolve(results) end
      end
    )
  end
  return d
end

-- ---------------------------------------------------------------------------
-- Character-count helpers (box widths are character-based, not display-based).
-- ---------------------------------------------------------------------------

function M.char_count(s)
  return vim.fn.strchars(s or '')
end

--- Truncate a string to `maxchars` characters, appending an ellipsis.
function M.truncate(s, maxchars)
  if not s then return '' end
  if vim.fn.strchars(s) <= maxchars then return s end
  if maxchars <= 1 then return '…' end
  return vim.fn.strcharpart(s, 0, maxchars - 1) .. '…'
end

-- Separators between a qualified name's parts, longest first.
local NAME_SEPARATORS = { '::', '.', '#' }

--- Split a qualified name into its container and its last part:
--- `A.B.fun/1` -> 'A.B', 'fun/1', '.'; `ns::Cls::m` -> 'ns::Cls', 'm', '::'.
--- A name with no separator has no container ('').
function M.split_name(name)
  -- Only the part before a signature or description counts: some servers name
  -- items `process(Map.Entry<K, V>)` or `items.forEach() callback`.
  local limit = (name:find('[%( ]') or (#name + 1)) - 1
  local best, best_sep
  for _, sep in ipairs(NAME_SEPARATORS) do
    local i = 0
    local last
    while true do
      local s = name:find(sep, i + 1, true)
      -- A separator at the very start or end belongs to the name (`.method`, `foo.`).
      if not s or s + #sep > limit then break end
      if s > 1 then last = s end
      i = s
    end
    if last and (not best or last > best) then best, best_sep = last, sep end
  end
  if not best then return '', name, nil end
  -- In a run of dots the first one separates: `Kernel.../2` is `Kernel` + `../2`.
  if best_sep == '.' then
    while best > 2 and name:sub(best - 1, best - 1) == '.' do best = best - 1 end
  end
  return name:sub(1, best - 1), name:sub(best + #best_sep), best_sep
end

-- Initials of one name part: the capitals and digits of CamelCase
-- (`ResortServiceV2` -> 'RSV2'), else the first letter of each word
-- (`my_module` -> 'mm').
local function initials(part)
  local caps = part:gsub('[^%u%d]', '')
  if #caps >= 2 then return caps end
  local out = {}
  for word in part:gmatch('[^_%-]+') do out[#out + 1] = vim.fn.strcharpart(word, 0, 1) end
  local s = table.concat(out)
  return s ~= '' and s or part
end

--- Shorten a container to `maxchars`: replace its parts with their initials
--- from the left, keeping the last part whole, until it fits; then cut from
--- the left.
function M.abbreviate(container, sep, maxchars)
  if container == '' or M.char_count(container) <= maxchars then return container end
  local parts = vim.split(container, sep, { plain = true })
  for i = 1, #parts - 1 do
    parts[i] = initials(parts[i])
    local s = table.concat(parts, sep)
    if M.char_count(s) <= maxchars then return s end
  end
  return M.truncate_left(table.concat(parts, sep), maxchars)
end

--- Like `truncate`, but keeps the end: the distinctive part of a qualified
--- name (`Module.Sub.function/1`) is its last segments.
function M.truncate_left(s, maxchars)
  if not s then return '' end
  local n = vim.fn.strchars(s)
  if n <= maxchars then return s end
  if maxchars <= 1 then return '…' end
  return '…' .. vim.fn.strcharpart(s, n - maxchars + 1)
end

return M
