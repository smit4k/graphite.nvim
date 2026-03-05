-- parser.lua: Detect inter-file dependencies using regex patterns.
-- Add a new entry to M.parsers to support additional languages.

local M = {}

-- parsers table: extension -> function(content, file_path, root) -> string[]
-- Each function returns a list of raw dependency identifiers (module paths/names).
M.parsers = {}

-- ── Lua ──────────────────────────────────────────────────────────────────────
-- Matches: require("foo.bar")  require('foo.bar')
M.parsers.lua = function(content)
  local deps = {}
  for dep in content:gmatch('require%s*%(%s*["\']([^"\']+)["\']%s*%)') do
    table.insert(deps, dep)
  end
  return deps
end

-- ── JavaScript / TypeScript ───────────────────────────────────────────────────
-- Matches: import ... from "./foo"   require("./foo")
local function js_parser(content)
  local deps = {}
  -- ESM: import ... from "path"  (single-line form)
  for dep in content:gmatch('import[^\n]+from%s+["\']([^"\']+)["\']') do
    table.insert(deps, dep)
  end
  -- CJS: require("path")
  for dep in content:gmatch('require%s*%(%s*["\']([^"\']+)["\']%s*%)') do
    table.insert(deps, dep)
  end
  return deps
end

M.parsers.js = js_parser
M.parsers.mjs = js_parser
M.parsers.cjs = js_parser
M.parsers.ts = js_parser
M.parsers.tsx = js_parser
M.parsers.jsx = js_parser

-- ── Python ────────────────────────────────────────────────────────────────────
-- Matches: import foo.bar   from foo.bar import baz
M.parsers.py = function(content)
  local deps = {}
  for line in (content .. "\n"):gmatch("([^\n]*)\n") do
    local dep = line:match("^import%s+([%w%.]+)")
    if dep then
      table.insert(deps, dep)
    end
    dep = line:match("^from%s+([%.%w]+)%s+import")
    if dep then
      table.insert(deps, dep)
    end
  end
  return deps
end

-- ── Rust ─────────────────────────────────────────────────────────────────────
-- Matches: mod parser;   use crate::util
M.parsers.rs = function(content)
  local deps = {}
  for line in (content .. "\n"):gmatch("([^\n]*)\n") do
    local dep = line:match("^%s*mod%s+([%w_]+)%s*;")
    if dep then
      table.insert(deps, dep)
    end
    dep = line:match("^%s*use%s+([%w_:]+)")
    if dep then
      table.insert(deps, dep)
    end
  end
  return deps
end

--- Parse a single file and return its raw dependency identifiers.
---@param file_path string Absolute path
---@param root string Project root (passed to parser, may be used for context)
---@return string[]
M.parse_file = function(file_path, root)
  local ext = file_path:match("%.([^%./]+)$") or ""
  local parser_fn = M.parsers[ext]
  if not parser_fn then
    return {}
  end

  local f = io.open(file_path, "r")
  if not f then
    return {}
  end
  local content = f:read("*a")
  f:close()

  local ok, result = pcall(parser_fn, content, file_path, root)
  if not ok then
    return {}
  end
  return result
end

--- Register a parser for a custom file extension.
--- The function receives (content, file_path, root) and must return string[].
---@param ext string  e.g. "go"
---@param fn fun(content:string, file_path:string, root:string):string[]
M.register = function(ext, fn)
  M.parsers[ext] = fn
end

return M
