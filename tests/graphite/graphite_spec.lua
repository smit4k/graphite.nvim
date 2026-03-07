local util = require("graphite.util")
local parser = require("graphite.parser")
local graph = require("graphite.graph")
local renderer = require("graphite.renderer")
local treesitter = require("graphite.treesitter")

-- ── util ──────────────────────────────────────────────────────────────────────

describe("util.get_extension", function()
  it("returns the extension without a dot", function()
    assert.equal("lua", util.get_extension("foo/bar.lua"))
    assert.equal("ts", util.get_extension("src/index.ts"))
    assert.equal("", util.get_extension("Makefile"))
  end)
end)

describe("util.relative_path", function()
  it("strips the root prefix", function()
    assert.equal("lua/graphite/init.lua", util.relative_path("/proj/lua/graphite/init.lua", "/proj"))
  end)

  it("returns the path unchanged when not under root", function()
    assert.equal("/other/file.lua", util.relative_path("/other/file.lua", "/proj"))
  end)
end)

-- ── parser ────────────────────────────────────────────────────────────────────

describe("parser.parsers.lua", function()
  it("extracts require calls", function()
    local deps = parser.parsers.lua('local x = require("foo.bar")\nlocal y = require("baz")')
    assert.same({ "foo.bar", "baz" }, deps)
  end)

  it("ignores non-require lines", function()
    local deps = parser.parsers.lua("local x = 1 + 2")
    assert.same({}, deps)
  end)
end)

describe("parser.parsers.py", function()
  it("extracts import statements", function()
    local deps = parser.parsers.py("import os\nfrom pathlib import Path\n")
    assert.truthy(vim.tbl_contains(deps, "os"))
    assert.truthy(vim.tbl_contains(deps, "pathlib"))
  end)
end)

describe("parser.parsers.js", function()
  it("extracts ESM imports", function()
    local deps = parser.parsers.js('import React from "react"\nimport { foo } from "./util"')
    assert.truthy(vim.tbl_contains(deps, "react"))
    assert.truthy(vim.tbl_contains(deps, "./util"))
  end)

  it("extracts require calls", function()
    local deps = parser.parsers.js('const x = require("express")')
    assert.truthy(vim.tbl_contains(deps, "express"))
  end)
end)

describe("parser.parsers.go", function()
  it("extracts single and grouped imports", function()
    local deps = parser.parsers.go('import "fmt"\nimport (\n  "my/app/pkg"\n)')
    assert.truthy(vim.tbl_contains(deps, "fmt"))
    assert.truthy(vim.tbl_contains(deps, "my/app/pkg"))
  end)
end)

describe("parser.parsers.rs", function()
  it("extracts mod/use variants", function()
    local deps = parser.parsers.rs([[
pub mod models;
pub(crate) mod db;
use crate::db::connect;
pub use crate::models::{User, Role};
use super::cache::Store as CacheStore;
]])
    assert.truthy(vim.tbl_contains(deps, "models"))
    assert.truthy(vim.tbl_contains(deps, "db"))
    assert.truthy(vim.tbl_contains(deps, "crate::db::connect"))
    assert.truthy(vim.tbl_contains(deps, "crate::models"))
    assert.truthy(vim.tbl_contains(deps, "super::cache::Store"))
  end)
end)

describe("parser.parsers.java/kt/scala/cs/swift", function()
  it("extracts dotted imports/usings", function()
    local deps = parser.parsers.java("import a.b.C;\nimport static d.e.F;\n")
    assert.truthy(vim.tbl_contains(deps, "a.b.C"))
    assert.truthy(vim.tbl_contains(deps, "d.e.F"))

    deps = parser.parsers.kt("import foo.bar.Baz as B\n")
    assert.truthy(vim.tbl_contains(deps, "foo.bar.Baz"))

    deps = parser.parsers.cs("using System.Text;\nglobal using My.App.Core;\n")
    assert.truthy(vim.tbl_contains(deps, "System.Text"))
    assert.truthy(vim.tbl_contains(deps, "My.App.Core"))
  end)
end)

