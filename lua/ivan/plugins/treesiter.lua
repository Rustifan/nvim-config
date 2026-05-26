return {
  {
    'nvim-treesitter/nvim-treesitter',
    branch = 'main',
    build = ':TSUpdate',
    event = { 'BufReadPre', 'BufNewFile' },
    opts = {
      ensure_installed = {
        'bash', 'c', 'diff', 'html', 'lua', 'luadoc', 'markdown',
        'markdown_inline', 'query', 'vim', 'vimdoc', 'php', 'javascript',
        'typescript', 'xml', 'rust', 'go',
      },
      auto_install = true,
    },
    config = function(_, opts)
      require('nvim-treesitter').setup(opts)

      vim.api.nvim_create_autocmd('FileType', {
        pattern = { 'go', 'bash', 'c', 'diff', 'html', 'lua', 'luadoc', 'markdown', 'query', 'vim', 'vimdoc', 'php', 'javascript', 'typescript', 'xml', 'rust' },
        callback = function()
          pcall(vim.treesitter.start)
        end,
      })

      vim.api.nvim_create_autocmd({ 'BufRead', 'BufNewFile' }, {
        pattern = '*.js',
        callback = function()
          local lines = vim.api.nvim_buf_get_lines(0, 0, 10, false)
          local content = table.concat(lines, '\n')
          if content:match('@flow') or
             content:match(':%s*[%w<>%[%]|]+%s*[=,;)]') or
             content:match('type%s+%w+%s*=') then
            vim.treesitter.language.register('typescript', vim.bo.filetype)
          end
        end,
      })
    end,
  },
}