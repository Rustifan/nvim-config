local execution = require 'ivan.utils.code_execution'
local M = {}
local runners = {}
local running = {}
local current
local output_buf
local options = { height = 12 }

local function notify(message)
  vim.notify('Code runner: ' .. message, vim.log.levels.ERROR)
end

local function set_lines(buf, start, finish, lines)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, start, finish, false, lines)
  vim.bo[buf].modifiable = false
end

local function close_output()
  local win = vim.api.nvim_get_current_win()
  if #vim.api.nvim_tabpage_list_wins(0) == 1 then
    vim.cmd 'enew'
    return
  end
  vim.api.nvim_win_close(win, true)
end

local function ensure_output()
  if output_buf and vim.api.nvim_buf_is_valid(output_buf) then
    return output_buf
  end
  output_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(output_buf, 'code-run://output')
  vim.bo[output_buf].bufhidden = 'hide'
  vim.bo[output_buf].swapfile = false
  vim.bo[output_buf].modifiable = false
  vim.bo[output_buf].filetype = 'code-run-output'
  vim.keymap.set('n', 'q', close_output, { buffer = output_buf, desc = 'Close code output' })
  vim.keymap.set('n', '<Esc>', close_output, { buffer = output_buf, desc = 'Close code output' })
  vim.keymap.set('n', '<C-c>', M.stop, { buffer = output_buf, desc = 'Stop code execution' })
  return output_buf
end

local function output_window(focus)
  local buf = ensure_output()
  local wins = vim.fn.win_findbuf(buf)
  for _, win in ipairs(wins) do
    local same_tab = vim.api.nvim_win_get_tabpage(win) == vim.api.nvim_get_current_tabpage()
    if same_tab and focus then
      vim.api.nvim_set_current_win(win)
    end
    if same_tab then
      return buf
    end
  end
  local source_win = vim.api.nvim_get_current_win()
  vim.cmd('botright ' .. math.max(1, math.min(options.height, vim.o.lines - 4)) .. 'split')
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = 'no'
  vim.wo[win].wrap = false
  vim.wo[win].winfixheight = true
  if not focus then
    vim.api.nvim_set_current_win(source_win)
  end
  return buf
end

local function status(run, text)
  if current ~= run or not vim.api.nvim_buf_is_valid(run.buf) then
    return
  end
  set_lines(run.buf, 0, 1, { '--- ' .. (run.plan.label or run.context.filetype) .. ': ' .. text .. ' ---' })
  vim.b[run.buf].code_run_status = text
end

local function source_paths(run, text)
  if not run.plan.path then
    return text
  end
  local source = run.context.path or '[No Name]'
  text = text:gsub(vim.pesc(vim.uri_from_fname(run.plan.path)), function()
    return run.context.path and vim.uri_from_fname(source) or source
  end)
  return text:gsub(vim.pesc(run.plan.path), function()
    return source
  end)
end

