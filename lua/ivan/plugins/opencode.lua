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
            require('opencode.terminal').open(opencode_cmd, {
              split = 'right',
              width = math.floor(vim.o.columns * 0.35),
            })
          end
        end,
        stop = function()
          if is_tmux() then
            local pane = tmux_opencode_pane()
            if pane ~= '' then
              vim.fn.system('tmux kill-pane -t ' .. pane)
            end
          else
            require('opencode.terminal').close()
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
            require('opencode.terminal').toggle(opencode_cmd, {
              split = 'right',
              width = math.floor(vim.o.columns * 0.35),
            })
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
      require('opencode').toggle()
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