describe("parser.parsers.rb", function()
  it("extracts require and require_relative", function()
    local deps = parser.parsers.rb('require "json"\nrequire_relative "../lib/foo"')
    assert.truthy(vim.tbl_contains(deps, "json"))
    assert.truthy(vim.tbl_contains(deps, "../lib/foo"))
  end)
end)

describe("parser.parsers.php", function()
  it("extracts use and include/require", function()
    local deps = parser.parsers.php([[use App\Foo\Bar;
      require_once "bootstrap.php";
      include "partials/header.php";]])
    assert.truthy(vim.tbl_contains(deps, "App\\Foo\\Bar"))
    assert.truthy(vim.tbl_contains(deps, "bootstrap.php"))
    assert.truthy(vim.tbl_contains(deps, "partials/header.php"))
  end)
end)

describe("parser.parsers.zig", function()
  it("extracts @import calls", function()
    local deps = parser.parsers.zig('const std = @import("std");\nconst a = @import("./a.zig");')
    assert.truthy(vim.tbl_contains(deps, "std"))
    assert.truthy(vim.tbl_contains(deps, "./a.zig"))
  end)
end)

describe("parser.parsers.c/cpp", function()
  it("extracts includes", function()
    local deps = parser.parsers.c('#include "app.h"\n#include <vector>')
    assert.truthy(vim.tbl_contains(deps, "app.h"))
    assert.truthy(vim.tbl_contains(deps, "vector"))
  end)
end)

describe("parser.parsers.ex", function()
  it("extracts alias/import/require/use", function()
    local deps = parser.parsers.ex("alias MyApp.Repo\nimport Ecto.Query\nrequire Logger\nuse Phoenix.Controller\n")
    assert.truthy(vim.tbl_contains(deps, "MyApp.Repo"))
    assert.truthy(vim.tbl_contains(deps, "Ecto.Query"))
    assert.truthy(vim.tbl_contains(deps, "Logger"))
    assert.truthy(vim.tbl_contains(deps, "Phoenix.Controller"))
  end)
end)

describe("parser.register", function()
  it("allows registering a custom parser", function()
    parser.register("xyz", function(content)
      return { "custom_dep" }
    end)
    assert.not_nil(parser.parsers.xyz)
    assert.same({ "custom_dep" }, parser.parsers.xyz("anything"))
  end)
end)

describe("treesitter.extract fallback", function()
  local function with_missing_ts_parser(fn)
    local original = vim.treesitter.get_string_parser
    vim.treesitter.get_string_parser = function()
      error("missing parser")
    end
    local ok, err = pcall(fn)
    vim.treesitter.get_string_parser = original
    assert.truthy(ok, err)
  end

  local function write_temp(ext, content)
    local path = vim.fn.tempname() .. "." .. ext
    local f = assert(io.open(path, "w"))
    f:write(content)
    f:close()
    return path
  end

  it("extracts Java defs/calls via regex fallback", function()
    with_missing_ts_parser(function()
      local path = write_temp(
        "java",
        [[class A {
  void alpha() { beta(); }
  void beta() {}
}]]
      )
      local info = treesitter.extract(path)
      os.remove(path)
      assert.truthy(info)
      assert.truthy(vim.tbl_contains(info.defs, "alpha"))
      assert.truthy(vim.tbl_contains(info.defs, "beta"))
      assert.truthy(info.calls_by_func.alpha)
    end)
  end)

  it("extracts Elixir defs via regex fallback", function()
    with_missing_ts_parser(function()
      local path = write_temp(
        "ex",
        [[defmodule A do
  def alpha do
    beta()
  end

  defp beta do
  end
end]]
      )
      local info = treesitter.extract(path)
      os.remove(path)
      assert.truthy(info)
      assert.truthy(vim.tbl_contains(info.defs, "alpha"))
      assert.truthy(vim.tbl_contains(info.defs, "beta"))
    end)
  end)
end)

-- ── graph ─────────────────────────────────────────────────────────────────────

describe("graph.get / graph.clear", function()
  it("returns an empty graph before any build", function()
    graph.clear()
    local g = graph.get()
    assert.same({}, g.nodes)
    assert.same({}, g.edges)
  end)
end)

