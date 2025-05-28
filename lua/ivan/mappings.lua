vim.keymap.set('n', '<Esc>', '<cmd>nohlsearch<CR>')


vim.keymap.set('n', '<leader>q', vim.diagnostic.setloclist, { desc = 'Open diagnostic [Q]uickfix list' })
vim.keymap.set('n', '<leader>e', vim.diagnostic.open_float, { desc = 'Open [E]rror float' })
vim.keymap.set('t', '<Esc><Esc>', '<C-\\><C-n>', { desc = 'Exit terminal mode' })

-- Telescope browser
vim.keymap.set('n', '<leader>se', ':Telescope file_browser path=%:p:h select_buffer=true<CR>', { desc = '[S]earch [S]elect File Explorer' })
vim.keymap.set('n', '<leader>st', ':Telescope telescope-tabs list_tabs<CR>', { desc = '[S]earch [T]abs' })

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

