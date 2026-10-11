local M = {}
local references = require 'ivan.ai_references'
local lsp = require 'ivan.utils.lsp'
local settings
local cache, cache_order, pending, revisions = {}, {}, {}, {}
local preview
local cache_generation = 0
local method = 'textDocument/hover'
local summary_instruction = 'Briefly explain what this symbol does at the indicated location.'
local context_rules = table.concat({
  'You explain the symbol under the cursor in Neovim, using read-only project tools.',
  'The prompt contains the symbol location, LSP hover documentation, and the current file.',
  'File lines have a line number and tab prefix; those prefixes are not part of the code.',
  'The supplied file is the live Neovim buffer and may have unsaved changes; prefer it over the on-disk version.',
  'Use the LSP documentation and surrounding code to explain what this particular symbol does here.',
  'If necessary, search and read definitions or related files elsewhere in the project with your tools.',
  'Do not guess; state uncertainty briefly when needed.',
  references.prompt_rules,
}, ' ')
local handler = {
  tools = 'Read,Glob,Grep',
  system_prompt = context_rules
    .. ' Return ONLY a very short Markdown summary: 2–3 short sentences, at most 60 words.'
    .. ' Mention the purpose, key inputs or output, and important side effects only when relevant.'
    .. ' No heading, preamble, code block, or lengthy signature.',
}
local follow_up_handler = {
  tools = handler.tools,
  system_prompt = context_rules
    .. ' A <conversation> contains the initial symbol explanation and earlier questions with their answers.'
    .. ' Answer only the newest question in <instruction>, using that conversation as context.'
    .. ' Reply directly and concisely in Markdown; include more detail or code examples when the question asks for them.',
}

local function notify(message, level)
  vim.notify('AI hover: ' .. message, level)
end

local function project_root(buf)
  return vim.fs.root(buf, '.git') or vim.fn.getcwd()
end

