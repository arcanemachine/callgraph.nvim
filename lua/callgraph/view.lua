--- The callgraph view: a right-side split window hosting multiple independent
--- tabs (one per function + direction), a tab bar, fixed-width sizing,
--- buffer-local keymaps, mouse interaction, hover echo, and the async glue
--- between LSP data and the layout/render core.

local config = require('callgraph.config')
local debug = require('callgraph.debug')
local graph_mod = require('callgraph.graph')
local layout_mod = require('callgraph.layout')
local picker = require('callgraph.picker')
local render_mod = require('callgraph.render')
local scanner = require('callgraph.scanner')
local lsp_mod = require('callgraph.lsp')
local source_mod = require('callgraph.source')
local util = require('callgraph.util')

local M = {}
local state = nil
local zoom_ns = vim.api.nvim_create_namespace('callgraph_zoom')

-- ---------------------------------------------------------------------------
-- Entry points
-- ---------------------------------------------------------------------------

--- Open (or reuse) the view for the function under the cursor.
function M.open(direction)
  util.async_start(function()
    local ok, err = pcall(function()
      local bufnr = vim.api.nvim_get_current_buf()
      local curr_win = vim.api.nvim_get_current_win()
      if state and state.win and curr_win == state.win and state.orig_win and vim.api.nvim_win_is_valid(state.orig_win) then
        bufnr = vim.api.nvim_win_get_buf(state.orig_win)
      end
      local opts = config.get()
      source_mod.check_available(opts)
      local root, encoding, client = source_mod.resolve_root(bufnr, opts)
      if not root then return end
      M.open_with_root(root, direction, encoding, client)
    end)
    if not ok then
      vim.notify('Callgraph: ' .. tostring(err), vim.log.levels.ERROR)
    end
  end)
end

--- Tab identity: arrow before the name = callin, after = callout, both = both.
local function tab_key(name, direction, arrows)
  if direction == 'callin' then return arrows.right .. name end
  if direction == 'both' then return arrows.right .. name .. arrows.right end
  return name .. arrows.right
end

-- Switch the active tab, remembering the previous one so closing a tab can
-- return to wherever the user was before (temporarily flipping direction with
-- i/o and closing lands back on the originating tab).
local function set_active(i)
  if i ~= state.active then
    state.prev_active = state.active
    state.active = i
  end
end

-- Make the callgraph window the current one. The very first open focuses it
-- via open_float; every later open/reuse must switch focus here so calling
-- :Callout/:Callin from the editor lands in the graph window.
local function focus_view()
  if not state or not state.win or not vim.api.nvim_win_is_valid(state.win) then return end
  if vim.api.nvim_get_current_win() ~= state.win then
    vim.api.nvim_set_current_win(state.win)
  end
end

-- ---------------------------------------------------------------------------
-- Tab bar on the window's winbar
-- ---------------------------------------------------------------------------

