-- renderer.lua: Convert GraphData into displayable lines and node-position maps.
-- Supports multiple layouts: "tree" (default) and "graph" (row-routed).

local M = {}
local ICON_NODE = "󰈔"
local ICON_LINK = "󰌹"
local ICON_MAP = "󰖩"
local ICON_LIST = "󰄱"

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
  local max_layer = 1
  for key in pairs(graph.nodes) do
    layer[key] = 1
    if in_degree[key] == 0 then
      table.insert(queue, key)
    end
  end

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
      if (layer[child] or 1) < new_layer then
        layer[child] = new_layer
        if new_layer > max_layer then
          max_layer = new_layer
        end
      end

      in_degree[child] = (in_degree[child] or 0) - 1
      if in_degree[child] == 0 then
        table.insert(queue, child)
      end
    end
  end

  -- Cycle-safe fallback: nodes left with in-degree > 0 are in one or more
  -- cycles. Assign them a stable layer so sorting/rendering can proceed.
  for key in pairs(graph.nodes) do
    if (in_degree[key] or 0) > 0 then
      layer[key] = math.max(layer[key] or 1, max_layer + 1)
    end
  end

  return layer
end

---@param graph GraphData
---@return string[]
local function sorted_keys(graph)
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
  return sorted
end

---@param graph GraphData
---@return table<string,number>
local function incoming_counts(graph)
  local counts = {}
  for key in pairs(graph.nodes) do
    counts[key] = 0
  end
  for _, edge in ipairs(graph.edges) do
    if counts[edge.to] ~= nil then
      counts[edge.to] = counts[edge.to] + 1
    end
  end
  return counts
end

