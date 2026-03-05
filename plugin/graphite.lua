-- plugin/graphite.lua: Plugin entry point.
-- Registers user commands and performs a default setup so the plugin works
-- out of the box without an explicit require("graphite").setup() call.

-- Guard against loading more than once
if vim.g.loaded_graphite then
  return
end
vim.g.loaded_graphite = true

-- Register :GraphiteOpen / :GraphiteRefresh / :GraphiteFocus
require("graphite.commands").setup()

-- Apply default configuration (users may call setup() again to override)
require("graphite").setup()
