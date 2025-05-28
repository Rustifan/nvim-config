return {
  {
    'github/copilot.vim',
    config = function()
      -- Path to the state file
      local state_file = vim.fn.stdpath 'data' .. '/copilot_enabled'

      -- Read persisted state
      local function read_state()
        if vim.fn.filereadable(state_file) == 1 then
          local content = vim.fn.readfile(state_file)
          if content and content[1] == '1' then
            return true
          end
        end
        return false
      end

      -- Persist state to file
      local function save_state(state)
        local val = state and '1' or '0'
        vim.fn.writefile({ val }, state_file)
      end

      -- Set Copilot state if needed
      local function set_copilot(state)
        if state then
          vim.cmd 'Copilot enable'
        else
          vim.cmd 'Copilot disable'
        end
        vim.g.copilot_enabled = state
        save_state(state)
      end

      -- Initialize Copilot state
      local enabled = read_state()
      set_copilot(enabled)

      -- Toggle keymap
      vim.keymap.set('n', '<leader>ct', function()
        local status = vim.g.copilot_enabled or false
        set_copilot(not status)
      end, { desc = 'Copilot: Toggle enable/disable' })
    end,
  },
  --
  -- Use `opts = {}` to automatically pass options to a plugin's `setup()` function, forcing the plugin to be loaded.
  --

  -- Alternatively, use `config = function() ... end` for full control over the configuration.
  -- If you prefer to call `setup` explicitly, use:
  --    {
  --        'lewis6991/gitsigns.nvim',
  --        config = function()
  --            require('gitsigns').setup({
  --                -- Your gitsigns configuration here
  --            })
  --        end,
  --    }
  --

  {
    'CopilotC-Nvim/CopilotChat.nvim',
    dependencies = {
      { 'github/copilot.vim' }, -- or zbirenbaum/copilot.lua
      { 'nvim-lua/plenary.nvim', branch = 'master' }, -- for curl, log and async functions
    },
    build = 'make tiktoken', -- Only on MacOS or Linux
    opts = {
      -- See Configuration section for options
    },
    -- See Commands section for default commands if you want to lazy load on them
  },
}
