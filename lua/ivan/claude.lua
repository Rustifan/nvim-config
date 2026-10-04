local data_file = vim.fn.stdpath 'data' .. '/claude_edit.json'
local models = { 'haiku', 'sonnet', 'opus', 'fable' }
local default_model = 'sonnet'
local thinking_effort = 'high'
local namespace = vim.api.nvim_create_namespace 'ivan-claude'
local pending_hl = 'DiffChange'
local reference_hl = 'Underlined'
local path_char_pattern = '[%w_%.%-/~@+]'
local path_token_pattern = '()(' .. path_char_pattern .. '+)'
local path_continues_pattern = '^%.?[%w_%-/]'
local line_suffix_pattern = '^:(%d+)()'
local bare_line_pattern = '()[Ll]ines? (%d+)()'
local named_file_pattern = '^%s+[io][fn]%s+[`*_]*()'
local border_size = 2
local location_list_title = 'Claude references'

local read_tools = 'Read,Glob,Grep'

local function sentences(...)
  return vim.iter({ ... }):flatten():join ' '
end

local style_rules = {
  'Keep the language of the original, whether it is a natural or a programming language.',
  'Preserve indentation and the surrounding style.',
}

local rewrite_system_prompt = sentences(
  'You are an editing engine inside Neovim.',
  'You receive a <selection> from a file, optionally the whole <file> for context, and an <instruction>.',
  'Apply the instruction to the selection and reply with ONLY the text that replaces the selection:',
  'no explanations, no preamble, no markdown code fences.',
  style_rules,
  'If the instruction cannot be applied, return the selection unchanged.',
  'A <conversation> may hold earlier instructions for this selection with your responses;',
  'the selection region now contains your latest response and your reply replaces it.'
)

local edit_system_prompt = sentences(
  'You are an editing engine inside Neovim with read-only tools for the project.',
  'You receive a <selection> from a file, optionally the whole <file> for context, and an <instruction>.',
  'Put the text that replaces the selection in replacement, without explanations or markdown code fences.',
  style_rules,
  'When the instruction needs changes outside the selection, such as moving code to another file or updating callers and imports,',
  'read the files you need and add one file_edits entry per change.',
  'path is relative to the working directory or absolute;',
  'find is an exact snippet of the current file content that occurs exactly once, or empty to append to the file or create it;',
  'replace is the new text for that snippet. Never use file_edits for the selection itself.',
  'If the instruction cannot be applied, return the selection unchanged and no file_edits.',
  'A <conversation> may hold earlier instructions with your responses. The selection region now contains your latest replacement,',
  'and earlier file_edits are undone before yours are applied, so write file_edits against the original files.'
)

local edit_schema = vim.json.encode {
  type = 'object',
  properties = {
    replacement = { type = 'string' },
    file_edits = {
      type = 'array',
      items = {
        type = 'object',
        properties = { path = { type = 'string' }, find = { type = 'string' }, replace = { type = 'string' } },
        required = { 'path', 'find', 'replace' },
      },
    },
  },
  required = { 'replacement', 'file_edits' },
}

local ask_system_prompt = sentences(
  'You are a helpful assistant inside Neovim with read-only tools for the project.',
  'You receive a <selection> from a file, optionally the whole <file> for context, and a question in <instruction>.',
  'Every line is prefixed with its line number and a tab; that prefix is not part of the content.',
  'When the answer depends on code you were not given, such as definitions, callers or configuration elsewhere,',
  'search and read the project files with your tools.',
  'Whenever you refer to a specific place, cite it as path:line (for example src/app.lua:42), never as a bare line number:',
  'for the given file use the path exactly as in the path attribute, for other files the path relative to the working directory.',
  'Answer the question directly and concisely in Markdown.',
  'A <conversation> may hold earlier questions with your answers; <instruction> is the follow-up to answer.'
)

local prettify_instruction = sentences(
  'Make this better.',
  'For prose: fix grammar, spelling and punctuation, improve clarity and flow,',
  'and make it sound polished and professional while keeping the meaning, the language and roughly the length.',
  'For code: improve readability and naming without changing behaviour.'
)

local function notify(message, level)
  vim.notify('Claude: ' .. message, level)
end

local function read_preferences()
  if vim.fn.filereadable(data_file) == 0 then
    return {}
  end
  local ok, data = pcall(vim.json.decode, table.concat(vim.fn.readfile(data_file), '\n'))
  return ok and type(data) == 'table' and data or {}
end

local preferences = read_preferences()

local state = {
  model = vim.tbl_contains(models, preferences.model) and preferences.model or default_model,
  thinking = preferences.thinking == true,
  last_request = nil,
  last_exchange = nil,
  last_answer = nil,
  applied = nil,
}

local function save_preferences()
  vim.fn.writefile({ vim.json.encode { model = state.model, thinking = state.thinking } }, data_file)
end

local function split_lines(text)
  return vim.split(text, '\n', { plain = true })
