--- Render a layout into a scratch buffer: edges first, then boxes on top so
--- boxes stay readable even where an edge would pass underneath. Highlights
--- are applied as extmarks (box/focus/cycle/collapse/edge groups).

local M = {}

-- ns: highlight extmarks (only populated when the `highlight` toggle is on).
-- anchor_ns: one anchor extmark per box at its text start, always populated.
-- The anchor is the source of truth for the text position — cursor placement
-- and highlighting query it via nvim_buf_get_extmarks, so both always land on
-- the exact same character (no off-by-one between them).
M.ns = vim.api.nvim_create_namespace('callgraph')
M.anchor_ns = vim.api.nvim_create_namespace('callgraph_anchors')

local util = require('callgraph.util')

-- Box height in rows (top border, container row, name row, bottom border).
local BOX_H = 4

-- Junction glyphs by connection mask (1=N, 2=S, 4=W, 8=E).
local GLYPH = {
  [1] = '│', [2] = '│', [3] = '│',
  [4] = '─', [8] = '─', [12] = '─',
  [5] = '┘', [6] = '┐', [9] = '└', [10] = '┌',
  -- 7 = N+S+W (vertical + LEFT bar) -> ┤; 11 = N+S+E (vertical + RIGHT bar) -> ├.
  [7] = '┤', [11] = '├', [13] = '┴', [14] = '┬',
  [15] = '┼',
}

local function make_grid(H, W)
  local grid = {}
  for r = 1, H do
    local row = {}
    for c = 1, W do row[c] = ' ' end
    grid[r] = row
  end
  return grid
end

local function put(grid, r, c, ch)
  if r < 1 or c < 1 then return end
  local row = grid[r]
  if row and c <= #row then row[c] = ch end
end