-- Render the logical tabs onto vim.wo[win].winbar, the native window-local
-- top bar. Unlike the global 'tabline' (which would span the whole editor and
-- clash with barbar), the winbar shows only across the callgraph window. Uses
-- statusline syntax; switching tabs is keyboard-driven (<Tab>/<S-Tab>). The
-- right end carries a clickable hint for the key help.
local function update_winbar()
  if not state or not state.win or not vim.api.nvim_win_is_valid(state.win) then return end
  local opts = config.get()
  local hl_active = opts.highlights.tab_active
  local hl_inactive = opts.highlights.tab_inactive
  local parts = {}
  for i, t in ipairs(state.tabs) do
    local label = (i == state.active) and ('[' .. t.key .. ']') or t.key
    local hl = (i == state.active) and hl_active or hl_inactive
    parts[#parts + 1] = '%#' .. hl .. '#' .. label .. '%*'
  end
  local bar = table.concat(parts, '  ')
  local help = opts.keymaps.help
  if help and help ~= '' then
    bar = bar .. '%=%#' .. hl_inactive .. '#%@v:lua.callgraph_help_click@' .. help .. ' keys%X'
  end
  vim.wo[state.win].winbar = bar
end

-- Click handler for the winbar's help hint (statusline clicks need a global).
function _G.callgraph_help_click()
  require('callgraph.view').show_help()
end

function M.open_with_root(root, direction, encoding, client)
  local opts = config.get()
  local win = vim.api.nvim_get_current_win()
  local key = tab_key(root.name, direction, opts.window.arrows)
  -- Two functions can share a name (callbacks, static functions): a tab is
  -- the same one only for the same function, by its identity.
  local ident = graph_mod.node_id(root) .. '\0' .. direction

  if not state or not (state.win and vim.api.nvim_win_is_valid(state.win)) then
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = 'wipe'
    vim.bo[buf].buftype = 'nofile'
    vim.bo[buf].swapfile = false
    vim.bo[buf].modifiable = false
    state = {
      buf = buf,
      win = nil,
      orig_win = win,
      encoding = encoding,
      client = client,
      tabs = {},
      active = 0,
      prev_active = nil, -- tab active before the current one
      last_w = nil,
      keyed = false,
    }
    M.open_float()
  else
    if state.win ~= win then
      state.orig_win = win
    end
    state.encoding = encoding
    state.client = client
  end

  -- Same function + same direction -> reuse the tab (jump to it).
  for i, t in ipairs(state.tabs) do
    if t.ident == ident then
      set_active(i)
      M.render_view()
      M.focus_selected()
      focus_view()
      return
    end
  end

  state.tabs[#state.tabs + 1] = {
    key = key, -- the label on the tab bar
    ident = ident,
    root = root,
    direction = direction,
    view_depth = direction == 'both' and opts.both_depth or opts.max_depth,
    graph = nil,
    selected_id = nil,
    last_layout = nil,
  }
  set_active(#state.tabs)
  focus_view()
  M.rebuild()
end

function M.open_float()
  -- Right-side or bottom-side split window (not a float).
  local pos = config.get().window.position
  local split = (pos == 'bottom') and 'below' or 'right'
  local win = vim.api.nvim_open_win(state.buf, true, {
    split = split,
  })
  state.win = win
  local wo = vim.wo[win]
  wo.wrap = false
  wo.number = false
  wo.relativenumber = false
  wo.signcolumn = 'no'
  -- The canvas pads with spaces; 'list' would draw them (e.g. trail:-).
  wo.list = false
  -- `:q` on the view bypasses M.close; the focus float must go with it.
  vim.api.nvim_create_autocmd('WinClosed', {
    pattern = tostring(win),
    once = true,
    callback = function() M.close_zoom() end,
  })
  M.setup_keymaps()
end

-- ---------------------------------------------------------------------------
-- Tab bar
-- ---------------------------------------------------------------------------

local function active_tab()
  if not state then return nil end
  return state.tabs[state.active]
end

-- ---------------------------------------------------------------------------
-- Build / render pipeline
-- ---------------------------------------------------------------------------

function M.rebuild()
  local tab = active_tab()
  if not tab then return end
  local d = graph_mod.build(tab.root, tab.direction, { max_depth = tab.view_depth }, M.make_fetch())
  d:next(function(graph)
    tab.graph = graph
    tab.selected_id = graph.root.id
    tab.came_from, tab.last_move = nil, nil -- the selection jumped: no way back to remember
    M.render_view()
  end, function(err)
    vim.notify('Callgraph: graph build failed: ' .. tostring(err), vim.log.levels.ERROR)
  end)
end

function M.render_view()
  local opts = config.get()
  local tab = active_tab()
  if not tab then return end
  local layout = layout_mod.layout(tab.graph, opts, {
    direction = tab.direction,
    selected_id = tab.selected_id,
    style = state.style,
    orientation = state.orientation or opts.window.orientation,
  })
  tab.last_layout = layout

  -- Resolve canvas colors each render so `auto` picks up the colorscheme, and
  -- mirror the code area's background onto this window.
  local colors = config.resolve_colors()
  config.apply_colors()
  if colors and colors.bg then
    vim.wo[state.win].winhighlight = 'Normal:CallgraphNormal'
  end

  M.resize_window(opts)
  render_mod.render(state.buf, layout, tab.graph, {
    selected_id = tab.selected_id,
    highlight = opts.highlight,
    highlights = opts.highlights,
    arrows = opts.window.arrows,
    collapse_marker = opts.window.collapse_marker,
    colors = colors,
  })
  update_winbar()
  M.focus_selected()
  M.update_zoom()
end

function M.resize_window(opts)
  local pos = opts.window.position
  if pos == 'bottom' then
    local fh = opts.window.fixed_height or 0
    local h = fh > 0 and fh or 20
    if h < 3 then h = 3 end
    if state.last_w ~= h then
      state.last_w = h
      vim.api.nvim_win_set_height(state.win, h)
    end
  else
    local fw = opts.window.fixed_width or 0
    local w
    if fw > 0 then
      w = fw
    else
      local tab = active_tab()
      local columns = vim.o.columns
      local mw = math.floor(columns * opts.window.max_width_ratio)
      w = math.min((tab and tab.last_layout and tab.last_layout.width or 10) + 2, mw)
    end
    if w < 3 then w = 3 end
    if state.last_w == w then return end
    state.last_w = w
    vim.api.nvim_win_set_width(state.win, w)
  end
end

function M.focus_selected()
  if not state or not state.win or not vim.api.nvim_win_is_valid(state.win) then return end
  local tab = active_tab()
  if not tab then return end
  local layout = tab.last_layout
  if not layout then return end
  local mark_id = layout.box_marks and layout.box_marks[tab.selected_id]
  if not mark_id then return end
  -- The selected box's text start comes from its anchor extmark (source of
  -- truth), so the cursor always lands on the same character the highlight
  -- covers.
  local pos = vim.api.nvim_buf_get_extmark_by_id(state.buf, render_mod.anchor_ns, mark_id, {})
  if not pos then return end
  -- pos[2] is a BYTE column (nvim_win_set_cursor is byte-based).
  local crow, ccol = pos[1] + 1, pos[2]
  pcall(function()
    vim.api.nvim_win_set_cursor(state.win, { crow, ccol })
    -- Vertically center the cursor line so the box sits mid-window.
    vim.api.nvim_win_call(state.win, function()
      vim.cmd('normal! zz')
    end)
    -- Keep the focused function name visible with a small margin, scrolling as
    -- little as possible (a full centering scrolls too far and makes the
    -- cursor's on-screen position jump backwards). `vim.wo.scroll` does NOT
    -- control horizontal scroll; the window's left edge is winsaveview().leftcol
    -- (a character column), set via winrestview().
    local box = layout.boxes[tab.selected_id]
    local line_text = vim.api.nvim_buf_get_lines(state.buf, crow - 1, crow, false)[1] or ''
    local char_idx = util.byte_to_char(line_text, ccol)
    if box then
      local winw = vim.api.nvim_win_get_width(state.win)
      local bw = box.width
      local view = vim.api.nvim_win_call(state.win, function()
        return vim.fn.winsaveview()
      end)
      local cur_left = view.leftcol or 0
      local target = cur_left
      local margin = 2
      -- Keep the focused box fully visible when it fits. A box wider than the
      -- window cannot fully fit, so favor the function name (cursor) over
      -- aligning the box's right edge — the old edge-alignment pushed the
      -- cursor out of the window's left side for wide boxes, making the
      -- selection invisible.
      -- From the box, not the cursor: the cursor sits on the name, which in a
      -- dense box comes after the container.
      local box_left = box.col - 1 -- box left edge (0-based column)
      local box_right = box.col + box.width - 2 -- box right edge
      if box.width <= winw - 2 * margin then
        local bl = box_left - margin
        local br = box_right + margin
        if bl < cur_left then
          target = math.max(0, bl)
        elseif br > cur_left + winw - 1 then
          target = math.max(0, br - winw + 1)
        end
      else
        local want_left = char_idx - margin
        local want_right = char_idx + margin
        if want_left < cur_left then
          target = math.max(0, want_left)
        elseif want_right > cur_left + winw - 1 then
          target = math.max(0, want_right - winw + 1)
        end
      end
      if target ~= cur_left then
        view.leftcol = target
        vim.api.nvim_win_call(state.win, function()
          vim.fn.winrestview(view)
        end)
      end
      local char_at = vim.fn.strcharpart(line_text, char_idx, 1)
      debug.log('location', 'focus_selected', 'anchor=(' .. pos[1] .. ',' .. pos[2] .. ')',
        'cursor=(' .. crow .. ',' .. ccol .. ')', 'char=' .. vim.inspect(char_at), 'box_w=' .. bw,
        'leftcol=' .. target)
    end
  end)
end

-- ---------------------------------------------------------------------------
-- Interaction
-- ---------------------------------------------------------------------------

local function box_at(row, col)
  if not state then return nil end
  local tab = active_tab()
  if not tab or not tab.last_layout then return nil end
  for id, b in pairs(tab.last_layout.boxes) do
    if row >= b.row and row <= b.row + b.height - 1 and col >= b.col and col <= b.col + b.width - 1 then
      return id
    end
  end
  return nil
end

--- Move the selection. The graph is drawn in levels: columns left to right,
--- or rows top to bottom when vertical. A move along that axis crosses to the
--- nearest level with a box, preferring the selection's parent or child, then
--- a box level with it, then the nearest; the other two directions move within
--- the level and stop at its end. Moving back the way the selection came
--- returns to the box it came from, along a call edge or undoing the last move.
function M.move(dir)
  local tab = active_tab()
  if not tab or not tab.last_layout or not tab.graph then return end
  local boxes, nodes = tab.last_layout.boxes, tab.graph.nodes
  local sel = tab.selected_id
  local focus = boxes[sel]
  local sign = ({ left = -1, right = 1, up = -1, down = 1 })[dir]
  if not focus or not sign then return end
  local vertical = tab.last_layout.orientation == 'vertical'
  local across = (dir == 'left' or dir == 'right') ~= vertical
  local function level(b) return vertical and b.row or b.col end
  -- The cross axis: rows in horizontal, columns in vertical.
  local function lo(b) return vertical and b.col or b.row end
  local function hi(b) return vertical and (b.col + b.width - 1) or (b.row + b.height - 1) end
  local function center(b) return (lo(b) + hi(b)) / 2 end
  local function in_dir(b)
    if across then return sign * (level(b) - level(focus)) > 0 end
    return level(b) == level(focus) and sign * (lo(b) - lo(focus)) > 0
  end
  local function connected(a, b)
    return (nodes[a] and nodes[a].parents[1] == b) or (nodes[b] and nodes[b].parents[1] == a)
  end

  tab.came_from = tab.came_from or {}
  local back = tab.came_from[sel] and tab.came_from[sel][dir]
  local undo = tab.last_move and tab.last_move.to == sel and tab.last_move.from == back
  local target
  if back and boxes[back] and in_dir(boxes[back]) and (undo or connected(sel, back)) then
    target = back
  else
    local best, best_key
    local nearest -- across: the distance to the nearest level with a box
    if across then
      for id, b in pairs(boxes) do
        if id ~= sel and in_dir(b) then
          local dist = math.abs(level(b) - level(focus))
          if not nearest or dist < nearest then nearest = dist end
        end
      end
    end
    for id, b in pairs(boxes) do
      if id ~= sel and in_dir(b) and (not across or math.abs(level(b) - level(focus)) == nearest) then
        local key
        if across then
          local overlap = lo(b) <= hi(focus) and lo(focus) <= hi(b)
          key = { connected(sel, id) and 0 or 1, overlap and 0 or 1, math.abs(center(b) - center(focus)), lo(b) }
        else
          key = { 0, 0, sign * (lo(b) - lo(focus)), 0 }
        end
        local better = not best_key
        if not better then
          for k = 1, 4 do
            if key[k] ~= best_key[k] then better = key[k] < best_key[k]; break end
          end
        end
        if better then best, best_key = id, key end
      end
    end
    target = best
  end
  if target then
    local opposite = { left = 'right', right = 'left', up = 'down', down = 'up' }
    tab.came_from[target] = tab.came_from[target] or {}
    tab.came_from[target][opposite[dir]] = sel
    tab.last_move = { from = sel, to = target }
    tab.selected_id = target
    M.render_view()
  end
end

-- Forward declarations: the helpers are defined after toggle_expand but
-- referenced inside it.
local is_call_site_node, expand_normal, expand_with_def, query_definitions

function M.toggle_expand()
  local tab = active_tab()
  if not tab or not tab.graph then return end
  local node = tab.graph.nodes[tab.selected_id]
  if not node then return end
  local fetch = M.make_fetch()
  if config.get().multi_def and is_call_site_node(node) then
    query_definitions(node):next(function(defs)
      if defs and #defs > 1 then
        -- Several definitions: the user must pick one before we can expand
        -- against the right implementation. Remember the choice on the node.
        if node.chosen_def then
          expand_with_def(tab, node, fetch, node.chosen_def)
        else
          picker.pick(defs, function(def)
            if def then
              node.chosen_def = def
              expand_with_def(tab, node, fetch, def)
            end
          end)
        end
      else
        expand_normal(tab, node, fetch)
      end
    end)
  else
    expand_normal(tab, node, fetch)
  end
end

-- Text-based nodes (cscope / auto) carry the call-site location in uri/range
-- and their definition is ambiguous — unlike semantic LSP nodes. Detect them by
-- the source tag each provider stamps on its calls. The uri matching call_site
-- means the node points at a call site, not a definition.
is_call_site_node = function(node)
  return (node.source == 'cscope' or node.source == 'auto')
    and node.call_site ~= nil
    and node.uri == node.call_site.uri
end

-- Text-scan `node`'s own file for same-name definition lines (the auto /
-- no-LSP path): unlike a semantic server, this sees conditionally-compiled
-- duplicates.
local function text_definitions(node)
  local d = util.Deferred.new()
  local uri = node.uri
  if not uri then d:resolve({}); return d end
  local fname = vim.uri_to_fname(uri)
  if vim.fn.filereadable(fname) ~= 1 then d:resolve({}); return d end
  local bufnr = vim.uri_to_bufnr(uri)
  vim.fn.bufload(bufnr)
  local text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), '\n')
  local defs = {}
  for _, p in ipairs(scanner.find_definitions(text, node.name)) do
    defs[#defs + 1] = { uri = uri, line = p[1] }
  end
  d:resolve(defs)
  return d
end

-- Definitions for `node`: cscope (cross-file) when its database resolves the
-- name, else a text scan of the node's file (auto single-file fallback).
query_definitions = function(node)
  local d = util.Deferred.new()
  local cscope = source_mod.provider('cscope')
  cscope.find_definitions(node.name):next(function(defs)
    if defs and #defs > 0 then
      d:resolve(defs)
    else
      text_definitions(node):next(function(tdefs)
        d:resolve(tdefs)
      end)
    end
  end)
  return d
end

-- Wrap the raw fetch so a node with several definitions (not chosen yet) is NOT
-- auto-expanded during graph building — it renders as a collapsible stub and the
-- user picks the definition on manual expand (toggle_expand). Once chosen, calls
-- are filtered to that definition's file.
local function def_aware_fetch(raw)
  return function(node, direction)
    if not is_call_site_node(node) then return raw(node, direction) end
    local d = util.Deferred.new()
    query_definitions(node):next(function(defs)
      if defs and #defs > 1 then
        if node.chosen_def then
          node.def_pending = false -- chosen: expand normally, no stub marker
          local def = node.chosen_def
          local dd = raw(node, direction)
          dd:next(function(calls)
            local kept = {}
            for _, c in ipairs(calls) do
              if c.call_site and c.call_site.uri == def.uri then
                -- Same-file definitions (mock cscope carries end_line): keep only
                -- call sites inside the chosen definition's range, so expanding
                -- impl shows mqtest (USE_V2) OR mqtest2, not both.
                if not def.end_line
                   or (c.call_site.line >= def.line and c.call_site.line < def.end_line) then
                  kept[#kept + 1] = c
                end
              end
            end
            d:resolve(kept)
          end, function(err) d:reject(err) end)
        else
          node.def_pending = true
          node.has_children = true -- expandable stub (collapse marker shows)
          d:resolve({})
        end
      else
        node.def_pending = false
        if defs and #defs == 1 then node.chosen_def = defs[1] end
        local dd = raw(node, direction)
        dd:next(function(calls) d:resolve(calls) end, function(err) d:reject(err) end)
      end
    end)
    return d
  end
end

--- View-level fetch: raw sources wrapped with definition-aware expansion (used
--- by graph building so multi-definition nodes stop until the user picks).
--- Only wraps when config.multi_def is on — otherwise the raw fetch avoids the
--- per-node definition lookup entirely.
function M.make_fetch()
  local raw = source_mod.make_fetch(state.encoding, state.client, config.get())
  if not config.get().multi_def then return raw end
  return def_aware_fetch(raw)
end

expand_normal = function(tab, node, fetch)
  local d = graph_mod.expand(tab.graph, node, fetch)
  d:next(function(g)
    tab.graph = g
    M.render_view()
  end, function(err)
    vim.notify('Callgraph: expand failed: ' .. tostring(err), vim.log.levels.ERROR)
  end)
end

expand_with_def = function(tab, node, fetch, def)
  -- auto: same-file definition — point the node at that definition's range so
  -- the fallback rescans its body; cscope: cross-file — filter call sites to
  -- the chosen definition's file.
  if def.uri == node.uri then
    node.range = { start = { line = def.line, character = 0 }, ['end'] = { line = def.line + 1, character = 0 } }
    node.selectionRange = node.range
  end
  -- Already expanded with this definition? Space should toggle collapse back
  -- (a plain rebuild always re-expands, so folding would never work).
  local has_visible = false
  for _, cid in ipairs(node.children) do
    local c = tab.graph.nodes[cid]
    if c and c.visible then has_visible = true; break end
  end
  if has_visible then
    expand_normal(tab, node, fetch)
    return
  end
  -- `fetch` is definition-aware: it already filters call sites to the chosen
  -- definition (by file, and by range for same-file definitions).
  local d = graph_mod.rebuild(tab.graph, node, fetch)
  d:next(function(g)
    tab.graph = g
    M.render_view()
  end, function(err)
    vim.notify('Callgraph: expand failed: ' .. tostring(err), vim.log.levels.ERROR)
  end)
end

-- Force-rebuild a node's subtree with `def` — unlike expand_with_def it always
-- rebuilds (never toggles collapse); used by reselect_def to apply a new pick.
local function rebuild_with_def(tab, node, def)
  if def.uri == node.uri then
    node.range = { start = { line = def.line, character = 0 }, ['end'] = { line = def.line + 1, character = 0 } }
    node.selectionRange = node.range
  end
  -- M.make_fetch is definition-aware (filters by chosen definition's file/range).
  local d = graph_mod.rebuild(tab.graph, node, M.make_fetch())
  d:next(function(g)
    tab.graph = g
    M.render_view()
  end, function(err)
    vim.notify('Callgraph: expand failed: ' .. tostring(err), vim.log.levels.ERROR)
  end)
end

function M.change_depth(delta)
  local tab = active_tab()
  if not tab then return end
  tab.view_depth = math.max(1, tab.view_depth + delta)
  M.rebuild()
end

--- Grow/shrink the view window: width for `right` layout, height for `bottom`.
--- The adjusted size is written back to config so later renders and re-opens
--- keep it.
function M.resize_window_size(delta)
  if not state or not state.win or not vim.api.nvim_win_is_valid(state.win) then return end
  local opts = config.get()
  local pos = opts.window.position
  local step = (pos == 'right') and 5 or 2
  if pos == 'right' then
    local w = vim.api.nvim_win_get_width(state.win) + delta * step
    local max = math.floor(vim.o.columns * (opts.window.max_width_ratio or 0.8))
    w = math.max(3, math.min(w, max))
    config.update({ window = { fixed_width = w } })
  else
    local h = vim.api.nvim_win_get_height(state.win) + delta * step
    local max = math.max(3, vim.o.lines - 1) -- keep at least one row for the editor
    h = math.max(3, math.min(h, max))
    config.update({ window = { fixed_height = h } })
  end
  M.resize_window(config.get())
end

--- Flip the graph between left-to-right and top-to-bottom for this view.
function M.flip()
  if not state then return end
  local current = state.orientation or config.get().window.orientation or 'horizontal'
  state.orientation = current == 'vertical' and 'horizontal' or 'vertical'
  -- Remembered moves name directions that no longer hold.
  for _, t in ipairs(state.tabs) do t.came_from, t.last_move = nil, nil end
  M.render_view()
end

--- Switch the box style between boxed and dense for this view.
function M.toggle_style()
  if not state then return end
  local current = state.style or config.get().window.style or 'boxed'
  state.style = current == 'dense' and 'boxed' or 'dense'
  M.render_view()
end

--- Switch to the other direction for the current root (a different tab).
function M.set_direction(dir)
  local tab = active_tab()
  if not tab or tab.direction == dir then return end
  M.open_with_root(tab.root, dir, state.encoding, state.client)
end

--- Open a graph rooted on the selected function, in a tab of its own with
--- the current tab's direction.
function M.reroot()
  local tab = active_tab()
  local node = tab and tab.graph and tab.graph.nodes[tab.selected_id]
  if not node or node == tab.graph.root or not node.item then return end
  M.open_with_root(node.item, tab.direction, state.encoding, state.client)
end

--- Close the active tab; when the last tab closes, close the window.
function M.close_tab()
  if not state then return end
  if #state.tabs <= 1 then
    M.close()
    return
  end
  table.remove(state.tabs, state.active)
  -- Return to the tab that was active before this one (e.g. closing a
  -- direction-flip tab lands back where the user came from). Fall back to the
  -- adjacent tab when there's no recorded previous one or it was removed.
  local target = state.prev_active
  state.prev_active = nil
  if target and target >= 1 and target <= #state.tabs then
    state.active = target
  elseif state.active > #state.tabs then
    state.active = #state.tabs
  end
  M.render_view()
  M.focus_selected()
end

function M.close()
  if not state then return end
  M.close_zoom()
  local orig = state.orig_win
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    pcall(vim.api.nvim_win_close, state.win, true)
  end
  state = nil
  if orig and vim.api.nvim_win_is_valid(orig) then
    vim.api.nvim_set_current_win(orig)
  end
end

function M.jump_to_def()
  local tab = active_tab()
  if not tab or not tab.graph then return end
  local node = tab.graph.nodes[tab.selected_id]
  if not node or not node.uri then return end
  -- Keep the view open; only q closes it. Focus the main window, jump to
  -- the definition there, and leave the callgraph window on screen.
  local orig = state.orig_win
  if orig and vim.api.nvim_win_is_valid(orig) then
    vim.api.nvim_set_current_win(orig)
  end
  -- cscope nodes carry the *call-site* location in uri/range (cscope -L output
  -- is call sites, not definitions). Jump to the real definition via `cscope -1`
  -- — preferring the definition the user already chose when expanding; with
  -- several definitions, ask which one to jump to.
  if is_call_site_node(node) then
    local function jump_to_def(def)
      lsp_mod.jump_to_location(def.uri,
        { start = { line = def.line, character = 0 }, ['end'] = { line = def.line, character = 0 } },
        state.encoding)
    end
    if not config.get().multi_def then
      -- Default: jump to the first definition — no multi-definition handling.
      source_mod.provider('cscope').find_definition(node.name):next(function(def)
        if def then
          jump_to_def(def)
        elseif node.range then
          lsp_mod.jump_to_location(node.uri, node.range, state.encoding)
        end
      end)
      return
    end
    if node.chosen_def then
      jump_to_def(node.chosen_def)
      return
    end
    query_definitions(node):next(function(defs)
      if defs and #defs > 1 then
        -- Open the picker from the graph window so cancelling returns there
        -- (jump_to_def already moved focus to the main window).
        if state.win and vim.api.nvim_win_is_valid(state.win) then
          vim.api.nvim_set_current_win(state.win)
        end
        picker.pick(defs, function(def)
          if def then
            node.chosen_def = def
            -- picker.close restored focus to the graph window; the jump itself
            -- must land in the main (code) window.
            if orig and vim.api.nvim_win_is_valid(orig) then
              vim.api.nvim_set_current_win(orig)
            end
            jump_to_def(def)
          end
        end)
      elseif defs and #defs == 1 then
        node.chosen_def = defs[1]
        jump_to_def(defs[1])
      elseif node.range then
        -- Fallback: jump to the call site if definition lookup fails.
        lsp_mod.jump_to_location(node.uri, node.range, state.encoding)
      end
    end)
    return
  end
  if node.range then
    lsp_mod.jump_to_location(node.uri, node.range, state.encoding)
  end
end

--- Re-pick the definition of a multi-definition node (in case the earlier
--- choice was wrong). Only meaningful when config.multi_def is on; no-op
--- otherwise.
function M.reselect_def()
  local tab = active_tab()
  if not tab or not tab.graph then return end
  local node = tab.graph.nodes[tab.selected_id]
  if not node or not is_call_site_node(node) then return end
  query_definitions(node):next(function(defs)
    if defs and #defs > 1 then
      picker.pick(defs, function(def)
        if def then
          node.chosen_def = def
          rebuild_with_def(tab, node, def)
        end
      end)
    end
  end)
end

function M.hover_echo()
  if not state or not state.win or not vim.api.nvim_win_is_valid(state.win) then return end
  local pos = vim.api.nvim_win_get_cursor(state.win)
  local tab = active_tab()
  local id = box_at(pos[1], pos[2] + 1)
  if id and tab and tab.graph then
    local node = tab.graph.nodes[id]
    if node then
      local path = vim.fn.fnamemodify(vim.uri_to_fname(node.uri or ''), ':~:.')
      local line = (node.range and node.range.start and node.range.start.line or 0) + 1
      -- Fit the message line: a longer message wraps and stops at "Press ENTER".
      local text = util.truncate_display(node.name .. '  ' .. path .. ':' .. tostring(line), vim.v.echospace)
      vim.api.nvim_echo({ { text, 'Normal' } }, false, {})
    end
  end
end

-- ---------------------------------------------------------------------------
-- Focus float: when the selected box hides part of its label, a float over
-- the box shows it in full (same rows: container and path, then the name).
-- ---------------------------------------------------------------------------

function M.close_zoom()
  if not state or not state.zoom_win then return end
  local win = state.zoom_win
  if vim.api.nvim_win_is_valid(win) then pcall(vim.api.nvim_win_close, win, true) end
  if not vim.api.nvim_win_is_valid(win) then
    state.zoom_win = nil
  else
    -- Closing can be refused inside an autocmd (BufLeave, WinClosed): retry
    -- after it, so the float is never left without a handle.
    vim.schedule(function()
      if vim.api.nvim_win_is_valid(win) then pcall(vim.api.nvim_win_close, win, true) end
      if state and state.zoom_win == win and not vim.api.nvim_win_is_valid(win) then state.zoom_win = nil end
    end)
  end
end

function M.update_zoom()
  if not state then return end
  local opts = config.get()
  local tab = active_tab()
  local box = tab and tab.last_layout and tab.last_layout.boxes[tab.selected_id]
  if not opts.window.focus_float or not box or not box.shortened
    or not (state.win and vim.api.nvim_win_is_valid(state.win))
    or vim.api.nvim_get_current_win() ~= state.win then
    M.close_zoom()
    return
  end

  local marker = vim.trim(box.marker or '')
  local function dw(s) return vim.fn.strdisplaywidth(s) end
  if box.dense then return M.update_zoom_dense(box, marker, opts) end
  local gap1 = (box.full_container ~= '' and box.full_loc ~= '') and '  ' or ''
  local width = math.max(
    dw(box.full_container) + #gap1 + dw(box.full_loc),
    dw(box.full_name) + (marker ~= '' and 1 + dw(marker) or 0),
    box.width - 2
  )
  width = math.max(math.min(width, vim.o.columns - 2), 1)
  -- Right-align the location and marker, as the box does.
  local row1 = box.full_container
    .. string.rep(' ', math.max(width - dw(box.full_container) - dw(box.full_loc), #gap1)) .. box.full_loc
  local row2 = box.full_name
    .. string.rep(' ', math.max(width - dw(box.full_name) - dw(marker), marker ~= '' and 1 or 0)) .. marker

  if not (state.zoom_buf and vim.api.nvim_buf_is_valid(state.zoom_buf)) then
    state.zoom_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[state.zoom_buf].bufhidden = 'wipe'
  end
  vim.api.nvim_buf_set_lines(state.zoom_buf, 0, -1, false, { row1, row2 })

  -- Anchor the float's top-left corner (its border) on the box's top-left
  -- border cell: border lands on border, text on text. Grid row r is buffer
  -- row r - 1.
  local top = box.row - 1
  local line_text = vim.api.nvim_buf_get_lines(state.buf, top, top + 1, false)[1] or ''
  local cfg = {
    relative = 'win',
    win = state.win,
    bufpos = { top, util.char_to_byte(line_text, box.col - 1) },
    row = 0,
    col = 0,
    width = width,
    height = 2,
    border = 'rounded',
    focusable = false,
    style = 'minimal',
    zindex = 50,
  }
  if state.zoom_win and vim.api.nvim_win_is_valid(state.zoom_win) then
    vim.api.nvim_win_set_config(state.zoom_win, cfg)
  else
    cfg.noautocmd = true
    state.zoom_win = vim.api.nvim_open_win(state.zoom_buf, false, cfg)
  end

  local colors = opts.colors and opts.colors.mode ~= 'off'
  local hl = opts.highlights
  local normal = (colors and vim.fn.hlexists('CallgraphNormal') == 1) and 'CallgraphNormal' or 'Normal'
  -- A clamped first row must not wrap into the name row.
  vim.wo[state.zoom_win].wrap = false
  vim.wo[state.zoom_win].winhighlight = 'NormalFloat:' .. normal
    .. (colors and ',FloatBorder:CallgraphBorder' or '')
  vim.api.nvim_buf_clear_namespace(state.zoom_buf, zoom_ns, 0, -1)
  vim.api.nvim_buf_set_extmark(state.zoom_buf, zoom_ns, 0, 0, {
    end_col = #row1, hl_group = colors and 'CallgraphLocation' or hl.loc,
  })
  vim.api.nvim_buf_set_extmark(state.zoom_buf, zoom_ns, 1, 0, {
    end_col = #box.full_name, hl_group = colors and 'CallgraphFocus' or hl.focus,
  })
  if box.id == tab.graph.root.id then
    vim.api.nvim_buf_set_extmark(state.zoom_buf, zoom_ns, 1, 0, {
      end_col = #box.full_name, hl_group = hl.root, priority = 4200,
    })
  end
  if marker ~= '' then
    vim.api.nvim_buf_set_extmark(state.zoom_buf, zoom_ns, 1, #row2 - #marker, {
      end_col = #row2, hl_group = colors and 'CallgraphSymbol' or hl.focus,
    })
  end
end

-- Dense: one borderless row exactly over the box's text, the whole
-- `container.name ❯`, set apart by its background. The location stays in the
-- bottom line; a border would cover the neighbours j/k move to.
function M.update_zoom_dense(box, marker, opts)
  local text = box.full_prefix .. box.full_name .. (marker ~= '' and (' ' .. marker) or '')
  local width = math.max(math.min(vim.fn.strdisplaywidth(text), vim.o.columns - 2), 1)
  if not (state.zoom_buf and vim.api.nvim_buf_is_valid(state.zoom_buf)) then
    state.zoom_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[state.zoom_buf].bufhidden = 'wipe'
  end
  vim.api.nvim_buf_set_lines(state.zoom_buf, 0, -1, false, { text })
  -- The text starts one cell into the box: 0-based character box.col.
  local row = box.row - 1
  local line_text = vim.api.nvim_buf_get_lines(state.buf, row, row + 1, false)[1] or ''
  local cfg = {
    relative = 'win',
    win = state.win,
    bufpos = { row, util.char_to_byte(line_text, box.col) },
    row = 0,
    col = 0,
    width = width,
    height = 1,
    border = 'none',
    focusable = false,
    style = 'minimal',
    zindex = 50,
  }
  if state.zoom_win and vim.api.nvim_win_is_valid(state.zoom_win) then
    vim.api.nvim_win_set_config(state.zoom_win, cfg)
  else
    cfg.noautocmd = true
    state.zoom_win = vim.api.nvim_open_win(state.zoom_buf, false, cfg)
  end
  local colors = opts.colors and opts.colors.mode ~= 'off'
  local hl = opts.highlights
  vim.wo[state.zoom_win].wrap = false
  vim.wo[state.zoom_win].winhighlight = 'NormalFloat:CursorLine'
  vim.api.nvim_buf_clear_namespace(state.zoom_buf, zoom_ns, 0, -1)
  local p, n = #box.full_prefix, #box.full_name
  if p > 0 then
    vim.api.nvim_buf_set_extmark(state.zoom_buf, zoom_ns, 0, 0, {
      end_col = p, hl_group = colors and 'CallgraphLocation' or hl.loc,
    })
  end
  vim.api.nvim_buf_set_extmark(state.zoom_buf, zoom_ns, 0, p, {
    end_col = p + n, hl_group = colors and 'CallgraphFocus' or hl.focus,
  })
  local tab = active_tab()
  if tab and tab.graph and box.id == tab.graph.root.id then
    vim.api.nvim_buf_set_extmark(state.zoom_buf, zoom_ns, 0, p, {
      end_col = p + n, hl_group = hl.root, priority = 4200,
    })
  end
  if marker ~= '' then
    vim.api.nvim_buf_set_extmark(state.zoom_buf, zoom_ns, 0, #text - #marker, {
      end_col = #text, hl_group = colors and 'CallgraphSymbol' or hl.focus,
    })
  end
end

-- ---------------------------------------------------------------------------
-- Docs: LSP hover for the selected node (K)
-- ---------------------------------------------------------------------------

function M.hover_docs()
  local tab = active_tab()
  local node = tab and tab.graph and tab.graph.nodes[tab.selected_id]
  if not node or not node.uri then return end
  local client = state.client
  if not client or not client.request or client:is_stopped() then
    vim.notify('Callgraph: no language server for docs', vim.log.levels.WARN)
    return
  end
  local range = node.selectionRange or node.range
  if not range then return end

  -- Servers answer reliably only for open documents: load the file and make
  -- sure the client has it (didOpen), as jumping to it would.
  local bufnr = vim.fn.bufadd(vim.uri_to_fname(node.uri))
  vim.fn.bufload(bufnr)
  if #vim.lsp.get_clients({ bufnr = bufnr, id = client.id }) == 0 then
    vim.lsp.buf_attach_client(bufnr, client.id)
  end

  local asked, graph_buf = tab.selected_id, state.buf
  M.close_zoom()
  client:request('textDocument/hover', {
    textDocument = { uri = node.uri },
    position = range.start,
  }, function(err, result)
    -- Drop a late answer: the selection moved or the view was left.
    if not state or active_tab() ~= tab or tab.selected_id ~= asked
      or vim.api.nvim_get_current_buf() ~= graph_buf then
      return
    end
    local lines = {}
    if not err and result and result.contents then
      lines = vim.lsp.util.convert_input_to_markdown_lines(result.contents)
    end
    while lines[1] and vim.trim(lines[1]) == '' do table.remove(lines, 1) end
    while lines[#lines] and vim.trim(lines[#lines]) == '' do table.remove(lines) end
    if #lines == 0 then
      vim.notify('Callgraph: no docs for ' .. (node.name or '?'), vim.log.levels.INFO)
      return
    end
    local fbuf, fwin = vim.lsp.util.open_floating_preview(lines, 'markdown', { border = 'rounded', focus_id = 'callgraph_hover' })
    -- Entered with a second K: the same key closes it from inside.
    local key = config.get().keymaps.close_popup
    if key and key ~= '' then
      vim.keymap.set('n', key, function() pcall(vim.api.nvim_win_close, fwin, true) end,
        { buffer = fbuf, silent = true, nowait = true })
    end
  end, bufnr)
end

--- Close the popups over the view: the docs float (K) and the focus float.
--- Returns whether one was open.
function M.close_popups()
  if not state then return false end
  local closed = false
  local docs = vim.b[state.buf].lsp_floating_preview
  if docs and vim.api.nvim_win_is_valid(docs) then
    pcall(vim.api.nvim_win_close, docs, true)
    closed = true
  end
  if state.zoom_win and vim.api.nvim_win_is_valid(state.zoom_win) then
    M.close_zoom()
    closed = true
  end
  return closed
end

function M.on_mouse(clicks)
  if not state or not state.win or not vim.api.nvim_win_is_valid(state.win) then return end
  local m = vim.fn.getmousepos()
  -- The view's own click mapping takes clicks on its winbar too: the help
  -- hint at its right end opens the help.
  if m.winid == state.win and m.winrow == 1 and vim.wo[state.win].winbar ~= '' then
    local help = config.get().keymaps.help
    if help and help ~= '' and m.wincol > vim.api.nvim_win_get_width(state.win) - vim.fn.strdisplaywidth(help .. ' keys') then
      M.show_help()
    end
    return
  end
  local id = box_at(m.line, m.column)
  if id then
    local tab = active_tab()
    tab.selected_id = id
    tab.came_from, tab.last_move = nil, nil -- the selection jumped: no way back to remember
    M.render_view()
    if clicks >= 2 then M.toggle_expand() end
  end
end

function M.scroll(delta)
  if not state or not state.win or not vim.api.nvim_win_is_valid(state.win) then return end
  local cur = vim.api.nvim_win_get_cursor(state.win)
  local line = math.max(1, math.min(vim.api.nvim_buf_line_count(state.buf), cur[1] + delta))
  vim.api.nvim_win_set_cursor(state.win, { line, cur[2] })
end

-- The help's rows: the keys as configured (an entry set to '' is left out)
-- and what they do.
local function help_rows()
  local km = config.get().keymaps
  local rows = {
    { { km.move_left, km.move_down, km.move_up, km.move_right }, 'move the selection' },
    { { km.move_left_alt, km.move_down_alt, km.move_up_alt, km.move_right_alt }, 'move the selection' },
    { { km.toggle_expand }, 'expand / collapse' },
    { { km.jump_to_def, km.jump_to_def_alt }, 'jump to the definition (the view stays)' },
    { { km.hover }, 'docs for the function (LSP hover)' },
    { { km.reroot }, 'new graph on the selected function' },
    { { km.to_callin, km.to_callout }, 'callers / callees of the root' },
    { { km.depth_up, km.depth_up_alt }, 'one level deeper' },
    { { km.depth_down }, 'one level shallower' },
    { { km.toggle_style }, 'boxed / dense boxes' },
    { { km.flip }, 'left-to-right / top-to-bottom' },
    { { km.tab_next, km.tab_prev }, 'next / previous tab' },
    { { km.refresh }, 'refresh' },
    { { km.win_grow, km.win_shrink }, 'grow / shrink the view' },
    { { km.close_popup }, 'close the docs / focus float' },
    { { km.close, km.close_alt }, 'close the tab (:q closes the view)' },
    { { km.help }, 'this help' },
    { { 'click', 'double-click' }, 'select / expand' },
  }
  if config.get().multi_def then
    table.insert(rows, 4, { { km.reselect_def }, 're-pick the definition' })
  end
  local out = {}
  for _, r in ipairs(rows) do
    local keys = vim.tbl_filter(function(k) return k and k ~= '' end, r[1])
    if #keys > 0 then out[#out + 1] = { table.concat(keys, ' '), r[2] } end
  end
  return out
end

--- The key help in a float over the editor; ?, q or Esc closes it. Already
--- open (a second click on the hint), it stays.
function M.show_help()
  if state and state.help_win and vim.api.nvim_win_is_valid(state.help_win) then return end
  local rows = help_rows()
  local kw = 0
  for _, r in ipairs(rows) do kw = math.max(kw, vim.fn.strdisplaywidth(r[1])) end
  local lines = {}
  for _, r in ipairs(rows) do
    lines[#lines + 1] = ' ' .. r[1] .. string.rep(' ', kw - vim.fn.strdisplaywidth(r[1]) + 3) .. r[2] .. ' '
  end
  local width = 0
  for _, l in ipairs(lines) do width = math.max(width, vim.fn.strdisplaywidth(l)) end
  local height = math.min(#lines, math.max(vim.o.lines - 4, 1))
  width = math.min(width, math.max(vim.o.columns - 2, 1))

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
    width = width,
    height = height,
    border = 'rounded',
    title = ' Callgraph keys ',
    title_pos = 'center',
    style = 'minimal',
  })
  if state then state.help_win = win end
  local hl = config.get().highlights
  for i, r in ipairs(rows) do
    vim.api.nvim_buf_set_extmark(buf, zoom_ns, i - 1, 1, { end_col = 1 + #r[1], hl_group = hl.focus })
  end
  local function close()
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
  end
  local km = config.get().keymaps
  for _, key in ipairs({ km.help, 'q', '<Esc>' }) do
    if key and key ~= '' then
      vim.keymap.set('n', key, close, { buffer = buf, silent = true, nowait = true })
    end
  end
  vim.api.nvim_create_autocmd('WinLeave', { buffer = buf, once = true, callback = close })
end

-- ---------------------------------------------------------------------------
-- Keymaps & autocmds
-- ---------------------------------------------------------------------------

function M.setup_keymaps()
  if state.keyed then return end
  state.keyed = true
  local km = config.get().keymaps
  local buf = state.buf
  local opts = { buffer = buf, silent = true, nowait = true }
  local function set(keys, fn)
    if keys and keys ~= '' then vim.keymap.set('n', keys, fn, opts) end
  end
  set(km.move_left, function() M.move('left') end)
  set(km.move_down, function() M.move('down') end)
  set(km.move_up, function() M.move('up') end)
  set(km.move_right, function() M.move('right') end)
  set(km.move_left_alt, function() M.move('left') end)
  set(km.move_down_alt, function() M.move('down') end)
  set(km.move_up_alt, function() M.move('up') end)
  set(km.move_right_alt, function() M.move('right') end)
  set(km.toggle_expand, function() M.toggle_expand() end)
  set(km.close, function() M.close_tab() end)
  -- One key for both: it closes the popups first, the tab only when none is open.
  if km.close_alt ~= km.close_popup then
    set(km.close_alt, function() M.close_tab() end)
  end
  set(km.close_popup, function()
    if not M.close_popups() and km.close_alt == km.close_popup then M.close_tab() end
  end)
  set(km.refresh, function() M.rebuild() end)
  set(km.to_callin, function() M.set_direction('callin') end)
  set(km.to_callout, function() M.set_direction('callout') end)
  set(km.reroot, function() M.reroot() end)
  set(km.depth_up, function() M.change_depth(1) end)
  set(km.depth_up_alt, function() M.change_depth(1) end)
  set(km.depth_down, function() M.change_depth(-1) end)
  set(km.win_grow, function() M.resize_window_size(1) end)
  set(km.win_shrink, function() M.resize_window_size(-1) end)
  set(km.jump_to_def, function() M.jump_to_def() end)
  set(km.jump_to_def_alt, function() M.jump_to_def() end)
  set(km.reselect_def, function() M.reselect_def() end)
  set(km.hover, function() M.hover_docs() end)
  set(km.toggle_style, function() M.toggle_style() end)
  set(km.flip, function() M.flip() end)
  -- Tab keys switch between callgraph tabs. These buffer-local bindings
  -- override global ones (e.g. barbar's <Tab> -> BufferNext), so pressing Tab
  -- inside the view cycles tabs instead of leaving it.
  set(km.tab_next, function() M.tab_next() end)
  set(km.tab_prev, function() M.tab_prev() end)
  set(km.help, function() M.show_help() end)

  vim.keymap.set('n', '<LeftMouse>', function() M.on_mouse(1) end, opts)
  vim.keymap.set('n', '<2-LeftMouse>', function() M.on_mouse(2) end, opts)
  vim.keymap.set('n', '<ScrollWheelUp>', function() M.scroll(-3) end, opts)
  vim.keymap.set('n', '<ScrollWheelDown>', function() M.scroll(3) end, opts)

  vim.api.nvim_create_autocmd('CursorMoved', {
    buffer = buf,
    callback = function()
      M.hover_echo()
      M.update_zoom()
    end,
  })
  -- Entering the view doesn't fire CursorMoved; leaving it hides the float.
  vim.api.nvim_create_autocmd('BufEnter', {
    buffer = buf,
    callback = function() M.update_zoom() end,
  })
  vim.api.nvim_create_autocmd('BufLeave', {
    buffer = buf,
    callback = function() M.close_zoom() end,
  })
end

--- Cycle to the next tab (wraps around).
function M.tab_next()
  if not state or #state.tabs <= 1 then return end
  local n = #state.tabs
  set_active(state.active % n + 1)
  M.render_view()
  M.focus_selected()
end

--- Cycle to the previous tab (wraps around).
function M.tab_prev()
  if not state or #state.tabs <= 1 then return end
  local n = #state.tabs
  set_active((state.active - 2) % n + 1)
  M.render_view()
  M.focus_selected()
end

return M
