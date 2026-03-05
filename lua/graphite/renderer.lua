-- renderer.lua: Convert a GraphData into displayable lines and a node-position map.
-- The tree-style ASCII layout is intentionally simple so it can be swapped out
-- later (e.g. for a force-directed layout) without touching any other module.

local M = {}

---@class NodePosition
---@field row number   1-indexed line number in the rendered output
---@field key string   node key (relative file path)

--- Assign each node a BFS layer (depth) starting from root nodes.
--- Nodes with no incoming edges are in layer 1.
---@param graph GraphData
---@return table<string,number>  node_key -> layer (1-based)
local function compute_layers(graph)
  local in_degree = {}
  for key in pairs(graph.nodes) do
    in_degree[key] = 0
  end
  for _, edge in ipairs(graph.edges) do
    if graph.nodes[edge.to] then
      in_degree[edge.to] = (in_degree[edge.to] or 0) + 1
    end
  end

  -- Build adjacency list
  local adj = {}
  for key in pairs(graph.nodes) do
    adj[key] = {}
  end
  for _, edge in ipairs(graph.edges) do
    if graph.nodes[edge.from] and graph.nodes[edge.to] then
      table.insert(adj[edge.from], edge.to)
    end
  end

  local layer = {}
  local queue = {}
  for key in pairs(graph.nodes) do
    if in_degree[key] == 0 then
      layer[key] = 1
      table.insert(queue, key)
    end
  end
  -- Handle fully cyclic graphs: seed with an arbitrary node
  if #queue == 0 then
    local first = next(graph.nodes)
    if first then
      layer[first] = 1
      table.insert(queue, first)
    end
  end

  local head = 1
  while head <= #queue do
    local node = queue[head]
    head = head + 1
    for _, child in ipairs(adj[node]) do
      local new_layer = (layer[node] or 1) + 1
      if not layer[child] or layer[child] < new_layer then
        layer[child] = new_layer
        table.insert(queue, child)
      end
    end
  end

  -- Assign stragglers (nodes only reachable via cycles)
  for key in pairs(graph.nodes) do
    if not layer[key] then
      layer[key] = 1
    end
  end

  return layer
end

--- Build a map: node_key -> list of node_keys that import it (reverse edges).
---@param graph GraphData
---@return table<string, string[]>
local function build_incoming(graph)
  local inc = {}
  for key in pairs(graph.nodes) do
    inc[key] = {}
  end
  for _, edge in ipairs(graph.edges) do
    if graph.nodes[edge.from] and graph.nodes[edge.to] then
      table.insert(inc[edge.to], edge.from)
    end
  end
  return inc
end

--- Render the graph as a list of text lines plus a map of navigable node positions.
---@param graph GraphData
---@return string[], table<string, NodePosition>
M.render = function(graph)
  local node_count = 0
  for _ in pairs(graph.nodes) do
    node_count = node_count + 1
  end

  -- ── Header ────────────────────────────────────────────────────────────────
  local lines = {}
  table.insert(lines, string.format("  graphite.nvim  ·  Nodes: %d  Edges: %d", node_count, #graph.edges))
  table.insert(lines, "  [Enter] open file   [q] close   [j/k] prev/next node   [h/l] parent/child")
  table.insert(lines, string.rep("─", 72))

  if node_count == 0 then
    table.insert(lines, "")
    table.insert(lines, "  No source files found in this directory.")
    table.insert(lines, "  Tip: run :GraphiteOpen from your project root.")
    return lines, {}
  end

  table.insert(lines, "")

  -- ── Sort nodes: by layer, then alphabetically ─────────────────────────────
  local layer_of = compute_layers(graph)
  local sorted = {}
  for key in pairs(graph.nodes) do
    table.insert(sorted, key)
  end
  table.sort(sorted, function(a, b)
    local la = layer_of[a] or 1
    local lb = layer_of[b] or 1
    if la ~= lb then
      return la < lb
    end
    return a < b
  end)

  -- ── Render each node with its dependency tree ─────────────────────────────
  local node_positions = {}

  for _, key in ipairs(sorted) do
    local node = graph.nodes[key]
    if not node then
      goto continue
    end

    -- Node header line  ◆ filename.ext            (from: X)  (to: Y)
    -- Support both file-level nodes (.deps) and function nodes (.calls)
    local children = node.deps or node.calls or {}
    local n_deps = #children
    local n_inc = 0
    for _, edge in ipairs(graph.edges) do
      if edge.to == key then
        n_inc = n_inc + 1
      end
    end

    local badge = ""
    if n_deps > 0 and n_inc > 0 then
      badge = string.format("  ← %d  → %d", n_inc, n_deps)
    elseif n_deps > 0 then
      badge = string.format("  → %d dep%s", n_deps, n_deps == 1 and "" or "s")
    elseif n_inc > 0 then
      badge = string.format("  ← %d importer%s", n_inc, n_inc == 1 and "" or "s")
    end

    local header = string.format("  ◆ %s%s", node.label, badge)
    local line_num = #lines + 1
    node_positions[key] = { row = line_num, key = key }
    table.insert(lines, header)

    -- Dependency lines
    if n_deps > 0 then
      for i, dep_key in ipairs(children) do
        local dep_node = graph.nodes[dep_key]
        local dep_label = dep_node and dep_node.label or dep_key
        local connector = (i < n_deps) and "  ├─⟶  " or "  └─⟶  "
        table.insert(lines, connector .. dep_label)
      end
    end

    table.insert(lines, "") -- blank line between nodes

    ::continue::
  end

  return lines, node_positions
end

return M