---@param graph GraphData
---@param node_count number
---@return string[], table<string, NodePosition>
local function render_tree(graph, node_count)
  local lines = {}
  local node_positions = {}

  table.insert(
    lines,
    string.format("  graphite.nvim  ·  Layout: tree  ·  Nodes: %d  Edges: %d", node_count, #graph.edges)
  )
  table.insert(lines, "  [Enter] open file   [q] close   [j/k] prev/next node   [h/l] parent/child   [t] toggle layout")
  table.insert(lines, string.format("  %s node   %s dependency edge", ICON_NODE, ICON_LINK))
  table.insert(lines, string.rep("─", 78))

  if node_count == 0 then
    table.insert(lines, "")
    table.insert(lines, "  No source files found in this directory.")
    table.insert(lines, "  Tip: run :GraphiteOpen from your project root.")
    return lines, node_positions
  end

  table.insert(lines, "")

  local sorted = sorted_keys(graph)
  local inc_count = incoming_counts(graph)

  for _, key in ipairs(sorted) do
    local node = graph.nodes[key]
    if not node then
      goto continue
    end

    local children = node.deps or node.calls or {}
    local n_deps = #children
    local n_inc = inc_count[key] or 0

    local badge = ""
    if n_deps > 0 and n_inc > 0 then
      badge = string.format("  ← %d  → %d", n_inc, n_deps)
    elseif n_deps > 0 then
      badge = string.format("  → %d dep%s", n_deps, n_deps == 1 and "" or "s")
    elseif n_inc > 0 then
      badge = string.format("  ← %d importer%s", n_inc, n_inc == 1 and "" or "s")
    end

    local header = string.format("  %s ◆ %s%s", ICON_NODE, node.label, badge)
    local line_num = #lines + 1
    node_positions[key] = { row = line_num, key = key }
    table.insert(lines, header)

    if n_deps > 0 then
      for i, dep_key in ipairs(children) do
        local dep_node = graph.nodes[dep_key]
        local dep_label = dep_node and dep_node.label or dep_key
        local connector = (i < n_deps) and "  │  ├──▶ " or "  │  └──▶ "
        table.insert(lines, connector .. dep_label)
      end
    end

    table.insert(lines, "")
    ::continue::
  end

  return lines, node_positions
end

---@param canvas string[][]
---@param x number
---@param y number
---@param ch string
local function put(canvas, x, y, ch)
  if y >= 1 and y <= #canvas and x >= 1 and x <= #canvas[y] then
    canvas[y][x] = ch
  end
end

---@param canvas string[][]
---@param x number
---@param y number
---@param ch string
local function put_edge(canvas, x, y, ch)
  if y < 1 or y > #canvas or x < 1 or x > #canvas[y] then
    return
  end
  local current = canvas[y][x]
  if current == " " then
    canvas[y][x] = ch
    return
  end
  if current == ch then
    return
  end
  if current == "┼" then
    return
  end
  if (current == "─" and ch == "│") or (current == "│" and ch == "─") then
    canvas[y][x] = "┼"
  end
end

---@param canvas string[][]
---@param x1 number
---@param x2 number
---@param y number
local function draw_h(canvas, x1, x2, y)
  local from_x = math.min(x1, x2)
  local to_x = math.max(x1, x2)
  for x = from_x, to_x do
    put_edge(canvas, x, y, "─")
  end
end

---@param canvas string[][]
---@param x number
---@param y1 number
---@param y2 number
local function draw_v(canvas, x, y1, y2)
  local from_y = math.min(y1, y2)
  local to_y = math.max(y1, y2)
  for y = from_y, to_y do
    put_edge(canvas, x, y, "│")
  end
end

---@param canvas string[][]
---@param from_x number
---@param from_y number
---@param to_x number
---@param to_y number
local function draw_edge(canvas, from_x, from_y, to_x, to_y)
  if from_x == to_x and from_y == to_y then
    return
  end

  local mid_x = math.floor((from_x + to_x) / 2)
  draw_h(canvas, from_x, mid_x, from_y)
  draw_v(canvas, mid_x, from_y, to_y)
  draw_h(canvas, mid_x, to_x, to_y)

  if to_x > from_x then
    put(canvas, to_x, to_y, "▶")
  elseif to_x < from_x then
    put(canvas, to_x, to_y, "◀")
  elseif to_y > from_y then
    put(canvas, to_x, to_y, "▼")
  else
    put(canvas, to_x, to_y, "▲")
  end
end

---@param canvas string[][]
---@param routes table[]
---@param dir "right"|"left"
local function draw_fanout(canvas, routes, dir)
  if #routes == 0 then
    return
  end
  if #routes == 1 then
    local r = routes[1]
    draw_edge(canvas, r.from_x, r.from_y, r.to_x, r.to_y)
    return
  end

  table.sort(routes, function(a, b)
    if a.to_y ~= b.to_y then
      return a.to_y < b.to_y
    end
    return a.to_x < b.to_x
  end)

  local from_x = routes[1].from_x
  local from_y = routes[1].from_y
  local min_to_x = routes[1].to_x
  local max_to_x = routes[1].to_x
  local min_y = from_y
  local max_y = from_y

  for _, r in ipairs(routes) do
    min_to_x = math.min(min_to_x, r.to_x)
    max_to_x = math.max(max_to_x, r.to_x)
    min_y = math.min(min_y, r.to_y)
    max_y = math.max(max_y, r.to_y)
  end

  local split_x
  if dir == "right" then
    split_x = math.floor((from_x + min_to_x) / 2)
  else
    split_x = math.floor((from_x + max_to_x) / 2)
  end

  draw_h(canvas, from_x, split_x, from_y)
  draw_v(canvas, split_x, min_y, max_y)
  put(canvas, split_x, from_y, "┼")

  for i, r in ipairs(routes) do
    draw_h(canvas, split_x, r.to_x, r.to_y)

    if r.to_y ~= from_y then
      if dir == "right" then
        local branch = (i == #routes) and "└" or "├"
        put(canvas, split_x, r.to_y, branch)
      else
        local branch = (i == #routes) and "┘" or "┤"
        put(canvas, split_x, r.to_y, branch)
      end
    end

    if dir == "right" then
      put(canvas, r.to_x, r.to_y, "▶")
    else
      put(canvas, r.to_x, r.to_y, "◀")
    end
  end
end

---@param graph GraphData
---@param node_count number
---@return string[], table<string, NodePosition>
local function render_graph(graph, node_count)
  local lines = {}
  local node_positions = {}

  table.insert(
    lines,
    string.format("  graphite.nvim  ·  Layout: graph  ·  Nodes: %d  Edges: %d", node_count, #graph.edges)
  )
  table.insert(lines, "  [Enter] open file   [q] close   [j/k] prev/next node   [h/l] parent/child   [t] toggle layout")
  table.insert(lines, string.format("  %s map token [NN]   %s directed edge", ICON_MAP, ICON_LINK))
  table.insert(lines, string.rep("─", 78))

  if node_count == 0 then
    table.insert(lines, "")
    table.insert(lines, "  No source files found in this directory.")
    table.insert(lines, "  Tip: run :GraphiteOpen from your project root.")
    return lines, node_positions
  end

  table.insert(lines, "")
  table.insert(lines, "  Local graph map (row-routed, labeled):")

  local sorted = sorted_keys(graph)
  local idx_of = {}
  local inc_count = incoming_counts(graph)
  for i, key in ipairs(sorted) do
    idx_of[key] = i
  end

  -- Build adjacency list once so routing and legend always match the real graph.
  local outgoing = {}
  for _, edge in ipairs(graph.edges) do
    if idx_of[edge.from] and idx_of[edge.to] then
      outgoing[edge.from] = outgoing[edge.from] or {}
      table.insert(outgoing[edge.from], edge.to)
    end
  end

  for from, deps in pairs(outgoing) do
    table.sort(deps, function(a, b)
      local ia = idx_of[a] or 0
      local ib = idx_of[b] or 0
      if ia ~= ib then
        return ia < ib
      end
      return a < b
    end)
    local seen = {}
    local dedup = {}
    for _, to in ipairs(deps) do
      if not seen[to] then
        seen[to] = true
        table.insert(dedup, to)
      end
    end
    outgoing[from] = dedup
  end

  local sources = {}
  for _, key in ipairs(sorted) do
    if outgoing[key] and #outgoing[key] > 0 then
      table.insert(sources, key)
    end
  end

  local col_of_source = {}
  for i, key in ipairs(sources) do
    -- One private routing column per source; never reused by other sources.
    col_of_source[key] = (i - 1) * 3 + 1
  end

  local route_width = math.max(1, #sources * 3 + 2)
  local canvas = {}
  for row = 1, #sorted do
    canvas[row] = {}
    for col = 1, route_width do
      canvas[row][col] = " "
    end
  end

  local function mark(row, col, ch)
    if row < 1 or row > #canvas or col < 1 or col > route_width then
      return
    end
    local cur = canvas[row][col]
    if cur == " " then
      canvas[row][col] = ch
      return
    end
    if cur == ch then
      return
    end
    if cur == "│" and (ch == "├" or ch == "└" or ch == "┼") then
      canvas[row][col] = ch
      return
    end
    if (cur == "├" or cur == "└") and ch == "┼" then
      canvas[row][col] = "┼"
      return
    end
    if (cur == "─" and ch == "│") or (cur == "│" and ch == "─") then
      canvas[row][col] = "┼"
      return
    end
  end

  for _, from in ipairs(sources) do
    local sr = idx_of[from]
    local targets = outgoing[from]
    local col = col_of_source[from]
    local target_rows = {}
    for _, to in ipairs(targets) do
      if idx_of[to] ~= sr then
        table.insert(target_rows, idx_of[to])
      end
    end

    if #target_rows == 0 then
      goto continue_source
    end

    table.sort(target_rows)
    local top = math.min(sr, target_rows[1])
    local bottom = math.max(sr, target_rows[#target_rows])
    for row = top, bottom do
      mark(row, col, "│")
    end
    mark(sr, col, "┼")

    for i, tr in ipairs(target_rows) do
      local branch = (i < #target_rows) and "├" or "└"
      mark(tr, col, branch)
      for c = col + 1, route_width - 2 do
        mark(tr, c, "─")
      end
      mark(tr, route_width - 1, "▶")
    end

    ::continue_source::
  end

  table.insert(lines, "  Routing view:")
  for i, key in ipairs(sorted) do
    local route = table.concat(canvas[i])
    local line = string.format("  %s [%02d] %s %s", route, i, ICON_NODE, key)
    local line_num = #lines + 1
    node_positions[key] = { row = line_num, key = key }
    table.insert(lines, line)
  end

  table.insert(lines, "")
  table.insert(lines, string.format("  %s Edge list:", ICON_LIST))
  local edge_listed = 0
  for _, edge in ipairs(graph.edges) do
    local from_idx = idx_of[edge.from]
    local to_idx = idx_of[edge.to]
    if from_idx and to_idx then
      table.insert(lines, string.format("  [%02d] ──▶ [%02d]", from_idx, to_idx))
      edge_listed = edge_listed + 1
      if edge_listed >= 80 then
        table.insert(lines, string.format("  ... and %d more edges", #graph.edges - edge_listed))
        break
      end
    end
  end

  table.insert(lines, "")
  table.insert(lines, string.format("  %s Degree summary:", ICON_LIST))
  for _, key in ipairs(sorted) do
    local node = graph.nodes[key]
    local children = node and (node.deps or node.calls or {}) or {}
    local n_deps = #children
    local n_inc = inc_count[key] or 0
    table.insert(lines, string.format("  [%02d]  in:%d  out:%d", idx_of[key], n_inc, n_deps))
  end

  return lines, node_positions
end

--- Render the graph as a list of text lines plus a map of navigable node positions.
---@param graph GraphData
---@param opts table|nil
---@return string[], table<string, NodePosition>
M.render = function(graph, opts)
  local node_count = 0
  for _ in pairs(graph.nodes) do
    node_count = node_count + 1
  end

  local layout = (opts and opts.layout) or "tree"
  if layout == "graph" then
    return render_graph(graph, node_count)
  end
  return render_tree(graph, node_count)
end

return M