end

local function without_final_newline(text)
  return (text:gsub('\n$', ''))
end

local function line_text(buf, row)
  return vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ''
end

local function whole_buffer_range(buf)
  local last_row = vim.api.nvim_buf_line_count(buf) - 1
  return { start_row = 0, start_col = 0, end_row = last_row, end_col = #line_text(buf, last_row) }
end

local function charwise_end_col(line, mark_col)
  if mark_col >= #line then
    return #line
  end
  return mark_col + 1 + vim.str_utf_end(line, mark_col + 1)
end

local function linewise_range(buf, start_row, end_row)
  if end_row + 1 < vim.api.nvim_buf_line_count(buf) then
    return { start_row = start_row, start_col = 0, end_row = end_row + 1, end_col = 0 }
  end
  return { start_row = start_row, start_col = 0, end_row = end_row, end_col = #line_text(buf, end_row) }
end

local function selection_range(buf, mode)
  vim.cmd('normal! ' .. vim.keycode '<Esc>')
  local start_mark = vim.api.nvim_buf_get_mark(buf, '<')
  local end_mark = vim.api.nvim_buf_get_mark(buf, '>')
  local start_row, end_row = start_mark[1] - 1, end_mark[1] - 1
  if mode ~= 'v' then
    return linewise_range(buf, start_row, end_row)
  end
  local end_col = charwise_end_col(line_text(buf, end_row), end_mark[2])
  return { start_row = start_row, start_col = start_mark[2], end_row = end_row, end_col = end_col }
end

local function current_range(buf)
  local mode = vim.fn.mode()
  if mode:match '^[vV\22]' then
    return selection_range(buf, mode)
  end
  return whole_buffer_range(buf)
end

local function range_text(buf, range)
  local lines = vim.api.nvim_buf_get_text(buf, range.start_row, range.start_col, range.end_row, range.end_col, {})
  return table.concat(lines, '\n')
end

local function place_mark(buf, range, mark_id, hl_group)
  return vim.api.nvim_buf_set_extmark(buf, namespace, range.start_row, range.start_col, {
    id = mark_id,
    end_row = range.end_row,
    end_col = range.end_col,
    hl_group = hl_group,
  })
end

-- redo can leave an extmark's end before its start, still spanning the re-inserted text
local function ordered_range(start_row, start_col, end_row, end_col)
  if end_row < start_row or (end_row == start_row and end_col < start_col) then
    return { start_row = end_row, start_col = end_col, end_row = start_row, end_col = start_col }
  end
  return { start_row = start_row, start_col = start_col, end_row = end_row, end_col = end_col }
end

local function mark_range(buf, mark_id)
  local mark = vim.api.nvim_buf_get_extmark_by_id(buf, namespace, mark_id, { details = true })
  if #mark == 0 then
    return nil
  end
  return ordered_range(mark[1], mark[2], mark[3].end_row, mark[3].end_col)
end

local function request_range(request)
  if not vim.api.nvim_buf_is_valid(request.buf) then
    return nil
  end
  return mark_range(request.buf, request.mark_id)
end

local function set_mark_highlight(request, hl_group)
  local range = request_range(request)
  if not range then
    return
  end
  place_mark(request.buf, range, request.mark_id, hl_group)
end

local function display_path(path)
  if path == '' then
    return 'untitled'
  end
  return vim.fn.fnamemodify(path, ':~:.')
end

local function project_root(buf)
  return vim.fs.root(buf, '.git') or vim.fn.getcwd()
end

local function prompt_path(path, root)
  if path == '' then
    return display_path(path)
  end
  return vim.fs.relpath(root, path) or display_path(path)
end

local function path_aliases(path, root)
  local display = display_path(path)
  local aliases = vim
    .iter({ prompt_path(path, root), display, path, vim.fs.basename(display) })
    :filter(function(alias)
      return alias ~= ''
    end)
    :totable()
  table.sort(aliases, function(a, b)
    return #a > #b
  end)
  return aliases
end

local function new_request(buf, range, kind, instruction)
  local path = vim.api.nvim_buf_get_name(buf)
  local filetype = vim.bo[buf].filetype
  local whole_buffer = whole_buffer_range(buf)
  local text = range_text(buf, range)
  local selection = without_final_newline(text)
  local root = project_root(buf)
  return {
    kind = kind,
    buf = buf,
    win = vim.api.nvim_get_current_win(),
    instruction = instruction,
    selection = selection,
    ends_with_newline = selection ~= text,
    buffer_text = range_text(buf, whole_buffer),
    is_whole_buffer = vim.deep_equal(range, whole_buffer),
    path = prompt_path(path, root),
    path_aliases = path_aliases(path, root),
    filetype = filetype ~= '' and filetype or 'text',
    first_line = range.start_row + 1,
    last_line = range.start_row + #split_lines(selection),
    cwd = root,
    mark_id = place_mark(buf, range),
    history = {},
  }
end

local function numbered_lines(text, first_line)
  return vim
    .iter(split_lines(text))
    :enumerate()
    :map(function(index, line)
      return string.format('%d\t%s', first_line + index - 1, line)
    end)
    :join '\n'
end

local function prompt_body(text, first_line, is_numbered)
  if not is_numbered then
    return text
  end
  return numbered_lines(text, first_line)
end

local function file_context(request, is_numbered)
  if request.is_whole_buffer then
    return ''
  end
  local body = prompt_body(request.buffer_text, 1, is_numbered)
  return string.format('<file path="%s" filetype="%s">\n%s\n</file>\n\n', request.path, request.filetype, body)
end

local function selection_block(request, is_numbered)
  local body = prompt_body(request.selection, request.first_line, is_numbered)
  local attributes = string.format('path="%s" filetype="%s" lines="%d-%d"', request.path, request.filetype, request.first_line, request.last_line)
  return string.format('<selection %s>\n%s\n</selection>\n\n', attributes, body)
end

local function turn_block(turn)
  return string.format('<instruction>\n%s\n</instruction>\n<response>\n%s\n</response>\n', turn.instruction, turn.response)
end

local function conversation_block(history)
  if #history == 0 then
    return ''
  end
  return string.format('<conversation>\n%s</conversation>\n\n', vim.iter(history):map(turn_block):join '')
end

local function build_prompt(request, is_numbered)
  return table.concat {
    file_context(request, is_numbered),
    selection_block(request, is_numbered),
    conversation_block(request.history),
    string.format('<instruction>\n%s\n</instruction>', request.instruction),
  }
end

local function turns(exchange)
  local latest = { instruction = exchange.request.instruction, response = exchange.text }
  return vim.iter({ exchange.request.history, { latest } }):flatten():totable()
end

local function follow_up_request(exchange, instruction)
  return vim.tbl_extend('force', exchange.request, { history = turns(exchange), instruction = instruction })
end

local function thinking_flags(thinking)
  if not thinking then
    return {}
  end
  return { '--effort', thinking_effort, '--thinking-display', 'summarized' }
end

local function schema_flags(schema)
  if not schema then
    return {}
  end
  return { '--json-schema', schema }
end

-- without the MCP/skill/hook/thinking opt-outs each call ships ~100k tokens, fires the alarm Stop hook and takes 10x longer
local function claude_command(handler, model, thinking)
  local settings = vim.json.encode { disableAllHooks = true, alwaysThinkingEnabled = thinking }
  local base = {
    'claude',
    '-p',
    '--model',
    model,
    '--output-format',
    'stream-json',
    '--verbose',
    '--system-prompt',
    handler.system_prompt,
    '--tools',
    handler.tools or '',
    '--strict-mcp-config',
    '--disable-slash-commands',
    '--no-session-persistence',
    '--settings',
    settings,
  }
  return vim.iter({ base, schema_flags(handler.schema), thinking_flags(thinking) }):flatten():totable()
end

local function failure_message(result)
  local output = vim.trim(result.stderr ~= '' and result.stderr or result.stdout)
  return output ~= '' and output or 'claude exited with code ' .. result.code
end

local function decode_events(stdout)
  return vim
    .iter(split_lines(stdout))
    :map(function(line)
      local ok, event = pcall(vim.json.decode, line)
      return ok and type(event) == 'table' and event or nil
    end)
    :totable()
end

local function thinking_text(events)
  local thoughts = vim
    .iter(events)
    :filter(function(event)
      return event.type == 'assistant'
    end)
    :map(function(event)
      local content = vim.tbl_get(event, 'message', 'content')
      return type(content) == 'table' and content or nil
    end)
    :flatten()
    :filter(function(block)
      return type(block) == 'table' and block.type == 'thinking' and type(block.thinking) == 'string' and block.thinking ~= ''
    end)
    :map(function(block)
      return block.thinking
    end)
    :totable()
  return #thoughts > 0 and table.concat(thoughts, '\n\n') or nil
end

local function parse_response(result)
  local events = decode_events(result.stdout)
  local response = vim.iter(events):find(function(event)
    return event.type == 'result'
  end)
  if not response then
    return nil, failure_message(result)
  end
  if response.is_error or type(response.result) ~= 'string' then
    return nil, tostring(response.result or response.subtype or failure_message(result))
  end
  return { text = response.result, structured = response.structured_output, thoughts = thinking_text(events) }
end

local function join_hints(groups)
  return vim.iter(groups):flatten():join ' · '
end

local function thinking_hints(exchange)
  return exchange.thoughts and { '<leader>cw thinking' } or {}
end

local function strip_code_fence(text, original)
  if vim.startswith(vim.trim(original), '```') then
    return text
  end
  return text:match '^%s*```[^\n]*\n(.-)\n?```%s*$' or text
end

local function inserted_range(range, lines)
  local end_row = range.start_row + #lines - 1
  local end_col = #lines == 1 and range.start_col + #lines[1] or #lines[#lines]
  return { start_row = range.start_row, start_col = range.start_col, end_row = end_row, end_col = end_col }
end

local function replace_marked(buf, mark_id, lines)
  local range = mark_range(buf, mark_id)
  if not range then
    return
  end
  vim.api.nvim_buf_set_text(buf, range.start_row, range.start_col, range.end_row, range.end_col, lines)
  place_mark(buf, inserted_range(range, lines), mark_id)
end

local function replacement_lines(request, text)
  local replacement = strip_code_fence(text, request.selection):gsub('%s+$', '')
  local keeps_line_break = request.ends_with_newline and replacement ~= ''
  return split_lines(keeps_line_break and replacement .. '\n' or replacement)
end

local function done_message(exchange, changed_files)
  local changed = #changed_files > 0 and ', also changed ' .. table.concat(changed_files, ', ') .. ' (unsaved)' or ''
  return string.format('done%s (%s)', changed, join_hints { { '<leader>cr retry', '<leader>cf refine' }, thinking_hints(exchange), { 'u undo' } })
end

local function apply_rewrite(exchange)
  local request = exchange.request
  if not request_range(request) then
    return notify('the edited region no longer exists', vim.log.levels.WARN)
  end
  replace_marked(request.buf, request.mark_id, replacement_lines(request, exchange.text))
  notify(done_message(exchange, {}))
end

local function load_buffer(path)
  local buf = vim.fn.bufadd(path)
  vim.fn.bufload(buf)
  return buf
end

local function absolute_path(request, path)
  local normalized = vim.fs.normalize(path)
  if vim.startswith(normalized, '/') then
    return normalized
  end
  return vim.fs.normalize(vim.fs.joinpath(request.cwd, normalized))
end

local function position_at(text, offset)
  local before = text:sub(1, offset - 1)
  local last_newline = before:match '.*()\n'
  return select(2, before:gsub('\n', '')), last_newline and #before - last_newline or #before
end

local function point_range(row, col)
  return { start_row = row, start_col = col, end_row = row, end_col = col }
end

local function unique_start(text, snippet)
  local start = text:find(snippet, 1, true)
  if not start then
    return nil, 'was not found'
  end
  if text:find(snippet, start + 1, true) then
    return nil, 'is not unique'
  end
  return start
end

local function append_change(text, _, replace)
  local separator = text == '' and '' or '\n'
  return { range = point_range(position_at(text, #text + 1)), text = separator .. without_final_newline(replace) }
end

-- buffers have no final newline but file snippets from Read do, so match against the text as it is on disk
local function snippet_change(text, find, replace)
  local file_text = text .. '\n'
  local start, problem = unique_start(file_text, find)
  if not start then
    return nil, problem
  end
  local finish = start + #find
  local start_row, start_col = position_at(text, start)
  local end_row, end_col = position_at(text, math.min(finish, #text + 1))
  local range = { start_row = start_row, start_col = start_col, end_row = end_row, end_col = end_col }
  return { range = range, text = finish > #file_text and without_final_newline(replace) or replace }
end

local function resolve_edit(request, edit)
  local path = absolute_path(request, edit.path)
  local buf = load_buffer(path)
  local change_for = edit.find == '' and append_change or snippet_change
  local change, problem = change_for(range_text(buf, whole_buffer_range(buf)), edit.find, edit.replace)
  if not change then
    return { problem = string.format('the text to replace in %s %s', display_path(path), problem) }
  end
  return {
    buf = buf,
    path = path,
    range = change.range,
    lines = split_lines(change.text),
    original = range_text(buf, change.range),
  }
end

local function resolve_edits(request, file_edits)
  return vim.tbl_map(function(edit)
    return resolve_edit(request, edit)
  end, type(file_edits) == 'table' and file_edits or {})
end

local function mark_file_edits(resolved)
  return vim.tbl_map(function(edit)
    return vim.tbl_extend('force', edit, { mark_id = place_mark(edit.buf, edit.range) })
  end, resolved)
end

local function apply_file_edits(marked)
  vim.iter(marked):each(function(edit)
    vim.bo[edit.buf].buflisted = true
    replace_marked(edit.buf, edit.mark_id, edit.lines)
  end)
end

local function is_still_applied(edit)
  local range = vim.api.nvim_buf_is_valid(edit.buf) and mark_range(edit.buf, edit.mark_id)
  return range and range_text(edit.buf, range) == table.concat(edit.lines, '\n')
end

local function revert_file_edits(request)
  if not state.applied or state.applied.request ~= request then
    return
  end
  vim.iter(state.applied.edits):rev():filter(is_still_applied):each(function(edit)
    replace_marked(edit.buf, edit.mark_id, split_lines(edit.original))
  end)
  state.applied = nil
end

local function other_files(request, edits)
  local paths = vim
    .iter(edits)
    :filter(function(edit)
      return edit.buf ~= request.buf
    end)
    :map(function(edit)
      return display_path(edit.path)
    end)
    :totable()
  return vim.fn.uniq(vim.fn.sort(paths))
end

local function edit_problems(resolved)
  return vim
    .iter(resolved)
    :map(function(edit)
      return edit.problem
    end)
    :totable()
end

local function apply_edit(exchange)
  local request, result = exchange.request, exchange.structured
  if type(result) ~= 'table' or type(result.replacement) ~= 'string' then
    return notify('Claude returned no edit (<leader>cr to retry)', vim.log.levels.ERROR)
  end
  if not request_range(request) then
    return notify('the edited region no longer exists', vim.log.levels.WARN)
  end
  local resolved = resolve_edits(request, result.file_edits)
  local problems = edit_problems(resolved)
  if #problems > 0 then
    return notify('nothing changed: ' .. table.concat(problems, '; ') .. ' (<leader>cr to retry)', vim.log.levels.ERROR)
  end
  local marked = mark_file_edits(resolved)
  replace_marked(request.buf, request.mark_id, replacement_lines(request, result.replacement))
  apply_file_edits(marked)
  state.applied = { request = request, edits = marked }
  notify(done_message(exchange, other_files(request, marked)))
end

local function is_after(position, row, col)
  return position.row > row or (position.row == row and position.start_col > col)
end

local function is_before(position, row, col)
  return position.row < row or (position.row == row and position.start_col < col)
end

local function by_position(a, b)
  return is_before(a, b.row, b.start_col)
end

local function readable_file(request, path)
  local file = absolute_path(request, path)
  return vim.fn.filereadable(file) == 1 and file or nil
end

local function request_buffer(request)
  return vim.api.nvim_buf_is_valid(request.buf) and { bufnr = request.buf } or nil
end

local function file_target(request, path)
  local file = readable_file(request, path)
  if not file then
    return nil
  end
  return vim.list_contains(request.path_aliases, file) and request_buffer(request) or { filename = file }
end

local function new_mention(target, row, line, start_col, path_end)
  local line_number, suffix_end = line:sub(path_end):match(line_suffix_pattern)
  return {
    target = target,
    row = row,
    start_col = start_col,
    path_end = path_end,
    line_number = line_number,
    end_col = suffix_end and path_end + suffix_end - 1,
  }
end

local function is_standalone(line, start_col, path_end)
  local char_before = line:sub(start_col - 1, start_col - 1)
  return not char_before:match(path_char_pattern) and not line:sub(path_end):match(path_continues_pattern)
end

local function alias_mentions(request, row, line)
  local target = request_buffer(request)
  if not target then
    return {}
  end
  return vim
    .iter(request.path_aliases)
    :map(function(alias)
      return vim
        .iter(line:gmatch('()' .. vim.pesc(alias) .. '()'))
        :filter(function(start_col, path_end)
          return is_standalone(line, start_col, path_end)
        end)
        :map(function(start_col, path_end)
          return new_mention(target, row, line, start_col, path_end)
        end)
        :totable()
    end)
    :flatten()
    :totable()
end

local function token_mention(request, row, line, start_col, token)
  local path = token:gsub('%.+$', '')
  local target = path:find '[/.]' and file_target(request, path)
  if not target then
    return nil
  end
  return new_mention(target, row, line, start_col, start_col + #path)
end

local function token_mentions(request, row, line)
  return vim
    .iter(line:gmatch(path_token_pattern))
    :map(function(start_col, token)
      return token_mention(request, row, line, start_col, token)
    end)
    :totable()
end

local function overlaps(a, b)
  return a.row == b.row and a.start_col < b.path_end and b.start_col < a.path_end
end

local function add_unless_overlapping(kept, mention)
  local is_taken = vim.iter(kept):any(function(other)
    return overlaps(other, mention)
  end)
  return is_taken and kept or vim.list_extend({ mention }, kept)
end

local function line_mentions(request, row, line)
  local candidates = vim.list_extend(alias_mentions(request, row, line), token_mentions(request, row, line))
  local mentions = vim.iter(candidates):fold({}, add_unless_overlapping)
  table.sort(mentions, by_position)
  return mentions
end

local function is_line_in_buffer(buf, lnum)
  return lnum >= 1 and lnum <= vim.api.nvim_buf_line_count(buf)
end

local function new_reference(target, row, line, start_col, end_col, line_number)
  local lnum = tonumber(line_number)
  if target.bufnr and not is_line_in_buffer(target.bufnr, lnum) then
    return nil
  end
  return vim.tbl_extend('force', target, {
    row = row,
    start_col = start_col - 1,
    end_col = end_col - 1,
    lnum = lnum,
    text = vim.trim(line),
  })
end

local function citation_reference(lines, mention)
  if not mention.line_number then
    return nil
  end
  return new_reference(mention.target, mention.row, lines[mention.row + 1], mention.start_col, mention.end_col, mention.line_number)
end

local function named_mention(mentions, row, line, end_col)
  local offset = line:sub(end_col):match(named_file_pattern)
  local col = offset and end_col + offset - 1
  return vim.iter(mentions):find(function(mention)
    return mention.row == row and mention.start_col == col
  end)
end

local function preceding_mention(mentions, row, col)
  return vim.iter(mentions):rev():find(function(mention)
    return is_before(mention, row, col)
  end)
end

local function bare_line_target(request, mentions, row, line, start_col, end_col)
  local mention = named_mention(mentions, row, line, end_col) or preceding_mention(mentions, row, start_col)
  return mention and mention.target or request_buffer(request)
end

local function bare_line_references(request, mentions, row, line)
  return vim
    .iter(line:gmatch(bare_line_pattern))
    :map(function(start_col, line_number, end_col)
      local target = bare_line_target(request, mentions, row, line, start_col, end_col)
      if not target then
        return nil
      end
      return new_reference(target, row, line, start_col, end_col, line_number)
    end)
    :totable()
end

local function same_place(a, b)
  return a.row == b.row and a.lnum == b.lnum and a.bufnr == b.bufnr and a.filename == b.filename
end

local function without_repeats(references, citations)
  return vim
    .iter(references)
    :filter(function(reference)
      return not vim.iter(citations):any(function(citation)
        return same_place(citation, reference)
      end)
    end)
    :totable()
end

local function flat_map_lines(lines, fn)
  return vim
    .iter(lines)
    :enumerate()
    :map(function(index, line)
      return fn(index - 1, line)
    end)
    :flatten()
    :totable()
end

local function find_references(request, lines)
  local mentions = flat_map_lines(lines, function(row, line)
    return line_mentions(request, row, line)
  end)
  local citations = vim
    .iter(mentions)
    :map(function(mention)
      return citation_reference(lines, mention)
    end)
    :totable()
  local bare = flat_map_lines(lines, function(row, line)
    return bare_line_references(request, mentions, row, line)
  end)
  local references = vim.list_extend(without_repeats(bare, citations), citations)
  table.sort(references, by_position)
  return vim
    .iter(references)
    :enumerate()
    :map(function(index, reference)
      return vim.tbl_extend('force', reference, { index = index })
    end)
    :totable()
end

local function contains_cursor(reference, row, col)
  return reference.row == row and col >= reference.start_col and col < reference.end_col
end

local function next_reference(references, row, col)
  return vim.iter(references):find(function(reference)
    return is_after(reference, row, col)
  end) or references[1]
end

local function previous_reference(references, row, col)
  return vim.iter(references):rev():find(function(reference)
    return is_before(reference, row, col)
  end) or references[#references]
end

local function reference_at(references, row, col)
  return vim.iter(references):find(function(reference)
    return contains_cursor(reference, row, col)
  end)
end

local function location_item(reference)
  return { bufnr = reference.bufnr, filename = reference.filename, lnum = reference.lnum, text = reference.text }
end

local function has_claude_list(win)
  return vim.fn.getloclist(win, { title = 0 }).title == location_list_title
end

local function set_location_list(request, references)
  if #references == 0 or not vim.api.nvim_win_is_valid(request.win) then
    return
  end
  local items = vim.tbl_map(location_item, references)
  vim.fn.setloclist(request.win, {}, has_claude_list(request.win) and 'r' or ' ', { title = location_list_title, items = items })
end

local function sync_location_list(request, reference)
  if not has_claude_list(request.win) then
    return
  end
  vim.fn.setloclist(request.win, {}, 'a', { idx = reference.index })
end

local function highlight_references(buf, references)
  vim.iter(references):each(function(reference)
    vim.api.nvim_buf_set_extmark(buf, namespace, reference.row, reference.start_col, { end_col = reference.end_col, hl_group = reference_hl })
  end)
end

local function move_to_reference(win, reference)
  vim.api.nvim_win_set_cursor(win, { reference.row + 1, reference.start_col })
end

local function reference_buffer(reference)
  if reference.bufnr then
    return vim.api.nvim_buf_is_valid(reference.bufnr) and reference.bufnr or nil
  end
  if vim.fn.filereadable(reference.filename) == 0 then
    return nil
  end
  return load_buffer(reference.filename)
end

local function jump_problem(request, reference, buf)
  if not vim.api.nvim_win_is_valid(request.win) then
    return 'the window you asked from is gone'
  end
  if not buf then
    return 'the referenced file no longer exists'
  end
  if not is_line_in_buffer(buf, reference.lnum) then
    return string.format('line %d is past the end of the file', reference.lnum)
  end
  return nil
end

local function jump_to_reference(request, reference, float_win)
  local buf = reference_buffer(reference)
  local problem = jump_problem(request, reference, buf)
  if problem then
    return notify(problem, vim.log.levels.WARN)
  end
  move_to_reference(float_win, reference)
  vim.api.nvim_win_close(float_win, true)
  vim.api.nvim_set_current_win(request.win)
  vim.cmd "normal! m'"
  vim.bo[buf].buflisted = true
  vim.api.nvim_win_set_buf(request.win, buf)
  vim.api.nvim_win_set_cursor(request.win, { reference.lnum, 0 })
  vim.cmd 'normal! zvzz'
  sync_location_list(request, reference)
end

local function missing_reference_message(references)
  if #references == 0 then
    return 'this answer has no file references'
  end
  return 'the cursor is not on a reference (<Tab> moves to the next one)'
end

local function attach_references(request, buf, win, references)
  local function on_reference(pick, action)
    return function()
      local cursor = vim.api.nvim_win_get_cursor(win)
      local reference = pick(references, cursor[1] - 1, cursor[2])
      if not reference then
        return notify(missing_reference_message(references), vim.log.levels.WARN)
      end
      action(reference)
    end
  end
  local function map(lhs, pick, action, desc)
    vim.keymap.set('n', lhs, on_reference(pick, action), { buffer = buf, desc = desc })
  end
  local function move(reference)
    move_to_reference(win, reference)
  end

  set_location_list(request, references)
  highlight_references(buf, references)
  map('<CR>', reference_at, function(reference)
    jump_to_reference(request, reference, win)
  end, 'Jump to Claude reference')
  map('<Tab>', next_reference, move, 'Next Claude reference')
  map('<S-Tab>', previous_reference, move, 'Previous Claude reference')
end

local function answer_footer(answer, references)
  local reference_hints = #references > 0 and { '<CR> jump', '<Tab> next ref', ']l [l after jump' } or {}
  return ' '
    .. join_hints {
      reference_hints,
      { '<leader>cf follow up' },
      thinking_hints(answer),
      { '<leader>co reopen', '<leader>cr retry' },
    }
    .. ' '
end

local function open_float(lines, title, footer)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = 'markdown'
  vim.bo[buf].bufhidden = 'wipe'

  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    width = math.max(1, vim.o.columns - border_size),
    height = math.max(1, vim.o.lines - vim.o.cmdheight - border_size),
    row = 0,
    col = 0,
    style = 'minimal',
    border = 'rounded',
    title = title,
    title_pos = 'center',
    footer = footer,
    footer_pos = 'center',
  })
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  return buf, win
end

local function remember_view(answer, win)
  vim.api.nvim_create_autocmd('WinClosed', {
    pattern = tostring(win),
    once = true,
    callback = function()
      answer.view = vim.api.nvim_win_call(win, vim.fn.winsaveview)
    end,
  })
end

local function open_answer(answer)
  local references = find_references(answer.request, answer.lines)
  local buf, win = open_float(answer.lines, ' Claude · ' .. answer.model .. ' ', answer_footer(answer, references))
  vim.b[buf].claude_answer = true
  vim.api.nvim_win_call(win, function()
    vim.fn.winrestview(answer.view)
  end)
  remember_view(answer, win)
  attach_references(answer.request, buf, win, references)
end

local function answer_windows()
  return vim.tbl_filter(function(win)
    return vim.b[vim.api.nvim_win_get_buf(win)].claude_answer == true
  end, vim.api.nvim_list_wins())
end

local function turn_lines(turn)
  local question = vim.tbl_map(function(line)
    return '> ' .. line
  end, split_lines(turn.instruction))
  return vim.iter({ question, { '' }, split_lines(turn.response), { '' } }):flatten():totable()
end

local function thread_lines(exchange)
  local blocks = vim.tbl_map(turn_lines, turns(exchange))
  local lines = vim.iter(blocks):flatten():totable()
  return lines, #lines - #blocks[#blocks] + 1
end

local function close_answer_windows()
  vim.iter(answer_windows()):each(function(win)
    vim.api.nvim_win_close(win, true)
  end)
end

local function show_answer(exchange)
  close_answer_windows()
  local lines, latest_row = thread_lines(exchange)
  state.last_answer = vim.tbl_extend('force', exchange, { lines = lines, view = { lnum = latest_row, col = 0, topline = latest_row } })
  open_answer(state.last_answer)
end

local function reopen_answer()
  local open_window = answer_windows()[1]
  if open_window then
    return vim.api.nvim_set_current_win(open_window)
  end
  if not state.last_answer then
    return notify('no answer to reopen yet', vim.log.levels.WARN)
  end
  open_answer(state.last_answer)
end

local handlers = {
  rewrite = {
    system_prompt = rewrite_system_prompt,
    on_result = apply_rewrite,
    label = 'editing',
    numbered = false,
    follow_up_prompt = 'Claude refine edit: ',
  },
  edit = {
    system_prompt = edit_system_prompt,
    on_result = apply_edit,
    label = 'editing',
    numbered = false,
    follow_up_prompt = 'Claude refine edit: ',
    tools = read_tools,
    schema = edit_schema,
  },
  ask = {
    system_prompt = ask_system_prompt,
    on_result = show_answer,
    label = 'asking',
    numbered = true,
    follow_up_prompt = 'Claude follow-up: ',
    tools = read_tools,
  },
}

local function run(request)
  local handler = handlers[request.kind]
  local model, thinking = state.model, state.thinking
  state.last_request = request
  set_mark_highlight(request, pending_hl)
  notify(string.format('%s with %s%s…', handler.label, model, thinking and ' + thinking' or ''))

  local on_exit = vim.schedule_wrap(function(result)
    set_mark_highlight(request, nil)
    local response, err = parse_response(result)
    if not response then
      return notify(err, vim.log.levels.ERROR)
    end
    state.last_exchange = vim.tbl_extend('force', response, { request = request, thinking = thinking, model = model })
    handler.on_result(state.last_exchange)
  end)

  local started, err = pcall(vim.system, claude_command(handler, model, thinking), {
    stdin = build_prompt(request, handler.numbered),
    cwd = request.cwd,
    text = true,
  }, on_exit)
  if started then
    return
  end
  set_mark_highlight(request, nil)
  notify('failed to start claude: ' .. tostring(err), vim.log.levels.ERROR)
end

local function ask_input(prompt, on_input)
  vim.ui.input({ prompt = prompt }, function(input)
    if not input or vim.trim(input) == '' then
      return
    end
    on_input(input)
  end)
end

local function on_current_range(action)
  return function()
    local buf = vim.api.nvim_get_current_buf()
    action(buf, current_range(buf))
  end
end

local function prettify(buf, range)
  run(new_request(buf, range, 'rewrite', prettify_instruction))
end

local function prompted(kind, prompt)
  return function(buf, range)
    ask_input(prompt, function(input)
      run(new_request(buf, range, kind, input))
    end)
  end
end

local function retry()
  if not state.last_request then
    return notify('nothing to retry yet', vim.log.levels.WARN)
  end
  revert_file_edits(state.last_request)
  run(state.last_request)
end

local function current_exchange()
  if vim.b.claude_answer then
    return state.last_answer
  end
  return state.last_exchange
end

local function follow_up()
  local exchange = current_exchange()
  if not exchange then
    return notify('nothing to follow up on yet', vim.log.levels.WARN)
  end
  ask_input(handlers[exchange.request.kind].follow_up_prompt, function(input)
    revert_file_edits(exchange.request)
    run(follow_up_request(exchange, input))
  end)
end

local function thinking_problem(exchange)
  if not exchange then
    return 'nothing has run yet'
  end
  if not exchange.thinking then
    return 'thinking was off for this result (<leader>ct turns it on, <leader>cr reruns)'
  end
  if not exchange.thoughts then
    return 'Claude did not need to think for this one'
  end
  return nil
end

local function show_thinking()
  local exchange = current_exchange()
  local problem = thinking_problem(exchange)
  if problem then
    return notify(problem, vim.log.levels.WARN)
  end
  open_float(split_lines(exchange.thoughts), ' Claude thinking · ' .. exchange.model .. ' ', ' :q back ')
end

local function toggle_thinking()
  state.thinking = not state.thinking
  save_preferences()
  notify(state.thinking and 'thinking on: slower, <leader>cw shows it after a result' or 'thinking off')
end

local function select_model()
  vim.ui.select(models, {
    prompt = 'Claude model',
    format_item = function(model)
      return model == state.model and model .. ' (current)' or model
    end,
  }, function(model)
    if not model then
      return
    end
    state.model = model
    save_preferences()
    notify('model set to ' .. model)
  end)
end

local function setup()
  vim.keymap.set({ 'n', 'v' }, '<leader>cp', on_current_range(prettify), { desc = '[C]laude [P]rettify selection or file' })
  vim.keymap.set({ 'n', 'v' }, '<leader>ce', on_current_range(prompted('edit', 'Claude edit: ')), { desc = '[C]laude [E]dit with prompt' })
  vim.keymap.set({ 'n', 'v' }, '<leader>ca', on_current_range(prompted('ask', 'Ask Claude: ')), { desc = '[C]laude [A]sk about selection or file' })
  vim.keymap.set('n', '<leader>cr', retry, { desc = '[C]laude [R]etry last request' })
  vim.keymap.set('n', '<leader>cf', follow_up, { desc = '[C]laude [F]ollow up on the last answer or edit' })
  vim.keymap.set('n', '<leader>cw', show_thinking, { desc = '[C]laude [W]hy: show thinking behind the last result' })
  vim.keymap.set('n', '<leader>ct', toggle_thinking, { desc = '[C]laude [T]hinking on/off' })
  vim.keymap.set('n', '<leader>co', reopen_answer, { desc = '[C]laude re[O]pen last answer' })
  vim.keymap.set('n', '<leader>cm', select_model, { desc = '[C]laude select [M]odel' })
end

return { setup = setup }
