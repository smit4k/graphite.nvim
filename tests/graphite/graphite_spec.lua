local util = require("graphite.util")
local parser = require("graphite.parser")
local graph = require("graphite.graph")
local renderer = require("graphite.renderer")

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

describe("parser.register", function()
  it("allows registering a custom parser", function()
    parser.register("xyz", function(content)
      return { "custom_dep" }
    end)
    assert.not_nil(parser.parsers.xyz)
    assert.same({ "custom_dep" }, parser.parsers.xyz("anything"))
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

-- ── renderer ─────────────────────────────────────────────────────────────────

describe("renderer.render", function()
  it("returns a message for an empty graph", function()
    local lines, positions = renderer.render({ nodes = {}, edges = {} })
    assert.truthy(#lines > 0)
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
end)
