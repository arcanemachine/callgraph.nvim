--- Definition picker: an outer float holding two bordered panes — left
--- "select" lists candidate definitions (`file:line` + the definition line's
--- text), right "preview" shows the code around the selected definition with
--- native syntax highlighting (definition line highlighted), so the user can
--- tell which implementation is which. j/k move, <CR> picks, q/<Esc> cancels;
--- the selection is delivered via a callback.

local util = require('callgraph.util')

local M = {}

local ns = vim.api.nvim_create_namespace('callgraph_picker')
local picker = nil -- { win0, win1, buf1, win2, buf2, idx, defs, cb }

local PREVIEW_BEFORE, PREVIEW_AFTER = 3, 10

local function def_rel_path(d)
  return vim.fn.fnamemodify(vim.uri_to_fname(d.uri), ':~:.')
end

local function line_at(uri, line0)
  local bufnr = vim.uri_to_bufnr(uri)
  vim.fn.bufload(bufnr)
  return vim.api.nvim_buf_get_lines(bufnr, line0, line0 + 1, false)[1] or ''
end

local function render()
  if not picker then return end
  local idx = picker.idx

  -- Left pane ("select"): the list — path:line + the definition line's text.
  local rows = {}
  for i, d in ipairs(picker.defs) do
    local content = util.truncate((line_at(d.uri, d.line):gsub('^%s+', '')), 40)
    rows[#rows + 1] = string.format('%s:%d  %s', def_rel_path(d), d.line + 1, content)
  end
  vim.api.nvim_buf_set_lines(picker.buf1, 0, -1, false, rows)
  vim.api.nvim_buf_clear_namespace(picker.buf1, ns, 0, -1)
  vim.api.nvim_buf_add_highlight(picker.buf1, ns, 'CursorLine', idx - 1, 0, -1)
  vim.api.nvim_win_set_cursor(picker.win1, { idx, 0 })

  -- Right pane ("preview"): code around the selected definition, syntax-highlighted.
  local d = picker.defs[idx]
  local fname = vim.uri_to_fname(d.uri)
  local ft = vim.filetype.match({ filename = fname })
  if ft then vim.bo[picker.buf2].filetype = ft end
  local bufnr = vim.uri_to_bufnr(d.uri)
  vim.fn.bufload(bufnr)
  local start = math.max(0, d.line - PREVIEW_BEFORE)
  local src = vim.api.nvim_buf_get_lines(bufnr, start, d.line + PREVIEW_AFTER, false)
  local preview = {}
  for i, l in ipairs(src) do
    preview[#preview + 1] = string.format('%4d  %s', start + i, l)
  end
  vim.api.nvim_buf_set_lines(picker.buf2, 0, -1, false, preview)
  vim.api.nvim_buf_clear_namespace(picker.buf2, ns, 0, -1)
  local def_rel = d.line - start + 1
  if def_rel >= 1 and def_rel <= #preview then
    vim.api.nvim_buf_add_highlight(picker.buf2, ns, 'CursorLine', def_rel - 1, 0, -1)
    vim.api.nvim_win_set_cursor(picker.win2, { def_rel, 0 })
  end
end

local function close(result)
  if not picker then return end
  local cb = picker.cb
  local wins = { picker.win0, picker.win1, picker.win2 }
  picker = nil
  for _, w in ipairs(wins) do
    if w and vim.api.nvim_win_is_valid(w) then pcall(vim.api.nvim_win_close, w, true) end
  end
  if cb then cb(result) end
end

local function move(delta)
  if not picker or #picker.defs == 0 then return end
  local n = #picker.defs
  picker.idx = ((picker.idx - 1 + delta) % n) + 1
  render()
end

local function setup_keymaps(buf)
  local opts = { buffer = buf, nowait = true, silent = true }
  vim.keymap.set('n', 'j', function() move(1) end, opts)
  vim.keymap.set('n', 'k', function() move(-1) end, opts)
  vim.keymap.set('n', '<Down>', function() move(1) end, opts)
  vim.keymap.set('n', '<Up>', function() move(-1) end, opts)
  vim.keymap.set('n', '<CR>', function()
    close(picker and picker.defs[picker.idx])
  end, opts)
  vim.keymap.set('n', 'q', function() close(nil) end, opts)
  vim.keymap.set('n', '<Esc>', function() close(nil) end, opts)
end

--- Show the definition picker. `defs` is a list of `{ uri, line }`; on pick the
--- callback receives the chosen definition, on cancel it receives nil.
function M.pick(defs, on_pick)
  if not defs or #defs == 0 then on_pick(nil); return end
  if picker then close(nil) end

  local w1, w2, gap = 64, 50, 2
  local preview_rows = PREVIEW_BEFORE + PREVIEW_AFTER + 1
  local pane_h = math.max(math.min(#defs, 12), preview_rows) + 2 -- pane incl. border
  local win1_w, win2_w = w1 + 2, w2 + 2

  local buf0 = vim.api.nvim_create_buf(false, true)
  vim.bo[buf0].buftype = 'nofile'
  vim.bo[buf0].swapfile = false
  local win0 = vim.api.nvim_open_win(buf0, true, {
    relative = 'win', row = 1, col = 1, width = win1_w + gap + win2_w, height = pane_h + 2,
    style = 'minimal', border = 'rounded',
  })

  local buf1 = vim.api.nvim_create_buf(false, true)
  vim.bo[buf1].buftype = 'nofile'
  vim.bo[buf1].swapfile = false
  local win1 = vim.api.nvim_open_win(buf1, true, {
    relative = 'win', win = win0, row = 1, col = 1, width = win1_w, height = pane_h,
    style = 'minimal', border = 'rounded', title = 'select', title_pos = 'center',
  })

  local buf2 = vim.api.nvim_create_buf(false, true)
  vim.bo[buf2].buftype = 'nofile'
  vim.bo[buf2].swapfile = false
  local win2 = vim.api.nvim_open_win(buf2, true, {
    relative = 'win', win = win0, row = 1, col = win1_w + gap, width = win2_w, height = pane_h,
    style = 'minimal', border = 'rounded', title = 'preview', title_pos = 'center',
  })

  picker = { win0 = win0, win1 = win1, buf1 = buf1, win2 = win2, buf2 = buf2, idx = 1, defs = defs, cb = on_pick }
  setup_keymaps(buf1)
  setup_keymaps(buf2)
  render()
end

return M
