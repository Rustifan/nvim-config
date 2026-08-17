-- Adds git related signs to the gutter, as well as utilities for managing changes
-- NOTE: gitsigns is already included in init.lua but contains only the base
-- config. This will add also the recommended keymaps.

return {
  {
    'lewis6991/gitsigns.nvim',
    opts = {
      attach_to_untracked = true,
      on_attach = function(bufnr)
        local gitsigns = require 'gitsigns'

        local function map(mode, l, r, opts)
          opts = opts or {}
          opts.buffer = bufnr
          vim.keymap.set(mode, l, r, opts)
        end

        local function git_repo_files(args)
          local root = vim.fn.systemlist('git rev-parse --show-toplevel')[1]
          if vim.v.shell_error ~= 0 then
            return {}
          end
          return vim.tbl_map(function(file)
            return root .. '/' .. file
          end, vim.fn.systemlist(vim.list_extend({ 'git', '-C', root }, args)))
        end

        local function files_with_unstaged_changes()
          return git_repo_files { 'diff', '--name-only' }
        end

        local function untracked_files()
          return git_repo_files { 'ls-files', '--others', '--exclude-standard' }
        end

        local function open_file_picker(opts)
          local finders = require 'telescope.finders'
          local conf = require('telescope.config').values
          require('telescope.pickers')
            .new({}, {
              prompt_title = opts.title,
              finder = finders.new_table {
                results = opts.results,
                entry_maker = opts.entry_maker or require('telescope.make_entry').gen_from_file {},
              },
              sorter = conf.generic_sorter {},
              previewer = opts.previewer,
              attach_mappings = opts.attach_mappings,
            })
            :find()
        end

        local function nav_unstaged_file(direction)
          local files = files_with_unstaged_changes()
          if #files == 0 then
            vim.notify('No files with unstaged changes', vim.log.levels.INFO)
            return
          end
          local current = vim.api.nvim_buf_get_name(0)
          local current_index = 0
          for i, file in ipairs(files) do
            if file == current then
              current_index = i
            end
          end
          local step = direction == 'next' and 1 or -1
          local fallback = direction == 'next' and files[1] or files[#files]
          local target = current_index == 0 and fallback or files[((current_index - 1 + step) % #files) + 1]
          vim.cmd.edit(vim.fn.fnameescape(target))
          -- gitsigns attaches to the new buffer asynchronously, so jump after a short delay
          vim.defer_fn(function()
            gitsigns.nav_hunk 'first'
          end, 100)
        end

        -- Navigation
        map('n', ']C', function()
          nav_unstaged_file 'next'
        end, { desc = 'Jump to next file with unstaged changes' })

        map('n', '[C', function()
          nav_unstaged_file 'prev'
        end, { desc = 'Jump to previous file with unstaged changes' })

        map('n', ']c', function()
          if vim.wo.diff then
            vim.cmd.normal { ']c', bang = true }
          else
            gitsigns.nav_hunk 'next'
          end
        end, { desc = 'Jump to next git [c]hange' })

        map('n', '[c', function()
          if vim.wo.diff then
            vim.cmd.normal { '[c', bang = true }
          else
            gitsigns.nav_hunk 'prev'
          end
        end, { desc = 'Jump to previous git [c]hange' })

        map('n', '<leader>hn', function()
          gitsigns.nav_hunk 'next'
        end, { desc = 'git [n]ext hunk' })

        -- Actions
        -- visual mode
        map('v', '<leader>hs', function()
          gitsigns.stage_hunk { vim.fn.line '.', vim.fn.line 'v' }
        end, { desc = 'git [s]tage hunk' })
        map('v', '<leader>hr', function()
          gitsigns.reset_hunk { vim.fn.line '.', vim.fn.line 'v' }
        end, { desc = 'git [r]eset hunk' })
        -- normal mode
        map('n', '<leader>hs', gitsigns.stage_hunk, { desc = 'git [s]tage hunk' })
        map('n', '<leader>hr', gitsigns.reset_hunk, { desc = 'git [r]eset hunk' })
        map('n', '<leader>hS', gitsigns.stage_buffer, { desc = 'git [S]tage buffer' })
        map('n', '<leader>hu', gitsigns.stage_hunk, { desc = 'git [u]ndo stage hunk' })
        map('n', '<leader>hR', gitsigns.reset_buffer, { desc = 'git [R]eset buffer' })
        map('n', '<leader>hp', gitsigns.preview_hunk, { desc = 'git [p]review hunk' })
        map('n', '<leader>hb', gitsigns.blame_line, { desc = 'git [b]lame line' })
        map('n', '<leader>hd', gitsigns.diffthis, { desc = 'git [d]iff against index' })
        map('n', '<leader>hD', function()
          gitsigns.diffthis '@'
        end, { desc = 'git [D]iff against last commit' })
        map('n', '<leader>hq', function()
          gitsigns.setqflist('all', { open = false }, function()
            require('telescope.builtin').quickfix()
          end)
        end, { desc = 'git hunks (repo-wide) in telescope' })
        local function to_file_items(paths, untracked)
          return vim.tbl_map(function(path)
            return { path = path, untracked = untracked }
          end, paths)
        end

        local function changed_file_entry(item)
          local marker = item.untracked and '? ' or 'M '
          local display = marker .. vim.fn.fnamemodify(item.path, ':.')
          return { value = item.path, path = item.path, untracked = item.untracked, display = display, ordinal = display }
        end

        map('n', '<leader>hf', function()
          local items = vim.list_extend(
            to_file_items(files_with_unstaged_changes(), false),
            to_file_items(untracked_files(), true)
          )
          if #items == 0 then
            vim.notify('No files with unstaged changes', vim.log.levels.INFO)
            return
          end
          open_file_picker {
            title = 'Files with unstaged hunks (? = untracked)',
            results = items,
            entry_maker = changed_file_entry,
            previewer = require('telescope.previewers').new_termopen_previewer {
              get_command = function(entry)
                if entry.untracked then
                  return { 'git', 'diff', '--no-index', '--', '/dev/null', entry.path }
                end
                return { 'git', 'diff', '--', entry.path }
              end,
            },
          }
        end, { desc = 'git unstaged [f]iles in telescope' })
        map('n', '<leader>hF', function()
          local files = git_repo_files { 'diff', '--cached', '--name-only' }
          if #files == 0 then
            vim.notify('No staged files', vim.log.levels.INFO)
            return
          end
          local unstage_selected = function(prompt_bufnr)
            local picker = require('telescope.actions.state').get_current_picker(prompt_bufnr)
            picker:delete_selection(function(selection)
              vim.fn.system { 'git', 'restore', '--staged', '--', selection.path }
            end)
          end
          open_file_picker {
            title = 'Staged files (<Tab> unstages)',
            results = files,
            previewer = require('telescope.previewers').new_termopen_previewer {
              get_command = function(entry)
                return { 'git', 'diff', '--cached', '--', entry.path }
              end,
            },
            attach_mappings = function(_, map_key)
              map_key({ 'i', 'n' }, '<Tab>', unstage_selected)
              return true
            end,
          }
        end, { desc = 'git staged [F]iles in telescope' })
        map('n', '<leader>hU', function()
          local files = untracked_files()
          if #files == 0 then
            vim.notify('No untracked files', vim.log.levels.INFO)
            return
          end
          local stage_selected = function(prompt_bufnr)
            local picker = require('telescope.actions.state').get_current_picker(prompt_bufnr)
            picker:delete_selection(function(selection)
              vim.fn.system { 'git', 'add', '--', selection.path }
            end)
          end
          open_file_picker {
            title = 'Untracked files (<Tab> stages)',
            results = files,
            previewer = require('telescope.config').values.file_previewer {},
            attach_mappings = function(_, map_key)
              map_key({ 'i', 'n' }, '<Tab>', stage_selected)
              return true
            end,
          }
        end, { desc = 'git [U]ntracked files in telescope' })
        -- Toggles
        map('n', '<leader>tb', gitsigns.toggle_current_line_blame, { desc = '[T]oggle git show [b]lame line' })
        map('n', '<leader>tD', gitsigns.preview_hunk_inline, { desc = '[T]oggle git show [D]eleted' })
      end,
    },
  },
}
