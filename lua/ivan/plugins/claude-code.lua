return {
  'zolinthecow/nvim-claude',
  submodules = false,
  config = function()
    require('nvim-claude').setup({
      -- your configuration
    })
  end,
  dependencies = {
    'nvim-telescope/telescope.nvim',  -- Required
    'nvim-lua/plenary.nvim',         -- Required
    'sindrets/diffview.nvim',        -- Optional: for enhanced diff viewing
  },
}
