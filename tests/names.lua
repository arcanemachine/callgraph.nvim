-- Labels: util.split_name splits a qualified name into container and last
-- part, util.abbreviate shortens a container to fit, util.truncate_display
-- cuts by display cells.
-- Run: nvim --headless -u NONE -l tests/names.lua

local here = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fn.fnamemodify(here, ':h:h')
vim.opt.runtimepath:append(root)

local util = require('callgraph.util')

local failed = 0
local function check(name, cond, detail)
  if cond then print('PASS ' .. name) else failed = failed + 1; print('FAIL ' .. name .. (detail and (' :: ' .. tostring(detail)) or '')) end
end

local splits = {
  -- name, container, last part
  { 'MyApp.Accounts.get_user/1', 'MyApp.Accounts', 'get_user/1' },
  { 'Kernel.+/2', 'Kernel', '+/2' },
  { 'Kernel.../2', 'Kernel', '../2' },
  { 'ns::detail::Parser::parse', 'ns::detail::Parser', 'parse' },
  { 'ns::Cls::operator()', 'ns::Cls', 'operator()' },
  { 'std::vector<a::b>::push_back', 'std::vector<a::b>', 'push_back' },
  { 'Cls#method', 'Cls', 'method' },
  { 'a::b.c', 'a::b', 'c' },
  { '.method', '', '.method' },
  { 'foo.', '', 'foo.' },
  { 'main', '', 'main' },
  { 'process(Map.Entry<K, V>) : void', '', 'process(Map.Entry<K, V>) : void' },
  { 'items.forEach() callback', 'items', 'forEach() callback' },
}
for _, c in ipairs(splits) do
  local container, last = util.split_name(c[1])
  check('split ' .. c[1], container == c[2] and last == c[3], vim.inspect({ container, last }))
end

local abbrevs = {
  -- container, separator, max, expected
  { 'MyApp.Accounts', '.', 40, 'MyApp.Accounts' },
  { 'ShopServiceV2Web.OrdersLive.Show', '.', 24, 'SSV2W.OrdersLive.Show' },
  { 'ShopServiceV2Web.OrdersLive.Show', '.', 15, 'SSV2W.OL.Show' },
  { 'my_package.sub_module.Thing', '.', 20, 'mp.sub_module.Thing' },
  { 'my_package.sub_module.Thing', '.', 15, 'mp.sm.Thing' },
  { 'ShopServiceV2Web.OrdersLive.ShowEverything', '.', 10, '…verything' },
  { 'émile_pkg.Thing', '.', 8, 'ép.Thing' },
}
for _, c in ipairs(abbrevs) do
  local got = util.abbreviate(c[1], c[2], c[3])
  check('abbreviate ' .. c[1] .. ' to ' .. c[3], got == c[4], got)
end

local displays = {
  -- text, cells, expected
  { 'short', 10, 'short' },
  { 'abcdef', 4, 'abc…' },
  { '日本語テキスト', 7, '日本語…' }, -- wide characters take two cells each
}
for _, c in ipairs(displays) do
  local got = util.truncate_display(c[1], c[2])
  check('truncate_display ' .. c[1] .. ' to ' .. c[2], got == c[3] and vim.fn.strdisplaywidth(got) <= c[2], got)
end

print('---')
if failed == 0 then print('NAMES OK') else print('NAMES FAILED: ' .. failed) end
os.exit(failed == 0 and 0 or 1)
