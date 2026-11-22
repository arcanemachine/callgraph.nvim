# callgraph.nvim

> **English** · [中文](README.zh.md)

![Call graph in auto color mode](assets/auto_colors.png)

A Neovim plugin that shows a **real function call graph** (a directed graph / flowchart), not an indent tree.

Callers are on the **left**, callees on the **right** (or above and below, with `v`); edges are orthogonal polylines with arrowheads. Data comes from the LSP
[Call Hierarchy](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#textDocument_prepareCallHierarchy) —
a language-agnostic, cross-file source — plus optional `cscope` / heuristic sources (see [Data sources](#data-sources)).

## Commands

| Command | Action |
|---|---|
| `:Callout` | Build the graph rooted at the function under the cursor — **what it calls** |
| `:Callin` | Build the graph rooted at the function under the cursor — **who calls it** |
| `:Callgraph` | Both at once: callers fan out left of the function, callees right; each side expands in its own direction |
| `:CallgraphToggle` | Show or hide the view without starting a new graph: open, it closes; closed, it comes back as it was left; with no graph yet, it opens `:Callgraph` |
| `:CallgraphLog` | Open the debug log file |
| `:CallgraphDebug on\|off` | Toggle debug logging at runtime |

Run from the code, `:Callout` / `:Callin` / `:Callgraph` start fresh: the graphs opened so far and their history go. Run from inside the view, they close it (the graphs stay for `:CallgraphToggle`).

## View

- Splits along the editor's **bottom edge, full width**, by default, whichever pane it is opened from (`window.position = 'right'` puts it along the right edge, full height); it is a read-only canvas buffer.
- The split keeps a fixed size (`fixed_width` columns for `right`, `fixed_height` rows for `bottom`; `0` = fit to content).
- A **winbar tab bar** on the view window: each tab is a function + direction, cycled with `<Tab>` / `<S-Tab>`. Inside the view (`.`, `i` / `o`), opening the same function + direction again jumps to its tab instead of duplicating; opening from the code starts fresh.
- The selected box's **function name is colored** (default green, `highlights.focus`), the location label `file:line` is **dimmed** (`highlights.loc`); `highlights.focus_bold` optionally bolds the name.
- The **function the graph was opened on** has its name bold and underlined (`highlights.root`), on top of its color, so it is easy to find again (whenever `highlight` or `colors` is on).
- `<Enter>` jumps to the definition and **keeps the view open**; `q` closes a tab, and on the last tab drops the graphs; `:q`, the open commands run inside the view and `:CallgraphToggle` close the view and keep the graphs for `:CallgraphToggle` (focus returns to the pane it was opened from).

### Keymaps

| Key | Action |
|---|---|
| `h` `j` `k` `l` / arrows | move the selection: across columns (rows when top-to-bottom) to the nearest one, preferring the function's caller or callee, then the box level with it; within a column (row when top-to-bottom) it stops at the end. Back the way it came returns to where it came from, along a call edge or to undo the last move |
| `e` | expand / collapse the focused box (not `<Space>`: a common leader key, which the view's keys would take over) |
| `<Enter>` / `d` | jump to the function definition (view stays open) |
| `R` | re-pick the definition of a multi-definition node (multi_def only) |
| `K` | docs for the selected function (LSP hover) |
| `D` | switch between boxed and dense boxes |
| `v` | flip between left-to-right and top-to-bottom |
| `<Tab>` `<S-Tab>` | cycle tabs |
| `q` | close the current tab (on the last tab, closes the view and drops the graphs) |
| `<Esc>` | close the docs float (`K`) or the focus float, also from inside the docs float; never the view |
| `r` | refresh |
| `i` / `o` | toggle callin / callout in place |
| `.` | open a graph rooted on the selected function, in a new tab (same direction) |
| `[` or `<C-o>` / `]` | back / forward through the tabs in the order visited, like a browser; closing a tab lands where back would |
| `+` / `=` / `-` | depth +1 / -1 |
| `<` / `>` | grow / shrink the view window (width for `right`, height for `bottom`) |
| `?` | key help (a float; `?`, `q` or `<Esc>` closes it) — also the `? keys` button at the right of the tab bar |

Mouse: single click selects a box, **double-click** expands/collapses, scroll wheel scrolls the canvas.

## Features

- **Tree expansion**: every call path expands into its own nodes — the same function called from different places appears once per path (no dedup), so edges never cross and it's always clear who calls whom.
- **Depth limit**: `max_depth` defaults to 4 (at most 4 edges from the root). Boundary nodes collapse to a `▸` marker; Enter / double-click expands, `+` / `-` adjust depth.
- **Cycles**: when a back edge is detected the node is not expanded again; a highlighted **⟳** terminal is shown next to the name and no back edge is drawn.
- **Crossing-free edges**: rows are assigned so each subtree occupies a contiguous band; parent→child edges never overlap other edges.
- **Two-row boxes**: a qualified name (`Mod.Sub.fun/1`, `ns::Cls::m`, `Cls#m`) splits at its last separator: the container and `file:line` sit on a dim first row, the last part on the second. A container wider than `max_name_width` shortens its parts to initials from the left (`ShopServiceWeb` → `SSW`), keeping the last part.
- **Dense style** (`window.style = 'dense'`, or `D`): one borderless row per function, `container.name ❯`, siblings on consecutive rows — several times as many functions fit. The location moves to the message line.
- **Top-to-bottom** (`window.orientation = 'vertical'`, or `v`): callers above, callees below. Siblings sit side by side, so it suits deep, narrow chains; wide fan-outs fit better left to right.
- **Focus float**: when the selected box's label is shortened, a float over the box shows it in full — the whole container, the path relative to the working directory, the whole name (`focus_float`).
- **Location labels**: each box shows `file:line` — the definition for LSP/auto sources, the call site for cscope (`show_call_site` can be turned off).
- **Long-name truncation**: over-wide function names keep their end (`…Scheduler.start_job/1`), where a qualified name differs; hovering shows the full path in the message area.
- **Auto-scroll**: moving the selection scrolls the canvas (horizontal/vertical) so the focused box stays visible.
- **Dynamic window size**: `<` / `>` grow/shrink the view window (width for `right`, height for `bottom`); the size is kept for later renders and re-opens.
- **Multiple tabs**: several function+direction graphs can be open at once in one view, shown in the winbar.
- **Multi-source**: call relationships can come from `lsp` / `cscope` / `ctags` / `auto` in the configured priority order; availability is probed once at startup and cached.
- **Query caching**: each symbol's callers/callees are fetched only once per session — tree expansion reaches the same function along many paths, so the underlying query (cscope / LSP / auto) is never repeated for it, including across rebuilds and expands.
- **Multiple definitions** (`multi_def = true`): when a function name has several definitions — cscope finds them across files / conditional branches, and auto text-scans the file (so `#ifdef`-gated duplicates count) — graph building stops at the node and expanding / jumping opens a definition picker. The picker is a two-pane float: left lists each definition (`file:line` + the definition line's text), right previews the code around the selected one — so you can tell which implementation is which. The chosen definition's implementation is used (cscope keeps call sites in that file, auto re-scans that definition's body); the choice is remembered per node for the session. Off by default: most codebases don't need it, and it adds a definition lookup per call-site node.
- **Lazy.nvim friendly**: `documentSymbol` is cached in the background after `LspAttach`; opening a file costs zero.

## Data sources

`config.sources` lists the sources in priority order (`sources = { 'lsp', 'auto' }`). The plugin probes which are actually available on this machine (executable + index present) and caches the result:

- **`lsp`** (default first): LSP Call Hierarchy — language-agnostic, cross-file. `incomingCalls` (callin) needs clangd ≥ LLVM 12; `outgoingCalls` (callout) needs clangd **≥ LLVM 20** (landed 2024-12).
- **`cscope`**: cscope database queries (needs `cscope` + `cscope.out`; good for C/C++). A name resolving to several definitions pops a picker on expand / jump (see [Features](#features)).
- **`ctags`**: ctags (reserved; not implemented yet).
- **`auto`** (fallback): heuristic single-file — callout scans the function body and resolves each call token via `prepareCallHierarchy`, falling back to **name matching against the file's documentSymbol** (handles call-before-declaration source); callin uses `references` + documentSymbol. **Single-file only** — cross-file calls cannot be resolved.

> Tip: use clangd ≥ 20 so both callin and callout use standard semantic analysis (cross-file, precise).
> With clangd < 20, callout automatically falls through to the next source (e.g. `auto`).

## Supported languages

The plugin is **language-agnostic** — call-graph data comes from the LSP
[Call Hierarchy](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#textDocument_prepareCallHierarchy)
protocol and nothing scans C syntax specifically. Install an LSP for your file
type and the plugin uses it automatically.

What actually matters is which call-hierarchy methods the server implements:

| LSP method | Plugin uses it for | Known implementations |
|---|---|---|
| `prepareCallHierarchy` | resolving the root function under the cursor | most servers (LSP 3.16+) |
| `callHierarchy/incomingCalls` | callin — who calls this | clangd ≥ LLVM 12, pyright ≥ 1.1.44, … |
| `callHierarchy/outgoingCalls` | callout — what this calls | clangd ≥ LLVM 20, pyright ≥ 1.1.44, … |

If the server lacks a method, that fetch resolves empty and the plugin falls
through to the next configured source. Note the `auto` fallback scans C-like
`name(` call tokens and `cscope` is C/C++ only — so for a non-C language use a
server that implements **both** directions for full callout + callin. A server
without call hierarchy at all shows a message telling you to install/enable an
LSP for the file type.

## Requirements

- Neovim **≥ 0.11**
- A language server. For C use **clangd** (≥ 20 for full callout/callin support)
- For cross-file / large projects, make sure a `compile_commands.json` exists and background indexing is ready

## Installation

```lua
-- lazy.nvim
{
  'mengq627/callgraph.nvim',
  cmd = { 'Callout', 'Callin', 'Callgraph', 'CallgraphToggle' },
  keys = {
    { '<leader>co', '<cmd>Callout<CR>', desc = 'Call graph: callees' },
    { '<leader>ci', '<cmd>Callin<CR>',  desc = 'Call graph: callers' },
    { '<leader>cg', '<cmd>Callgraph<CR>', desc = 'Call graph: callers and callees' },
    { '<leader>cG', '<cmd>CallgraphToggle<CR>', desc = 'Call graph: show / hide' },
  },
  opts = {}, -- optional, see below
}
```

## Configuration

```lua
require('callgraph').setup({
  max_depth = 4,          -- maximum edges expanded from the root by default
  both_depth = 2,         -- levels per side in :Callgraph
  show_call_site = true,  -- show  file:line  inside each box
  sources = { 'lsp', 'auto' }, -- call-graph sources in priority order; the
                              -- first one that returns results wins. Available:
                              -- lsp / cscope / ctags (reserved) / auto (single-file
                              -- heuristic). Probed for availability at startup.
  mock_cscope = false,        -- debug: use a text-index mock instead of the
                              -- real `cscope` binary (Windows / CI). Validates
                              -- cscope scenarios, not production accuracy.
  mock_cscope_dir = '',       -- optional directory the mock indexes (default: cwd)
  multi_def = false,          -- multi-definition support (cscope/auto): graph
                              -- stops at nodes with several definitions and
                              -- expanding/jumping opens a picker. OFF by default
                              -- (zero overhead); jump goes to the first def.
  highlight = true,       -- highlight toggle (on by default): color the focused
                          -- function name, dim the location label
  window = {
    position = 'bottom',     -- 'bottom' (full width) | 'right' (full height)
    fixed_width = 80,        -- right-layout fixed columns (0 = fit to content)
    fixed_height = 20,       -- bottom-layout fixed rows
    row_gap = 2,             -- vertical gap between stacked boxes in a column
    col_gap = 5,             -- horizontal gap between columns
    max_name_width = 26,     -- name and container truncation
    max_func_width = nil,    -- name-row truncation (nil = max_name_width)
    max_loc_width = 22,      -- location label truncation
    focus_float = true,      -- full label in a float over a shortened selected box
    style = 'boxed',         -- 'boxed' | 'dense' (one row per function); D switches
    orientation = 'horizontal', -- or 'vertical' (callers above, callees below); v flips
    arrows = { right='', down='', up='', left='' }, -- Nerd Font arrows
    collapse_marker = '❯',  -- expandable marker: '❯' thick | '▶' large | '▸' small | '▷' outline
  },
  highlights = {
    focus = 'CallgraphFocus',       -- focused function name color (default green)
    focus_bold = false,             -- bold the focused function name
    loc = 'CallgraphLoc',           -- location label color (default dim)
    root = 'CallgraphRoot',         -- the opened function's name (default bold + underline)
    tab_active = 'CallgraphTabActive',     -- current tab label
    tab_inactive = 'CallgraphTabInactive', -- other tab labels
  },
  colors = {
    -- Canvas colors: 'off' (default terminal colors) | 'auto' (mirror the code
    -- area: function name <- @function, selected name + inline markers <-
    -- @keyword, file:line <- Comment, background <- Normal; edges white,
    -- borders bluish purple) | 'custom' (use the colors below).
    mode = 'auto',
    func = '#98c379',    -- function / symbol name (custom)
    location = '#5c6370', -- file:line label (custom)
    border = '#9d7cd8',  -- box border (custom)
    edge = '#ffffff',    -- connection lines (custom)
    focus = '#98c379',   -- focused function name (custom)
    symbol = '#e5c07b',  -- inline markers ⟳ cycle / ▸ collapsible (custom)
  },
  keymaps = {               -- all remappable; set to '' to disable
    move_left = 'h', move_down = 'j', move_up = 'k', move_right = 'l',
    move_left_alt = '<Left>', move_down_alt = '<Down>',
    move_up_alt = '<Up>', move_right_alt = '<Right>',
    toggle_expand = 'e',
    close = 'q', close_alt = '', -- close_alt: a second close-tab key
    close_popup = '<Esc>', -- close the docs float and the focus float
    refresh = 'r',
    to_callin = 'i', to_callout = 'o',
    reroot = '.',       -- new tab rooted on the selected function
    back = '[', back_alt = '<C-o>', forward = ']', -- tab history
    depth_up = '+', depth_up_alt = '=', -- `=` equals `+` (no shift needed)
    depth_down = '-',
    win_grow = '<', win_shrink = '>', -- '<' grow / '>' shrink the view window
    jump_to_def = '<CR>', jump_to_def_alt = 'd',
    reselect_def = 'R', -- re-pick the definition of a multi-definition node
    hover = 'K',        -- docs for the selected function (LSP hover)
    toggle_style = 'D', -- boxed / dense boxes
    flip = 'v',         -- left-to-right / top-to-bottom
    tab_next = '<Tab>', tab_prev = '<S-Tab>',
    help = '?',
  },
})
```

### Color modes

`colors.mode` controls how the canvas is colored:

| `off` (default terminal colors) | `auto` (mirrors the code area) |
|---|---|
| ![off](assets/off_colors.png) | ![auto](assets/auto_colors.png) |

- **off**: plain terminal colors — borders, text and connection lines all use the default palette.
- **auto**: mirrors the code area — function name follows `@function`, the **selected** function name and inline markers (⟳ / ❯) follow `@keyword`, `file:line` follows `Comment`, background follows `Normal`, borders are bluish purple, edges white.
- **custom**: use the `colors.*` values above.

## Architecture

```
plugin/callgraph.lua  lazy entry point: registers :Callout / :Callin / :Callgraph / :CallgraphToggle / :CallgraphLog / :CallgraphDebug
lua/callgraph/
  init.lua      setup(), public API, LspAttach background cache
  config.lua    defaults + merge + highlight group definitions
  source.lua    source manager: availability probe cache, combined fetch by
                sources priority, root resolution
  source/       symbol sources (each one way to query call relationships):
    lsp.lua       LSP call hierarchy (outgoing/incomingCalls)
    auto.lua      heuristic single-file (reuses scanner + fallback)
    cscope.lua    cscope database queries (-dL -2/-3)
    ctags.lua     ctags (reserved)
  lsp.lua       LSP tools: root resolution (prepareCallHierarchy + documentSymbol), jump to definition
  graph.lua     graph build: recursive fetch (tree, no dedup), cycle detection, depth clip (pure logic, injected fetch)
  scanner.lua   pure-C call-site scanner (skips comments/strings/preprocessor, returns call tokens)
  fallback.lua  heuristic fetch: callout body-scan + name match, callin via references
  layout.lua    layered layout + orthogonal edge routing (pure functions)
  render.lua    draw the graph into the canvas buffer + highlight extmarks
  view.lua      split view, tabs (winbar), keymaps, mouse, hover echo
```

The core (graph / scanner / layout / render) is pure logic and can be tested without an LSP.

## Development / Testing

All tests live in `tests/`, run from the repo root:

```bash
nvim --headless -u NONE -l tests/load_check.lua        # every module loads
nvim --headless -u NONE -l tests/smoke.lua             # no server: graph/layout/render/scanner/fallback
nvim --headless -u NONE -l tests/repro_move.lua        # cursor placement regression while moving
nvim --headless -u NONE -l tests/tabs.lua              # tabs: reuse/switch/close + winbar
nvim --headless -u NONE -l tests/scroll.lua            # horizontal scroll keeps the box visible
nvim --headless -u NONE -l tests/ui.lua                # no server: split view / navigation / expand / close
nvim --headless -u NONE -l tests/integration.lua       # real clangd: clean.c callout(fallback) + callin
nvim --headless -u NONE -l tests/integration_testc.lua # real clangd: test.c name-match fallback
nvim --headless -u NONE -l tests/integration_lsp.lua   # clangd ≥ 20: pure-LSP callout 4 levels + callin
nvim --headless -u NONE -l tests/integration_py.lua    # pyright: Python callout(outgoing)+callin (skips if absent)
nvim --headless -u NONE -l tests/integration_auto_multidef.lua # auto: multidef.c 条件编译多定义触发条件
nvim --headless -u NONE -l tests/cscope_mock.lua # mock cscope：文本索引多定义（无 cscope 也可验证）
nvim --headless -u NONE -l tests/cscope.lua            # cscope provider: output parse / index discovery / availability
nvim --headless -u NONE -l tests/integration_complex.lua # test_complex.c: diamond / cycles / fan-out / deep chain
nvim --headless -u NONE -l tests/e2e_callout.lua         # end-to-end: open file, place cursor, run :Callout (CI)

### Interactive E2E (watch it run)

Runs cases in a real Neovim window, stepping through each action with on-screen
prompts and pauses so you can judge every step. Drive the whole suite with a
single command:

```bash
# watch all cases — callout, callin, direction, expand, depth, tabs, jump,
# close, cycle, scroll, help (one command steps through every capability)
nvim -u NONE --cmd "set rtp+=<repo>" tests/test_complex.c \
  -c "lua dofile('<repo>/tests/e2e_cases.lua').run_all()"

# or watch a single case
nvim -u NONE --cmd "set rtp+=<repo>" tests/test_complex.c \
  -c "lua dofile('<repo>/tests/e2e_cases.lua').run('tabs')"
```

Cases live in `tests/e2e_cases.lua` (a list of `{ msg, fn, wait_ms, check }`
steps); add more to guard other features. Headless (CI) runs the same cases
synchronously and asserts each step:

```bash
nvim --headless -u NONE -c "lua dofile('<repo>/tests/e2e_cases.lua').run_all()"
```

`tests/smoke.lua` covers: tree expansion (a symbol appears once per call path), cycle terminals, callin mirror,
`max_depth` boundary collapse, expand/collapse, the C call-site scanner, fallback orchestration, same-column arrows.
`tests/clean.c` is well-formed sample source; `tests/test.c` is a call-before-declaration diamond sample.

### Coverage (luacov)

Every test runs under a vendored [luacov](https://lunarmodules.github.io/luacov/) (`tests/vendor/luacov/`, pure Lua, no external deps).

```bash
# run all tests + print the coverage summary
nvim --headless -u NONE -l tests/run_coverage.lua

# additionally check that newly added lines are covered
nvim --headless -u NONE -l tests/run_coverage.lua --diff origin/main
```

Rules:

- **Tests are a hard gate**: every push / PR must pass the full suite (`test` job).
- **Coverage is a non-blocking gate**: push and PR both report new-code coverage (`--diff <base>` marks newly added **executable** lines that aren't exercised as `UNCOVERED NEW LINE`; lines in `lua/callgraph` files no test loads are also flagged). It **never blocks the merge** — a committer can force-merge.
- **Exempting branches**: wrap deliberately-untested branches (e.g. defensive / error handling) in `-- luacov: disable` / `-- luacov: enable` comments; those lines count neither as misses nor as new-code requirements.
- GitHub Actions (`.github/workflows/ci.yml`): one job — tests + coverage summary are the hard gate; the new-code coverage check reuses the same run's report (`--no-run`, `continue-on-error`) on push and PR and shows the result without blocking. `luacov.report.out` is uploaded as a build artifact.
