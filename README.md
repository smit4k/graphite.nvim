# graphite.nvim

![Lua](https://img.shields.io/badge/Made%20with%20Lua-blueviolet.svg?style=for-the-badge&logo=lua)
![Neovim](https://img.shields.io/badge/Neovim%200.9+-green.svg?style=for-the-badge&logo=neovim)

**graphite.nvim** visualises the structure of your codebase as an interactive
dependency graph inside Neovim — think Obsidian's graph view, but for source
code.

It scans your project, detects `import` / `require` / `use` / `mod` statements,
builds an in-memory dependency graph, and renders it in a floating window you
can navigate with your keyboard.

---

## Screenshot

```
  graphite.nvim  ·  Nodes: 5  Edges: 4
  [Enter] open file   [q] close   [j/k] prev/next node   [h/l] parent/child
  ────────────────────────────────────────────────────────────────────────
  ◆ init.lua  → 2 deps
    ├─→  graph.lua
    └─→  ui.lua

  ◆ graph.lua  → 2 deps
    ├─→  util.lua
    └─→  parser.lua

  ◆ ui.lua  → 1 dep
    └─→  renderer.lua

  ◆ util.lua
  ◆ parser.lua
  ◆ renderer.lua
```

---

## Installation

### [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  "username/graphite.nvim",
  config = function()
    require("graphite").setup()
  end,
}
```

### [packer.nvim](https://github.com/wbthomason/packer.nvim)

```lua
use {
  "username/graphite.nvim",
  config = function()
    require("graphite").setup()
  end,
}
```

---

## Configuration

All options are optional — the plugin works with zero configuration.

```lua
require("graphite").setup({
  -- Maximum number of files to scan (prevents hangs on huge monorepos)
  max_files = 1000,

  -- When true, :GraphiteOpen always rescans instead of reusing the cache
  auto_refresh = false,

  -- Layout algorithm.  "tree" is the only option right now;
  -- a force-directed layout is planned.
  layout = "tree",

  -- Lua patterns for paths that should be excluded from scanning
  ignore_patterns = {
    "node_modules", "%.git", "%.cache", "dist", "build", "vendor",
  },
})
```

---

## Commands

| Command | Description |
|---|---|
| `:GraphiteOpen` | Scan the project and open the graph window |
| `:GraphiteRefresh` | Force a full rescan and re-render |
| `:GraphiteFocus` | Show only the current file and its direct neighbours |
| `:GraphiteFunctions` | Show the function-level call graph (requires Tree-sitter grammars) |

---

## Keybindings (inside the graph window)

| Key | Action |
|---|---|
| `j` / `k` | Move to the next / previous node |
| `l` | Jump to the first dependency of the selected node |
| `h` | Jump to the first node that imports the selected node |
| `<Enter>` | Open the selected file in the editor |
| `q` / `<Esc>` | Close the graph window |

---

## Supported Languages

| Language | Detected patterns |
|---|---|
| **Lua** | `require("module")` |
| **JavaScript / TypeScript** | `import … from "…"`, `require("…")` |
| **Python** | `import foo`, `from foo import bar` |
| **Rust** | `mod name;`, `use crate::…` |

### Adding a custom language

```lua
require("graphite.parser").register("go", function(content, file_path, root)
  local deps = {}
  for pkg in content:gmatch('"([^"]+)"') do
    table.insert(deps, pkg)
  end
  return deps
end)
```

---

## How It Works

1. **Scan** — `util.scan_dir` recursively enumerates files via `vim.fn.glob`,
   skipping ignored paths and capping at `max_files`.
2. **Parse** — `parser.parse_file` runs a language-specific regex parser and
   returns raw dependency identifiers.
3. **Resolve** — `graph.build` maps each identifier to an actual project file
   (handles Lua dot-paths, JS relative paths, Python dotted modules, Rust mod
   names, etc.).
4. **Render** — `renderer.render` assigns BFS layers, produces an ASCII tree
   listing with `◆` markers per node, and returns a position map used for
   navigation.
5. **Display** — `ui.open` creates a rounded floating window, applies syntax
   highlights, and wires up keyboard navigation.

---

## Project Structure

```
lua/
  graphite/
    init.lua       ← public API & setup()
    commands.lua   ← :Graphite* user commands
    graph.lua      ← graph building, caching, focus mode
    parser.lua     ← language-specific dependency parsers
    renderer.lua   ← ASCII renderer & node-position map
    ui.lua         ← floating window, keymaps, highlights
    util.lua       ← file scanning & path utilities
plugin/
  graphite.lua     ← auto-loaded entry point
```

---

## Requirements

- Neovim **0.9+**
- No external dependencies
