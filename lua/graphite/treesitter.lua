-- treesitter.lua: Extract function definitions and call relationships using
-- Tree-sitter.
--
-- Design principle: every query pattern is parsed independently with pcall so
-- that a single bad pattern (wrong node type for the installed grammar version)
-- never silently kills results for the whole file.

local M = {}

-- ── Language mapping ──────────────────────────────────────────────────────────

-- Primary extension -> TS language name.
local EXT_TO_LANG = {
  lua = "lua",
  js  = "javascript",
  mjs = "javascript",
  cjs = "javascript",
  jsx = "javascript",
  ts  = "typescript",
  tsx = "tsx",
  py  = "python",
  rs  = "rust",
}

-- Fallback language names tried in order when the primary fails.
local LANG_ALIASES = {
  tsx       = { "typescriptreact", "typescript" },
  jsx       = { "javascriptreact", "javascript" },
  typescript = { "typescript" },
  javascript = { "javascript" },
  lua        = { "lua" },
  python     = { "python" },
  rust       = { "rust" },
}

-- ── Query patterns ────────────────────────────────────────────────────────────
-- Each language maps to a *list* of single-pattern query strings.
-- Patterns are tried individually; any that fail to parse are silently skipped.

-- Function-definition patterns: capture @def on the name identifier node.
local DEF_PATTERNS = {
  lua = {
    "(function_declaration name: (identifier) @def)",
    "(local_function name: (identifier) @def)",
  },
  javascript = {
    "(function_declaration name: (identifier) @def)",
    "(function_expression  name: (identifier) @def)",
    "(method_definition    key:  (property_identifier) @def)",
  },
  typescript = {
    "(function_declaration name: (identifier) @def)",
    "(function_expression  name: (identifier) @def)",
    "(method_definition    key:  (property_identifier) @def)",
    "(function_signature   name: (identifier) @def)",
  },
  python = {
    "(function_definition name: (identifier) @def)",
  },
  rust = {
    "(function_item name: (identifier) @def)",
  },
}
DEF_PATTERNS.tsx = DEF_PATTERNS.typescript
DEF_PATTERNS.typescriptreact = DEF_PATTERNS.typescript
DEF_PATTERNS.javascriptreact = DEF_PATTERNS.javascript

-- Call-expression patterns: capture @call on the callee name.
local CALL_PATTERNS = {
  lua = {
    "(function_call name: (identifier) @call)",
    -- method calls: obj:method()
    "(function_call name: (method_index_expression method: (identifier) @call))",
    -- field calls: obj.method()
    "(function_call name: (dot_index_expression   field:  (identifier) @call))",
  },
  javascript = {
    "(call_expression function: (identifier) @call)",
    "(call_expression function: (member_expression property: (property_identifier) @call))",
  },
  typescript = {
    "(call_expression function: (identifier) @call)",
    "(call_expression function: (member_expression property: (property_identifier) @call))",
  },
  python = {
    "(call function: (identifier) @call)",
    "(call function: (attribute attribute: (identifier) @call))",
  },
  rust = {
    "(call_expression function: (identifier) @call)",
    "(call_expression function: (scoped_identifier name: (identifier) @call))",
  },
}
CALL_PATTERNS.tsx = CALL_PATTERNS.typescript
CALL_PATTERNS.typescriptreact = CALL_PATTERNS.typescript
CALL_PATTERNS.javascriptreact = CALL_PATTERNS.javascript

-- ── Node types that mark a function boundary (for parent-chain walk) ──────────
local FUNC_NODE_TYPES = {
  lua        = { function_declaration=true, local_function=true, function_definition=true },
  javascript = { function_declaration=true, function_expression=true, arrow_function=true, method_definition=true },
  typescript = { function_declaration=true, function_expression=true, arrow_function=true, method_definition=true, function_signature=true },
  python     = { function_definition=true },
  rust       = { function_item=true },
}
FUNC_NODE_TYPES.tsx = FUNC_NODE_TYPES.typescript
FUNC_NODE_TYPES.typescriptreact = FUNC_NODE_TYPES.typescript
FUNC_NODE_TYPES.javascriptreact = FUNC_NODE_TYPES.javascript

-- ── Helpers ───────────────────────────────────────────────────────────────────

--- Try to get a string parser for `source` using `lang`, then its aliases.
--- Returns (parser, resolved_lang) or (nil, nil).
local function get_parser(source, lang)
  local attempts = { lang }
  for _, alias in ipairs(LANG_ALIASES[lang] or {}) do
    table.insert(attempts, alias)
  end
  for _, l in ipairs(attempts) do
    local ok, p = pcall(vim.treesitter.get_string_parser, source, l)
    if ok and p then
      return p, l
    end
  end
  return nil, nil
end

--- Run a list of single-pattern query strings against `root`/`source`.
--- Returns a list of {text, node} for the given capture name.
--- Patterns that fail to parse are silently skipped.
local function run_patterns(root, source, lang, patterns, capture_name)
  local results = {}
  local seen = {}
  for _, pat in ipairs(patterns or {}) do
    local ok, query = pcall(vim.treesitter.query.parse, lang, pat)
    if ok and query then
      for id, node in query:iter_captures(root, source, 0, -1) do
        if query.captures[id] == capture_name then
          local text = vim.treesitter.get_node_text(node, source)
          if text and text ~= "" and not seen[text] then
            seen[text] = true
            table.insert(results, { text = text, node = node })
          end
        end
      end
    end
  end
  return results
end

--- Walk up the parent chain of `node` and return the first ancestor whose
--- type is in `func_types`, or nil if the call is at module/top level.
local function containing_func_node(node, func_types)
  local current = node:parent()
  while current do
    if func_types[current:type()] then
      return current
    end
    current = current:parent()
  end
  return nil
