-- Run with: nvim --headless -u NONE -l tests/ai_hover.lua
vim.opt.runtimepath:append(vim.fn.getcwd())
vim.g.mapleader = ' '

local clients, lsp_requests, runs, messages = {}, {}, {}, {}
local fail_start = false
local prefs_path = vim.fn.stdpath 'data' .. '/claude_edit.json'
local filereadable = vim.fn.filereadable
vim.fn.filereadable = function(path)
  return path == prefs_path and 0 or filereadable(path)
end
vim.fn.writefile = function()
  return 0
end
vim.notify = function(message)
  messages[#messages + 1] = message
end
vim.lsp.get_clients = function(opts)
  if opts and opts.method and opts.method ~= 'textDocument/hover' then
    return {}
  end
  return clients
end
vim.lsp.buf_request = function(buf, method, params, callback)
  assert(method == 'textDocument/hover')
  local request = { buf = buf, callback = callback, params = {}, cancelled = false }
  local ids = {}
  for _, client in ipairs(clients) do
    request.params[client.id] = params(client)
    ids[client.id] = client.id
  end
  lsp_requests[#lsp_requests + 1] = request
  return ids, function()
    request.cancelled = true
  end
end
vim.system = function(command, options, callback)
  if fail_start then
    fail_start = false
    error 'test executable is unavailable'
  end
  local run = { command = command, options = options, callback = callback }
  runs[#runs + 1] = run
  return {
    kill = function()
      run.killed = true
    end,
  }
end

local plugin = require 'ivan.claude'
local hover = require 'ivan.ai_hover'
local source = vim.api.nvim_get_current_buf()
local source_win = vim.api.nvim_get_current_win()
local source_lines = {
  'local function explain(value)',
  '  return value * 2',
  'end',
  'local café = explain(3)',
}
vim.api.nvim_buf_set_name(source, vim.fs.joinpath(vim.fn.getcwd(), 'tests/hover_fixture.lua'))
vim.api.nvim_buf_set_lines(source, 0, -1, false, source_lines)
vim.bo[source].filetype = 'lua'
vim.keymap.set('n', 'K', function() end, { desc = 'Existing LSP hover' })
plugin.setup { backend = 'opencode', model = 'test/fast', hover = { lsp_timeout_ms = 30, cache_size = 2 } }

local function flush()
  local done = false
  vim.schedule(function()
    vim.schedule(function()
      done = true
    end)
  end)
  assert(
    vim.wait(1000, function()
      return done
    end),
    'scheduled callbacks did not finish'
  )
end

local function go(row, col)
  vim.api.nvim_set_current_win(source_win)
  vim.api.nvim_win_set_buf(source_win, source)
  vim.api.nvim_win_set_cursor(source_win, { row or 4, col or 14 })
  vim.api.nvim_exec_autocmds('CursorMoved', { buffer = source })
  flush()
end

local function reply_lsp(id, result, err, request)
  request = request or lsp_requests[#lsp_requests]
  request.callback(err, result, { client_id = id, bufnr = source })
end

local function resolve_lsp()
  reply_lsp(1, { contents = { kind = 'markdown', value = 'Doubles the supplied value.' } })
  reply_lsp(2, { contents = { { language = 'lua', value = 'explain(value): number' }, 'Returns a number.' } })
end

local function reply_model(text, index, code)
  local run = runs[index or #runs]
  local event = run.command[1] == 'claude' and { type = 'result', result = text } or { type = 'text', part = { text = text } }
  run.callback { code = code or 0, stdout = vim.json.encode(event), stderr = code and 'test model failure' or '' }
  flush()
end

local function float()
  local win = vim.b[source].lsp_floating_preview
  assert(win and vim.api.nvim_win_is_valid(win), 'expected a hover window')
  return win
end

local function float_text()
  return table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(float()), 0, -1, false), '\n')
end

local function float_title()
  return vim
    .iter(vim.api.nvim_win_get_config(float()).title)
    :map(function(chunk)
      return chunk[1]
    end)
    :join ''
end

local function map(key)
  local mapping = vim.fn.maparg(key, 'n', false, true)
  assert(type(mapping.callback) == 'function', 'missing mapping: ' .. key)
  mapping.callback()
  flush()
end

local function select(value)
  vim.ui.select = function(_, _, callback)
    callback(value)
  end
end

local passed = 0
local function test(name, scenario)
  local ok, failure = xpcall(scenario, debug.traceback)
  if not ok then
    io.stderr:write(name .. ':\n' .. failure .. '\n')
    vim.cmd 'cquit 1'
    return
  end
  passed = passed + 1
  print('PASS ' .. name)
end

test('LSP context, client encodings, read-only backend, and in-flight deduplication', function()
  assert(vim.fn.maparg('K', 'n', false, true).desc == 'Existing LSP hover')
  clients = { { id = 1, offset_encoding = 'utf-8' }, { id = 2, offset_encoding = 'utf-16' } }
  go()
  map 'H'
  hover.hover()
  assert(#lsp_requests == 1 and #runs == 0)
  assert(lsp_requests[1].params[1].position.character == 14)
  assert(lsp_requests[1].params[2].position.character == 13)
  resolve_lsp()
  assert(#runs == 1)
  local run = runs[1]
  assert(run.command[1] == 'opencode' and vim.list_contains(run.command, 'test/fast'))
  assert(run.options.cwd == vim.fn.getcwd())
  assert(run.options.env.PWD == run.options.cwd)
  assert(run.options.stdin:find('Doubles the supplied value.', 1, true))
  assert(run.options.stdin:find('explain(value): number', 1, true))
  assert(run.options.stdin:find('4\tlocal café = explain(3)', 1, true))
  assert(run.options.stdin:find('name="explain"', 1, true))
  local agent = vim.json.decode(run.options.env.OPENCODE_CONFIG_CONTENT).agent.nvim_editor
  assert(agent.permission['*'] == 'deny' and agent.permission.read == 'allow' and agent.permission.grep == 'allow')
  assert(agent.prompt:find('at most 60 words', 1, true))
  reply_model 'Doubles the input and returns the result without changing other state.'
  assert(vim.api.nvim_get_current_win() == source_win, 'hover stole focus')
  assert(float_text():find('Doubles the input', 1, true))
  local config = vim.api.nvim_win_get_config(float())
  assert(config.width <= 72 and config.height <= 12 and config.relative == 'win')
end)

test('focus, dismissal, and cached reopening', function()
  local calls = #runs
  map 'H'
  assert(vim.api.nvim_get_current_win() == float())
  map 'q'
  go(4, 17)
  hover.hover()
  assert(#runs == calls and #lsp_requests == 1)
  assert(float_title():find('cached', 1, true))
  go(4, 0)
  assert(not vim.b[source].lsp_floating_preview, 'cursor movement left the hover open')
end)

test('current and related unsaved buffers invalidate summaries', function()
  vim.api.nvim_buf_set_lines(source, 1, 2, false, { '  return value * 3' })
  go()
  hover.hover()
  resolve_lsp()
  assert(runs[#runs].options.stdin:find('return value * 3', 1, true))
  reply_model 'Triples the input.'
  local related = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(related, vim.fs.joinpath(vim.fn.getcwd(), 'tests/related_fixture.lua'))
  vim.api.nvim_buf_set_lines(related, 0, -1, false, { 'return 1' })
  local calls = #runs
  go()
  hover.hover()
  resolve_lsp()
  assert(#runs == calls + 1)
  reply_model 'Uses the related module.'
  vim.api.nvim_buf_set_lines(related, 0, -1, false, { 'return 2' })
  go()
  hover.hover()
  resolve_lsp()
  assert(#runs == calls + 2)
  reply_model 'Uses the changed related module.'
  vim.api.nvim_exec_autocmds('BufWritePost', { buffer = related })
  go()
  hover.hover()
  resolve_lsp()
  assert(#runs == calls + 3)
  reply_model 'Uses the saved related module.'
end)

test('backend/thinking selection and request-time profile snapshot', function()
  go()
  map '<leader>ct'
  hover.hover()
  select 'claude'
  map '<leader>cb'
  resolve_lsp()
  assert(runs[#runs].command[1] == 'opencode')
  assert(vim.list_contains(runs[#runs].command, '--thinking'))
  assert(vim.list_contains(runs[#runs].command, 'high'))
  reply_model 'An OpenCode summary.'
  assert(not vim.b[source].lsp_floating_preview, 'outdated profile remained visible')
  hover.hover()
  resolve_lsp()
  assert(runs[#runs].command[1] == 'claude')
  assert(vim.list_contains(runs[#runs].command, 'Read,Glob,Grep'))
  assert(vim.list_contains(runs[#runs].command, 'sonnet'))
  reply_model 'A Claude summary.'
  select 'haiku'
  map '<leader>cm'
  go()
  hover.hover()
  resolve_lsp()
  assert(vim.list_contains(runs[#runs].command, 'haiku'))
  reply_model 'A Haiku summary.'
end)

test('timeout keeps partial LSP context and ignores late replies', function()
  hover.clear_cache()
  go()
  local calls = #runs
  hover.hover()
  local request = lsp_requests[#lsp_requests]
  reply_lsp(1, { contents = 'Partial documentation.' }, nil, request)
  assert(vim.wait(1000, function()
    return #runs == calls + 1
  end))
  assert(request.cancelled)
  assert(runs[#runs].options.stdin:find('Partial documentation.', 1, true))
  reply_lsp(2, { contents = 'Late documentation.' }, nil, request)
  assert(#runs == calls + 1)
  reply_model 'A summary with partial documentation.'
end)

test('no-LSP fallback, forced regeneration, and superseded requests', function()
  clients = {}
  go()
  hover.hover()
  assert(runs[#runs].options.stdin:find('No LSP hover documentation', 1, true))
  local old_run = #runs
  vim.cmd 'AIHover!'
  assert(runs[old_run].killed and #runs == old_run + 1)
  reply_model('An obsolete summary.', old_run)
  assert(float_text():find('Explaining', 1, true))
  reply_model 'A fresh summary.'
  go()
  vim.cmd 'AIHover'
  assert(#runs == old_run + 1)
  vim.cmd 'AIHoverClearCache'
  hover.hover()
  assert(#runs == old_run + 2)
  reply_model 'A summary after clearing the cache.'
end)

test('stale responses do not replace another symbol hover or enter the cache', function()
  hover.clear_cache()
  go()
  hover.hover()
  local old_run = #runs
  go(1, 23)
  hover.hover()
  reply_model('Old location summary.', old_run)
  assert(float_text():find('`value`', 1, true))
  reply_model 'The value parameter.'
  go()
  hover.hover()
  assert(#runs == old_run + 1, 'completed summary was not cached after moving away')
  vim.cmd 'AIHover!'
  local stale = #runs
  vim.api.nvim_buf_set_lines(source, 1, 2, false, { '  return value * 4' })
  reply_model('Outdated source summary.', stale)
  assert(not vim.b[source].lsp_floating_preview)
  go()
  hover.hover()
  assert(#runs == stale + 1)
  reply_model 'Quadruples the input.'
end)

test('process failures and empty replies can be retried without caching', function()
  hover.clear_cache()
  go()
  fail_start = true
  hover.hover()
  assert(messages[#messages]:find('failed to start Claude', 1, true))
  assert(float_text():find('Could not explain', 1, true))
  local calls = #runs
  hover.hover()
  assert(#runs == calls + 1)
  reply_model('', nil, 1)
  hover.hover()
  assert(#runs == calls + 2)
  reply_model ''
  assert(messages[#messages]:find('no summary', 1, true))
  hover.hover()
  assert(#runs == calls + 3)
  reply_model 'Recovered summary.'
end)

test('focused follow-ups retain LSP/file context and the conversation in the same window', function()
  hover.clear_cache()
  clients = { { id = 1, offset_encoding = 'utf-8' }, { id = 2, offset_encoding = 'utf-16' } }
  go()
  hover.hover()
  resolve_lsp()
  reply_model 'Quadruples the input and returns the result.'
  map 'H'
  local win, lsp_calls = float(), #lsp_requests
  vim.ui.input = function(opts, callback)
    assert(opts.prompt == 'Ask about explain: ')
    callback 'Can you show an example?'
  end
  map '<CR>'
  local run = runs[#runs]
  assert(run.options.stdin:find('Doubles the supplied value.', 1, true))
  assert(run.options.stdin:find('return value * 4', 1, true))
  assert(run.options.stdin:find('<conversation>', 1, true))
  assert(run.options.stdin:find('Quadruples the input and returns the result.', 1, true))
  assert(run.options.stdin:find('Can you show an example?', 1, true))
  assert(#lsp_requests == lsp_calls, 'follow-up re-requested LSP context')
  local calls = #runs
  map '<CR>'
  assert(#runs == calls, 'a second question launched while the first was pending')
  local answer = 'For example:\n```lua\nexplain(3) -- returns 12\n```'
  reply_model(answer)
  assert(float() == win and vim.api.nvim_get_current_win() == win, 'answer replaced the focused window')
  assert(float_text():find('Can you show an example?', 1, true))
  assert(float_text():find('explain(3) -- returns 12', 1, true))
  vim.ui.input = function(_, callback)
    callback 'Does it modify the input?'
  end
  map '<leader>cf'
  assert(runs[#runs].options.stdin:find('Can you show an example?', 1, true))
  assert(runs[#runs].options.stdin:find(answer, 1, true))
  assert(runs[#runs].options.stdin:find('Does it modify the input?', 1, true))
  reply_model 'No. It returns a new number and leaves the input untouched.'
  map 'q'
  go()
  hover.hover()
  assert(#runs == calls + 1, 'cached conversation launched another model')
  assert(float_text():find('Does it modify the input?', 1, true))
  assert(float_text():find('leaves the input untouched', 1, true))
end)

test('cancelled inputs and failed follow-ups retain the successful conversation', function()
  map 'H'
  local calls = #runs
  vim.ui.input = function(_, callback)
    callback(nil)
  end
  map '<CR>'
  vim.ui.input = function(_, callback)
    callback '   '
  end
  map '<leader>cf'
  assert(#runs == calls)
  vim.ui.input = function(_, callback)
    callback 'What about zero?'
  end
  map '<CR>'
  reply_model('', nil, 1)
  assert(float_text():find('Could not answer', 1, true))
  assert(float_text():find('leaves the input untouched', 1, true))
  vim.ui.input = function(opts, callback)
    assert(opts.default == 'What about zero?')
    callback(opts.default)
  end
  map '<CR>'
  assert(not runs[#runs].options.stdin:find('Could not answer', 1, true), 'failed response entered the conversation')
  reply_model 'Zero produces zero.'
  assert(float_text():find('Zero produces zero.', 1, true))
  assert(not float_text():find('Could not answer', 1, true))
end)

test('closed follow-ups are cached without reopening or replacing another symbol', function()
  vim.ui.input = function(_, callback)
    callback 'And negative numbers?'
  end
  map '<CR>'
  local old_run = #runs
  map 'q'
  reply_model 'Negative numbers are multiplied in the same way.'
  assert(not vim.b[source].lsp_floating_preview, 'late follow-up reopened a closed window')
  go()
  hover.hover()
  assert(#runs == old_run)
  assert(float_text():find('Negative numbers are multiplied', 1, true))
  map 'H'
  vim.ui.input = function(_, callback)
    callback 'Is it thread safe?'
  end
  map '<CR>'
  old_run = #runs
  go(1, 23)
  hover.hover()
  reply_model('It has no shared state.', old_run)
  assert(float_text():find('`value`', 1, true), 'follow-up replaced a different symbol hover')
  resolve_lsp()
  reply_model 'The value parameter.'
  go()
  hover.hover()
  assert(float_text():find('It has no shared state.', 1, true))
end)

test('follow-ups use the newly selected model and ignore stale input dialogs', function()
  map 'H'
  select 'sonnet'
  map '<leader>cm'
  vim.ui.input = function(_, callback)
    callback 'Explain the return type.'
  end
  map '<CR>'
  assert(vim.list_contains(runs[#runs].command, 'sonnet'))
  reply_model 'The return type is a number.'
  assert(float_title():find('sonnet', 1, true))
  local submit
  vim.ui.input = function(_, callback)
    submit = callback
  end
  map '<CR>'
  local calls = #runs
  map 'q'
  submit 'This dialog was closed.'
  assert(#runs == calls, 'closed dialog still launched a model')
  clients = {}
end)

test('opening an input immediately after focusing does not dismiss the hover', function()
  go()
  hover.hover()
  reply_model 'A summary for an immediate follow-up.'
  local win, input_win, submit = float()
  vim.ui.input = function(_, callback)
    submit = callback
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = 'wipe'
    input_win = vim.api.nvim_open_win(buf, true, { relative = 'editor', row = 1, col = 1, width = 40, height = 1, style = 'minimal' })
  end
  hover.hover()
  hover.follow_up()
  flush()
  assert(input_win and vim.api.nvim_win_is_valid(win), 'question input dismissed the hover')
  vim.api.nvim_win_close(input_win, true)
  vim.api.nvim_set_current_win(win)
  submit 'Tell me more.'
  reply_model 'More about this symbol.'
  assert(float() == win and float_text():find('More about this symbol.', 1, true))
end)

test('hover leaves the last ask/retry conversation intact', function()
  go()
  vim.ui.input = function(_, callback)
    callback 'Explain this file.'
  end
  map '<leader>ca'
  local ask_prompt = runs[#runs].options.stdin
  reply_model 'A full answer about this file.'
  go()
  hover.hover { force = true }
  reply_model 'A small symbol summary.'
  map '<leader>cr'
  assert(runs[#runs].options.stdin == ask_prompt, 'hover replaced the last ask request')
  reply_model 'A retried full answer.'
end)

test('hover follow-ups refresh references and Enter jumps to code in another file', function()
  hover.clear_cache()
  go()
  hover.hover()
  reply_model 'Calls [`explain`](tests/hover_fixture.lua:1:16).'
  map 'H'
  local asked = 0
  vim.ui.input = function(_, callback)
    asked = asked + 1
    callback 'Where is the related function?'
  end
  map '<leader>cf'
  reply_model 'See [`remote`](tests/fixtures/ai_target.lua:3:16).'
  map '<Tab>'
  map '<S-Tab>'
  local old_ref = vim.api.nvim_win_get_cursor(float())
  assert(old_ref[1] == 1, 'previous reference was not preserved after a follow-up')
  map '<Tab>'
  map '<CR>'
  assert(asked == 1, 'Enter asked a question instead of jumping from a reference')
  assert(vim.api.nvim_get_current_win() == source_win)
  assert(vim.api.nvim_buf_get_name(0) == vim.fs.joinpath(vim.fn.getcwd(), 'tests/fixtures/ai_target.lua'))
  assert(vim.deep_equal(vim.api.nvim_win_get_cursor(0), { 3, 15 }))
  assert(not vim.b[source].lsp_floating_preview)
end)

test('full AI answers use the same reference navigation and reopen after a jump', function()
  go()
  vim.ui.input = function(_, callback)
    callback 'Explain this file.'
  end
  map '<leader>ca'
  reply_model 'Uses [`remote`](tests/fixtures/ai_target.lua:3:16).'
  local answer_win = vim.api.nvim_get_current_win()
  assert(vim.b[vim.api.nvim_win_get_buf(answer_win)].claude_answer)
  map '<Tab>'
  map '<CR>'
  assert(not vim.api.nvim_win_is_valid(answer_win))
  assert(vim.deep_equal(vim.api.nvim_win_get_cursor(0), { 3, 15 }))
  map '<leader>co'
  assert(vim.b[vim.api.nvim_get_current_buf()].claude_answer)
  local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
  assert(text:find('Uses [`remote`]', 1, true))
end)

test('normal ask and follow-up answers navigate file-only and varied citations in the original source window', function()
  go()
  vim.ui.input = function(_, callback)
    callback 'Find the file containing the remote implementation.'
  end
  map '<leader>ca'
  reply_model 'The implementation is in `tests/fixtures/ai_target.lua`.'
  local answer_win = vim.api.nvim_get_current_win()
  map '<Tab>'
  map '<CR>'
  assert(not vim.api.nvim_win_is_valid(answer_win))
  assert(vim.api.nvim_get_current_win() == source_win)
  assert(vim.api.nvim_win_get_cursor(0)[1] == 1)
  map '<leader>co'
  vim.ui.input = function(_, callback)
    callback 'Which line is the function on?'
  end
  map '<leader>cf'
  assert(runs[#runs].options.stdin:find('The implementation is in `tests/fixtures/ai_target.lua`.', 1, true))
  reply_model 'See `tests/fixtures/ai_target.lua#L3-L5`.'
  answer_win = vim.api.nvim_get_current_win()
  map '<Tab>'
  map '<CR>'
  assert(not vim.api.nvim_win_is_valid(answer_win))
  assert(vim.api.nvim_get_current_win() == source_win)
  assert(vim.api.nvim_win_get_cursor(0)[1] == 3)
  assert(#vim.fn.getloclist(source_win) == 2, 'both answer references were not preserved')
end)

test('bounded cache evicts old entries and non-symbol positions do not launch', function()
  hover.clear_cache()
  go()
  hover.hover()
  reply_model 'First symbol.'
  go(1, 23)
  hover.hover()
  reply_model 'Second symbol.'
  go(2, 3)
  hover.hover()
  reply_model 'Third symbol.'
  local calls = #runs
  go()
  hover.hover()
  assert(#runs == calls + 1, 'cache did not evict its oldest entry')
  reply_model 'First symbol again.'
  go(4, 5)
  hover.hover()
  assert(#runs == calls + 1, 'whitespace launched a model')
end)

test('late replies stay dismissed in Insert mode and hover settings can be reapplied', function()
  go()
  hover.hover { force = true }
  local mode = vim.fn.mode
  vim.fn.mode = function()
    return 'i'
  end
  vim.api.nvim_exec_autocmds('InsertEnter', { buffer = source })
  reply_model 'A summary completed during Insert mode.'
  assert(not vim.b[source].lsp_floating_preview, 'late result reopened the hover in Insert mode')
  vim.fn.mode = mode
  plugin.setup { hover = { key = 'Z', cache_size = 0 } }
  assert(vim.fn.maparg('H', 'n') == '' and vim.fn.maparg('Z', 'n') ~= '')
  go()
  local calls = #runs
  map 'Z'
  reply_model 'An uncached summary.'
  go()
  map 'Z'
  assert(#runs == calls + 2, 'cache_size = 0 still reused a summary')
  reply_model 'Another uncached summary.'
  plugin.setup { hover = { key = false } }
  assert(vim.fn.maparg('Z', 'n') == '' and vim.fn.exists ':AIHover' == 2)
end)

print(string.format('%d AI hover scenarios passed.', passed))
vim.cmd 'qa!'
