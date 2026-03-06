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

  it("does not render transitive edges as direct edges in graph routing", function()
    local g = {
      nodes = {
        ["01_init.lua"] = { path = "/01_init.lua", label = "01_init.lua", deps = { "06_graph.lua", "07_ui.lua", "10_ts.lua" } },
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
