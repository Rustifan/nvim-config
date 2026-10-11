local execution = require 'ivan.utils.code_execution'
local M = {}

local extensions = {
  javascript = '.js',
  javascriptreact = '.jsx',
  typescript = '.ts',
  typescriptreact = '.tsx',
}
local supported_extensions =
  { ['.js'] = true, ['.mjs'] = true, ['.cjs'] = true, ['.jsx'] = true, ['.ts'] = true, ['.mts'] = true, ['.cts'] = true, ['.tsx'] = true }

local function source_extension(context)
  local extension = context.path and context.path:match '(%.[^.]+)$'
  return supported_extensions[extension] and extension or extensions[context.filetype]
end

local function find_tsx(directory)
  local directories = { directory }
  vim.list_extend(directories, vim.iter(vim.fs.parents(directory)):totable())
  for _, parent in ipairs(directories) do
    local candidate = vim.fs.joinpath(parent, 'node_modules', '.bin', 'tsx')
    if vim.fn.executable(candidate) == 1 then
      return candidate
    end
  end
  return vim.fn.executable 'tsx' == 1 and vim.fn.exepath 'tsx' or nil
end

local function node_command(options, extension)
  local executable = options.executable or 'node'
  if vim.fn.executable(executable) == 0 then
    return nil, 'Node.js is not installed or is not on PATH'
  end
  if extension == '.tsx' or extension == '.jsx' then
    return nil, 'JSX/TSX execution needs tsx. Install it in the project with: npm install --save-dev tsx'
  end
  local command = { executable, '--enable-source-maps' }
  if extension == '.ts' or extension == '.mts' or extension == '.cts' then
    command[#command + 1] = '--experimental-transform-types'
  end
  vim.list_extend(command, options.args or {})
  return command
end

function M.new(options)
  options = options or {}
  return {
    prepare = function(context)
      local extension = source_extension(context)
      local tsx = options.tsx ~= false and find_tsx(context.directory) or nil
      local command, command_error = tsx and { tsx } or nil, nil
      if not command then
        command, command_error = node_command(options, extension)
      end
      if not command then
        return nil, command_error
      end
      local path, cleanup = execution.tempfile(context, extension)
      if not path then
        return nil, cleanup
      end
      command[#command + 1] = path
      return {
        cmd = command,
        label = tsx and 'tsx' or 'Node.js',
        path = path,
        cleanup = cleanup,
      }
    end,
  }
end

return M