end

--- Return the function name from a function-definition node.
--- Tries the first identifier / property_identifier named child.
local function func_node_name(func_node, source)
  for i = 0, func_node:named_child_count() - 1 do
    local child = func_node:named_child(i)
    local t = child:type()
    if t == "identifier" or t == "property_identifier" then
      return vim.treesitter.get_node_text(child, source)
    end
  end
  return nil
end

-- ── Public API ────────────────────────────────────────────────────────────────

---@class FuncCallInfo
---@field defs string[]
---@field calls_by_func table<string, string[]>

--- Parse `file_path` and return function definitions + per-function call lists.
--- Returns nil if no TS parser is available for the file's language.
---@param file_path string
---@return FuncCallInfo|nil
M.extract = function(file_path)
  local ext = file_path:match("%.([^%./]+)$") or ""
  local primary_lang = EXT_TO_LANG[ext]
  if not primary_lang then
    return nil
  end

  local f = io.open(file_path, "r")
  if not f then
    return nil
  end
  local source = f:read("*a")
  f:close()
  if source == "" then
    return { defs = {}, calls_by_func = {} }
  end

  -- Resolve the actual TS language (handles aliases like tsx/typescriptreact)
  local ts_parser, lang = get_parser(source, primary_lang)
  if not ts_parser or not lang then
    return nil
  end

  local ok_t, trees = pcall(function()
    return ts_parser:parse()
  end)
  if not ok_t or not trees or not trees[1] then
    return nil
  end
  local root = trees[1]:root()

  local func_types = FUNC_NODE_TYPES[lang] or {}

  -- ── 1. Collect definitions ────────────────────────────────────────────────
  local def_results = run_patterns(root, source, lang, DEF_PATTERNS[lang], "def")

  local defs = {}
  local def_set = {}
  for _, r in ipairs(def_results) do
    if not def_set[r.text] then
      def_set[r.text] = true
      table.insert(defs, r.text)
    end
  end

  -- ── 2. Collect calls and map each to its containing function ──────────────
  local call_results = run_patterns(root, source, lang, CALL_PATTERNS[lang], "call")

  local calls_by_func_set = {} -- container_name -> {callee -> true}
  for _, r in ipairs(call_results) do
    local container_node = containing_func_node(r.node, func_types)
    local container_name
    if container_node then
      container_name = func_node_name(container_node, source)
    else
      container_name = "__toplevel__"
    end
    if container_name then
      calls_by_func_set[container_name] = calls_by_func_set[container_name] or {}
      calls_by_func_set[container_name][r.text] = true
    end
  end

  -- Convert sets to sorted lists
  local calls_by_func = {}
  for fname, callees_set in pairs(calls_by_func_set) do
    local list = {}
    for callee in pairs(callees_set) do
      table.insert(list, callee)
    end
    table.sort(list)
    calls_by_func[fname] = list
  end

  return { defs = defs, calls_by_func = calls_by_func }
end

--- Diagnostic helper: returns a human-readable string describing what
--- Tree-sitter can extract from a given file.  Useful for debugging.
---  :lua print(require("graphite.treesitter").diagnose("/path/to/file.lua"))
---@param file_path string
---@return string
M.diagnose = function(file_path)
  local ext = file_path:match("%.([^%./]+)$") or ""
  local primary_lang = EXT_TO_LANG[ext]
  if not primary_lang then
    return ("No language mapping for extension '%s'"):format(ext)
  end

  local f = io.open(file_path, "r")
  if not f then
    return "Cannot open file: " .. file_path
  end
  local source = f:read("*a")
  f:close()

  local ts_parser, lang = get_parser(source, primary_lang)
  if not ts_parser then
    return ("No Tree-sitter parser available for '%s' (tried aliases too). "
      .. "Run :TSInstall %s"):format(primary_lang, primary_lang)
  end

  local ok_t, trees = pcall(function() return ts_parser:parse() end)
  if not ok_t or not trees or not trees[1] then
    return "Parser found but tree:parse() failed for: " .. file_path
  end
  local root = trees[1]:root()

  local lines = {
    ("File: %s  (lang: %s)"):format(file_path, lang),
    ("Root node type: %s"):format(root:type()),
    "",
    "Definition patterns:",
  }
  for _, pat in ipairs(DEF_PATTERNS[lang] or {}) do
    local ok, query = pcall(vim.treesitter.query.parse, lang, pat)
    local found = {}
    if ok and query then
      for id, node in query:iter_captures(root, source, 0, -1) do
        if query.captures[id] == "def" then
          table.insert(found, vim.treesitter.get_node_text(node, source))
        end
      end
      table.insert(lines, ("  ✓  %-60s  → [%s]"):format(pat:gsub("%s+", " "), table.concat(found, ", ")))
    else
      table.insert(lines, ("  ✗  %-60s  (query parse error)"):format(pat:gsub("%s+", " ")))
    end
  end

  table.insert(lines, "")
  table.insert(lines, "Call patterns:")
  for _, pat in ipairs(CALL_PATTERNS[lang] or {}) do
    local ok, query = pcall(vim.treesitter.query.parse, lang, pat)
    local found = {}
    if ok and query then
      for id, node in query:iter_captures(root, source, 0, -1) do
        if query.captures[id] == "call" then
          table.insert(found, vim.treesitter.get_node_text(node, source))
        end
      end
      table.insert(lines, ("  ✓  %-60s  → [%s]"):format(pat:gsub("%s+", " "), table.concat(found, ", ")))
    else
      table.insert(lines, ("  ✗  %-60s  (query parse error)"):format(pat:gsub("%s+", " ")))
    end
  end

  return table.concat(lines, "\n")
end

return M
