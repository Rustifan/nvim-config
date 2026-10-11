-- Run with: nvim --headless -u NONE -l tests/ai_references.lua
vim.opt.runtimepath:append(vim.fn.getcwd())
vim.o.hidden = true
local references = require 'ivan.ai_references'
local root = vim.fn.getcwd()
local source_path = 'tests/fixtures/ai_source.lua'
local target_path = 'tests/fixtures/ai_target.lua'
local spaced_path = 'tests/fixtures/ai target with spaces.lua'
local source = vim.fn.bufadd(vim.fs.joinpath(root, source_path))
vim.fn.bufload(source)
local source_win = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_buf(source_win, source)
local context = { buf = source, win = source_win, cwd = root, path = source_path, symbol = 'localDef', row = 5, start_col = 15 }
local clients, requests, messages = {}, {}, {}
local active_win
vim.notify = function(message)
  messages[#messages + 1] = message
end
vim.lsp.get_clients = function(opts)
  return vim.tbl_filter(function(client)
    return client.methods[opts.method] == true
  end, clients)
end
vim.lsp.buf_request = function(buf, method, params, callback)
  local request = { buf = buf, method = method, params = params, callback = callback }
  requests[#requests + 1] = request
  local ids = {}
  for _, client in ipairs(vim.lsp.get_clients { bufnr = buf, method = method }) do
    ids[client.id] = client.id
  end
  return ids, function()
    request.cancelled = true
  end
end

local function flush()
  local done = false
  vim.schedule(function()
    done = true
  end)
  assert(vim.wait(1000, function()
    return done
  end))
end

local function show(lines, options, request)
  if active_win and vim.api.nvim_win_is_valid(active_win) then
    vim.api.nvim_win_close(active_win, true)
  end
  vim.api.nvim_set_current_win(source_win)
  vim.api.nvim_win_set_buf(source_win, source)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  active_win = vim.api.nvim_open_win(buf, true, { relative = 'editor', row = 1, col = 1, width = 70, height = 10, style = 'minimal', border = 'rounded' })
  return references.attach(request or context, buf, active_win, options), buf, active_win
end

local function map(key)
  local mapping = vim.fn.maparg(key, 'n', false, true)
  assert(type(mapping.callback) == 'function', 'missing mapping: ' .. key)
  mapping.callback()
  flush()
end

local function reply(request, result, err)
  request.callback(err, result, { client_id = 1, bufnr = source })
end

local function position(line, character)
  return { start = { line = line, character = character }, ['end'] = { line = line, character = character + 1 } }
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

test('verified Markdown symbol/code links, spaces, anchors, and invalid targets', function()
  local lines = {
    '[`localDef`](' .. source_path .. ':2:16) and [`remote`](' .. target_path .. ':3:16).',
    '[`input[0] > 0`](' .. target_path .. ':4) and [label](' .. spaced_path .. '#L2).',
    '[missing](does/not/exist.lua:1) [bad line](' .. target_path .. ':999) [bad col](' .. target_path .. ':1:999).',
    '[web](https://example.com:42) [zero](' .. source_path .. ':0).',
  }
  local found = references.find(context, lines)
  assert(#found == 4, vim.inspect(found))
  assert(found[1].bufnr == source and found[1].lnum == 2 and found[1].col == 15)
  assert(found[2].filename == vim.fs.joinpath(root, target_path) and found[2].col == 15)
  assert(lines[2]:sub(found[3].start_col + 1, found[3].end_col) == '`input[0] > 0`')
  assert(found[4].filename == vim.fs.joinpath(root, spaced_path) and found[4].lnum == 2)
end)

test('Tab and Shift-Tab wrap, Enter jumps across files and preserves the location list', function()
  local attachment, _, win = show {
    'Use [`localDef`](' .. source_path .. ':2:16), then [`remote`](' .. target_path .. ':3:16).',
  }
  assert(#attachment.references == 2)
  map '<Tab>'
  local first = vim.api.nvim_win_get_cursor(win)
  map '<Tab>'
  local second = vim.api.nvim_win_get_cursor(win)
  assert(second[2] > first[2])
  map '<Tab>'
  assert(vim.deep_equal(vim.api.nvim_win_get_cursor(win), first))
  map '<S-Tab>'
  assert(vim.deep_equal(vim.api.nvim_win_get_cursor(win), second))
  map '<CR>'
  assert(not vim.api.nvim_win_is_valid(win))
  assert(vim.api.nvim_get_current_win() == source_win)
  assert(vim.api.nvim_buf_get_name(0) == vim.fs.joinpath(root, target_path))
  assert(vim.deep_equal(vim.api.nvim_win_get_cursor(0), { 3, 15 }))
  local list = vim.fn.getloclist(source_win, { title = 0, idx = 0, items = 0 })
  assert(list.title == 'AI references' and list.idx == 2 and #list.items == 2)
end)

test('existing path:line citations and named bare-line references still work', function()
  local found = references.find(context, {
    source_path .. ':2:16 defines the function.',
    target_path .. ':3 calls it.',
    'Line 4 in `' .. target_path .. '` returns the result.',
  })
  assert(#found == 3, vim.inspect(found))
  assert(found[1].bufnr == source and found[1].lnum == 2 and found[1].col == 15)
  assert(found[2].lnum == 3 and found[3].lnum == 4)
  assert(found[2].bufnr == found[3].bufnr)
end)

test('file discovery answers work without a line number or an LSP', function()
  local found = references.find(context, {
    'The implementation is in `' .. target_path .. '`.',
    'Open [the implementation](' .. target_path .. ').',
    'The file is ' .. target_path .. '.',
    '`' .. spaced_path .. '` contains the example.',
  })
  assert(#found == 4, vim.inspect(found))
  assert(found[1].lnum == 1 and found[2].lnum == 1 and found[3].lnum == 1)
  assert(found[4].filename == vim.fs.joinpath(root, spaced_path))
end)

test('source-relative paths and common source citation formats are recognized', function()
  local found = references.find(context, {
    '`./ai_target.lua:3:16` and `ai_target.lua#L4-L5`.',
    '`' .. spaced_path .. ':2`.',
    target_path .. ':3-5 and ' .. target_path .. '#L4.',
    '`' .. target_path .. '` (line 3).',
    '[remote](<' .. target_path .. '#L3> "Definition").',
    '[spaces](tests/fixtures/ai%20target%20with%20spaces.lua#L2).',
    '[local file](' .. vim.uri_from_fname(vim.fs.joinpath(root, target_path)) .. '#L3).',
    '[' .. target_path .. ':3].',
    '`' .. target_path .. ':3–5`.',
    '``' .. spaced_path .. ':2``.',
  })
  assert(#found == 12, vim.inspect(found))
  assert(found[1].lnum == 3 and found[1].col == 15)
  assert(found[2].lnum == 4 and found[3].lnum == 2)
  assert(found[6].lnum == 3 and found[7].lnum == 3 and found[8].lnum == 2 and found[9].lnum == 3)
  assert(found[10].lnum == 3 and found[11].lnum == 3 and found[12].lnum == 2 and found[12].start_col == 0)
  local annotation = references.find(context, { '`' .. target_path .. '` at line 3.' })
  assert(#annotation == 1 and annotation[1].lnum == 3)
  assert(annotation[1].start_col == 0, 'the file name was not included in the annotated reference')
end)

test('reference-style, collapsed, and shortcut Markdown links navigate their definitions', function()
  local lines = {
    'Use [`remote`][impl].',
    'Open [config][].',
    'Or [definition].',
    '',
    '[impl]: ' .. target_path .. ':3:16 "Function"',
    '[config]: <' .. spaced_path .. '>',
    '[definition]: ' .. target_path .. '#L4-L5',
  }
  local found = references.find(context, lines)
  assert(#found == 3, vim.inspect(found))
  assert(found[1].row == 0 and found[1].lnum == 3 and found[1].col == 15)
  assert(found[2].row == 1 and found[2].lnum == 1)
  assert(found[3].row == 2 and found[3].lnum == 4)
  local _, _, win = show(lines)
  vim.api.nvim_win_set_cursor(win, { 1, lines[1]:find('[impl]', 1, true) - 1 })
  map '<CR>'
  assert(not vim.api.nvim_win_is_valid(win))
  assert(vim.deep_equal(vim.api.nvim_win_get_cursor(0), { 3, 15 }))
end)

test('invalid citations and explicitly named missing files never fall back to unrelated source lines', function()
  local found = references.find(context, {
    '[bad line](' .. target_path .. ':999).',
    target_path .. ':999 and ' .. source_path .. ':3oops.',
    'Line 2 in `does/not/exist.lua`.',
    '`../fixtures/ai_target.lua:0`.',
  })
  assert(#found == 0, vim.inspect(found))
end)

test('file-only links to an empty file are navigable before the file is loaded', function()
  local path = vim.fs.joinpath(root, 'tests/fixtures/ai_empty.lua')
  assert(#vim.fn.readfile(path) == 0, 'fixture must be an empty file')
  local attachment, _, win = show { '[empty](tests/fixtures/ai_empty.lua)' }
  assert(#attachment.references == 1)
  map '<Tab>'
  map '<CR>'
  assert(not vim.api.nvim_win_is_valid(win))
  assert(vim.api.nvim_buf_get_name(0) == path)
  assert(vim.deep_equal(vim.api.nvim_win_get_cursor(0), { 1, 0 }))
end)

test('file references survive an unloaded or wiped source buffer and a different editor working directory', function()
  local buf = vim.fn.bufadd(vim.fs.joinpath(root, spaced_path))
  vim.fn.bufload(buf)
  local request = { buf = buf, win = source_win, cwd = root, path = spaced_path }
  vim.api.nvim_buf_delete(buf, { unload = true })
  local found = references.find(request, { spaced_path .. ':2' })
  assert(#found == 1 and found[1].lnum == 2, 'an unloaded source buffer masked a valid file reference')
  vim.api.nvim_buf_delete(buf, { force = true })
  vim.api.nvim_win_call(source_win, function()
    vim.cmd.lcd '/tmp/opencode'
  end)
  local attachment, _, win = show({ 'The file is `' .. spaced_path .. '`. Also `./ai_target.lua:3` and `UnavailableSymbol`.' }, nil, request)
  assert(#attachment.references == 2, vim.inspect(attachment.references))
  assert(attachment.references[1].lnum == 1 and attachment.references[2].lnum == 3)
  map '<Tab>'
  map '<Tab>'
  map '<CR>'
  assert(not vim.api.nvim_win_is_valid(win))
  assert(vim.api.nvim_buf_get_name(0) == vim.fs.joinpath(root, target_path))
  vim.cmd.lcd(root)
end)

test('already-resolved references reload targets that are unloaded or wiped before Enter', function()
  local path = vim.fs.joinpath(root, spaced_path)
  local target = vim.fn.bufadd(path)
  vim.fn.bufload(target)
  local attachment, _, win = show { '`' .. spaced_path .. ':2`.' }
  assert(attachment.references[1].bufnr == target)
  vim.api.nvim_buf_delete(target, { unload = true })
  map '<Tab>'
  map '<CR>'
  assert(not vim.api.nvim_win_is_valid(win))
  assert(vim.api.nvim_buf_get_name(0) == path and vim.api.nvim_win_get_cursor(0)[1] == 2)
  attachment, _, win = show { '`' .. spaced_path .. ':2`.' }
  target = attachment.references[1].bufnr
  vim.api.nvim_buf_delete(target, { force = true })
  map '<Tab>'
  map '<CR>'
  assert(not vim.api.nvim_win_is_valid(win))
  assert(vim.api.nvim_buf_get_name(0) == path and vim.api.nvim_win_get_cursor(0)[1] == 2)
end)

test('Enter accepts Markdown delimiters, link destinations, and a single reference on the current answer line', function()
  local line = '- See [`remote`](' .. target_path .. ':3:16).'
  local attachment, _, win = show { line }
  assert(#attachment.references == 1)
  vim.api.nvim_win_set_cursor(win, { 1, line:find('[', 1, true) - 1 })
  map '<CR>'
  assert(not vim.api.nvim_win_is_valid(win), 'Enter on the opening bracket did not jump')
  assert(vim.deep_equal(vim.api.nvim_win_get_cursor(0), { 3, 15 }))
  _, _, win = show { line }
  vim.api.nvim_win_set_cursor(win, { 1, line:find(target_path, 1, true) - 1 })
  map '<CR>'
  assert(not vim.api.nvim_win_is_valid(win), 'Enter on the link destination did not jump')
  _, _, win = show { line }
  map '<CR>'
  assert(not vim.api.nvim_win_is_valid(win), 'Enter on a single-reference answer line did not jump')
end)

test('abbreviated project paths resolve asynchronously and ambiguous filenames stay unresolved', function()
  local attachment, _, win = show { 'The implementation is in `fixtures/nested/ai_discovery.lua:2`.' }
  assert(vim.wait(3000, function()
    return attachment.pending == 0
  end))
  assert(#attachment.references == 1, vim.inspect(attachment.references))
  map '<Tab>'
  map '<CR>'
  assert(not vim.api.nvim_win_is_valid(win))
  assert(vim.api.nvim_buf_get_name(0) == vim.fs.joinpath(root, 'tests/fixtures/nested/ai_discovery.lua'))
  assert(vim.api.nvim_win_get_cursor(0)[1] == 2)
  attachment = show { '`ai_discovery.lua` could refer to either of two files.' }
  assert(vim.wait(3000, function()
    return attachment.pending == 0
  end))
  assert(#attachment.references == 0, 'an ambiguous filename was guessed: ' .. vim.inspect(attachment.references))
end)

test('Tab and Enter pressed before file lookup completes are resumed safely', function()
  local files = require 'ivan.utils.project_files'
  local original = files.list
  local callback
  files.list = function(_, on_result)
    callback = on_result
    return function() end
  end
  local attachment, _, win = show { '- `fixtures/nested/ai_discovery.lua:2` is the implementation.' }
  assert(attachment.pending > 0 and #attachment.references == 0)
  map '<Tab>'
  callback { 'tests/fixtures/nested/ai_discovery.lua' }
  flush()
  assert(vim.api.nvim_win_get_cursor(win)[2] == attachment.references[1].start_col)
  map '<CR>'
  assert(not vim.api.nvim_win_is_valid(win))
  attachment, _, win = show { '- `fixtures/nested/ai_discovery.lua:2` is the implementation.' }
  map '<CR>'
  callback { 'tests/fixtures/nested/ai_discovery.lua' }
  flush()
  assert(not vim.api.nvim_win_is_valid(win), 'early Enter was lost')
  assert(vim.api.nvim_win_get_cursor(0)[1] == 2)
  files.list = original
end)

test('file lookup and deferred navigation cannot replace newer follow-ups or jump after cursor movement', function()
  local files = require 'ivan.utils.project_files'
  local original = files.list
  local callbacks, cancelled = {}, {}
  files.list = function(_, on_result)
    local index = #callbacks + 1
    callbacks[index] = on_result
    return function()
      cancelled[index] = true
    end
  end
  local attachment, buf, win = show { '`fixtures/nested/ai_discovery.lua:2`.', 'Another line.' }
  map '<CR>'
  vim.api.nvim_win_set_cursor(win, { 2, 0 })
  callbacks[1] { 'tests/fixtures/nested/ai_discovery.lua' }
  flush()
  assert(vim.api.nvim_win_is_valid(win), 'late resolution jumped after cursor movement')
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '`unresolved/new.lua`.' })
  references.refresh(attachment)
  local old = #callbacks
  map '<Tab>'
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '[remote](' .. target_path .. ':3).' })
  references.refresh(attachment)
  assert(cancelled[old])
  callbacks[old] { 'tests/fixtures/nested/ai_discovery.lua' }
  flush()
  assert(#attachment.references == 1 and attachment.references[1].lnum == 3)
  assert(vim.api.nvim_win_get_cursor(win)[2] == 0, 'old deferred Tab moved the newer answer')
  files.list = original
end)

test('hovered inline symbols and function calls link to their real buffer without an LSP', function()
  local attachment = show { 'The `localDef(value)` symbol doubles the input.' }
  assert(#attachment.references == 1)
  assert(attachment.references[1].bufnr == source and attachment.references[1].lnum == 5)
  map '<Tab>'
  map '<CR>'
  assert(vim.api.nvim_get_current_buf() == source)
  assert(vim.deep_equal(vim.api.nvim_win_get_cursor(0), { 5, 15 }))
end)

test('LSP document/workspace symbols resolve cross-file mentions and Unicode columns', function()
  clients = { { id = 1, offset_encoding = 'utf-16', methods = { ['textDocument/documentSymbol'] = true, ['workspace/symbol'] = true } } }
  local attachment = show { '`localDef` calls `api.remoteValue`; `clash` is ambiguous.' }
  local document = requests[#requests]
  assert(document.method == 'textDocument/documentSymbol')
  reply(document, { { name = 'Container', range = position(0, 0), children = { { name = 'localDef', selectionRange = position(1, 15) } } } })
  local workspace = {}
  for _, request in ipairs(requests) do
    if request.method == 'workspace/symbol' then
      workspace[request.params.query] = request
    end
  end
  assert(workspace.remoteValue and workspace.clash)
  local target = vim.fs.joinpath(root, target_path)
  local line = vim.fn.readfile(target)[2]
  local byte = line:find('remoteValue', 1, true) - 1
  local character = vim.str_utfindex(line, 'utf-16', byte)
  reply(workspace.remoteValue, {
    { name = 'remoteValue', containerName = 'company/module/internal/api', location = { uri = vim.uri_from_fname(target), range = position(1, character) } },
    { name = 'remoteValue', containerName = 'company/module/internal/other', location = { uri = vim.uri_from_fname(target), range = position(0, 0) } },
  })
  reply(workspace.clash, {
    { name = 'clash', location = { uri = vim.uri_from_fname(target), range = position(0, 0) } },
    { name = 'clash', location = { uri = vim.uri_from_fname(target), range = position(2, 15) } },
  })
  assert(#attachment.references == 2, vim.inspect(attachment.references))
  assert(attachment.references[1].lnum == 2 and attachment.references[1].col == 15, 'document definition did not replace the origin fallback')
  assert(attachment.references[2].lnum == 2 and attachment.references[2].col == byte, 'LSP UTF-16 column was not converted to bytes')
  map '<Tab>'
  map '<Tab>'
  map '<CR>'
  assert(vim.deep_equal(vim.api.nvim_win_get_cursor(0), { 2, byte }))
  clients = {}
end)

test('qualified symbols do not bind to an unrelated same-named symbol in the current file', function()
  clients = { { id = 1, offset_encoding = 'utf-16', methods = { ['textDocument/documentSymbol'] = true, ['workspace/symbol'] = true } } }
  local attachment = show { 'The setting is `api.enabled`.' }
  reply(requests[#requests], { { name = 'enabled', selectionRange = position(0, 6) } })
  local workspace = requests[#requests]
  assert(workspace.method == 'workspace/symbol' and workspace.params.query == 'enabled')
  local target = vim.fs.joinpath(root, target_path)
  reply(workspace, { { name = 'enabled', containerName = 'company/module/api', location = { uri = vim.uri_from_fname(target), range = position(0, 6) } } })
  assert(#attachment.references == 1)
  local reference = attachment.references[1]
  assert((reference.filename or vim.api.nvim_buf_get_name(reference.bufnr)) == target, 'qualified symbol linked to the current-file namesake')
  clients = {}
end)

test('refresh cancels outdated symbol queries and does not accumulate highlights', function()
  clients = { { id = 1, offset_encoding = 'utf-16', methods = { ['textDocument/documentSymbol'] = true } } }
  local attachment, buf = show { 'The `OldName` symbol.' }
  local old = requests[#requests]
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'Now [`remote`](' .. target_path .. ':3).' })
  references.refresh(attachment)
  assert(old.cancelled)
  reply(old, { { name = 'OldName', selectionRange = position(0, 0) } })
  assert(#attachment.references == 1 and attachment.references[1].lnum == 3)
  references.refresh(attachment)
  local marks = vim.api.nvim_buf_get_extmarks(buf, vim.api.nvim_create_namespace 'ivan-ai-references', 0, -1, {})
  assert(#marks == 1)
  clients = {}
end)

test('Enter away from references retains the hover follow-up action', function()
  local asked = false
  show({ 'An explanation without code references.' }, {
    on_missing = function()
      asked = true
    end,
  })
  map '<CR>'
  assert(asked)
  map '<Tab>'
  assert(messages[#messages]:find('no resolved code references', 1, true))
end)

print(string.format('%d AI reference scenarios passed.', passed))
vim.cmd 'qa!'
