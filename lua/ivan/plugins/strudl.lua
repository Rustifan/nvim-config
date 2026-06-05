return {
  'gruvw/strudel.nvim',
  build = 'npm ci',
  config = function()
    local strudel = require 'strudel'
    strudel.setup {
      ui = {
        hide_menu_panel = true,
        hide_top_bar = true,
        hide_error_display = true,
        hide_code_editor = false,
        -- Set `hide_code_editor = false` if you want to overlay the code editor
      },
    }

    vim.filetype.add {
      extension = {
        str = 'strudel',
      },
    }

    local strudel_augroup = vim.api.nvim_create_augroup('strudel', { clear = true })

    vim.api.nvim_create_autocmd('BufWritePost', {
      group = strudel_augroup,
      pattern = '*.str',
      callback = strudel.execute,
    })

    vim.keymap.set('n', '<leader>ml', strudel.launch, { desc = 'Launch Strudel' })
    vim.keymap.set('n', '<leader>mq', strudel.quit, { desc = 'Quit Strudel' })
    vim.keymap.set('n', '<leader>mt', strudel.toggle, { desc = 'Strudel Toggle Play/Stop' })
    vim.keymap.set('n', '<leader>mu', strudel.update, { desc = 'Strudel Update' })
    vim.keymap.set('n', '<leader>ms', strudel.stop, { desc = 'Strudel Stop Playback' })
    vim.keymap.set('n', '<leader>mb', strudel.set_buffer, { desc = 'Strudel set current buffer' })
    vim.keymap.set('n', '<leader>mx', strudel.execute, { desc = 'Strudel set current buffer and update' })
  end,
}
