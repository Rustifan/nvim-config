local M = {}

function M.context(buf, code, first_line, last_line)
  local name = vim.api.nvim_buf_get_name(buf)
  local path = name ~= '' and not name:match '^[%a][%w+.-]*://' and name or nil
  local directory = path and vim.fs.dirname(path) or vim.fn.getcwd()
  return {
    bufnr = buf,
    filetype = vim.bo[buf].filetype,
    path = path,
    directory = directory,
    cwd = vim.fs.root(directory, 'package.json') or vim.fs.root(directory, '.git') or directory,
    code = code,
    first_line = first_line,
    last_line = last_line,
  }
end

function M.selection(buf)
  local mode = vim.fn.mode()
  local active = mode == 'v' or mode == 'V' or mode == '\22'
  local start = vim.fn.getpos(active and 'v' or "'<")
  local finish = vim.fn.getpos(active and '.' or "'>")
  if start[2] == 0 or finish[2] == 0 then
    return nil, 'Select some code first'
  end
  start[1], finish[1] = buf, buf
  local lines = vim.fn.getregion(start, finish, {
    type = active and mode or vim.fn.visualmode(),
    exclusive = vim.o.selection == 'exclusive',
  })
  local context = M.context(buf, table.concat(lines, '\n'), math.min(start[2], finish[2]), math.max(start[2], finish[2]))
  if active then
    vim.api.nvim_feedkeys(vim.keycode '<Esc>', 'nx', false)
  end
  return context
end

-- Sibling files retain relative imports and the source file's package/module scope.
function M.tempfile(context, extension, prefix)
  local name = (prefix or '.nvim-run-') .. vim.fn.getpid() .. '-' .. tostring(vim.uv.hrtime()) .. extension
  local path = vim.fs.joinpath(context.directory, name)
  local fd, open_error = vim.uv.fs_open(path, 'wx', 384)
  if not fd then
    return nil, 'Cannot create an execution file beside the source: ' .. tostring(open_error)
  end
  local code = string.rep('\n', context.first_line - 1) .. context.code .. '\n'
  local written, write_error = vim.uv.fs_write(fd, code, 0)
  vim.uv.fs_close(fd)
  if written ~= #code then
    vim.uv.fs_unlink(path)
    return nil, 'Cannot write execution file: ' .. tostring(write_error or 'incomplete write')
  end
  return path, function()
    vim.uv.fs_unlink(path)
  end
end

return M
