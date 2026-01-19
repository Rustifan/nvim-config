vim.keymap.set('n', '<Esc>', '<cmd>nohlsearch<CR>')

vim.keymap.set('n', '<leader>q', vim.diagnostic.setloclist, { desc = 'Open diagnostic [Q]uickfix list' })
vim.keymap.set('n', '<leader>e', vim.diagnostic.open_float, { desc = 'Open [E]rror float' })
vim.keymap.set('t', '<Esc><Esc>', '<C-\\><C-n>', { desc = 'Exit terminal mode' })

-- Telescope browser
vim.keymap.set('n', '<leader>se', ':Telescope file_browser path=%:p:h select_buffer=true<CR>', { desc = '[S]earch [S]elect File Explorer' })
vim.keymap.set('n', '<leader>st', ':Telescope telescope-tabs list_tabs<CR>', { desc = '[S]earch [T]abs' })

vim.keymap.set('n', '<leader>l', '<C-^>', { desc = 'Toggle between [L]ast two buffers' })
-- Disable arrows
vim.keymap.set('n', '<left>', '<cmd>echo "Use h to move!!"<CR>')
vim.keymap.set('n', '<right>', '<cmd>echo "Use l to move!!"<CR>')
vim.keymap.set('n', '<up>', '<cmd>echo "Use k to move!!"<CR>')
vim.keymap.set('n', '<down>', '<cmd>echo "Use j to move!!"<CR>')

-- Keybinds to make split navigation easier.
--  Use CTRL+<hjkl> to switch between windows
--
--  See `:help wincmd` for a list of all window commands
vim.keymap.set('n', '<C-h>', '<C-w><C-h>', { desc = 'Move focus to the left window' })
vim.keymap.set('n', '<C-l>', '<C-w><C-l>', { desc = 'Move focus to the right window' })
vim.keymap.set('n', '<C-j>', '<C-w><C-j>', { desc = 'Move focus to the lower window' })
vim.keymap.set('n', '<C-k>', '<C-w><C-k>', { desc = 'Move focus to the upper window' })

-- CopilotChat.nvim keymaps
vim.keymap.set('n', '<leader>cc', '<cmd>CopilotChatToggle<CR>', { desc = 'CopilotChat: Toggle chat window' })
vim.keymap.set('n', '<leader>cq', '<cmd>CopilotChatQuit<CR>', { desc = 'CopilotChat: Quit chat' })
vim.keymap.set('n', '<leader>cr', '<cmd>CopilotChatReset<CR>', { desc = 'CopilotChat: Reset chat' })
vim.keymap.set('v', '<leader>ce', ':CopilotChatExplain<CR>', { desc = 'CopilotChat: Explain selection' })
vim.keymap.set('v', '<leader>cf', ':CopilotChatFix<CR>', { desc = 'CopilotChat: Fix selection' })

vim.api.nvim_create_autocmd('TextYankPost', {
  desc = 'Highlight when yanking (copying) text',
  group = vim.api.nvim_create_augroup('kickstart-highlight-yank', { clear = true }),
  callback = function()
    vim.hl.on_yank()
  end,
})

vim.keymap.set('n', '<leader>rp', function()
  local path = vim.fn.expand '%:.'
  vim.fn.setreg('+', path)
  vim.notify('Copied relative path: ' .. path)
end, { desc = 'Copy [R]elative file [P]ath to clipboard' })

vim.keymap.set('n', '<leader>rl', function()
  local line_number = vim.fn.line '.'
  local path = vim.fn.expand '%:.'
  local full_path = path .. ':' .. line_number
  vim.fn.setreg('+', full_path)
  vim.notify('Copied path and line nunber: ' .. full_path)
end, { desc = 'Copy [R]eference to a [L]ine number and path' })

vim.api.nvim_create_user_command('DiffOrig', function()
  local orig_ft = vim.bo.filetype
  vim.cmd [[
    vnew | set bt=nofile | r ++edit # | 0d_
  ]]
  vim.bo.filetype = orig_ft
  vim.cmd 'diffthis'
  vim.cmd 'wincmd p | diffthis'
end, {})

vim.api.nvim_create_user_command('Ex', function(opts)
  vim.cmd('Oil ' .. opts.args)
end, { nargs = '*' })

-- Mongo migration runner
local function run_mongosh(input, is_file)
  local code
  if is_file then
    local lines = vim.fn.readfile(input)
    code = table.concat(lines, '\n')
  else
    code = input
  end

  -- Strip trailing semicolons and whitespace, then wrap with printjson
  code = code:gsub('%s*;%s*$', '')
  local wrapped = 'printjson(' .. code .. ')'
  local cmd = { 'mongosh', 'mongodb://localhost/kompare-platform', '--norc', '--quiet', '--eval', wrapped }
  local env = { NO_COLOR = '1' }

  local output = {}

  vim.fn.jobstart(cmd, {
    env = env,
    pty = true,
    on_stdout = function(_, data)
      if data then
        for _, line in ipairs(data) do
          -- Strip carriage returns from PTY
          line = line:gsub('\r', '')
          table.insert(output, line)
        end
      end
    end,
    on_stderr = function(_, data)
      if data then
        for _, line in ipairs(data) do
          table.insert(output, '[stderr] ' .. line)
        end
      end
    end,
    on_exit = function(_, exit_code)
      vim.schedule(function()
        -- Create a floating window for output
        local buf = vim.api.nvim_create_buf(false, true)
        table.insert(output, 1, '--- Mongosh Output (exit: ' .. exit_code .. ') ---')
        table.insert(output, '')
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, output)
        vim.api.nvim_set_option_value('filetype', 'javascript', { buf = buf })

        local width = math.min(100, vim.o.columns - 10)
        local height = math.min(#output + 1, vim.o.lines - 10)

        vim.api.nvim_open_win(buf, true, {
          relative = 'editor',
          width = width,
          height = height,
          row = (vim.o.lines - height) / 2,
          col = (vim.o.columns - width) / 2,
          style = 'minimal',
          border = 'rounded',
          title = ' Mongosh ',
          title_pos = 'center',
        })
      end)
    end,
  })
end

-- Normal mode: run current file
vim.keymap.set('n', '<leader>me', function()
  local file = vim.fn.expand '%:p'
  run_mongosh(file, true)
end, { desc = '[M]ongo [E]xecute current file' })

-- Visual mode: run selected text
vim.keymap.set('v', '<leader>me', function()
  -- Get visual selection
  vim.cmd 'normal! "vy'
  local selection = vim.fn.getreg 'v'
  run_mongosh(selection, false)
end, { desc = '[M]ongo [E]xecute selection' })

