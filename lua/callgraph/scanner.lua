--- Pure C source scanner: finds `identifier(` call-site tokens inside a
--- function body, skipping strings, char literals, comments, preprocessor
--- lines, and the function's own signature (scanning starts after the first
--- `{`). Used by the heuristic callout fallback when a server lacks outgoing
--- call hierarchy (e.g. clangd < 20).
---
--- Output positions are { line, col } with 0-based line and 0-based byte
--- column, both relative to the scanned text.

local M = {}

-- C keywords that may be followed by '(' without being a function call.
-- (Keys are quoted because several are Lua reserved words.)
local KEYWORDS = {
  ['if'] = true, ['for'] = true, ['while'] = true, switch = true, ['return'] = true,
  sizeof = true, ['do'] = true, ['else'] = true, typedef = true, struct = true,
  union = true, ['enum'] = true, ['case'] = true, ['catch'] = true, try = true,
  _Alignof = true, _Static_assert = true, _Generic = true, ['__attribute__'] = true,
  ['__typeof__'] = true, typeof = true,
}

local function is_ident_start(b)
  return (b >= 0x41 and b <= 0x5A) or (b >= 0x61 and b <= 0x7A) or b == 0x5F
end

local function is_ident_char(b)
  return is_ident_start(b) or (b >= 0x30 and b <= 0x39)
end

--- Scan `text` for call-site token positions.
--- @param text string Source text of a function range.
--- @return table[] list of { line, byte_col, name } (line/col 0-based; name is
---   the identifier, useful when the server can't resolve the token).
function M.scan_calls(text)
  local n = #text
  local out = {}
  local line, col = 0, 0 -- position of the next char to consume
  local in_body = false
  local i = 1

  while i <= n do
    local b = string.byte(text, i)

    if b == 0x0A then
      line = line + 1
      col = 0
      i = i + 1
    elseif b == 0x23 then
      -- preprocessor directive: skip to end of line
      while i <= n and string.byte(text, i) ~= 0x0A do i = i + 1 end
    elseif b == 0x2F and string.byte(text, i + 1) == 0x2F then
      -- line comment
      while i <= n and string.byte(text, i) ~= 0x0A do i = i + 1 end
    elseif b == 0x2F and string.byte(text, i + 1) == 0x2A then
      -- block comment
      i = i + 2
      while i <= n do
        local cb = string.byte(text, i)
        if cb == 0x0A then
          line = line + 1
          col = 0
          i = i + 1
        elseif cb == 0x2A and string.byte(text, i + 1) == 0x2F then
          col = col + 1
          i = i + 2
          break
        else
          col = col + 1
          i = i + 1
        end
      end
    elseif b == 0x22 or b == 0x27 then
      -- string / char literal
      local quote = b
      i = i + 1
      while i <= n do
        local cb = string.byte(text, i)
        if cb == 0x5C then
          i = i + 2
          col = col + 2
        elseif cb == 0x0A then
          line = line + 1
          col = 0
          i = i + 1
        elseif cb == quote then
          col = col + 1
          i = i + 1
          break
        else
          col = col + 1
          i = i + 1
        end
      end
    elseif b == 0x7B then
      if not in_body then in_body = true end
      col = col + 1
      i = i + 1
    elseif is_ident_start(b) then
      local id_line, id_col = line, col
      local start_i = i
      i = i + 1
      col = col + 1
      while i <= n and is_ident_char(string.byte(text, i)) do
        i = i + 1
        col = col + 1
      end
      if in_body then
        local word = text:sub(start_i, i - 1)
        if not KEYWORDS[word] then
          -- lookahead past spaces/tabs/newlines for '('
          local j = i
          local c = string.byte(text, j)
          while true do
            if c == 0x20 or c == 0x09 or c == 0x0D then
              j = j + 1
              col = col + 1
            elseif c == 0x0A then
              j = j + 1
              line = line + 1
              col = 0
            else
              break
            end
            c = string.byte(text, j)
          end
          if c == 0x28 then
            out[#out + 1] = { id_line, id_col, word }
          end
          i = j
        end
      end
    else
      col = col + 1
      i = i + 1
    end
  end

  return out
end

--- Find all definition lines for `name` in C source `text`. A text-level scan:
--- a definition is `<rettype> name(`, i.e. the identifier `name` followed by
--- `(` whose preceding token is a non-keyword identifier (the return type).
--- This sees BOTH conditionally-compiled branches (`#ifdef`/`#else`) — unlike a
--- semantic server, which only parses the active one. Skips comments, strings,
--- char literals and preprocessor directive lines.
--- @param text string Source text (a whole file, not a function range).
--- @param name string Function name to look for.
--- @return table[] list of { line, byte_col } (0-based) definition starts.
function M.find_definitions(text, name)
  local out = {}
  local n = #text
  local line, col = 0, 0
  local prev_ident = nil -- previous identifier token (or nil after punctuation)
  local i = 1
  while i <= n do
    local b = string.byte(text, i)
    if b == 0x0A then
      line = line + 1
      col = 0
      i = i + 1
    elseif b == 0x23 and col == 0 then
      -- preprocessor directive line (whole line skipped, not just #ifdef)
      while i <= n and string.byte(text, i) ~= 0x0A do i = i + 1 end
    elseif b == 0x2F and string.byte(text, i + 1) == 0x2F then
      while i <= n and string.byte(text, i) ~= 0x0A do i = i + 1 end
    elseif b == 0x2F and string.byte(text, i + 1) == 0x2A then
      i = i + 2
      col = col + 2
      while i <= n do
        local cb = string.byte(text, i)
        if cb == 0x0A then
          line = line + 1
          col = 0
          i = i + 1
        elseif cb == 0x2A and string.byte(text, i + 1) == 0x2F then
          col = col + 1
          i = i + 2
          break
        else
          col = col + 1
          i = i + 1
        end
      end
    elseif b == 0x22 or b == 0x27 then
      local quote = b
      i = i + 1
      while i <= n do
        local cb = string.byte(text, i)
        if cb == 0x5C then
          i = i + 2
          col = col + 2
        elseif cb == 0x0A then
          line = line + 1
          col = 0
          i = i + 1
        elseif cb == quote then
          col = col + 1
          i = i + 1
          break
        else
          col = col + 1
          i = i + 1
        end
      end
    elseif is_ident_start(b) then
      local id_line, id_col = line, col
      local start_i = i
      i = i + 1
      col = col + 1
      while i <= n and is_ident_char(string.byte(text, i)) do
        i = i + 1
        col = col + 1
      end
      local word = text:sub(start_i, i - 1)
      -- Lookahead past spaces for '('.
      local j = i
      local c = string.byte(text, j)
      while c == 0x20 or c == 0x09 or c == 0x0D do
        j = j + 1
        c = string.byte(text, j)
      end
      if c == 0x28 and word == name then
        -- Definition iff the preceding token is a non-keyword identifier
        -- (the return type) — not a call (return impl(), x = impl(), etc.).
        if prev_ident and not KEYWORDS[prev_ident] then
          out[#out + 1] = { id_line, id_col }
        end
      end
      prev_ident = word
    else
      if b ~= 0x20 and b ~= 0x09 and b ~= 0x0D then prev_ident = nil end
      col = col + 1
      i = i + 1
    end
  end
  return out
end

return M
