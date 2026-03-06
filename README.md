<h1 align='center'>
    graphite.nvim
</h1>
<p align='center'>
  <b>Visualize the structure of your codebase as an interactive dependency graph inside Neovim.</b>
</p>

## Installation

**Prerequisites**: Neovim >= 0.90

Use your favorite package manager!

```lua
{
  "smit4k/graphite.nvim",
  config = function()
    require("graphite").setup()
  end,
}
```

## Configuration

All options are optional — the plugin works with zero configuration.

```lua
require("graphite").setup({
  -- Maximum number of files to scan (prevents hangs on huge monorepos)
  max_files = 1000,

  -- When true, :GraphiteOpen always rescans instead of reusing the cache
  auto_refresh = false,

  -- Layout algorithm:
  -- "tree"      -> hierarchical ASCII list
  -- "graph"     -> routed graph view + node list
  layout = "tree",

  -- Lua patterns for paths that should be excluded from scanning
  ignore_patterns = {
    "node_modules", "%.git", "%.cache", "dist", "build", "vendor",
  },
})
```

## Commands

| Command              | Description                                                        |
| -------------------- | ------------------------------------------------------------------ |
| `:GraphiteOpen`      | Scan the project and open the graph window                         |
| `:GraphiteRefresh`   | Force a full rescan and re-render                                  |
| `:GraphiteFocus`     | Show only the current file and its direct neighbours               |
| `:GraphiteFunctions` | Show the function-level call graph (requires Tree-sitter grammars) |

## Keybindings (inside the graph window)

| Key           | Action                                                |
| ------------- | ----------------------------------------------------- |
| `j` / `k`     | Move to the next / previous node                      |
| `l`           | Jump to the first dependency of the selected node     |
| `h`           | Jump to the first node that imports the selected node |
| `t`           | Toggle layout (`tree` ↔ `graph`)                      |
| `<Enter>`     | Open the selected file in the editor                  |
| `q` / `<Esc>` | Close the graph window                                |

## Supported Languages

| Language                    | Detected patterns                   |
| --------------------------- | ----------------------------------- |
| **Lua**                     | `require("module")`                 |
| **JavaScript / TypeScript** | `import … from "…"`, `require("…")` |
| **Python**                  | `import foo`, `from foo import bar` |
| **Rust**                    | `mod name;`, `use crate::…`         |

This plugin is in its early stages, expect support for more languages soon

## How It Works

1. **Scan** — `util.scan_dir` recursively enumerates files via `vim.fn.glob`,
   skipping ignored paths and capping at `max_files`.
2. **Parse** — `parser.parse_file` runs a language-specific regex parser and
   returns raw dependency identifiers.
3. **Resolve** — `graph.build` maps each identifier to an actual project file
   (handles Lua dot-paths, JS relative paths, Python dotted modules, Rust mod
   names, etc.).
4. **Render** — `renderer.render` assigns BFS layers and renders either a
   tree view (`layout = "tree"`) or a routed graph view (`layout = "graph"`),
   returning a node-position map for navigation.
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
