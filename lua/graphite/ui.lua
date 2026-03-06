-- ui.lua: Floating window management, keybindings, and node navigation.

local renderer = require("graphite.renderer")

local M = {}

-- ── Module state ──────────────────────────────────────────────────────────────
local _win = nil -- window handle
local _buf = nil -- buffer handle
local _graph = nil -- currently displayed GraphData
local _config = nil -- active GraphiteConfig
local _node_positions = {} -- key -> NodePosition
local _navigable = {} -- ordered list of NodePosition (sorted by row)
local _cursor_idx = 1 -- index into _navigable pointing at the selected node

-- ── Highlight groups ──────────────────────────────────────────────────────────
local NS = vim.api.nvim_create_namespace("graphite")

local function setup_highlights()
  vim.api.nvim_set_hl(0, "GraphiteHeader", { link = "Title", default = true })
  vim.api.nvim_set_hl(0, "GraphiteNode", { link = "Function", default = true })
  vim.api.nvim_set_hl(0, "GraphiteNodeSel", { link = "CursorLine", default = true })
  vim.api.nvim_set_hl(0, "GraphiteArrow", { link = "Comment", default = true })
  vim.api.nvim_set_hl(0, "GraphiteBadge", { link = "Special", default = true })
end

--- Apply syntax highlights to buffer lines.
local function apply_highlights(lines)
  if not _buf or not vim.api.nvim_buf_is_valid(_buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(_buf, NS, 0, -1)

  for i, line in ipairs(lines) do
    local lnum = i - 1
    if line:match("^  graphite%.nvim") then
      vim.api.nvim_buf_add_highlight(_buf, NS, "GraphiteHeader", lnum, 0, -1)
    elseif line:match("^  󰈔") or line:match("^  [◆●]") or line:match("^  %[%d%d%]") then
      -- Highlight the ◆ symbol and filename
      vim.api.nvim_buf_add_highlight(_buf, NS, "GraphiteNode", lnum, 0, -1)
    elseif line:match("^  %[") then
      vim.api.nvim_buf_add_highlight(_buf, NS, "GraphiteArrow", lnum, 0, -1)
    elseif line:match("^  [├└│]") or line:match("^  %[") or line:match("^  [┌┐└┘]") then
      vim.api.nvim_buf_add_highlight(_buf, NS, "GraphiteArrow", lnum, 0, -1)
    end
  end
end

--- Highlight the currently selected node line.
local function highlight_selection()
  if not _buf or not vim.api.nvim_buf_is_valid(_buf) then
    return
  end
  if #_navigable == 0 then
    return
  end

  -- Clear previous selection extmark
  vim.api.nvim_buf_clear_namespace(_buf, NS, 0, -1)

  -- Re-apply base highlights (cheap since buffer is small)
  local lines = vim.api.nvim_buf_get_lines(_buf, 0, -1, false)
  apply_highlights(lines)

  -- Overlay the selected node
  local sel = _navigable[_cursor_idx]
  if sel then
    vim.api.nvim_buf_add_highlight(_buf, NS, "GraphiteNodeSel", sel.row - 1, 0, -1)
  end
end

--- Move the Neovim cursor to the currently selected node row.
local function sync_cursor()
  if not _win or not vim.api.nvim_win_is_valid(_win) then
    return
  end
  if #_navigable == 0 then
    return
  end
  local sel = _navigable[_cursor_idx]
  if sel then
    local total = vim.api.nvim_buf_line_count(_buf)
    local row = math.max(1, math.min(sel.row, total))
    vim.api.nvim_win_set_cursor(_win, { row, 2 })
  end
end

--- Get the node key for the currently selected node (or nil).
---@return string|nil
local function current_key()
  if #_navigable == 0 then
    return nil
  end
  return _navigable[_cursor_idx] and _navigable[_cursor_idx].key
end

-- ── Navigation helpers ────────────────────────────────────────────────────────

--- Move selection by delta (positive = down, negative = up).
---@param delta number
local function move_cursor(delta)
  if #_navigable == 0 then
    return
  end
  _cursor_idx = ((_cursor_idx - 1 + delta) % #_navigable) + 1
  sync_cursor()
  highlight_selection()
end

--- Jump to the first dependency of the current node (move to child).
local function move_to_child()
  local key = current_key()
  if not key or not _graph then
    return
  end
  local node = _graph.nodes[key]
  local children = node and (node.deps or node.calls or {}) or {}
  if #children == 0 then
    return
  end
  local child_key = children[1]
  local pos = _node_positions[child_key]
  if pos then
    for i, nav in ipairs(_navigable) do
      if nav.key == child_key then
        _cursor_idx = i
        break
      end
    end
    sync_cursor()
    highlight_selection()
  end
end

--- Jump to the first node that imports the current node (move to parent).
local function move_to_parent()
  local key = current_key()
  if not key or not _graph then
    return
  end
  local parent_key = nil
  for _, edge in ipairs(_graph.edges) do
    if edge.to == key then
      parent_key = edge.from
      break
    end
  end
  if not parent_key then
    return
  end
  for i, nav in ipairs(_navigable) do
    if nav.key == parent_key then
      _cursor_idx = i
      break
    end
  end
  sync_cursor()
  highlight_selection()
end

--- Open the file corresponding to the currently selected node.
local function open_current_node()
  local key = current_key()
  if not key or not _graph then
    return
  end
  local node = _graph.nodes[key]
  if not node then
    return
  end
  M.close()
  vim.cmd("edit " .. vim.fn.fnameescape(node.path))
end

--- Toggle the active renderer layout and refresh the current graph view.
local function toggle_layout()
  if not _graph or not _config then
    return
  end

  local selected = current_key()
  _config.layout = (_config.layout == "graph") and "tree" or "graph"
  vim.notify("graphite: layout -> " .. _config.layout, vim.log.levels.INFO)
  M.open(_graph, _config, selected)
end

-- ── Public API ────────────────────────────────────────────────────────────────

--- Open (or refresh) the graph floating window.
---@param graph GraphData
---@param config GraphiteConfig|nil
---@param focus_key string|nil
M.open = function(graph, config, focus_key)
  setup_highlights()
  _graph = graph
  _config = config or { layout = "tree" }

  -- Render to lines
  local lines, node_positions = renderer.render(graph, _config)
  _node_positions = node_positions

  -- Build sorted navigable list
  _navigable = {}
  for _, pos in pairs(node_positions) do
    table.insert(_navigable, pos)
  end
  table.sort(_navigable, function(a, b)
    return a.row < b.row
  end)
  _cursor_idx = 1
  if focus_key then
    for i, nav in ipairs(_navigable) do
      if nav.key == focus_key then
        _cursor_idx = i
        break
      end
    end
  end

  -- ── Create / reuse buffer ────────────────────────────────────────────────
  if _buf and vim.api.nvim_buf_is_valid(_buf) then
    vim.api.nvim_buf_delete(_buf, { force = true })
  end
  _buf = vim.api.nvim_create_buf(false, true) -- unlisted scratch buffer
  vim.bo[_buf].modifiable = true
  vim.api.nvim_buf_set_lines(_buf, 0, -1, false, lines)
  vim.bo[_buf].modifiable = false
  vim.bo[_buf].buftype = "nofile"
  vim.bo[_buf].swapfile = false
  vim.bo[_buf].filetype = "graphite"

  -- ── Window dimensions ────────────────────────────────────────────────────
  local ui_info = vim.api.nvim_list_uis()[1] or { width = 120, height = 40 }
  local win_w = math.min(100, ui_info.width - 6)
  local win_h = math.min(math.max(10, #lines + 2), ui_info.height - 6)
  local row = math.floor((ui_info.height - win_h) / 2)
  local col = math.floor((ui_info.width - win_w) / 2)

  -- ── Create window ────────────────────────────────────────────────────────
  if _win and vim.api.nvim_win_is_valid(_win) then
    vim.api.nvim_win_close(_win, true)
  end
  _win = vim.api.nvim_open_win(_buf, true, {
    relative = "editor",
    width = win_w,
    height = win_h,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = " graphite.nvim ",
    title_pos = "center",
  })
  vim.wo[_win].wrap = false
  vim.wo[_win].cursorline = false -- we manage highlighting ourselves

  -- ── Keymaps ──────────────────────────────────────────────────────────────
  local opts = { buffer = _buf, noremap = true, silent = true }
  vim.keymap.set("n", "q", M.close, opts)
  vim.keymap.set("n", "<Esc>", M.close, opts)
  vim.keymap.set("n", "<CR>", open_current_node, opts)
  vim.keymap.set("n", "j", function()
    move_cursor(1)
  end, opts)
  vim.keymap.set("n", "k", function()
    move_cursor(-1)
  end, opts)
  vim.keymap.set("n", "l", move_to_child, opts)
  vim.keymap.set("n", "h", move_to_parent, opts)
  vim.keymap.set("n", "t", toggle_layout, opts)

  -- ── Initial render ───────────────────────────────────────────────────────
  apply_highlights(lines)
  sync_cursor()
  highlight_selection()
end

--- Close the graph window.
M.close = function()
  if _win and vim.api.nvim_win_is_valid(_win) then
    vim.api.nvim_win_close(_win, true)
  end
  if _buf and vim.api.nvim_buf_is_valid(_buf) then
    vim.api.nvim_buf_delete(_buf, { force = true })
  end
  _win = nil
  _buf = nil
end

--- Return true if the graph window is currently open.
---@return boolean
M.is_open = function()
  return _win ~= nil and vim.api.nvim_win_is_valid(_win)
end

return M