-- Record a color span on `line` covering cols [c0, c1] with a group key
-- ('border' | 'func' | 'loc' | 'edge'). `sel` carries the box id when the span
-- is the focused box's function name (so it can be recolored on selection).
local function add_span(spans, line, c0, c1, group, sel)
  if not spans then return end
  local s = spans[line]
  if not s then s = {}; spans[line] = s end
  s[#s + 1] = { c0 = c0, c1 = c1, group = group, sel = sel }
end

local function draw_box(grid, b, spans, collapse_marker)
  local r, c, w = b.row, b.col, b.width
  local top, bottom = r, r + (b.height or BOX_H) - 1

  -- Dense: one borderless row, `container.name ❯`; only the text is drawn so
  -- the edge line from the text's end to the column edge stays visible.
  if b.dense then
    local col = c + 1
    local idx = 0
    local span_start, span_grp
    local function flush()
      if spans and span_start then
        add_span(spans, r, span_start, col - 1, span_grp, (span_grp == 'func') and b.id or nil)
      end
    end
    for _, ch in ipairs(vim.fn.split(b.text, '\\zs')) do
      idx = idx + 1
      local grp
      if idx <= b.name_offset then grp = 'loc'
      elseif idx <= b.name_offset + b.name_width then grp = 'func'
      elseif ch == ' ' then grp = 'blank'
      else grp = 'symbol' end
      put(grid, r, col, ch)
      if grp ~= span_grp then
        if span_grp ~= 'blank' then flush() end
        span_start, span_grp = col, grp
      end
      col = col + 1
    end
    if span_grp ~= 'blank' then flush() end
    return
  end

  put(grid, top, c, '╭')
  put(grid, top, c + w - 1, '╮')
  put(grid, bottom, c, '╰')
  put(grid, bottom, c + w - 1, '╯')
  for i = c + 1, c + w - 2 do
    put(grid, top, i, '─')
    put(grid, bottom, i, '─')
  end
  for rr = r + 1, r + 2 do
    put(grid, rr, c, '│')
    put(grid, rr, c + w - 1, '│')
    if spans then
      add_span(spans, rr, c, c, 'border')
      add_span(spans, rr, c + w - 1, c + w - 1, 'border')
    end
  end

  -- Write `text` into row `rr`, one span per run of the same group;
  -- `group_of(char_index, char)` names each character's group.
  local function draw_text(rr, text, group_of)
    local col = c + 1
    local last = c + w - 2
    local i, n = 1, #text
    local char_index = 0
    local span_start, span_grp
    local function flush_span()
      if spans and span_start and span_grp and span_grp ~= 'blank' then
        add_span(spans, rr, span_start, col - 1, span_grp, (span_grp == 'func') and b.id or nil)
      end
    end
    while i <= n do
      local byte = string.byte(text, i)
      local char
      if byte < 0x80 then
        char = string.sub(text, i, i); i = i + 1
      elseif byte < 0xE0 then
        char = string.sub(text, i, i + 1); i = i + 2
      elseif byte < 0xF0 then
        char = string.sub(text, i, i + 2); i = i + 3
      else
        char = string.sub(text, i, i + 3); i = i + 4
      end
      if col <= last then
        grid[rr][col] = char
        char_index = char_index + 1
        local grp = group_of(char_index, char)
        if spans and grp ~= span_grp then
          flush_span()
          span_start, span_grp = col, grp
        end
        col = col + 1
      end
    end
    flush_span()
  end

  -- Container row: container and location label, both dim.
  draw_text(r + 1, b.line1 or '', function(_, char)
    return char == ' ' and 'blank' or 'loc'
  end)
  -- Name row: the name, then the marker (⟳ / ❯).
  draw_text(r + 2, b.text, function(idx, char)
    if idx <= b.name_width then return 'func' end
    if char == '⟳' or (collapse_marker and char == collapse_marker) then return 'symbol' end
    return 'blank'
  end)
end

--- Render `layout` into `buf`.
--- `view` = { selected_id = id, highlights = config.highlights }
function M.render(buf, layout, graph, view)
  local W = math.max(layout.width, 1)
  local H = math.max(layout.height, 1)
  local grid = make_grid(H, W)
  local spans = {} -- line -> { {c0,c1,group,sel}, ... } for the colors mode

  -- Edges first. Build a per-cell connection mask (1=N, 2=S, 4=W, 8=E) from
  -- all axis-aligned runs, then render the correct box-drawing glyph per cell
  -- (corners, T-junctions, crossings). This keeps line junctions connected.
  local bit = require('bit')
  local masks = {} -- 'r,c' -> bitmask (1=N, 2=S, 4=W, 8=E), OR-ed across runs
  local hints = {} -- 'r,c' -> 'h'|'v' for single-cell runs
  for _, e in ipairs(layout.edges) do
    for _, seg in ipairs(e.segments) do
      if seg.dir == 'h' then
        for cc = seg.c1, seg.c2 do
          local k = seg.r1 .. ',' .. cc
          local m = masks[k] or 0
          if cc > seg.c1 then m = bit.bor(m, 4) end
          if cc < seg.c2 then m = bit.bor(m, 8) end
          masks[k] = m
          hints[k] = 'h'
        end
      else
        for rr = seg.r1, seg.r2 do
          local k = rr .. ',' .. seg.c1
          local m = masks[k] or 0
          if rr > seg.r1 then m = bit.bor(m, 1) end
          if rr < seg.r2 then m = bit.bor(m, 2) end
          masks[k] = m
          hints[k] = 'v'
        end
      end
    end
  end
  for k, m in pairs(masks) do
    if m == 0 then -- single-cell run: render as its direction
      m = (hints[k] == 'v') and 3 or 12
    end
    local rr, cc = k:match('^(%d+),(%d+)$')
    rr, cc = tonumber(rr), tonumber(cc)
    put(grid, rr, cc, GLYPH[m])
    add_span(spans, rr, cc, cc, 'edge')
  end

  -- Arrowheads: glyphs come from `view.arrows` (config `window.arrows`) so
  -- Unicode triangles or Nerd Font arrows can be chosen freely.
  local arrows = view.arrows or { right = '', down = '', up = '', left = '' }
  for _, e in ipairs(layout.edges) do
    if e.arrow then
      local ch = (e.arrow.dir == 'd' and arrows.down) or (e.arrow.dir == 'u' and arrows.up) or (e.arrow.dir == 'l' and arrows.left) or arrows.right
      put(grid, e.arrow.row, e.arrow.col, ch)
      add_span(spans, e.arrow.row, e.arrow.col, e.arrow.col, 'edge')
    end
  end

  -- Boxes on top.
  for _, b in pairs(layout.boxes) do
    draw_box(grid, b, spans, view.collapse_marker)
  end

  -- Tab labels live on the native 'tabline' (see view.update_tabline), so the
  -- canvas starts at row 0 and anchors need no offset.
  local lines = {}
  for r = 1, H do lines[#lines + 1] = table.concat(grid[r]) end

  local modifiable = vim.bo[buf].modifiable
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = modifiable

  -- Clear stale marks and anchor every box to its text start. nvim_buf_set_extmark
  -- uses BYTE columns, so convert the character index (b.col) to bytes.
  vim.api.nvim_buf_clear_namespace(buf, M.anchor_ns, 0, -1)
  vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
  layout.box_marks = {}
  for id, b in pairs(layout.boxes) do
    -- The anchor sits on the name: grid row b.row + name_row is buffer row
    -- b.row + name_row - 1 (0-based); the name starts name_offset characters
    -- after the first text column (0-based character b.col).
    local name_row = b.name_row or 2
    local line_text = lines[b.row + name_row] or ''
    local byte_col = util.char_to_byte(line_text, b.col + (b.name_offset or 0))
    layout.box_marks[id] = vim.api.nvim_buf_set_extmark(buf, M.anchor_ns, b.row + name_row - 1, byte_col, {})
  end

  -- Colors mode: color every part (borders, function names, locations, edges)
  -- and recolor the focused box's name. Falls back to the legacy highlight path
  -- (focus + dim location) when colors are off.
  if view.colors then
    local group_map = { border = 'CallgraphBorder', func = 'CallgraphFunc', loc = 'CallgraphLocation', edge = 'CallgraphEdge', symbol = 'CallgraphSymbol' }
    for line, list in pairs(spans) do
      -- spans key on 1-based grid rows; extmarks use 0-based buffer rows.
      local line_text = lines[line] or ''
      for _, sp in ipairs(list) do
        local g = group_map[sp.group]
        if g then
          if sp.group == 'func' and sp.sel == view.selected_id then
            g = 'CallgraphFocus'
          end
          -- spans use 1-based layout columns; char_to_byte is 0-based.
          local byte0 = util.char_to_byte(line_text, sp.c0 - 1)
          local byte1 = util.char_to_byte(line_text, sp.c1)
          vim.api.nvim_buf_set_extmark(buf, M.ns, line - 1, byte0, { end_col = byte1, hl_group = g })
        end
      end
    end
    return
  end

  -- Highlighting is opt-in and defaults to off. When off, no highlight code
  -- runs at all; the canvas is drawn with the default terminal colors.
  if not view.highlight then return end

  local hl = view.highlights

  for id, b in pairs(layout.boxes) do
    local mark_id = layout.box_marks[id]
    if mark_id then
      local pos = vim.api.nvim_buf_get_extmark_by_id(buf, M.anchor_ns, mark_id, {})
      if pos then
        local line_text = lines[pos[1] + 1] or ''
        local name_end = util.char_to_byte(line_text, b.col + (b.name_offset or 0) + b.name_width)

        -- Dim the container: boxed, its own row (with the location) just above
        -- the name row; dense, the text before the name.
        local row1_line = b.dense and pos[1] or pos[1] - 1
        local row1_text = lines[row1_line + 1] or ''
        local row1_start = util.char_to_byte(row1_text, b.col)
        local row1_end = b.dense and pos[2] or util.char_to_byte(row1_text, b.col + b.width - 2)
        if row1_end > row1_start then
          vim.api.nvim_buf_set_extmark(buf, M.ns, row1_line, row1_start, {
            end_col = row1_end,
            hl_group = hl.loc,
            priority = 2,
          })
        end

        -- Selected box: brighten the function name on top.
        if id == view.selected_id then
          vim.api.nvim_buf_set_extmark(buf, M.ns, pos[1], pos[2], {
            end_col = name_end,
            hl_group = hl.focus,
            priority = 3,
          })
        end
      end
    end
  end
end

return M
