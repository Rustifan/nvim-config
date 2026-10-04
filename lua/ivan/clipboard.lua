local M = {}

local function send_query(register)
  if vim.env.TMUX then
    -- tmux must request the clipboard itself to route the reply to this pane.
    vim.fn.system({ 'tmux', 'refresh-client', '-l', vim.env.TMUX_PANE })
    return vim.v.shell_error == 0
  end
  local selection = register == '+' and 'c' or 'p'
  local sequence = '\027]52;' .. selection .. ';?\027\\'
  vim.api.nvim_chan_send(2, sequence)
  return true
end

local function paste(register)
  return function()
    local contents
    local id = vim.api.nvim_create_autocmd('TermResponse', {
      callback = function(args)
        local encoded = args.data.sequence:match('\027%]52;%w?;([A-Za-z0-9+/=]*)')
        if encoded == nil then
          return
        end
        contents = vim.base64.decode(encoded)
      end,
    })
    if not send_query(register) then
      vim.api.nvim_del_autocmd(id)
      vim.notify('Unable to request clipboard from the tmux client', vim.log.levels.WARN)
      return 0
    end
    local ok = vim.wait(3000, function()
      return contents ~= nil
    end, 10)
    vim.api.nvim_del_autocmd(id)
    if not ok then
      vim.notify('No clipboard response from the connecting terminal', vim.log.levels.WARN)
      return 0
    end
    return vim.split(contents, '\n', { plain = true })
  end
end

local function is_ssh_session()
  if vim.env.SSH_TTY or vim.env.SSH_CONNECTION then
    return true
  end
  if not vim.env.TMUX or vim.fn.executable('tmux') ~= 1 then
    return false
  end
  -- Existing tmux panes retain their original environment after SSH attaches.
  local connection = vim.fn.system({ 'tmux', 'show-environment', 'SSH_CONNECTION' })
  return vim.v.shell_error == 0 and connection:match('^SSH_CONNECTION=') ~= nil
end

function M.setup()
  if not is_ssh_session() then
    return
  end
  local osc52 = require('vim.ui.clipboard.osc52')
  vim.g.clipboard = {
    name = 'OSC 52 (tmux client)',
    copy = { ['+'] = osc52.copy('+'), ['*'] = osc52.copy('*') },
    paste = { ['+'] = paste('+'), ['*'] = paste('*') },
    cache_enabled = 0,
  }
end

return M
