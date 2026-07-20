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

vim.keymap.set('n', '<leader>ap', function()
  local path = vim.fn.expand '%:p'
  vim.fn.setreg('+', path)
  vim.notify('Copied absolute path: ' .. path)
end, { desc = 'Copy [A]bsolute file [P]ath to clipboard' })

vim.keymap.set('n', '<leader>al', function()
  local line_number = vim.fn.line '.'
  local path = vim.fn.expand '%:p'
  local full_path = path .. ':' .. line_number
  vim.fn.setreg('+', full_path)
  vim.notify('Copied absolute path and line number: ' .. full_path)
end, { desc = 'Copy [A]bsolute path and [L]ine number' })

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
