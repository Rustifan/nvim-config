return {
  'NMAC427/guess-indent.nvim',
  config = function()
    vim.api.nvim_create_autocmd({ 'FileType' }, {
      pattern = { 'typescript' },
      callback = function()
        vim.opt_local.shiftwidth = 2
        vim.opt_local.tabstop = 2
      end,
    })
  end,
}