describe("graph.focus", function()
  it("returns empty graph for unknown file", function()
    graph.clear()
    local focused = graph.focus("nonexistent.lua")
    assert.same({}, focused.nodes)
    assert.same({}, focused.edges)
  end)
end)

describe("graph.build (rust)", function()
  local function write_file(path, content)
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    local f = assert(io.open(path, "w"))
    f:write(content)
    f:close()
  end

  it("resolves Rust use/mod deps to .rs and mod.rs files", function()
    graph.clear()
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")

    write_file(
      root .. "/src/main.rs",
      [[
pub mod models;
mod db;
use crate::db::connect;
pub use crate::models::{Role, User};
]]
    )
    write_file(root .. "/src/db.rs", "pub fn connect() {}\n")
    write_file(root .. "/src/models/mod.rs", "pub struct User;\npub struct Role;\n")

    local g = graph.build(root, { max_files = 100, ignore_patterns = {} })
    local main = g.nodes["src/main.rs"]

    assert.truthy(main, "expected src/main.rs node")
    assert.truthy(vim.tbl_contains(main.deps, "src/db.rs"))
    assert.truthy(vim.tbl_contains(main.deps, "src/models/mod.rs"))

    vim.fn.delete(root, "rf")
  end)
end)

describe("graph.build (cross-language)", function()
  local function write_file(path, content)
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    local f = assert(io.open(path, "w"))
    f:write(content)
    f:close()
  end

  it("resolves Java dotted imports to project files", function()
    graph.clear()
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")

    write_file(root .. "/src/main/java/app/Main.java", "import app.services.UserService;\nclass Main {}\n")
    write_file(root .. "/src/main/java/app/services/UserService.java", "package app.services;\nclass UserService {}\n")

    local g = graph.build(root, { max_files = 100, ignore_patterns = {} })
    local main = g.nodes["src/main/java/app/Main.java"]

    assert.truthy(main, "expected src/main/java/app/Main.java node")
    assert.truthy(vim.tbl_contains(main.deps, "src/main/java/app/services/UserService.java"))

    vim.fn.delete(root, "rf")
  end)

  it("resolves C/C++ include paths with file extensions", function()
    graph.clear()
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")

    write_file(root .. "/src/main.cpp", '#include "app.h"\nint main() { return 0; }\n')
    write_file(root .. "/src/app.h", "int answer();\n")

    local g = graph.build(root, { max_files = 100, ignore_patterns = {} })
    local main = g.nodes["src/main.cpp"]

    assert.truthy(main, "expected src/main.cpp node")
    assert.truthy(vim.tbl_contains(main.deps, "src/app.h"))

    vim.fn.delete(root, "rf")
  end)

  it("renders TypeScript cyclic imports without overflow", function()
    graph.clear()
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")

    write_file(root .. "/src/a.ts", 'import { b } from "./b"\nexport const a = b\n')
    write_file(root .. "/src/b.ts", 'import { a } from "./a"\nexport const b = a\n')

    local g = graph.build(root, { max_files = 100, ignore_patterns = {} })
    local ok, lines = pcall(renderer.render, g)

    assert.truthy(ok, lines)
    assert.truthy(#g.edges >= 2, "expected cyclic TS edges")
    assert.truthy(#lines > 0)

    vim.fn.delete(root, "rf")
  end)
end)

-- ── renderer ─────────────────────────────────────────────────────────────────

describe("renderer.render", function()
  it("returns a message for an empty graph", function()
    local lines, positions = renderer.render({ nodes = {}, edges = {} })
    assert.truthy(#lines > 0)
    assert.truthy(lines[2]:find("[t] toggle layout", 1, true))
    assert.same({}, positions)
  end)

  it("includes the node label in the output", function()
    local g = {
      nodes = {
        ["a.lua"] = { path = "/a.lua", label = "a.lua", deps = {} },
        ["b.lua"] = { path = "/b.lua", label = "b.lua", deps = {} },
      },
      edges = { { from = "a.lua", to = "b.lua" } },
    }
    local lines, positions = renderer.render(g)
    local combined = table.concat(lines, "\n")
    assert.truthy(combined:find("a.lua"))
    assert.truthy(combined:find("b.lua"))
    assert.not_nil(positions["a.lua"])
    assert.not_nil(positions["b.lua"])
  end)

  it("handles function nodes that use .calls instead of .deps", function()
    local g = {
      nodes = {
        ["a.lua::foo"] = { path = "/a.lua", label = "a.lua::foo", calls = { "a.lua::bar" } },
        ["a.lua::bar"] = { path = "/a.lua", label = "a.lua::bar", calls = {} },
      },
      edges = { { from = "a.lua::foo", to = "a.lua::bar" } },
    }
    -- Should not error (was the bug: node.deps was nil for function nodes)
    local ok, result = pcall(renderer.render, g)
    assert.truthy(ok, result)
  end)

  it("supports graph layout output", function()
    local g = {
      nodes = {
        ["a.lua"] = { path = "/a.lua", label = "a.lua", deps = { "b.lua" } },
        ["b.lua"] = { path = "/b.lua", label = "b.lua", deps = {} },
      },
      edges = { { from = "a.lua", to = "b.lua" } },
    }
    local lines, positions = renderer.render(g, { layout = "graph" })
    local combined = table.concat(lines, "\n")
    assert.truthy(combined:find("Layout: graph", 1, true))
    assert.truthy(combined:find("Routing view:", 1, true))
    assert.truthy(combined:find("[01]", 1, true))
    assert.not_nil(positions["a.lua"])
    assert.not_nil(positions["b.lua"])
  end)

  it("renders cyclic dependency graphs without overflowing", function()
    local g = {
      nodes = {
        ["a.rs"] = { path = "/a.rs", label = "a.rs", deps = { "b.rs" } },
        ["b.rs"] = { path = "/b.rs", label = "b.rs", deps = { "a.rs" } },
      },
      edges = {
        { from = "a.rs", to = "b.rs" },
        { from = "b.rs", to = "a.rs" },
      },
    }

    local ok, lines = pcall(renderer.render, g)
    assert.truthy(ok, lines)
    assert.truthy(#lines > 0)
  end)

  it("does not render transitive edges as direct edges in graph routing", function()
    local g = {
      nodes = {
        ["01_init.lua"] = {
          path = "/01_init.lua",
          label = "01_init.lua",
          deps = { "06_graph.lua", "07_ui.lua", "10_ts.lua" },
        },
        ["06_graph.lua"] = { path = "/06_graph.lua", label = "06_graph.lua", deps = { "08_parser.lua" } },
        ["07_ui.lua"] = { path = "/07_ui.lua", label = "07_ui.lua", deps = {} },
        ["08_parser.lua"] = { path = "/08_parser.lua", label = "08_parser.lua", deps = {} },
        ["10_ts.lua"] = { path = "/10_ts.lua", label = "10_ts.lua", deps = {} },
      },
      edges = {
        { from = "01_init.lua", to = "06_graph.lua" },
        { from = "01_init.lua", to = "07_ui.lua" },
        { from = "01_init.lua", to = "10_ts.lua" },
        { from = "06_graph.lua", to = "08_parser.lua" },
      },
    }

    local lines = renderer.render(g, { layout = "graph" })
    local out = table.concat(lines, "\n")

    local function idx_for(key)
      for _, line in ipairs(lines) do
        if line:find(key, 1, true) then
          local n = line:match("%[(%d%d)%]")
          if n then
            return tonumber(n)
          end
        end
      end
      return nil
    end

    local idx = {
      idx_for("01_init.lua"),
      idx_for("06_graph.lua"),
      idx_for("08_parser.lua"),
    }
    assert.not_nil(idx[1], "missing index for 01_init.lua")
    assert.not_nil(idx[2], "missing index for 06_graph.lua")
    assert.not_nil(idx[3], "missing index for 08_parser.lua")

    local e_01_06 = string.format("[%02d] ──▶ [%02d]", idx[1], idx[2])
    local e_06_08 = string.format("[%02d] ──▶ [%02d]", idx[2], idx[3])
    local e_01_08 = string.format("[%02d] ──▶ [%02d]", idx[1], idx[3])

    assert.truthy(out:find(e_01_06, 1, true))
    assert.truthy(out:find(e_06_08, 1, true))
    assert.falsy(out:find(e_01_08, 1, true))
  end)
end)
