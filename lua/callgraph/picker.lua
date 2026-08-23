--- Definition picker: a two-pane floating window — left lists candidate
--- definitions (`file:line` + the definition line's text), right previews the
--- code around the selected definition (with the definition line highlighted),
--- so the user can tell which implementation is which. j/k move, <CR> picks,
--- q/<Esc> cancels; selection is delivered via a callback.

local util = require('callgraph.util')

local M = {}

local ns = vim.api.nvim_create_namespace('callgraph_picker')
local picker = nil -- { win1, buf1, win2, buf2, idx, defs, cb }

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

  -- Left: the list — path:line + the definition line's content.
  local rows = {}
  for i, d in ipairs(picker.defs) do
    local content = util.truncate((line_at(d.uri, d.line):gsub('^%s+', '')), 44)
    rows[#rows + 1] = string.format('%s:%d  %s', def_rel_path(d), d.line + 1, content)
  end
  vim.api.nvim_buf_set_lines(picker.buf1, 0, -1, false, rows)
  vim.api.nvim_buf_clear_namespace(picker.buf1, ns, 0, -1)
  vim.api.nvim_buf_add_highlight(picker.buf1, ns, 'CursorLine', idx - 1, 0, -1)
  vim.api.nvim_win_set_cursor(picker.win1, { idx, 0 })

  -- Right: preview the code around the selected definition, highlighting the
  -- definition line itself.
  local d = picker.defs[idx]
  local bufnr = vim.uri_to_bufnr(d.uri)
  vim.fn.bufload(bufnr)
  local start = math.max(0, d.line - 2)
  local src = vim.api.nvim_buf_get_lines(bufnr, start, d.line + 6, false)
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
  vim.api.nvim_win_set_option(picker.win2, 'winhl', 'Normal:NormalFloat')
end

local function close(result)
  if not picker then return end
  local cb = picker.cb
  local w1, w2 = picker.win1, picker.win2
  picker = nil
  for _, w in ipairs({ w1, w2 }) do
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

--- Show a two-pane definition picker. `defs` is a list of `{ uri, line }`; on
--- pick the callback receives the chosen definition, on cancel it receives nil.
function M.pick(defs, on_pick)
  if not defs or #defs == 0 then on_pick(nil); return end
  if picker then close(nil) end
  local buf1 = vim.api.nvim_create_buf(false, true)
  vim.bo[buf1].buftype = 'nofile'
  vim.bo[buf1].swapfile = false
  local buf2 = vim.api.nvim_create_buf(false, true)
  vim.bo[buf2].buftype = 'nofile'
  vim.bo[buf2].swapfile = false
  local h = math.min(#defs, 10)
  local w1 = 64
  local w2 = 48
  local win1 = vim.api.nvim_open_win(buf1, true, {
    relative = 'win', row = 1, col = 1, width = w1, height = h,
    style = 'minimal', border = 'rounded', title = 'Select definition', title_pos = 'center',
  })
  local win2 = vim.api.nvim_open_win(buf2, true, {
    relative = 'win', row = 1, col = w1 + 3, width = w2, height = h,
    style = 'minimal', border = 'rounded', title = 'Preview', title_pos = 'center',
  })
  picker = { win1 = win1, buf1 = buf1, win2 = win2, buf2 = buf2, idx = 1, defs = defs, cb = on_pick }
  setup_keymaps(buf1)
  setup_keymaps(buf2)
  render()
end

return M
