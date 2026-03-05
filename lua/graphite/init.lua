-- init.lua: Public API and configuration entry point for graphite.nvim.
-- Users call require("graphite").setup({}) to configure the plugin.

local graph = require("graphite.graph")
local ui = require("graphite.ui")

local M = {}

---@class GraphiteConfig
---@field max_files number        Maximum files to scan (default: 1000)
---@field auto_refresh boolean    Re-scan on :GraphiteOpen if graph exists (default: false)
---@field layout string           Layout algorithm – "tree" only for now (default: "tree")
---@field ignore_patterns string[] Lua patterns for paths to exclude from scanning

--- Default configuration values.
local defaults = {
  max_files = 1000,
  auto_refresh = false,
  layout = "tree",
  ignore_patterns = { "node_modules", "%.git", "%.cache", "dist", "build", "vendor" },
}

--- Active configuration (merged defaults + user overrides).
---@type GraphiteConfig
M.config = vim.deepcopy(defaults)

--- Configure graphite.nvim.  Call this once from your plugin manager config.
---@param opts GraphiteConfig?
M.setup = function(opts)
  M.config = vim.tbl_deep_extend("force", defaults, opts or {})
end

--- Scan the current project and open the graph window.
--- If a cached graph already exists and auto_refresh is false, re-uses it.
M.open = function()
  local root = vim.fn.getcwd()

  -- Build (or reuse) the graph
  local g = graph.get()
  local has_graph = next(g.nodes) ~= nil

  if not has_graph or M.config.auto_refresh then
    vim.notify("graphite: scanning " .. root .. " …", vim.log.levels.INFO)
    g = graph.build(root, M.config)
    local node_count = 0
    for _ in pairs(g.nodes) do
      node_count = node_count + 1
    end
    vim.notify(
      string.format("graphite: found %d files, %d edges", node_count, #g.edges),
      vim.log.levels.INFO
    )
  end

  ui.open(g)
end

--- Force a full rescan and re-render.
M.refresh = function()
  local root = vim.fn.getcwd()
  graph.clear()
  vim.notify("graphite: refreshing graph for " .. root .. " …", vim.log.levels.INFO)
  local g = graph.build(root, M.config)
  local node_count = 0
  for _ in pairs(g.nodes) do
    node_count = node_count + 1
  end
  vim.notify(
    string.format("graphite: %d files, %d edges", node_count, #g.edges),
    vim.log.levels.INFO
  )
  ui.open(g)
end

--- Show a focused graph for the file in the active buffer.
--- The view includes the file itself, its imports, and files that import it.
M.focus = function()
  local abs_path = vim.api.nvim_buf_get_name(0)
  if abs_path == "" then
    vim.notify("graphite: no file in current buffer", vim.log.levels.WARN)
    return
  end

  local root = vim.fn.getcwd()

  -- Ensure graph is built
  local g = graph.get()
  if next(g.nodes) == nil then
    vim.notify("graphite: scanning project first …", vim.log.levels.INFO)
    g = graph.build(root, M.config)
  end

  -- Resolve relative path
  local rel = vim.fn.fnamemodify(abs_path, ":~:.")
  -- fnamemodify :~:. gives cwd-relative if possible
  -- fall back to manual stripping
  if rel:sub(1, 1) ~= "/" then
    -- already relative
  else
    local r = root:gsub("/+$", "")
    if abs_path:sub(1, #r + 1) == r .. "/" then
      rel = abs_path:sub(#r + 2)
    end
  end

  local focused = graph.focus(rel)
  local focused_count = 0
  for _ in pairs(focused.nodes) do
    focused_count = focused_count + 1
  end

  if focused_count == 0 then
    vim.notify("graphite: '" .. rel .. "' not found in graph. Try :GraphiteRefresh", vim.log.levels.WARN)
    return
  end

  vim.notify(
    string.format("graphite: focused on %s (%d neighbours)", vim.fn.fnamemodify(rel, ":t"), focused_count - 1),
    vim.log.levels.INFO
  )
  ui.open(focused)
end

--- Build and display the function-level call graph.
--- Requires Tree-sitter grammars to be installed for the project's languages.
--- Falls back to an empty graph with a helpful message if no functions are found.
M.open_functions = function()
  local root = vim.fn.getcwd()

  -- Ensure the file-level graph is built first (used for import resolution)
  local g = graph.get()
  if next(g.nodes) == nil then
    vim.notify("graphite: scanning project …", vim.log.levels.INFO)
    graph.build(root, M.config)
  end

  vim.notify("graphite: building function call graph …", vim.log.levels.INFO)
  local fg = graph.build_functions(root, M.config)

  local func_count = 0
  for _ in pairs(fg.nodes) do
    func_count = func_count + 1
  end

  if func_count == 0 then
    vim.notify(
      "graphite: no functions found. Make sure Tree-sitter grammars are installed"
        .. " (:TSInstall lua javascript typescript python rust)",
      vim.log.levels.WARN
    )
    return
  end

  vim.notify(
    string.format("graphite: %d functions, %d calls", func_count, #fg.edges),
    vim.log.levels.INFO
  )
  ui.open(fg)
end

--- Print a Tree-sitter diagnostic report for the current buffer's file.
--- Shows which query patterns succeeded/failed and what they found.
--- Usage: run :GraphiteDiagnose while editing the file you want to inspect.
M.diagnose = function()
  local abs_path = vim.api.nvim_buf_get_name(0)
  if abs_path == "" then
    vim.notify("graphite: no file in current buffer", vim.log.levels.WARN)
    return
  end
  local ts = require("graphite.treesitter")
  local report = ts.diagnose(abs_path)
  -- Display in a scratch buffer so the full output is readable
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(report, "\n"))
  vim.bo[buf].modifiable = false
  vim.bo[buf].buftype = "nofile"
  local ui_info = vim.api.nvim_list_uis()[1] or { width = 120, height = 40 }
  local w = math.min(100, ui_info.width - 6)
  local h = math.min(30, ui_info.height - 6)
  vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = w,
    height = h,
    row = math.floor((ui_info.height - h) / 2),
    col = math.floor((ui_info.width - w) / 2),
    style = "minimal",
    border = "rounded",
    title = " graphite: Tree-sitter diagnostic ",
    title_pos = "center",
  })
  vim.keymap.set("n", "q", "<cmd>close<CR>", { buffer = buf, noremap = true, silent = true })
  vim.keymap.set("n", "<Esc>", "<cmd>close<CR>", { buffer = buf, noremap = true, silent = true })
end

return M
