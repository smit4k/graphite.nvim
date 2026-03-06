-- graph.lua: Build and manage the file dependency graph.
-- Exposes build(), get(), focus(), clear() for file-level graphs and
-- build_functions() / get_function_graph() for function-level call graphs.

local util = require("graphite.util")
local parser = require("graphite.parser")
local ts = require("graphite.treesitter")

local M = {}

---@class GraphNode
---@field path string   Absolute file path
---@field label string  Display name (basename)
---@field deps string[] Relative paths of files this node imports

---@class GraphData
---@field nodes table<string, GraphNode>   key = relative path
---@field edges {from:string, to:string}[]

-- Module-level graph state
local _graph = { nodes = {}, edges = {} }

-- Supported source-file extensions
local SUPPORTED_EXTS = {
  lua = true,
  js = true,
  mjs = true,
  cjs = true,
  ts = true,
  tsx = true,
  jsx = true,
  py = true,
  rs = true,
  go = true,
  java = true,
  kt = true,
  kts = true,
  rb = true,
  php = true,
  cs = true,
  swift = true,
  zig = true,
  c = true,
  h = true,
  cpp = true,
  hpp = true,
  ex = true,
  exs = true,
  scala = true,
}

--- Resolve a raw dependency identifier to a relative file path that exists in the
--- project.  Returns nil when no match is found.
---@param dep string          Raw dep string (module name, relative path, …)
---@param from_file string    Relative path of the file declaring the dep
---@param file_index table<string,boolean>  Set of all known relative paths
---@return string|nil
local function resolve_dep(dep, from_file, file_index)
  local from_dir = from_file:match("^(.*)/[^/]+$") or ""
  local exts = {
    "lua",
    "js",
    "ts",
    "tsx",
    "jsx",
    "py",
    "rs",
    "mjs",
    "cjs",
    "go",
    "java",
    "kt",
    "kts",
    "rb",
    "php",
    "cs",
    "swift",
    "zig",
    "c",
    "h",
    "cpp",
    "hpp",
    "ex",
    "exs",
    "scala",
  }

  -- Normalize a candidate path (collapse .. and .)
  local function normalize(raw)
    local parts = {}
    for part in raw:gmatch("[^/]+") do
      if part == ".." then
        if #parts > 0 then
          table.remove(parts)
        end
      elseif part ~= "." and part ~= "" then
        table.insert(parts, part)
      end
    end
    return table.concat(parts, "/")
  end

  local candidates = {}

  if dep:match("^%.") then
    -- Relative import (JS/TS style: ./foo or ../bar)
    local base = normalize(from_dir .. "/" .. dep)
    for _, ext in ipairs(exts) do
      table.insert(candidates, base .. "." .. ext)
      table.insert(candidates, base .. "/index." .. ext)
    end
    table.insert(candidates, base) -- dep already has an extension
  else
    -- Absolute / module-style import
    -- Convert separators used in common module systems.
    local as_path = dep:gsub("::", "/"):gsub("%.", "/"):gsub("\\", "/")

    -- Try various root-relative prefixes
    local prefixes = { "", "lua/", "src/", "lib/" }
    for _, prefix in ipairs(prefixes) do
      for _, ext in ipairs(exts) do
        table.insert(candidates, prefix .. as_path .. "." .. ext)
      end
    end

    -- Rust mod: sibling file in the same directory
    for _, ext in ipairs(exts) do
      table.insert(candidates, normalize(from_dir .. "/" .. as_path .. "." .. ext))
    end
  end

  for _, c in ipairs(candidates) do
    if file_index[c] then
      return c
    end
  end
  return nil
end

--- Scan the project rooted at `root` and build the dependency graph.
---@param root string   Absolute project root directory
---@param config table  Plugin configuration (max_files, ignore_patterns)
---@return GraphData
M.build = function(root, config)
  local ignore_patterns = config.ignore_patterns or { "node_modules", "%.git", "%.cache", "dist", "build", "vendor" }

  local all_files = util.scan_dir(root, config.max_files or 1000, ignore_patterns)

  -- Filter to supported source files and build a relative-path index
  local src_files = {}
  local file_index = {} -- rel_path -> true
  for _, abs in ipairs(all_files) do
    local ext = util.get_extension(abs)
    if SUPPORTED_EXTS[ext] then
      local rel = util.relative_path(abs, root)
      table.insert(src_files, { abs = abs, rel = rel })
      file_index[rel] = true
    end
  end

  -- Initialise nodes
  local nodes = {}
  for _, f in ipairs(src_files) do
    nodes[f.rel] = {
      path = f.abs,
      label = vim.fn.fnamemodify(f.rel, ":t"),
      deps = {},
    }
  end

  -- Parse each file and build edges
  local edges = {}
  local edge_set = {} -- dedup key: "from->to"
  for _, f in ipairs(src_files) do
    local raw_deps = parser.parse_file(f.abs, root)
    for _, dep in ipairs(raw_deps) do
      local resolved = resolve_dep(dep, f.rel, file_index)
      if resolved and resolved ~= f.rel then
        local key = f.rel .. "->" .. resolved
        if not edge_set[key] then
          edge_set[key] = true
          table.insert(edges, { from = f.rel, to = resolved })
          table.insert(nodes[f.rel].deps, resolved)
        end
      end
    end
  end

  _graph = { nodes = nodes, edges = edges }
  return _graph
end

--- Return the currently cached graph.
---@return GraphData
M.get = function()
  return _graph
end

