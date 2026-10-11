local M = {}
local helper = vim.fs.joinpath(vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2)), 'go', 'runner.go')

local function goimports_executable(options)
  if options.goimports == false then
    return ''
  end
  local executable = options.goimports or 'goimports'
  return vim.fn.executable(executable) == 1 and vim.fn.exepath(executable) or ''
end

function M.new(options)
  options = options or {}
  return {
    prepare = function(context)
      local executable = options.executable or 'go'
      if vim.fn.executable(executable) == 0 then
        return nil, 'Go is not installed or is not on PATH'
      end
      local directory, err = vim.uv.fs_mkdtemp(vim.fs.joinpath(context.directory, '.nvim-run-XXXXXX'))
      if not directory then
        return nil, 'Cannot create a Go execution directory beside the source: ' .. tostring(err)
      end
      local path = vim.fs.joinpath(directory, 'main.go')
      local source = table.concat(vim.api.nvim_buf_get_lines(context.bufnr, 0, -1, false), '\n')
      return {
        cmd = { executable, 'run', helper },
        cwd = vim.fs.root(context.directory, 'go.mod') or vim.fs.root(context.directory, 'go.work') or context.directory,
        label = 'Go',
        path = path,
        stdin = vim.json.encode {
          code = context.code,
          source = source,
          filename = context.path or '[No Name]',
          first_line = context.first_line,
          path = path,
          executable = executable,
          args = options.args or {},
          goimports = goimports_executable(options),
        },
        cleanup = function()
          vim.fn.delete(directory, 'rf')
        end,
      }
    end,
  }
end

return M
