-- util.lua: File system helpers and path utilities for graphite.nvim

local M = {}

--- Recursively scan a directory and return all file paths.
--- Uses vim.fn.glob for simplicity and correctness on all platforms.
---@param dir string Absolute path to the root directory
---@param max_files number Maximum number of files to return
---@param ignore_patterns string[] Lua patterns; matching files/dirs are skipped
---@return string[] Absolute paths of discovered files
M.scan_dir = function(dir, max_files, ignore_patterns)
  local pattern = dir .. "/**/*"
  local all = vim.fn.glob(pattern, false, true)
  local files = {}

  for _, path in ipairs(all) do
    if #files >= max_files then
      break
    end

    local skip = false
    for _, pat in ipairs(ignore_patterns or {}) do
      if path:match(pat) then
        skip = true
        break
      end
    end

    -- Only include regular files (not directories)
    if not skip and vim.fn.isdirectory(path) == 0 then
      table.insert(files, path)
    end
  end

  return files
end

--- Return the path of `path` relative to `root`.
--- Returns path unchanged if it does not start with root.
---@param path string
---@param root string
---@return string
M.relative_path = function(path, root)
  local r = root:gsub("/+$", "") -- strip trailing slashes
  if path:sub(1, #r + 1) == r .. "/" then
    return path:sub(#r + 2)
  end
  return path
end

--- Extract the file extension (without the dot).
---@param path string
---@return string  e.g. "lua", "ts", "" when no extension
M.get_extension = function(path)
  return path:match("%.([^%./]+)$") or ""
end

return M