--- Return a subgraph containing only the given file and its immediate neighbours
--- (files it imports + files that import it).
---@param file_rel string Relative path of the focal file
---@return GraphData
M.focus = function(file_rel)
  local g = _graph
  if not g.nodes[file_rel] then
    return { nodes = {}, edges = {} }
  end

  local focus_nodes = { [file_rel] = g.nodes[file_rel] }
  local focus_edges = {}
  local edge_set = {}

  for _, edge in ipairs(g.edges) do
    local is_outgoing = edge.from == file_rel
    local is_incoming = edge.to == file_rel
    if is_outgoing or is_incoming then
      local key = edge.from .. "->" .. edge.to
      if not edge_set[key] then
        edge_set[key] = true
        table.insert(focus_edges, edge)
        -- Add the neighbour node if it exists in the full graph
        if is_outgoing and g.nodes[edge.to] then
          focus_nodes[edge.to] = g.nodes[edge.to]
        end
        if is_incoming and g.nodes[edge.from] then
          focus_nodes[edge.from] = g.nodes[edge.from]
        end
      end
    end
  end

  return { nodes = focus_nodes, edges = focus_edges }
end

--- Clear the cached graph (forces a full rebuild on the next build() call).
M.clear = function()
  _graph = { nodes = {}, edges = {} }
  _func_graph = { nodes = {}, edges = {} }
end

-- ── Function-level call graph ─────────────────────────────────────────────────

---@class FuncNode
---@field path  string  Absolute file path
---@field file  string  Relative file path
---@field name  string  Function name
---@field label string  Display label ("file::func" for cross-file clarity)
---@field calls string[] Keys of functions this function calls

-- Module-level function graph cache
local _func_graph = { nodes = {}, edges = {} }

--- Build a function-level call graph for the project.
--- Each node represents one function; edges represent call relationships.
--- Cross-file edges are resolved via the existing file import map.
---
--- Requires Tree-sitter grammars to be installed.  Files whose grammar is
--- missing are silently skipped (only their file-level imports are used as
--- a fallback to guide cross-file resolution).
---@param root string   Absolute project root
---@param config table  Plugin configuration
---@return GraphData
M.build_functions = function(root, config)
  -- Re-use (or rebuild) the file-level graph for import resolution
  local fg = _graph
  if next(fg.nodes) == nil then
    fg = M.build(root, config)
  end

  -- Build file-import map: rel_path -> set of rel_paths it imports
  local file_imports = {}
  for _, edge in ipairs(fg.edges) do
    file_imports[edge.from] = file_imports[edge.from] or {}
    file_imports[edge.from][edge.to] = true
  end

  -- Build a global index: func_name -> [{file_rel, node_key}]
  -- Used later for cross-file call resolution.
  local global_func_index = {} -- func_name -> list of node_keys

  -- First pass: extract defs from every file, build nodes
  local func_nodes = {}
  local file_defs = {} -- file_rel -> {func_name -> node_key}

  for file_rel, file_node in pairs(fg.nodes) do
    local info = ts.extract(file_node.path)
    if info and #info.defs > 0 then
      file_defs[file_rel] = {}
      for _, fname in ipairs(info.defs) do
        local node_key = file_rel .. "::" .. fname
        local label = vim.fn.fnamemodify(file_rel, ":t") .. "::" .. fname
        func_nodes[node_key] = {
          path = file_node.path,
          file = file_rel,
          name = fname,
          label = label,
          calls = {},
        }
        file_defs[file_rel][fname] = node_key
        global_func_index[fname] = global_func_index[fname] or {}
        table.insert(global_func_index[fname], { file = file_rel, key = node_key })
      end
    end
  end

  -- Second pass: resolve calls and build edges
  local func_edges = {}
  local edge_set = {}

  for file_rel, file_node in pairs(fg.nodes) do
    local info = ts.extract(file_node.path)
    if not info then
      goto continue
    end

    local imported_files = file_imports[file_rel] or {}

    for caller_name, callees in pairs(info.calls_by_func) do
      -- The caller node key (may not exist if the function was not in defs)
      local caller_key = file_defs[file_rel] and file_defs[file_rel][caller_name]

      for _, callee_name in ipairs(callees) do
        -- Resolution priority:
        --  1. Same-file definition
        --  2. Definition in a file that this file imports
        --  3. Best-effort: any file in the project that defines this name
        local resolved_key = nil

        -- 1. Same file
        if file_defs[file_rel] and file_defs[file_rel][callee_name] then
          resolved_key = file_defs[file_rel][callee_name]
        end

        -- 2. Imported files
        if not resolved_key then
          for imp_file in pairs(imported_files) do
            if file_defs[imp_file] and file_defs[imp_file][callee_name] then
              resolved_key = file_defs[imp_file][callee_name]
              break
            end
          end
        end

        -- 3. Global fallback (first match; ambiguous but better than nothing)
        if not resolved_key and global_func_index[callee_name] then
          local matches = global_func_index[callee_name]
          if #matches == 1 then
            resolved_key = matches[1].key
          end
        end

        if resolved_key and caller_key and caller_key ~= resolved_key then
          local edge_key = caller_key .. "->" .. resolved_key
          if not edge_set[edge_key] then
            edge_set[edge_key] = true
            table.insert(func_edges, { from = caller_key, to = resolved_key })
            table.insert(func_nodes[caller_key].calls, resolved_key)
          end
        end
      end
    end

    ::continue::
  end

  _func_graph = { nodes = func_nodes, edges = func_edges }
  return _func_graph
end

--- Return the cached function-level graph.
---@return GraphData
M.get_function_graph = function()
  return _func_graph
end

return M
