local M = {}

function M.list(root, callback)
  if vim.fn.executable 'rg' == 0 then
    callback {}
    return function() end
  end
  local finished = false
  local started, job = pcall(
    vim.system,
    { 'rg', '--files', '--hidden', '--null', '-g', '!.git', '-g', '!node_modules', '-g', '!vendor' },
    {
      cwd = root,
      text = false,
    },
    vim.schedule_wrap(function(result)
      if finished then
        return
      end
      finished = true
      callback(result.code == 0 and vim.split(result.stdout, '\0', { plain = true, trimempty = true }) or {})
    end)
  )
  if not started then
    callback {}
    return function() end
  end
  return function()
    if finished then
      return
    end
    finished = true
    job:kill(15)
  end
end

return M
