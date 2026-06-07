return {
  'NickvanDyke/opencode.nvim',
  dependencies = {
    -- Recommended for `ask()` and `select()`.
    -- Required for `snacks` provider.
    ---@module 'snacks' <- Loads `snacks.nvim` types for configuration intellisense.
    { 'folke/snacks.nvim', opts = { input = {}, picker = {}, terminal = {} } },
  },
  config = function()
    local opencode_cmd = 'opencode --port'
    local snacks_terminal_opts = {
      win = {
        position = 'right',
        width = math.floor(vim.o.columns * 0.35),
      },
    }

    local function tmux_opencode_pane()
      return vim.fn.system('tmux list-panes -F "#{pane_id} #{pane_current_command}" 2>/dev/null | grep -o "^%[0-9]* opencode" | head -1 | cut -d" " -f1'):gsub('\n', '')
    end

    local function is_tmux()
      return vim.env.TMUX ~= nil
    end

    ---@type opencode.Opts
    vim.g.opencode_opts = {
      server = {
        start = function()
          if is_tmux() then
            vim.fn.system('tmux split-window -h "' .. opencode_cmd .. '"')
          else
            require('snacks.terminal').open(opencode_cmd, snacks_terminal_opts)
          end
        end,
        stop = function()
          if is_tmux() then
            local pane = tmux_opencode_pane()
            if pane ~= '' then
              vim.fn.system('tmux kill-pane -t ' .. pane)
            end
          else
            local terminal = require('snacks.terminal').get(opencode_cmd, vim.tbl_extend('force', snacks_terminal_opts, { create = false }))
            if terminal then
              terminal:close()
            end
          end
        end,
        toggle = function()
          if is_tmux() then
            local pane = tmux_opencode_pane()
            if pane ~= '' then
              vim.fn.system('tmux kill-pane -t ' .. pane)
            else
              vim.fn.system('tmux split-window -h "' .. opencode_cmd .. '"')
            end
          else
            require('snacks.terminal').toggle(opencode_cmd, snacks_terminal_opts)
          end
        end,
      },
    }

    -- Required for `opts.events.reload`.
    vim.o.autoread = true

    vim.keymap.set({ 'n', 'x' }, '<leader>ca', function()
      require('opencode').ask('@this: ', { submit = true })
    end, { desc = 'Ask opencode…' })
    vim.keymap.set({ 'n', 'x' }, '<leader>cs', function()
      require('opencode').select()
    end, { desc = 'Execute opencode action…' })
    vim.keymap.set({ 'n', 't' }, '<leader>cc', function()
      vim.g.opencode_opts.server.toggle()
    end, { desc = 'Toggle opencode' })

    vim.keymap.set({ 'n', 'x' }, '<leader>cr', function()
      return require('opencode').operator '@this '
    end, { desc = 'Add range to opencode', expr = true })
    vim.keymap.set('n', '<leader>cl', function()
      return require('opencode').operator '@this ' .. '_'
    end, { desc = 'Add line to opencode', expr = true })

    vim.keymap.set('n', '<leader>cu', function()
      require('opencode').command 'session.half.page.up'
    end, { desc = 'Scroll opencode up' })
    vim.keymap.set('n', '<leader>cd', function()
      require('opencode').command 'session.half.page.down'
    end, { desc = 'Scroll opencode down' })
  end,
}
