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
  js = "javascript",
  mjs = "javascript",
  cjs = "javascript",
  jsx = "javascript",
  ts = "typescript",
  tsx = "tsx",
  py = "python",
  rs = "rust",
  go = "go",
  java = "java",
  kt = "kotlin",
  kts = "kotlin",
  rb = "ruby",
  php = "php",
  cs = "c_sharp",
  swift = "swift",
  zig = "zig",
  c = "c",
  h = "c",
  cpp = "cpp",
  hpp = "cpp",
  ex = "elixir",
  exs = "elixir",
  scala = "scala",
}

-- Fallback language names tried in order when the primary fails.
local LANG_ALIASES = {
  tsx = { "typescriptreact", "typescript" },
  jsx = { "javascriptreact", "javascript" },
  typescript = { "typescript" },
  javascript = { "javascript" },
  lua = { "lua" },
  python = { "python" },
  rust = { "rust" },
  go = { "go" },
  java = { "java" },
  kotlin = { "kotlin" },
  ruby = { "ruby" },
  php = { "php" },
  c_sharp = { "c_sharp", "c-sharp" },
  swift = { "swift" },
  zig = { "zig" },
  c = { "c" },
  cpp = { "cpp" },
  elixir = { "elixir" },
  scala = { "scala" },
}

M.EXT_TO_LANG = EXT_TO_LANG

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
  go = {
    "(function_declaration name: (identifier) @def)",
    "(method_declaration name: (field_identifier) @def)",
  },
  java = {
    "(method_declaration name: (identifier) @def)",
    "(constructor_declaration name: (identifier) @def)",
  },
  kotlin = {
    "(function_declaration name: (simple_identifier) @def)",
    "(function_declaration name: (identifier) @def)",
  },
  ruby = {
    "(method name: (identifier) @def)",
    "(singleton_method name: (identifier) @def)",
  },
  php = {
    "(function_definition name: (name) @def)",
    "(method_declaration name: (name) @def)",
  },
  c_sharp = {
    "(method_declaration name: (identifier) @def)",
    "(constructor_declaration name: (identifier) @def)",
    "(local_function_statement name: (identifier) @def)",
  },
  swift = {
    "(function_declaration name: (simple_identifier) @def)",
  },
  zig = {
    "(function_declaration name: (identifier) @def)",
  },
  c = {
    "(function_definition declarator: (function_declarator declarator: (identifier) @def))",
  },
  cpp = {
    "(function_definition declarator: (function_declarator declarator: (identifier) @def))",
    "(function_definition declarator: (function_declarator declarator: (field_identifier) @def))",
  },
  elixir = {
    '(call target: (identifier) @kind arguments: (arguments (identifier) @def) (#match? @kind "^(def|defp|defmacro)$"))',
  },
  scala = {
    "(function_definition name: (identifier) @def)",
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
  go = {
    "(call_expression function: (identifier) @call)",
    "(call_expression function: (selector_expression field: (field_identifier) @call))",
  },
  java = {
    "(method_invocation name: (identifier) @call)",
  },
  kotlin = {
    "(call_expression (simple_identifier) @call)",
    "(call_expression (identifier) @call)",
  },
  ruby = {
    "(call method: (identifier) @call)",
    "(command method: (identifier) @call)",
    "(command_call method: (identifier) @call)",
  },
  php = {
    "(function_call_expression function: (name) @call)",
    "(member_call_expression name: (name) @call)",
    "(scoped_call_expression name: (name) @call)",
  },
  c_sharp = {
    "(invocation_expression expression: (identifier) @call)",
    "(invocation_expression expression: (member_access_expression name: (identifier) @call))",
  },
  swift = {
    "(call_expression called_expression: (simple_identifier) @call)",
  },
  zig = {
    "(function_call_expression function: (identifier) @call)",
    "(function_call_expression function: (field_access_expression field: (identifier) @call))",
  },
  c = {
    "(call_expression function: (identifier) @call)",
    "(call_expression function: (field_expression field: (field_identifier) @call))",
  },
  cpp = {
    "(call_expression function: (identifier) @call)",
    "(call_expression function: (field_expression field: (field_identifier) @call))",
    "(call_expression function: (qualified_identifier name: (identifier) @call))",
  },
  elixir = {
    '(call target: (identifier) @call (#not-match? @call "^(def|defp|defmacro|if|case|cond|with|for|fn|quote)$"))',
  },
  scala = {
    "(call_expression function: (identifier) @call)",
  },
}
CALL_PATTERNS.tsx = CALL_PATTERNS.typescript
CALL_PATTERNS.typescriptreact = CALL_PATTERNS.typescript
CALL_PATTERNS.javascriptreact = CALL_PATTERNS.javascript