local function buffer_versions(root)
  local versions = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local path = vim.api.nvim_buf_get_name(buf)
    if path ~= '' and vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buftype == '' and vim.fs.relpath(root, path) then
      versions[#versions + 1] = { buf, path, vim.api.nvim_buf_get_changedtick(buf) }
    end
  end
  return vim.json.encode(versions)
end

local function hover_clients(buf)
  local ids = vim.tbl_map(function(client)
    return client.id
  end, vim.lsp.get_clients { bufnr = buf, method = method })
  table.sort(ids)
  return ids
end

local function new_context()
  local buf = vim.api.nvim_get_current_buf()
  if vim.bo[buf].buftype ~= '' then
    return nil, 'place the cursor on a symbol in a file'
  end
  local cursor = vim.api.nvim_win_get_cursor(0)
  local line = vim.api.nvim_buf_get_lines(buf, cursor[1] - 1, cursor[1], false)[1] or ''
  local after = vim.fn.matchstr(line:sub(cursor[2] + 1), [[^\k\+]])
  if after == '' then
    return nil, 'place the cursor on a symbol'
  end
  local before = vim.fn.matchstr(line:sub(1, cursor[2]), [[\k*$]])
  local root = project_root(buf)
  local path = vim.api.nvim_buf_get_name(buf)
  local context = {
    buf = buf,
    win = vim.api.nvim_get_current_win(),
    row = cursor[1],
    col = cursor[2],
    start_col = cursor[2] - #before,
    symbol = before .. after,
    line = line,
    path = path,
    cwd = root,
    filetype = vim.bo[buf].filetype,
    tick = vim.api.nvim_buf_get_changedtick(buf),
    versions = buffer_versions(root),
    revision = revisions[root] or 0,
    profile = settings.profile(),
    generation = cache_generation,
    clients = hover_clients(buf),
  }
  context.key = vim.fn.sha256(vim.json.encode {
    context.buf,
    context.path,
    context.cwd,
    context.filetype,
    context.row,
    context.start_col,
    context.symbol,
    context.tick,
    context.versions,
    context.revision,
    context.profile.backend,
    context.profile.model,
    context.profile.thinking,
    context.clients,
    context.generation,
  })
  return context
end

local function is_fresh(context)
  return vim.api.nvim_buf_is_valid(context.buf)
    and vim.api.nvim_buf_get_changedtick(context.buf) == context.tick
    and vim.api.nvim_buf_get_name(context.buf) == context.path
    and buffer_versions(context.cwd) == context.versions
    and (revisions[context.cwd] or 0) == context.revision
    and cache_generation == context.generation
end

local function is_visible(context)
  if vim.fn.mode() ~= 'n' or vim.api.nvim_get_current_win() ~= context.win or vim.api.nvim_get_current_buf() ~= context.buf then
    return false
  end
  local cursor = vim.api.nvim_win_get_cursor(context.win)
  return cursor[1] == context.row
    and cursor[2] >= context.start_col
    and cursor[2] < context.start_col + #context.symbol
    and vim.deep_equal(context.profile, settings.profile())
    and is_fresh(context)
end

local function close_preview()
  if preview and vim.api.nvim_win_is_valid(preview.win) then
    vim.api.nvim_win_close(preview.win, true)
  end
  preview = nil
end

local function dismiss_context(context)
  if preview and preview.key == context.key then
    close_preview()
  end
end

local function conversation_lines(session)
  local lines = vim.split(session.history[1].response, '\n', { plain = true })
  local latest_row = 1
  for index = 2, #session.history do
    local turn = session.history[index]
    vim.list_extend(lines, { '', '> ' .. turn.instruction, '' })
    latest_row = #lines + 1
    vim.list_extend(lines, vim.split(turn.response, '\n', { plain = true }))
  end
  if session.question then
    vim.list_extend(lines, { '', '> ' .. session.question, '', session.error or 'Thinking…' })
    latest_row = #lines
  end
  return lines, latest_row
end

local function preview_title(profile, cached)
  return string.format(' AI · %s · %s%s ', profile.label, profile.model, cached and ' · cached' or '')
end

local function reference_footer(session, resolved)
  if session.busy then
    return ' Thinking… · q close '
  end
  return #resolved > 0 and ' Tab refs · Enter jump · <leader>cf ask ' or ' <CR> ask · q close '
end

local function attach_references(view)
  view.references = references.attach(view.context, view.buf, view.win, {
    on_missing = M.follow_up,
    on_update = function(resolved)
      if not vim.api.nvim_win_is_valid(view.win) then
        return
      end
      vim.api.nvim_win_set_config(view.win, { footer = reference_footer(view.session, resolved), footer_pos = 'center' })
    end,
  })
end

local function show_preview(context, text, ready, cached, session)
  if not is_visible(context) then
    return
  end
  close_preview()
  local title = preview_title(session and session.profile or context.profile, cached)
  local buf, win = vim.lsp.util.open_floating_preview(vim.split(text, '\n', { plain = true }), 'markdown', {
    border = 'rounded',
    title = title,
    max_width = settings.max_width,
    max_height = settings.max_height,
    focus_id = 'ivan-ai-hover',
    focus = false,
    close_events = { 'CursorMoved', 'CursorMovedI', 'InsertEnter' },
  })
  vim.bo[buf].filetype = 'markdown'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].modifiable = false
  vim.wo[win].linebreak = true
  vim.keymap.set('n', '<Esc>', close_preview, { buffer = buf, nowait = true, desc = 'Close AI hover' })
  vim.keymap.set('n', 'q', close_preview, { buffer = buf, nowait = true, desc = 'Close AI hover' })
  vim.keymap.set('n', '<CR>', M.follow_up, { buffer = buf, desc = 'Ask a question about this symbol' })
  vim.keymap.set('n', '<leader>cf', M.follow_up, { buffer = buf, desc = 'AI [F]ollow up about this symbol' })
  if session then
    vim.api.nvim_win_set_config(win, { footer = ' <CR> ask · q close ', footer_pos = 'center' })
  end
  preview = { buf = buf, win = win, key = context.key, source_win = context.win, ready = ready, context = context, session = session }
  if session then
    attach_references(preview)
  end
end

