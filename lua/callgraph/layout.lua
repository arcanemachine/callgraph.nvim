--- Layered layout for a callgraph: nodes are stacked in columns by depth and
--- edges are routed orthogonally. For callout the root sits in the leftmost
--- column; for callin the whole graph is mirrored (root rightmost). Edge
--- arrows always point at the callee (the right-hand box).
---
--- Pure computation: input graph + opts, output boxes/edges geometry. No
--- window or buffer interaction.

local util = require('callgraph.util')

local M = {}

local BOX_H = 4 -- top border, container row, name row, bottom border
-- Row offset (from the box top) of the name row, where edges attach.
M.NAME_ROW = 2

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

local function add_forward_edge(edges, sb, tb)
  local R1 = sb.row + M.NAME_ROW
  local R2 = tb.row + M.NAME_ROW
  local src_right = sb.col + sb.width - 1
  local tgt_left = tb.col
  local segments = {}
  if R1 == R2 then
    -- straight: dashes up to the arrowhead at the child's left gap
    if tgt_left - 2 >= src_right + 1 then
      add_run(segments, R1, src_right + 1, R1, tgt_left - 2, 'h')
    end
  else
    -- Vertical channel near the source: a same-row (straight) edge runs
    -- continuously from the branch point to the target. (The junction glyphs
    -- were previously swapped in render.lua, which made the branch stub stick
    -- out left of the vertical line — that is fixed there.)
    local xj = src_right + 2
    if xj > tgt_left - 3 then xj = tgt_left - 3 end
    if xj >= src_right + 1 then
      add_run(segments, R1, src_right + 1, R1, xj, 'h')
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

--- Compute the full layout for a graph (tree mode).
function M.layout(graph, opts, view_state)
  local win = opts.window
  local max_name_width = win.max_name_width
  local max_func_width = win.max_func_width or max_name_width
  local max_loc_width = win.max_loc_width
  local show_call_site = opts.show_call_site
  local row_gap = win.row_gap
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
      texts[n.id] = {
        container = container,
        loc = loc,
        name = name,
        marker = marker,
        full_container = full_container,
        full_name = short,
        full_loc = full_loc,
        -- The box hides something: the focus float shows it in full.
        shortened = container ~= full_container or name ~= short or loc_cut == true,
        name_width = util.char_count(name),
        width = math.max(
          util.char_count(container) + gap + util.char_count(loc),
          util.char_count(name) + util.char_count(marker)
        ),
      }
    end
  end

  -- Size each depth column by its widest visible box.
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

  -- Tree layout: rows are assigned by a post-order DFS so each node's subtree
  -- occupies a contiguous vertical band and sibling subtrees never overlap.
  -- That keeps every parent->child L-shaped edge inside its own band — no
  -- shared vertical channels, no crossings.
  local boxes = {}
  local max_bottom = 0
  local y_cursor = 1
  local function make_box(node, c, row)
    local w = col_width[c] or 0
    local t = texts[node.id]
    -- Pad both rows to the inner width so the location and marker line up on
    -- the right edge.
    local inner = w - 2
    local pad1 = inner - util.char_count(t.container) - util.char_count(t.loc)
    local pad2 = inner - t.name_width - util.char_count(t.marker)
    local line1 = t.container .. string.rep(' ', math.max(pad1, 0)) .. t.loc
    local line2 = t.name .. string.rep(' ', math.max(pad2, 0)) .. t.marker
    local box = {
      id = node.id,
      row = row,
      col = col_x[c],
      width = w,
      height = BOX_H,
      line1 = line1,
      text = line2,
      text_width = util.char_count(line2),
      name_width = t.name_width,
      marker = t.marker,
      full_container = t.full_container,
      full_name = t.full_name,
      full_loc = t.full_loc,
      shortened = t.shortened,
      -- Function-name span in 0-based buffer columns: [name_start, name_end).
      name_start = col_x[c],
      name_end = col_x[c] + t.name_width,
    }
    boxes[node.id] = box
    if row + BOX_H - 1 > max_bottom then max_bottom = row + BOX_H - 1 end
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
  local place
  -- A 'both' root: each side is its own band from the same top, so callers
  -- and callees line up beside the root.
  local function place_both_root(node)
    local start = y_cursor
    local top, bottom
    for _, side in ipairs({ 'callin', 'callout' }) do
      y_cursor = start
      local side_top
      for _, ch in ipairs(visible_children(node, side)) do
        local t, b = place(ch)
        side_top = side_top or t
        bottom = math.max(bottom or b, b)
      end
      if side_top then top = math.min(top or side_top, side_top) end
    end
    if not top then
      top, bottom = start, start
      y_cursor = start + BOX_H + row_gap
    else
      y_cursor = math.max(y_cursor, bottom + BOX_H + row_gap)
    end
    make_box(node, col_of(node), top)
    return top, bottom
  end
  place = function(node)
    if graph.direction == 'both' and node == graph.root then return place_both_root(node) end
    local children = visible_children(node)
    local top, bottom
    if #children == 0 then
      top, bottom = y_cursor, y_cursor
      y_cursor = y_cursor + BOX_H + row_gap
    else
      for _, ch in ipairs(children) do
        local t, b = place(ch)
        if not top then top = t end
        bottom = b
      end
      -- Align the parent to its first child's top so its outgoing edges fan
      -- top-down to every child.
      top = boxes[children[1].id].row
    end
    make_box(node, col_of(node), top)
    return top, bottom
  end
  place(graph.root)

  local gutter_row = max_bottom + 2
  local height = gutter_row + 1
  local width = x - col_gap + 1 -- right margin
  if width < 1 then width = 1 end

  -- Route edges: parent -> child between adjacent columns. For callin the
  -- parent (deeper) sits right of its callers, so swap to keep the left box
  -- as the source of the L-shaped edge.
  local edges = {}
  for id, n in pairs(graph.nodes) do
    if n.visible then
      for _, cid in ipairs(n.children) do
        local c = graph.nodes[cid]
        if c and c.visible then
          local s, t = n, c
          local sb, tb = boxes[s.id], boxes[t.id]
          if sb and tb then
            if sb.col > tb.col then s, t = t, s; sb, tb = tb, sb end
            if sb.col < tb.col then
              add_forward_edge(edges, sb, tb)
            end
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
  }
end

return M
