-- commands.lua: Register all :Graphite* user commands.
-- Each command delegates to the public API in graphite.init.

local M = {}

--- Register all user commands.  Called once from plugin/graphite.lua.
M.setup = function()
  -- :GraphiteOpen  – scan the current project and open the graph view
  vim.api.nvim_create_user_command("GraphiteOpen", function()
    require("graphite").open()
  end, { desc = "Open the graphite dependency graph for the current project" })

  -- :GraphiteRefresh – rebuild the graph from scratch and re-render
  vim.api.nvim_create_user_command("GraphiteRefresh", function()
    require("graphite").refresh()
  end, { desc = "Rebuild and re-render the graphite dependency graph" })

  -- :GraphiteFocus – show only the current file and its neighbours
  vim.api.nvim_create_user_command("GraphiteFocus", function()
    require("graphite").focus()
  end, { desc = "Show a focused graph for the file in the current buffer" })

  -- :GraphiteFunctions – show the function-level call graph
  vim.api.nvim_create_user_command("GraphiteFunctions", function()
    require("graphite").open_functions()
  end, { desc = "Show the function-level call graph for the current project" })

  -- :GraphiteDiagnose – show Tree-sitter diagnostic for the current file
  vim.api.nvim_create_user_command("GraphiteDiagnose", function()
    require("graphite").diagnose()
  end, { desc = "Print Tree-sitter diagnostic for the current buffer's file" })
end

return M
