-- parser.lua: Detect inter-file dependencies using regex patterns.
-- Add a new entry to M.parsers to support additional languages.

local M = {}

-- parsers table: extension -> function(content, file_path, root) -> string[]
-- Each function returns a list of raw dependency identifiers (module paths/names).
M.parsers = {}

local function line_iter(content)
  return (content .. "\n"):gmatch("([^\n]*)\n")
end

-- ── Lua ──────────────────────────────────────────────────────────────────────
-- Matches: require("foo.bar")  require('foo.bar')
M.parsers.lua = function(content)
  local deps = {}
  for dep in content:gmatch("require%s*%(%s*[\"']([^\"']+)[\"']%s*%)") do
    table.insert(deps, dep)
  end
  return deps
end

-- ── JavaScript / TypeScript ───────────────────────────────────────────────────
-- Matches: import ... from "./foo"   require("./foo")
local function js_parser(content)
  local deps = {}
  -- ESM: import ... from "path"  (single-line form)
  for dep in content:gmatch("import[^\n]+from%s+[\"']([^\"']+)[\"']") do
    table.insert(deps, dep)
  end
  -- ESM side-effect import: import "path"
  for dep in content:gmatch("import%s+[\"']([^\"']+)[\"']") do
    table.insert(deps, dep)
  end
  -- CJS: require("path")
  for dep in content:gmatch("require%s*%(%s*[\"']([^\"']+)[\"']%s*%)") do
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
  for line in line_iter(content) do
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
  for line in line_iter(content) do
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

-- ── Go ────────────────────────────────────────────────────────────────────────
-- Matches:
--   import "fmt"
--   import alias "project/pkg"
--   import ( "a" alias "b" )
M.parsers.go = function(content)
  local deps = {}
  for dep in content:gmatch('import%s+[^\n"]*["]([^"]+)["]') do
    table.insert(deps, dep)
  end
  for block in content:gmatch("import%s*%b()") do
    for dep in block:gmatch('["]([^"]+)["]') do
      table.insert(deps, dep)
    end
  end
  return deps
end

-- ── Java / Kotlin / Scala / C# / Swift ──────────────────────────────────────
-- Matches line forms of import/using statements.
local function dotted_import_parser(content)
  local deps = {}
  for line in line_iter(content) do
    local dep = line:match("^%s*import%s+static%s+([%w%._]+)")
    if dep then
      table.insert(deps, dep)
    end
    dep = dep or line:match("^%s*import%s+([%w%._]+)")
    if dep then
      dep = dep:gsub("%s+as%s+[%w_]+$", "")
      table.insert(deps, dep)
    end
    dep = line:match("^%s*global%s+using%s+([%w%._]+)")
    if dep then
      table.insert(deps, dep)
    end
    dep = line:match("^%s*using%s+([%w%._]+)")
    if dep then
      table.insert(deps, dep)
    end
  end
  return deps
end

M.parsers.java = dotted_import_parser
M.parsers.kt = dotted_import_parser
M.parsers.kts = dotted_import_parser
M.parsers.scala = dotted_import_parser
M.parsers.cs = dotted_import_parser
M.parsers.swift = dotted_import_parser

-- ── Ruby ──────────────────────────────────────────────────────────────────────
-- Matches: require "x", require_relative "x", and call forms with parentheses.
M.parsers.rb = function(content)
  local deps = {}
  for dep in content:gmatch("require_relative%s*%(?%s*[\"']([^\"']+)[\"']%s*%)?") do
    table.insert(deps, dep)
  end
  for dep in content:gmatch("require%s*%(?%s*[\"']([^\"']+)[\"']%s*%)?") do
    table.insert(deps, dep)
  end
  return deps
end

-- ── PHP ───────────────────────────────────────────────────────────────────────
-- Matches: use Foo\Bar; require/include "path"
M.parsers.php = function(content)
  local deps = {}
  for line in line_iter(content) do
    local dep = line:match("^%s*use%s+([%w_\\]+)")
    if dep then
      table.insert(deps, dep)
    end
  end
  for dep in content:gmatch("require_once%s*%(?%s*[\"']([^\"']+)[\"']%s*%)?") do
    table.insert(deps, dep)
  end
  for dep in content:gmatch("require%s*%(?%s*[\"']([^\"']+)[\"']%s*%)?") do
    table.insert(deps, dep)
  end
  for dep in content:gmatch("include_once%s*%(?%s*[\"']([^\"']+)[\"']%s*%)?") do
    table.insert(deps, dep)
  end
  for dep in content:gmatch("include%s*%(?%s*[\"']([^\"']+)[\"']%s*%)?") do
    table.insert(deps, dep)
  end
  return deps
end

-- ── Zig ───────────────────────────────────────────────────────────────────────
-- Matches: @import("std"), @import("./foo.zig")
M.parsers.zig = function(content)
  local deps = {}
  for dep in content:gmatch("@import%s*%(%s*[\"']([^\"']+)[\"']%s*%)") do
    table.insert(deps, dep)
  end
  return deps
end

-- ── C / C++ ──────────────────────────────────────────────────────────────────
-- Matches: #include "foo.h" and #include <vector>
local function c_include_parser(content)
  local deps = {}
  for dep in content:gmatch('#include%s*[<"]([^">]+)[>"]') do
    table.insert(deps, dep)
  end
  return deps
end

M.parsers.c = c_include_parser
M.parsers.h = c_include_parser
M.parsers.cpp = c_include_parser
M.parsers.hpp = c_include_parser

-- ── Elixir ───────────────────────────────────────────────────────────────────
-- Matches: alias/import/require/use Foo.Bar
M.parsers.ex = function(content)
  local deps = {}
  for line in line_iter(content) do
    local dep = line:match("^%s*alias%s+([%w%._]+)")
    if dep then
      table.insert(deps, dep)
    end
    dep = line:match("^%s*import%s+([%w%._]+)")
    if dep then
      table.insert(deps, dep)
    end
    dep = line:match("^%s*require%s+([%w%._]+)")
    if dep then
      table.insert(deps, dep)
    end
    dep = line:match("^%s*use%s+([%w%._]+)")
    if dep then
      table.insert(deps, dep)
    end
  end
  return deps
end
M.parsers.exs = M.parsers.ex

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
