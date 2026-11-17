--- Layered layout for a callgraph: nodes are stacked in columns by depth and
--- edges are routed orthogonally. For callout the root sits in the leftmost
--- column; for callin the whole graph is mirrored (root rightmost). Edge
--- arrows always point at the callee (the right-hand box).
---
--- Pure computation: input graph + opts, output boxes/edges geometry. No
--- window or buffer interaction.

local util = require('callgraph.util')

local M = {}

-- Box geometry per style. boxed: top border, container row, name row, bottom
-- border. dense: one borderless row, `container.name ❯`.
-- name_row: offset from the box top of the row edges attach to.
M.STYLES = {
  boxed = { height = 4, name_row = 2 },
  dense = { height = 1, name_row = 0 },
}
M.NAME_ROW = M.STYLES.boxed.name_row

-- The location label: `file:line` cut to max_loc_width for the box, the path
-- relative to the working directory for the focus float, and whether the cut
-- took anything off.
local function text_label(graph, n, show_call_site, max_loc_width)
  if not show_call_site then return nil end
  local path, line
  if n == graph.root and n.uri and n.range then
    path, line = vim.uri_to_fname(n.uri), (n.range.start.line or 0) + 1
  elseif n.source == 'cscope' and n.call_site then
    -- cscope -L output is call sites, so show where the call happens.
    path, line = vim.uri_to_fname(n.call_site.uri), n.call_site.line + 1
  elseif n.uri and n.range then
    -- lsp / auto: the item range is the definition — show that, not the call site.
    path, line = vim.uri_to_fname(n.uri), (n.range.start.line or 0) + 1
  end
  if not path then return nil end
  local suffix = ':' .. tostring(line)
  local loc = vim.fn.fnamemodify(path, ':t') .. suffix
  local cut = util.truncate_left(loc, max_loc_width)
  return cut, vim.fn.fnamemodify(path, ':~:.') .. suffix, cut ~= loc
end

local function all_children_visible(graph, n)
  for _, cid in ipairs(n.children) do
    local c = graph.nodes[cid]
    if c and not c.visible then return false end
  end
  return true
end