local function touch_cache(key)
  cache_order = vim.tbl_filter(function(other)
    return other ~= key
  end, cache_order)
  cache_order[#cache_order + 1] = key
end

local function remember(key, response)
  if settings.cache_size <= 0 then
    return
  end
  cache[key] = response
  touch_cache(key)
  while #cache_order > settings.cache_size do
    cache[table.remove(cache_order, 1)] = nil
  end
end

local function hover_text(results)
  local parts = {}
  for _, id in ipairs(vim.fn.sort(vim.tbl_keys(results), 'n')) do
    local result = results[id].result
    local contents = result and result.contents
    if type(contents) == 'table' or type(contents) == 'string' then
      local text = table.concat(vim.lsp.util.convert_input_to_markdown_lines(contents), '\n')
      parts[#parts + 1] = vim.trim(text)
    end
  end
  local text = vim.trim(table.concat(parts, '\n\n'))
  return text ~= '' and text or 'No LSP hover documentation is available. Explain from the code and project files.'
end

local function collect_hover(context, callback)
  return lsp.request_all(
    context.buf,
    method,
    function(client)
      return {
        textDocument = { uri = vim.uri_from_bufnr(context.buf) },
        position = { line = context.row - 1, character = vim.str_utfindex(context.line, client.offset_encoding, context.col, false) },
      }
    end,
    settings.lsp_timeout_ms,
    function(results)
      callback(hover_text(results))
    end
  )
end

local function context_prompt(context, hover)
  local lines = vim.api.nvim_buf_get_lines(context.buf, 0, -1, false)
  local numbered = vim
    .iter(lines)
    :enumerate()
    :map(function(index, line)
      return string.format('%d\t%s', index, line)
    end)
    :join '\n'
  local path = vim.fs.relpath(context.cwd, context.path) or context.path
  path = path ~= '' and path or 'untitled'
  return string.format(
    '<symbol name=%q path=%q line="%d" byte_column="%d" />\n\n<lsp_hover>\n%s\n</lsp_hover>\n\n'
      .. '<file path=%q filetype=%q source="live Neovim buffer">\n%s\n</file>\n\n',
    context.symbol,
    path,
    context.row,
    context.col + 1,
    hover,
    path,
    context.filetype,
    numbered
  )
end

local function instruction_block(instruction)
  return string.format('<instruction>\n%s\n</instruction>', instruction)
end

local function conversation_prompt(session, question)
  local turns = vim.tbl_map(function(turn)
    return string.format('<instruction>\n%s\n</instruction>\n<response>\n%s\n</response>\n', turn.instruction, turn.response)
  end, session.history)
  return session.prompt .. '<conversation>\n' .. table.concat(turns) .. '</conversation>\n\n' .. instruction_block(question)
end

local function update_conversation(session)
  if not preview or preview.session ~= session or not vim.api.nvim_win_is_valid(preview.win) then
    return
  end
  local lines, latest_row = conversation_lines(session)
  local width = math.max(1, math.min(settings.max_width, vim.o.columns - 2))
  local height = vim.iter(lines):fold(0, function(total, line)
    return total + math.max(1, math.ceil(vim.fn.strdisplaywidth(line) / width))
  end)
  vim.bo[preview.buf].modifiable = true
  vim.api.nvim_buf_set_lines(preview.buf, 0, -1, false, lines)
  vim.bo[preview.buf].modifiable = false
  vim.api.nvim_win_set_config(preview.win, {
    width = width,
    height = math.max(1, math.min(settings.max_height, vim.o.lines - vim.o.cmdheight - 2, height)),
    title = preview_title(session.profile),
    footer = session.busy and ' Thinking… · q close ' or ' <CR> ask · q close ',
  })
  vim.api.nvim_win_set_cursor(preview.win, { latest_row, 0 })
  vim.api.nvim_win_call(preview.win, function()
    vim.cmd 'normal! zt'
  end)
  references.refresh(preview.references)
end

local function complete(item, response, err)
  local context = item.context
  if pending[context.key] ~= item then
    return
  end
  pending[context.key] = nil
  if not is_fresh(context) then
    return dismiss_context(context)
  end
  if not response or type(response.text) ~= 'string' or vim.trim(response.text) == '' then
    dismiss_context(context)
    show_preview(context, 'Could not explain this symbol. Press the AI hover key to retry.', false)
    return notify(err or 'the model returned no summary', vim.log.levels.ERROR)
  end
  local session = {
    prompt = item.prompt,
    profile = context.profile,
    history = { { instruction = summary_instruction, response = vim.trim(response.text) } },
  }
  remember(context.key, session)
  if not is_visible(context) then
    return dismiss_context(context)
  end
  show_preview(context, session.history[1].response, true, false, session)
end

local function complete_follow_up(item, response, err)
  if pending[item.context.key] ~= item then
    return
  end
  pending[item.context.key] = nil
  local session = item.session
  session.busy = false
  if not is_fresh(item.context) then
    return dismiss_context(item.context)
  end
  if not response or type(response.text) ~= 'string' or vim.trim(response.text) == '' then
    session.error = 'Could not answer. Press Enter to retry this question.'
    update_conversation(session)
    return notify(err or 'the model returned no answer', vim.log.levels.ERROR)
  end
  session.history[#session.history + 1] = { instruction = item.question, response = vim.trim(response.text) }
  session.question, session.error = nil, nil
  session.profile = item.profile
  update_conversation(session)
end

local function ask_follow_up(view, input)
  if not input or vim.trim(input) == '' or preview ~= view or not vim.api.nvim_win_is_valid(view.win) then
    return
  end
  if view.session.busy then
    return notify('a follow-up is already running', vim.log.levels.INFO)
  end
  if not is_fresh(view.context) then
    return notify('the symbol context changed; reopen AI hover for a fresh explanation', vim.log.levels.WARN)
  end
  local session = view.session
  local question = vim.trim(input)
  local item = { context = view.context, session = session, question = question, profile = settings.profile() }
  session.busy, session.question, session.error = true, question, nil
  pending[view.key] = item
  update_conversation(session)
  item.job = settings.generate(follow_up_handler, conversation_prompt(session, question), view.context.cwd, function(response, err)
    complete_follow_up(item, response, err)
  end, item.profile)
end

local function prompt_follow_up(view)
  if preview ~= view or not vim.api.nvim_win_is_valid(view.win) then
    return
  end
  vim.ui.input({ prompt = 'Ask about ' .. view.context.symbol .. ': ', default = view.session.error and view.session.question or nil }, function(input)
    ask_follow_up(view, input)
  end)
end

function M.follow_up()
  local view = preview
  if not view or not view.session or not vim.api.nvim_win_is_valid(view.win) then
    return notify('wait for a symbol explanation before asking a follow-up', vim.log.levels.WARN)
  end
  if view.session.busy then
    return notify('a follow-up is already running', vim.log.levels.INFO)
  end
  -- Neovim's BufLeave check schedules its close check a second time.
  vim.schedule(function()
    vim.schedule(function()
      prompt_follow_up(view)
    end)
  end)
end

local function stop_request(item)
  if item.cancel_hover then
    item.cancel_hover()
  end
  if item.job then
    pcall(item.job.kill, item.job, 15)
  end
  if item.session then
    item.session.busy, item.session.question = false, nil
  end
end

function M.hover(opts)
  opts = opts or {}
  if preview and vim.api.nvim_get_current_win() == preview.win then
    vim.api.nvim_set_current_win(preview.source_win)
    return opts.force and M.hover(opts) or nil
  end
  local context, err = new_context()
  if not context then
    return notify(err, vim.log.levels.WARN)
  end
  if not opts.force and preview and preview.key == context.key and preview.ready and vim.api.nvim_win_is_valid(preview.win) then
    return vim.api.nvim_set_current_win(preview.win)
  end
  if not opts.force and settings.cache_size > 0 and cache[context.key] then
    touch_cache(context.key)
    local session = cache[context.key]
    return show_preview(context, table.concat(conversation_lines(session), '\n'), true, true, session)
  end
  if opts.force and pending[context.key] then
    local item = pending[context.key]
    pending[context.key] = nil
    stop_request(item)
  end
  if opts.force then
    cache[context.key] = nil
  end
  show_preview(context, 'Explaining `' .. context.symbol .. '`…', false)
  if pending[context.key] then
    pending[context.key].context = context
    return
  end
  local item = { context = context }
  pending[context.key] = item
  item.cancel_hover = collect_hover(context, function(hover)
    if pending[context.key] ~= item then
      return
    end
    if not is_fresh(context) then
      pending[context.key] = nil
      return dismiss_context(context)
    end
    item.prompt = context_prompt(context, hover)
    item.job = settings.generate(handler, item.prompt .. instruction_block(summary_instruction), context.cwd, function(response, failure)
      complete(item, response, failure)
    end, context.profile)
  end)
end

function M.clear_cache()
  cache, cache_order = {}, {}
  cache_generation = cache_generation + 1
  close_preview()
end

function M.setup(opts)
  if settings and settings.key and settings.key ~= '' and vim.fn.maparg(settings.key, 'n', false, true).callback == M.hover then
    vim.keymap.del('n', settings.key)
  end
  settings = vim.tbl_extend('force', { key = 'H', max_width = 72, max_height = 12, lsp_timeout_ms = 1500, cache_size = 128 }, opts)
  if settings.key and settings.key ~= '' then
    vim.keymap.set('n', settings.key, M.hover, { desc = 'AI [H]over: explain symbol' })
  end
  vim.api.nvim_create_user_command('AIHover', function(args)
    M.hover { force = args.bang }
  end, { bang = true, desc = 'Explain the symbol with AI (! regenerates)' })
  vim.api.nvim_create_user_command('AIHoverClearCache', M.clear_cache, { desc = 'Clear session AI hover summaries' })
  local group = vim.api.nvim_create_augroup('ivan-ai-hover', { clear = true })
  vim.api.nvim_create_autocmd({ 'BufWritePost', 'FileChangedShellPost' }, {
    group = group,
    callback = function(args)
      local root = project_root(args.buf)
      revisions[root] = (revisions[root] or 0) + 1
    end,
  })
  vim.api.nvim_create_autocmd('VimLeavePre', {
    group = group,
    callback = function()
      for _, item in pairs(pending) do
        stop_request(item)
      end
      pending = {}
    end,
  })
end

return M