-- ── Node types that mark a function boundary (for parent-chain walk) ──────────
local FUNC_NODE_TYPES = {
  lua = { function_declaration = true, local_function = true, function_definition = true },
  javascript = { function_declaration = true, function_expression = true, arrow_function = true, method_definition = true },
  typescript = {
    function_declaration = true,
    function_expression = true,
    arrow_function = true,
    method_definition = true,
    function_signature = true,
  },
  python = { function_definition = true },
  rust = { function_item = true },
  go = { function_declaration = true, method_declaration = true },
  java = { method_declaration = true, constructor_declaration = true },
  kotlin = { function_declaration = true },
  ruby = { method = true, singleton_method = true },
  php = { function_definition = true, method_declaration = true },
  c_sharp = { method_declaration = true, constructor_declaration = true, local_function_statement = true },
  swift = { function_declaration = true },
  zig = { function_declaration = true },
  c = { function_definition = true },
  cpp = { function_definition = true },
  elixir = { call = true },
  scala = { function_definition = true },
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
--- Tries common identifier-like named child node types used across grammars.
local function func_node_name(func_node, source)
  for i = 0, func_node:named_child_count() - 1 do
    local child = func_node:named_child(i)
    local t = child:type()
    if
      t == "identifier"
      or t == "property_identifier"
      or t == "field_identifier"
      or t == "simple_identifier"
      or t == "name"
    then
      return vim.treesitter.get_node_text(child, source)
    end
  end
  return nil
end

local function iter_lines(source)
  return (source .. "\n"):gmatch("([^\n]*)\n")
end

local CALL_KEYWORDS = {
  ["if"] = true,
  ["for"] = true,
  ["while"] = true,
  ["switch"] = true,
  ["case"] = true,
  ["catch"] = true,
  ["return"] = true,
  ["new"] = true,
  ["function"] = true,
  ["def"] = true,
  ["defp"] = true,
  ["defmacro"] = true,
  ["fn"] = true,
  ["class"] = true,
  ["interface"] = true,
  ["struct"] = true,
  ["enum"] = true,
  ["do"] = true,
  ["end"] = true,
}

local function fallback_regex_extract(source, ext)
  local defs_set = {}
  local calls_set = {}

  local function add_def(name)
    if name and name ~= "" then
      defs_set[name] = true
    end
  end

  local function add_calls_from_source(text)
    for name in text:gmatch("([%a_][%w_]*)%s*%(") do
      if not CALL_KEYWORDS[name] then
        calls_set[name] = true
      end
    end
  end

  if ext == "go" then
    for line in iter_lines(source) do
      add_def(line:match("^%s*func%s+([%a_][%w_]*)%s*%("))
      add_def(line:match("^%s*func%s*%b()%s*([%a_][%w_]*)%s*%("))
    end
  elseif ext == "java" or ext == "kt" or ext == "kts" or ext == "scala" or ext == "cs" or ext == "swift" then
    for line in iter_lines(source) do
      local def = line:match("([%a_][%w_]*)%s*%b()%s*{")
      if def and not CALL_KEYWORDS[def] and not line:match("^%s*[%a_][%w_]*%s*[%{%[]?%s*$") then
        add_def(def)
      end
    end
  elseif ext == "rb" then
    for line in iter_lines(source) do
      local def = line:match("^%s*def%s+([%w_%.!?]+)")
      if def then
        add_def((def:match("([%w_!?]+)$")))
      end
    end
  elseif ext == "php" then
    for line in iter_lines(source) do
      add_def(line:match("^%s*function%s+([%a_][%w_]*)%s*%("))
    end
  elseif ext == "zig" then
    for line in iter_lines(source) do
      add_def(line:match("^%s*pub%s+fn%s+([%a_][%w_]*)%s*%("))
      add_def(line:match("^%s*fn%s+([%a_][%w_]*)%s*%("))
    end
  elseif ext == "c" or ext == "h" or ext == "cpp" or ext == "hpp" then
    for line in iter_lines(source) do
      local def = line:match("([%a_][%w_]*)%s*%b()%s*{")
      if def and not CALL_KEYWORDS[def] then
        add_def(def)
      end
    end
  elseif ext == "ex" or ext == "exs" then
    for line in iter_lines(source) do
      add_def(line:match("^%s*defp?%s+([%a_][%w_!?]*)%s*%("))
      add_def(line:match("^%s*defmacro%s+([%a_][%w_!?]*)%s*%("))
      add_def(line:match("^%s*defp?%s+([%a_][%w_!?]*)%s+do%s*$"))
    end
  else
    return nil
  end

  add_calls_from_source(source)

  local defs = {}
  for name in pairs(defs_set) do
    table.insert(defs, name)
  end
  table.sort(defs)
  if #defs == 0 then
    return nil
  end

  local calls = {}
  for name in pairs(calls_set) do
    table.insert(calls, name)
  end
  table.sort(calls)

  local calls_by_func = {}
  for _, def in ipairs(defs) do
    local per_func_calls = {}
    for _, callee in ipairs(calls) do
      if callee ~= def then
        table.insert(per_func_calls, callee)
      end
    end
    calls_by_func[def] = per_func_calls
  end

  return { defs = defs, calls_by_func = calls_by_func }
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
  local fallback = fallback_regex_extract(source, ext)

  -- Resolve the actual TS language (handles aliases like tsx/typescriptreact)
  local ts_parser, lang = get_parser(source, primary_lang)
  if not ts_parser or not lang then
    return fallback
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
  if #defs == 0 and fallback then
    return fallback
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

  if next(calls_by_func) == nil and fallback then
    return fallback
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
    return ("No Tree-sitter parser available for '%s' (tried aliases too). " .. "Run :TSInstall %s"):format(
      primary_lang,
      primary_lang
    )
  end

  local ok_t, trees = pcall(function()
    return ts_parser:parse()
  end)
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