-- Emit a plain axis-aligned run (no glyphs): junction glyphs are resolved at
-- render time so crossings/turns render as proper ┬ ├ ┼ shapes, and the arrow
-- connects to the line through a short dash (`└─→`) instead of floating (`└>`).
local function add_run(segments, r1, c1, r2, c2, dir)
  segments[#segments + 1] = { r1 = r1, c1 = c1, r2 = r2, c2 = c2, dir = dir }
end

local function add_forward_edge(edges, sb, tb, name_row)
  local R1 = sb.row + name_row
  local R2 = tb.row + name_row
  local src_right = sb.col + sb.width - 1
  local tgt_left = tb.col
  -- A dense box is its column's width but its text may be shorter: the line
  -- starts one blank after the text and runs to the column's shared channel.
  local start = sb.text_end and (sb.text_end + 2) or (src_right + 1)
  local segments = {}
  if R1 == R2 then
    -- straight: dashes up to the arrowhead at the child's left gap
    if tgt_left - 2 >= start then
      add_run(segments, R1, start, R1, tgt_left - 2, 'h')
    end
  else
    -- Vertical channel near the source: a same-row (straight) edge runs
    -- continuously from the branch point to the target. (The junction glyphs
    -- were previously swapped in render.lua, which made the branch stub stick
    -- out left of the vertical line — that is fixed there.)
    local xj = src_right + 2
    if xj > tgt_left - 3 then xj = tgt_left - 3 end
    if xj >= start then
      add_run(segments, R1, start, R1, xj, 'h')
    end
    if R1 < R2 then
      add_run(segments, R1, xj, R2, xj, 'v')
    else
      add_run(segments, R2, xj, R1, xj, 'v')
    end
    -- connector to the cell before the arrowhead; includes the corner cell
    if tgt_left - 2 >= xj then
      add_run(segments, R2, xj, R2, tgt_left - 2, 'h')
    end
  end
  edges[#edges + 1] = { segments = segments, arrow = { row = R2, col = tgt_left - 1, dir = 'r' } }
end

-- Vertical: from below the upper box down to the lower one. Each attaches a
-- couple of cells in from its left edge (a parent sits over its first child,
-- so that edge drops straight); the line turns on the junction row under the
-- upper box and the arrow sits just above the lower box.
local function add_down_edge(edges, ub, lb)
  local function attach(b) return b.col + (b.dense and 1 or 2) end
  local ua, la = attach(ub), attach(lb)
  local J = ub.row + ub.height -- junction row, just below the upper box
  local segments = {}
  -- Start inside the upper box's last row (drawn over by the box) so the
  -- junction cell connects upward.
  add_run(segments, ub.row + ub.height - 1, ua, J, ua, 'v')
  if ua ~= la then add_run(segments, J, math.min(ua, la), J, math.max(ua, la), 'h') end
  -- Down to the arrow cell, so the corner above it connects downward.
  add_run(segments, J, la, lb.row - 1, la, 'v')
  edges[#edges + 1] = { segments = segments, arrow = { row = lb.row - 1, col = la, dir = 'd' } }
end

--- Compute the full layout for a graph (tree mode).
function M.layout(graph, opts, view_state)
  local win = opts.window
  local max_name_width = win.max_name_width
  local max_func_width = win.max_func_width or max_name_width
  local max_loc_width = win.max_loc_width
  local show_call_site = opts.show_call_site
  local style = (view_state and view_state.style) or win.style or 'boxed'
  local dense = style == 'dense'
  local BOX_H = M.STYLES[style].height
  local name_row = M.STYLES[style].name_row
  -- Dense rows stack with no gap: that is the point of the style.
  local row_gap = dense and 0 or win.row_gap
  local col_gap = win.col_gap

  local max_depth = graph.max_visible_depth
  -- In a 'both' graph callers fan out left of the root, callees right.
  local max_in = graph.max_visible_in or 0
  local function col_of(node)
    local d = node.depth
    if graph.direction == 'both' then
      if node.side == 'callin' then return max_in - d end
      return max_in + d
    end
    if graph.direction == 'callin' then return max_depth - d end
    return d
  end

  -- Per-node display text. Row 1: the container (dim) and the location label,
  -- right-aligned. Row 2: the name's last part and the marker slot.
  local texts = {}
  for id, n in pairs(graph.nodes) do
    if n.visible then
      local full_container, short, sep = util.split_name(n.name or '?')
      local container = util.abbreviate(full_container, sep, max_name_width)
      local name = util.truncate_left(short, max_func_width)
      local loc, full_loc, loc_cut = text_label(graph, n, show_call_site, max_loc_width)
      loc, full_loc = loc or '', full_loc or ''
      -- A single reserved marker slot (space + one symbol): ⟳ (cycle) or ❯
      -- (expandable). The two never co-occur, so one slot keeps widths stable
      -- across expand/collapse while reserving less space.
      local marker = '  '
      if n.is_cycle then
        marker = ' ⟳'
      elseif n.def_pending or (n.has_children and not all_children_visible(graph, n)) then
        marker = ' ' .. win.collapse_marker
      end
      local gap = (container ~= '' and loc ~= '') and 2 or 0
      -- Dense: one row; the location lives in the bottom line only.
      local prefix = container ~= '' and (container .. sep) or ''
      local dense_text = prefix .. util.truncate_left(short, max_func_width) .. (vim.trim(marker) ~= '' and marker or '')
      texts[n.id] = {
        prefix = prefix,
        dense_text = dense_text,
        container = container,
        loc = loc,
        name = name,
        marker = marker,
        full_container = full_container,
        full_prefix = full_container ~= '' and (full_container .. sep) or '',
        full_name = short,
        full_loc = full_loc,
        -- The box hides something: the focus float shows it in full.
        shortened = container ~= full_container or name ~= short or (not dense and loc_cut == true),
        name_width = util.char_count(name),
        width = dense and util.char_count(dense_text) or math.max(
          util.char_count(container) + gap + util.char_count(loc),
          util.char_count(name) + util.char_count(marker)
        ),
      }
    end
  end

  -- Levels: the index col_of gives (callers before the root, callees after).
  -- Horizontal: levels are columns, each as wide as its widest box (sources
  -- in a column share one edge channel). Vertical: levels are rows, callers
  -- above; each box keeps its own width, since width is the scarce axis.
  local vertical = view_state and view_state.orientation == 'vertical'
  local level_gap = 2 -- vertical: one junction row and one arrow row
  local col_width = {}
  local max_col = 0
  for id, n in pairs(graph.nodes) do
    if n.visible then
      local c = col_of(n)
      if c > max_col then max_col = c end
      col_width[c] = math.max(col_width[c] or 0, texts[id].width + 2)
    end
  end
  local col_x = {}
  local x = 3 -- left margin (room for edge arrows / verticals into column 0)
  for c = 0, max_col do
    col_x[c] = x
    x = x + (col_width[c] or 0) + col_gap
  end
  local function level_pos(c)
    if vertical then return 1 + c * (BOX_H + level_gap) end
    return col_x[c]
  end
  local function box_width(node, c)
    if vertical then return texts[node.id].width + 2 end
    return col_width[c] or 0
  end

  -- Tree layout: bands are assigned by a post-order DFS so each node's
  -- subtree occupies a contiguous band (rows in horizontal, columns in
  -- vertical) and sibling subtrees never overlap. That keeps every
  -- parent->child L-shaped edge inside its own band — no crossings.
  local boxes = {}
  local max_bottom, max_right = 0, 0
  local cursor = vertical and 2 or 1
  local band_gap = vertical and col_gap or row_gap
  local function band_size(node, c)
    if vertical then return box_width(node, c) end
    return BOX_H
  end
  local function make_box(node, c, band)
    local w = box_width(node, c)
    local t = texts[node.id]
    local row, col
    if vertical then row, col = level_pos(c), band else row, col = band, level_pos(c) end
    -- Pad both rows to the inner width so the location and marker line up on
    -- the right edge.
    local inner = w - 2
    local pad1 = inner - util.char_count(t.container) - util.char_count(t.loc)
    local pad2 = inner - t.name_width - util.char_count(t.marker)
    local line1 = t.container .. string.rep(' ', math.max(pad1, 0)) .. t.loc
    local line2 = t.name .. string.rep(' ', math.max(pad2, 0)) .. t.marker
    if dense then line1, line2 = nil, t.dense_text end
    local box = {
      id = node.id,
      row = row,
      col = col,
      width = w,
      height = BOX_H,
      dense = dense or nil,
      name_row = name_row,
      line1 = line1,
      text = line2,
      text_width = util.char_count(line2),
      -- Dense: the last text column, where edges leaving the box start from.
      text_end = dense and (col + util.char_count(line2)) or nil,
      -- Characters before the name on the name row (dense: the container).
      name_offset = dense and util.char_count(t.prefix) or 0,
      name_width = t.name_width,
      marker = t.marker,
      full_container = t.full_container,
      full_prefix = t.full_prefix,
      full_name = t.full_name,
      full_loc = t.full_loc,
      shortened = t.shortened,
      -- Function-name span in 0-based buffer columns: [name_start, name_end).
      name_start = col + (dense and util.char_count(t.prefix) or 0),
      name_end = col + (dense and util.char_count(t.prefix) or 0) + t.name_width,
    }
    boxes[node.id] = box
    max_bottom = math.max(max_bottom, row + BOX_H - 1)
    max_right = math.max(max_right, col + w - 1)
    return box
  end
  local function visible_children(node, side)
    local out = {}
    for _, cid in ipairs(node.children) do
      local ch = graph.nodes[cid]
      if ch and ch.visible and (not side or ch.side == side) then out[#out + 1] = ch end
    end
    return out
  end
  -- Place `children` from the cursor; returns the first child's band start.
  local place
  local function place_children(children)
    local first
    for _, ch in ipairs(children) do
      local start = place(ch)
      first = first or start
    end
    return first
  end
  -- After a parent: the cursor moves past the parent itself too (in vertical
  -- a parent can be wider than its children's band).
  local function finish(node, c, start)
    cursor = math.max(cursor, start + band_size(node, c) + band_gap)
    make_box(node, c, start)
    return start
  end
  place = function(node)
    local c = col_of(node)
    if graph.direction == 'both' and node == graph.root then
      -- Each side is its own band from the same start, so callers and
      -- callees line up beside (or above and below) the root.
      local from, reach, start = cursor, cursor, nil
      for _, side in ipairs({ 'callin', 'callout' }) do
        cursor = from
        local first = place_children(visible_children(node, side))
        if first then start = math.min(start or first, first) end
        reach = math.max(reach, cursor)
      end
      cursor = reach
      return finish(node, c, start or from)
    end
    local children = visible_children(node)
    if #children == 0 then
      local start = cursor
      return finish(node, c, start)
    end
    -- Align the parent to its first child so its edges fan out from there.
    return finish(node, c, place_children(children))
  end
  place(graph.root)

  local gutter_row = max_bottom + 2
  local height = gutter_row + 1
  local width = (vertical and (max_right + 2) or (x - col_gap + 1)) -- right margin
  if width < 1 then width = 1 end

  -- Route edges between each parent and child. Horizontal: the left box is
  -- the source of an L-shaped edge into the right one. Vertical: the upper
  -- box into the lower one. Either way the arrow points at the callee.
  local edges = {}
  for id, n in pairs(graph.nodes) do
    if n.visible then
      for _, cid in ipairs(n.children) do
        local c = graph.nodes[cid]
        local sb, tb = boxes[n.id], c and c.visible and boxes[cid]
        if sb and tb then
          if vertical then
            if sb.row > tb.row then sb, tb = tb, sb end
            if sb.row < tb.row then add_down_edge(edges, sb, tb) end
          else
            if sb.col > tb.col then sb, tb = tb, sb end
            if sb.col < tb.col then add_forward_edge(edges, sb, tb, name_row) end
          end
        end
      end
    end
  end

  return {
    width = width,
    height = height,
    boxes = boxes,
    edges = edges,
    gutter_row = gutter_row,
    max_col = max_col,
    style = style,
    name_row = name_row,
    orientation = vertical and 'vertical' or 'horizontal',
  }
end

return M