local function append_output(run, stream, text)
  if current ~= run or not vim.api.nvim_buf_is_valid(run.buf) then
    return
  end
  local last = vim.api.nvim_buf_line_count(run.buf)
  local following = {}
  for _, win in ipairs(vim.fn.win_findbuf(run.buf)) do
    if vim.api.nvim_win_get_cursor(win)[1] >= last then
      following[#following + 1] = win
    end
  end
  local prefix = stream == 'stderr' and '[stderr] ' or ''
  set_lines(run.buf, -1, -1, { prefix .. source_paths(run, text):gsub('\r$', '') })
  for _, win in ipairs(following) do
    vim.api.nvim_win_set_cursor(win, { last + 1, 0 })
  end
end

local function receive(run, stream, data)
  if run.finished or current ~= run then
    return
  end
  data[1] = run.pending[stream] .. data[1]
  run.pending[stream] = data[#data]
  for index = 1, #data - 1 do
    append_output(run, stream, data[index])
  end
end

local function cleanup(run)
  if run.cleaned then
    return
  end
  run.cleaned = true
  running[run] = nil
  if not run.plan.cleanup then
    return
  end
  local ok, err = pcall(run.plan.cleanup)
  if not ok then
    notify('Could not clean up execution files: ' .. tostring(err))
  end
end

local function finish(run, code)
  if run.finished then
    return
  end
  for _, stream in ipairs { 'stdout', 'stderr' } do
    if run.pending[stream] ~= '' then
      append_output(run, stream, run.pending[stream])
    end
  end
  run.finished = true
  cleanup(run)
  status(run, run.stopped and 'stopped' or 'exit ' .. code)
  if current == run and vim.api.nvim_buf_is_valid(run.buf) then
    vim.b[run.buf].code_run_exit_code = code
  end
end

function M.stop()
  if not current or current.finished or current.stopped then
    return
  end
  current.stopped = true
  status(current, 'stopping')
  vim.fn.jobstop(current.job)
end

local function begin_run(context, plan)
  M.stop()
  local opened, buf = pcall(output_window, false)
  if not opened then
    cleanup { plan = plan }
    notify('Could not open output: ' .. tostring(buf))
    return
  end
  local run = { context = context, plan = plan, buf = buf, pending = { stdout = '', stderr = '' } }
  current = run
  running[run] = true
  vim.b[buf].code_run_exit_code = nil
  vim.b[buf].code_run_command = plan.cmd
  vim.b[buf].code_run_cwd = plan.cwd or context.cwd
  local source = context.path or '[No Name]'
  set_lines(buf, 0, -1, { '', source .. ' (lines ' .. context.first_line .. '–' .. context.last_line .. ')', 'cwd: ' .. (plan.cwd or context.cwd), '' })
  status(run, 'running')
  local started, job = pcall(vim.fn.jobstart, plan.cmd, {
    cwd = plan.cwd or context.cwd,
    env = vim.tbl_extend('force', { NO_COLOR = '1', FORCE_COLOR = '0', NODE_DISABLE_COLORS = '1' }, plan.env or {}),
    on_stdout = function(_, data)
      receive(run, 'stdout', data)
    end,
    on_stderr = function(_, data)
      receive(run, 'stderr', data)
    end,
    on_exit = function(_, code)
      finish(run, code)
    end,
  })
  if not started or job <= 0 then
    append_output(run, 'stderr', 'Could not start command: ' .. (started and table.concat(plan.cmd, ' ') or tostring(job)))
    finish(run, -1)
    return
  end
  run.job = job
  if plan.stdin then
    vim.fn.chansend(job, plan.stdin)
  end
  vim.fn.chanclose(job, 'stdin')
end

local function execute(context)
  if not context.code:match '%S' then
    notify 'There is no code to execute'
    return
  end
  local runner = runners[context.filetype]
  if not runner then
    notify('No runner registered for ' .. (context.filetype ~= '' and context.filetype or 'this filetype'))
    return
  end
  local prepared, plan, err = pcall(runner.prepare, context)
  if not prepared then
    notify('Could not prepare execution: ' .. tostring(plan))
    return
  end
  if not plan then
    notify(err or 'Could not prepare execution')
    return
  end
  begin_run(context, plan)
end

function M.run(first_line, last_line)
  local buf = vim.api.nvim_get_current_buf()
  first_line = first_line or 1
  last_line = last_line or vim.api.nvim_buf_line_count(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, first_line - 1, last_line, false)
  execute(execution.context(buf, table.concat(lines, '\n'), first_line, last_line))
end

function M.run_selection()
  local context, err = execution.selection(vim.api.nvim_get_current_buf())
  if not context then
    notify(err)
    return
  end
  execute(context)
end

function M.open_output()
  if not output_buf or not vim.api.nvim_buf_is_valid(output_buf) then
    vim.notify 'No code output yet'
    return
  end
  output_window(true)
end

function M.register_runner(filetype, runner)
  assert(type(filetype) == 'string' and filetype ~= '', 'A runner needs a filetype')
  assert(type(runner) == 'table' and type(runner.prepare) == 'function', 'A runner needs prepare(context)')
  runners[filetype] = runner
end

function M.setup(opts)
  options = vim.tbl_extend('force', { height = 12, key = '<leader>e' }, opts or {})
  local node = require('ivan.runners.node').new(options.node)
  for _, filetype in ipairs { 'javascript', 'javascriptreact', 'typescript', 'typescriptreact' } do
    M.register_runner(filetype, node)
  end
  M.register_runner('go', require('ivan.runners.go').new(options.go))
  for filetype, runner in pairs(options.runners or {}) do
    M.register_runner(filetype, runner)
  end
  vim.api.nvim_create_user_command('CodeRun', function(command)
    M.run(command.line1, command.line2)
  end, { range = '%', desc = 'Execute buffer or line range' })
  vim.api.nvim_create_user_command('CodeRunSelection', M.run_selection, { desc = 'Execute the Visual selection' })
  vim.api.nvim_create_user_command('CodeRunStop', M.stop, { desc = 'Stop code execution' })
  vim.api.nvim_create_user_command('CodeRunOutput', M.open_output, { desc = 'Open the last code output' })
  if options.key then
    vim.keymap.set('n', options.key, M.run, { desc = '[E]xecute buffer' })
    vim.keymap.set('x', options.key, M.run_selection, { desc = '[E]xecute selection' })
  end
  local group = vim.api.nvim_create_augroup('ivan-code-runner', { clear = true })
  vim.api.nvim_create_autocmd('VimLeavePre', {
    group = group,
    callback = function()
      for run in pairs(running) do
        vim.fn.jobstop(run.job)
        cleanup(run)
      end
    end,
  })
end

return M
