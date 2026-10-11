local M = {}
local lsp = require 'ivan.utils.lsp'
local project_files = require 'ivan.utils.project_files'
local namespace = vim.api.nvim_create_namespace 'ivan-ai-references'
local location_list_title = 'AI references'
local path_char_pattern = '[%w_%.%-/~@+%%]'
local path_token_pattern = '()([%w_%.%-/~@+%%:#]+)()'
local named_file_pattern = '^%s+[io][fn]%s+[`*_]*()'
local markdown_link_pattern = '()(%b[])%s*(%b())()'
local inline_code_pattern = '()(`+)([^`]+)%2()'
local resume_navigation

M.prompt_rules = table.concat({
  'Make verified code references navigable with Markdown links, for example [`validate`](src/check.go:42)',
  'or [`value > 0`](src/check.go:18:5); destinations are path:line or path:line:byte-column, with 1-based numbers.',
  'Use short symbol or code labels and project-relative paths, or the supplied file path.',
  'Link actual definitions or relevant source lines you verified in the supplied file or with your tools, never invented locations.',
  'When finding a file, always include a navigable link to its full project-relative path; a file-only link such as [config](src/config.lua) is valid.',
}, ' ')

local function notify(message, level)
  vim.notify('AI: ' .. message, level or vim.log.levels.WARN)
end

local function absolute_path(context, path)
  local normalized = vim.fs.normalize(path)
  return vim.startswith(normalized, '/') and normalized or vim.fs.normalize(vim.fs.joinpath(context.cwd, normalized))
end

local function normalize_context(request)
  local path = vim.api.nvim_buf_is_valid(request.buf) and vim.api.nvim_buf_get_name(request.buf) or request.source_path or request.path
  path = path or ''
  path = path ~= '' and absolute_path(request, path) or path
  local aliases = { request.path or '', path, vim.fn.fnamemodify(path, ':~:.'), vim.fs.basename(path), vim.fs.relpath(request.cwd, path) or '' }
  aliases = vim.tbl_filter(function(alias)
    return alias ~= ''
  end, aliases)
  table.sort(aliases, function(a, b)
    return #a > #b
  end)
  return vim.tbl_extend('force', request, { source_path = path, path_aliases = request.path_aliases or aliases, path_cache = {}, missing_paths = {} })
end

local function existing_file(file)
  local buf = vim.fn.bufnr(file)
  if buf >= 0 and vim.api.nvim_buf_is_loaded(buf) then
    return { bufnr = buf, filename = file }
  end
  return vim.fn.filereadable(file) == 1 and { filename = file } or nil
end

local function local_path(path)
  if path:match '^file://' then
    local ok, file = pcall(vim.uri_to_fname, path)
    return ok and file or nil
  end
  if path:match '^%a[%w+%.%-]*://' then
    return nil
  end
  return path
end

local function unique_file(context, path)
  if not context.files then
    return nil
  end
  local matches = {}
  for _, file in ipairs(context.files or {}) do
    local normalized = vim.fs.normalize(file)
    if normalized == path or vim.endswith(normalized, '/' .. path) then
      matches[absolute_path(context, normalized)] = true
    end
  end
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local file = vim.api.nvim_buf_get_name(buf)
    if vim.api.nvim_buf_is_loaded(buf) and vim.fs.relpath(context.cwd, file) and vim.endswith(file, '/' .. path) then
      matches[file] = true
    end
  end
  return vim.tbl_count(matches) == 1 and existing_file(next(matches)) or nil
end

local function resolve_file(context, path)
  local normalized = vim.fs.normalize(path)
  local target = existing_file(absolute_path(context, normalized))
  if target or vim.startswith(normalized, '/') then
    return target
  end
  local directory = vim.fs.dirname(context.source_path)
  local relative = directory and existing_file(vim.fs.normalize(vim.fs.joinpath(directory, normalized)))
  if relative then
    return relative
  end
  return unique_file(context, normalized:gsub('^%./', ''))
end

local function file_target(context, path)
  path = local_path(path)
  if not path or path == '' then
    return nil
  end
  if context.path_cache[path] ~= nil then
    return context.path_cache[path] or nil
  end
  local decoded = path:gsub('%%(%x%x)', function(hex)
    return string.char(tonumber(hex, 16))
  end)
  local target = resolve_file(context, path) or decoded ~= path and resolve_file(context, decoded) or nil
  context.path_cache[path] = target or false
  if not target and (path:find '/' or path:match '%.[%l%d_-]+$') then
    context.missing_paths[decoded] = true
  end
  return target
end

local function target_line(target, lnum)
  if lnum < 1 then
    return nil
  end
  if target.bufnr then
    return vim.api.nvim_buf_is_valid(target.bufnr) and vim.api.nvim_buf_get_lines(target.bufnr, lnum - 1, lnum, false)[1] or nil
  end
  local ok, lines = pcall(vim.fn.readfile, target.filename, '', lnum)
  return ok and (lines[lnum] or lnum == 1 and #lines == 0 and '') or nil
end

local function new_reference(target, row, line, start_col, end_col, line_number, column)
  local lnum = tonumber(line_number)
  local source = target and lnum and target_line(target, lnum)
  local column_number = tonumber(column) or 1
  if not source or column_number < 1 or column_number > #source + 1 then
    return nil
  end
  local col = column_number - 1
  return vim.tbl_extend('force', target, {
    row = row,
    start_col = start_col - 1,
    end_col = end_col - 1,
    lnum = lnum,
    col = col,
    text = vim.trim(line),
  })
end

local function location_suffix(suffix)
  suffix = suffix:gsub('–', '-'):gsub('—', '-')
  local number, column = suffix:match '^:(%d+):(%d+)$'
  if number then
    return number, column
  end
  number, column = suffix:match '^:(%d+):(%d+)%-%d+:%d+$'
  if number then
    return number, column
  end
  number, column = suffix:match '^#[Ll](%d+)C(%d+)[%-LlC%d]*$'
  if number then
    return number, column
  end
  return suffix:match '^:(%d+)$' or suffix:match '^:(%d+)%-%d+$' or suffix:match '^#[Ll](%d+)$' or suffix:match '^#[Ll](%d+)%-[Ll]?%d+$'
end

local function location_parts(value)
  local path, suffix = value:match '^(.-)(#[Ll]%d.*)$'
  if not path then
    path, suffix = value:match '^(.-)(:%d.*)$'
  end
  if not path then
    return value, 1
  end
  local number, column = location_suffix(suffix)
  return path, number, column
end

local function new_mention(target, row, line, start_col, path_end)
  local suffix = (line:sub(path_end):match '^([:#][^%s`"\'%(%[%]%),;]+)' or ''):gsub('%.+$', '')
  local number, column = location_suffix(suffix)
  local annotation = line:sub(path_end):match '^([`"\'%s,%(:]*[Ll]ines?%s+%d+)' or line:sub(path_end):match '^([`"\'%s,%(:]*[Aa][Tt]%s+[Ll]ines?%s+%d+)'
  local annotated = annotation and annotation:match '(%d+)$'
  return {
    target = target,
    row = row,
    start_col = start_col,
    path_end = path_end,
    line_number = suffix == '' and (annotated or 1) or number,
    column = column,
    explicit = suffix ~= '' or annotated ~= nil,
    end_col = path_end + #(annotation or suffix),
  }
end

local function is_standalone(line, start_col, path_end)
  return not line:sub(start_col - 1, start_col - 1):match(path_char_pattern) and not line:sub(path_end):match '^%.?[%w_%-/]'
end

local function alias_mentions(context, row, line)
  local target = vim.api.nvim_buf_is_loaded(context.buf) and { bufnr = context.buf, filename = context.source_path } or existing_file(context.source_path)
  if not target then
    return {}
  end
  return vim
    .iter(context.path_aliases)
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

local function token_mentions(context, row, line)
  return vim
    .iter(line:gmatch(path_token_pattern))
    :map(function(start_col, token)
      local path = location_parts(token:gsub('%.+$', ''))
      local target = path:find '[/.]' and file_target(context, path)
      return target and new_mention(target, row, line, start_col, start_col + #path) or nil
    end)
    :totable()
end

local function quoted_mention(context, row, line, start_col, value, end_col, value_start)
  local text = vim.trim(value)
  local path, number, column = location_parts(text)
  local target = file_target(context, path)
  if not target then
    return nil
  end
  local offset = value:find(text, 1, true)
  local mention = new_mention(target, row, line, start_col, (value_start or start_col + 1) + offset - 1 + #path)
  mention.end_col = math.max(mention.end_col, end_col)
  mention.line_number = text == path and mention.line_number or number
  mention.column = column
  return mention
end

local function quoted_mentions(context, row, line)
  local code = vim
    .iter(line:gmatch(inline_code_pattern))
    :map(function(start_col, fence, value, end_col)
      return quoted_mention(context, row, line, start_col, value, end_col, start_col + #fence)
    end)
    :totable()
  local quoted = vim
    .iter(line:gmatch '()(["\'])(.-)%2()')
    :map(function(start_col, _, value, end_col)
      return quoted_mention(context, row, line, start_col, value, end_col)
    end)
    :totable()
  return vim.list_extend(code, quoted)
end

local function overlaps(a, b)
  return a.row == b.row and a.start_col < b.end_col and b.start_col < a.end_col
end

local function mention_overlaps(a, b)
  return a.row == b.row and a.start_col < b.path_end and b.start_col < a.path_end
end

local function line_mentions(context, row, line)
  local candidates =
    vim.list_extend(vim.list_extend(quoted_mentions(context, row, line), alias_mentions(context, row, line)), token_mentions(context, row, line))
  return vim.iter(candidates):fold({}, function(kept, mention)
    local taken = vim.iter(kept):any(function(other)
      return mention_overlaps(other, mention)
    end)
    return taken and kept or vim.list_extend({ mention }, kept)
  end)
end

local function is_before(a, row, col)
  return a.row < row or (a.row == row and a.start_col < col)
end

local function by_position(a, b)
  return is_before(a, b.row, b.start_col)
end

local function bare_line_target(context, mentions, row, line, start_col, end_col)
  local offset = line:sub(end_col):match(named_file_pattern)
  local col = offset and end_col + offset - 1
  local named = vim.iter(mentions):find(function(mention)
    return mention.row == row and col and col >= mention.start_col and col < mention.end_col
  end)
  if col then
    return named and named.target or nil, named
  end
  local preceding = vim.iter(mentions):rev():find(function(mention)
    return is_before(mention, row, start_col)
  end)
  return (named or preceding or {}).target or { bufnr = context.buf }, named
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

local function bare_line_references(context, mentions, row, line)
  return vim
    .iter(line:gmatch '()[Ll]ines? (%d+)()')
    :map(function(start_col, number, end_col)
      local target, named = bare_line_target(context, mentions, row, line, start_col, end_col)
      return new_reference(target, row, line, start_col, named and named.end_col or end_col, number)
    end)
    :totable()
end

local function link_destination(destination)
  local value = vim.trim(destination)
  local angled = value:match '^<([^>]+)>'
  value = angled or value:gsub('%s+["\'].-["\']%s*$', '')
  return location_parts(value)
end

local function label_key(label)
  return vim.trim(label:sub(2, -2)):lower():gsub('%s+', ' ')
end

local function link_definitions(lines)
  local definitions, spans = {}, {}
  for index, line in ipairs(lines) do
    local label, destination = line:match '^%s*(%b[]):%s*(.+)$'
    if label then
      definitions[label_key(label)] = definitions[label_key(label)] or destination
      spans[#spans + 1] = { row = index - 1, start_col = 0, end_col = #line }
    end
  end
  return definitions, spans
end

local function link_span(link)
  return { row = link.row, start_col = link.start_col - 1, end_col = link.end_col - 1 }
end

local function markdown_links(row, line, definitions)
  local links = vim
    .iter(line:gmatch(markdown_link_pattern))
    :map(function(start_col, label, destination, end_col)
      return { row = row, line = line, start_col = start_col, end_col = end_col, label = label, destination = destination:sub(2, -2) }
    end)
    :totable()
  local styled = vim
    .iter(line:gmatch '()(%b[])%s*(%b[])()')
    :map(function(start_col, label, id, end_col)
      local key = id == '[]' and label_key(label) or label_key(id)
      local destination = definitions[key]
      return destination and { row = row, line = line, start_col = start_col, end_col = end_col, label = label, destination = destination } or nil
    end)
    :totable()
  vim.list_extend(links, styled)
  local short = vim
    .iter(line:gmatch '()(%b[])()')
    :map(function(start_col, label, end_col)
      local taken = vim.iter(links):any(function(link)
        return start_col >= link.start_col and start_col < link.end_col
      end)
      local destination = not taken and definitions[label_key(label)] or nil
      return destination and { row = row, line = line, start_col = start_col, end_col = end_col, label = label, destination = destination } or nil
    end)
    :totable()
  return vim.list_extend(links, short)
end

local function markdown_reference(context, link)
  local path, lnum, col = link_destination(link.destination)
  local target = path and file_target(context, path) or nil
  local reference = new_reference(target, link.row, link.line, link.start_col + 1, link.start_col + #link.label - 1, lnum, col)
  return reference and vim.tbl_extend('force', reference, { hit_start = link.start_col - 1, hit_end = link.end_col - 1 }) or nil
end

local function without_overlaps(references, primary)
  return vim
    .iter(references)
    :filter(function(reference)
      return not vim.iter(primary):any(function(other)
        return overlaps(reference, other)
      end)
    end)
    :totable()
end

local function indexed(references)
  table.sort(references, by_position)
  return vim
    .iter(references)
    :enumerate()
    :map(function(index, reference)
      return vim.tbl_extend('force', reference, { index = index })
    end)
    :totable()
end

local function without_markup(row, line, spans)
  for _, span in ipairs(spans) do
    if span.row == row then
      line = line:sub(1, span.start_col) .. string.rep(' ', span.end_col - span.start_col) .. line:sub(span.end_col + 1)
    end
  end
  return line
end

function M.find(request, lines)
  local context = normalize_context(request)
  local definitions, destinations = link_definitions(lines)
  local markup = flat_map_lines(lines, function(row, line)
    if line:match '^%s*%b[]:%s*' then
      return {}
    end
    return markdown_links(row, line, definitions)
  end)
  local links = vim
    .iter(markup)
    :map(function(link)
      return markdown_reference(context, link)
    end)
    :totable()
  vim.list_extend(destinations, vim.tbl_map(link_span, markup))
  local mentions = flat_map_lines(lines, function(row, line)
    return line_mentions(context, row, without_markup(row, line, destinations))
  end)
  table.sort(mentions, by_position)
  local citations = vim
    .iter(mentions)
    :map(function(mention)
      if not mention.line_number then
        return nil
      end
      local reference =
        new_reference(mention.target, mention.row, lines[mention.row + 1], mention.start_col, mention.end_col, mention.line_number, mention.column)
      return reference and vim.tbl_extend('force', reference, { explicit = mention.explicit }) or nil
    end)
    :totable()
  local bare = flat_map_lines(lines, function(row, line)
    return bare_line_references(context, mentions, row, line)
  end)
  -- Link labels take precedence over their printed destinations and inferred mentions.
  local explicit = vim.tbl_filter(function(reference)
    return reference.explicit
  end, citations)
  local inferred = without_overlaps(bare, vim.list_extend(vim.deepcopy(destinations), explicit))
  local direct = without_overlaps(citations, vim.list_extend(vim.deepcopy(destinations), inferred))
  return indexed(vim.list_extend(vim.list_extend(links, direct), inferred)), context.missing_paths, destinations
end

local function inline_mentions(lines, references)
  return flat_map_lines(lines, function(row, line)
    return vim
      .iter(line:gmatch(inline_code_pattern))
      :map(function(start_col, fence, text, end_col)
        local symbol = vim.trim(text):gsub('%b()$', '')
        local mention = {
          row = row,
          start_col = start_col + #fence - 1,
          end_col = end_col - #fence - 1,
          hit_start = start_col - 1,
          hit_end = end_col - 1,
          symbol = symbol,
          text = vim.trim(line),
        }
        local taken = vim.iter(references):any(function(reference)
          return overlaps(mention, reference)
        end)
        return not taken and symbol:match '^[%a_$][%w_$%.:]*$' and mention or nil
      end)
      :totable()
  end)
end

local function source_target(context, symbol)
  if context.symbol ~= symbol or not context.row or not target_line({ bufnr = context.buf }, context.row) then
    return nil
  end
  return { bufnr = context.buf, filename = context.source_path, lnum = context.row, col = context.start_col or context.col or 0 }
end

local function symbol_candidates(items, uri, encoding, parent)
  if type(items) ~= 'table' then
    return {}
  end
  local candidates = {}
  for _, item in ipairs(items) do
    local location = item.location or { uri = uri, range = item.selectionRange or item.range }
    local container = item.containerName or parent
    local qualified = container and container .. '.' .. item.name or item.name
    candidates[#candidates + 1] = {
      name = item.name,
      qualified = qualified,
      location = location,
      encoding = encoding,
    }
    vim.list_extend(candidates, symbol_candidates(item.children, uri, encoding, qualified))
  end
  return candidates
end

local function response_candidates(results, uri)
  return vim
    .iter(vim.tbl_values(results))
    :map(function(response)
      return symbol_candidates(response.result, uri, response.encoding)
    end)
    :flatten()
    :totable()
end

local function qualified_match(qualified, name)
  if qualified == name then
    return true
  end
  if not qualified or not vim.endswith(qualified, name) then
    return false
  end
  local boundary = #qualified - #name
  return qualified:sub(boundary, boundary):match '[/%.:]' ~= nil
end

local function symbol_score(candidate, name)
  if candidate.name == name or qualified_match(candidate.qualified, name) then
    return 2
  end
  local leaf = name:match '([^%.:]+)$'
  local candidate_leaf = (candidate.name or ''):match '([^%.:]+)$'
  return candidate_leaf == leaf and 1 or 0
end

local function consider_candidate(best, candidate, name)
  local value = symbol_score(candidate, name)
  local location = candidate.location
  local range = location and location.range
  if value == 0 or not range or not location.uri then
    return best
  end
  local key = location.uri .. ':' .. range.start.line .. ':' .. range.start.character
  if value > best.score then
    return { candidate = candidate, score = value, places = { [key] = true } }
  end
  if value < best.score then
    return best
  end
  return vim.tbl_extend('force', best, { places = vim.tbl_extend('force', best.places, { [key] = true }) })
end

local function unique_candidate(candidates, name, exact)
  local best = vim.iter(candidates):fold({ score = 0, places = {} }, function(kept, candidate)
    return consider_candidate(kept, candidate, name)
  end)
  return vim.tbl_count(best.places) == 1 and (not exact or best.score == 2) and best.candidate or nil
end

local function candidate_target(context, candidate)
  if not candidate or not candidate.location.uri:match '^file://' then
    return nil
  end
  local target = file_target(context, vim.uri_to_fname(candidate.location.uri))
  local position = candidate.location.range.start
  local line = target and target_line(target, position.line + 1)
  if not line then
    return nil
  end
  local col = vim.str_byteindex(line, candidate.encoding or 'utf-16', position.character, false)
  return vim.tbl_extend('force', target, { lnum = position.line + 1, col = col })
end

local function has_ai_list(win)
  return vim.fn.getloclist(win, { title = 0 }).title == location_list_title
end

local function set_location_list(context, references)
  if not vim.api.nvim_win_is_valid(context.win) or (#references == 0 and not has_ai_list(context.win)) then
    return
  end
  local items = vim.tbl_map(function(reference)
    return { bufnr = reference.bufnr, filename = reference.filename, lnum = reference.lnum, col = reference.col + 1, text = reference.text }
  end, references)
  vim.fn.setloclist(context.win, {}, has_ai_list(context.win) and 'r' or ' ', { title = location_list_title, items = items })
end

local function apply_references(attachment)
  local symbols = vim
    .iter(attachment.mentions)
    :map(function(mention)
      local target = attachment.symbols[mention.symbol] or source_target(attachment.context, mention.symbol)
      return target and vim.tbl_extend('force', mention, target) or nil
    end)
    :totable()
  attachment.references = indexed(vim.list_extend(vim.deepcopy(attachment.direct), symbols))
  vim.api.nvim_buf_clear_namespace(attachment.buf, namespace, 0, -1)
  for _, reference in ipairs(attachment.references) do
    vim.api.nvim_buf_set_extmark(attachment.buf, namespace, reference.row, reference.start_col, { end_col = reference.end_col, hl_group = 'Underlined' })
  end
  set_location_list(attachment.context, attachment.references)
  if attachment.options.on_update then
    attachment.options.on_update(attachment.references)
  end
  resume_navigation(attachment)
end

local function is_current(attachment, token)
  return attachment.token == token
    and vim.api.nvim_buf_is_valid(attachment.buf)
    and vim.api.nvim_win_is_valid(attachment.win)
    and vim.api.nvim_buf_get_changedtick(attachment.buf) == attachment.tick
end

local function resolve_workspace(attachment, token, names)
  for _, name in ipairs(names) do
    attachment.pending = attachment.pending + 1
    local cancel = lsp.request_all(attachment.context.buf, 'workspace/symbol', { query = name:match '([^%.:]+)$' }, 1000, function(results)
      if not is_current(attachment, token) then
        return
      end
      attachment.symbols[name] = candidate_target(attachment.context, unique_candidate(response_candidates(results), name))
      attachment.pending = attachment.pending - 1
      apply_references(attachment)
    end)
    attachment.cancellations[#attachment.cancellations + 1] = cancel
  end
end

local function resolve_paths(attachment, token, lines, missing)
  if vim.tbl_isempty(missing) then
    return
  end
  attachment.pending = attachment.pending + 1
  local cancel = project_files.list(attachment.context.cwd, function(files)
    if not is_current(attachment, token) then
      return
    end
    attachment.context.files = files
    attachment.context.path_cache = {}
    local _, protected
    attachment.direct, _, protected = M.find(attachment.context, lines)
    attachment.mentions = inline_mentions(lines, vim.list_extend(vim.deepcopy(attachment.direct), protected))
    attachment.pending = attachment.pending - 1
    apply_references(attachment)
  end)
  attachment.cancellations[#attachment.cancellations + 1] = cancel
end

function M.refresh(attachment)
  for _, cancel in ipairs(attachment.cancellations) do
    cancel()
  end
  attachment.token, attachment.cancellations, attachment.symbols = {}, {}, {}
  attachment.pending, attachment.waiting = 0, nil
  attachment.tick = vim.api.nvim_buf_get_changedtick(attachment.buf)
  local lines = vim.api.nvim_buf_get_lines(attachment.buf, 0, -1, false)
  local missing, protected
  attachment.direct, missing, protected = M.find(attachment.context, lines)
  attachment.mentions = inline_mentions(lines, vim.list_extend(vim.deepcopy(attachment.direct), protected))
  apply_references(attachment)
  local token = attachment.token
  resolve_paths(attachment, token, lines, missing)
  local names = vim.fn.uniq(vim.fn.sort(vim.tbl_map(function(mention)
    return mention.symbol
  end, attachment.mentions)))
  if #names == 0 or not vim.api.nvim_buf_is_loaded(attachment.context.buf) then
    return
  end
  local uri = vim.uri_from_bufnr(attachment.context.buf)
  attachment.pending = attachment.pending + 1
  local cancel = lsp.request_all(attachment.context.buf, 'textDocument/documentSymbol', { textDocument = { uri = uri } }, 1000, function(results)
    if not is_current(attachment, token) then
      return
    end
    local candidates = response_candidates(results, uri)
    for _, name in ipairs(names) do
      attachment.symbols[name] = candidate_target(attachment.context, unique_candidate(candidates, name, name:find '[%.:]'))
    end
    local missing = vim.tbl_filter(function(name)
      return not attachment.symbols[name] and not source_target(attachment.context, name)
    end, names)
    resolve_workspace(attachment, token, missing)
    attachment.pending = attachment.pending - 1
    apply_references(attachment)
  end)
  attachment.cancellations[#attachment.cancellations + 1] = cancel
end

local function move_to_reference(win, reference)
  vim.api.nvim_win_set_cursor(win, { reference.row + 1, reference.start_col })
end

local function reference_at(references, row, col)
  return vim.iter(references):find(function(reference)
    return reference.row == row and col >= (reference.hit_start or reference.start_col) and col < (reference.hit_end or reference.end_col)
  end)
end

local function reference_on_line(attachment, row)
  if attachment.options.on_missing then
    return nil
  end
  local candidates = vim.tbl_filter(function(reference)
    return reference.row == row
  end, attachment.references)
  return #candidates == 1 and candidates[1] or nil
end

local function reference_buffer(reference)
  local buf = reference.bufnr and vim.api.nvim_buf_is_valid(reference.bufnr) and reference.bufnr or nil
  if buf and vim.api.nvim_buf_is_loaded(buf) then
    return buf
  end
  local filename = buf and vim.api.nvim_buf_get_name(buf) or reference.filename
  if not filename or vim.fn.filereadable(filename) == 0 then
    return nil
  end
  buf = buf or vim.fn.bufadd(filename)
  vim.fn.bufload(buf)
  return buf
end

local function jump_to_reference(attachment, reference)
  local context = attachment.context
  if not vim.api.nvim_win_is_valid(context.win) then
    return notify 'the window you asked from is gone'
  end
  local buf = reference_buffer(reference)
  if not buf or not target_line({ bufnr = buf }, reference.lnum) then
    return notify 'the referenced source location no longer exists'
  end
  move_to_reference(attachment.win, reference)
  vim.api.nvim_win_close(attachment.win, true)
  vim.api.nvim_set_current_win(context.win)
  vim.cmd "normal! m'"
  vim.bo[buf].buflisted = true
  vim.api.nvim_win_set_buf(context.win, buf)
  local line = target_line({ bufnr = buf }, reference.lnum)
  vim.api.nvim_win_set_cursor(context.win, { reference.lnum, math.min(reference.col, #line) })
  vim.cmd 'normal! zvzz'
  if has_ai_list(context.win) then
    vim.fn.setloclist(context.win, {}, 'a', { idx = reference.index })
  end
end

local function wait_for_references(attachment, action)
  attachment.waiting = { token = attachment.token, cursor = vim.api.nvim_win_get_cursor(attachment.win), action = action }
  notify('resolving code references…', vim.log.levels.INFO)
end

local function cycle(attachment, backwards)
  local cursor = vim.api.nvim_win_get_cursor(attachment.win)
  local references = attachment.references
  local ordered = backwards and vim.iter(references):rev() or vim.iter(references)
  local reference = ordered:find(function(candidate)
    return backwards and is_before(candidate, cursor[1] - 1, cursor[2])
      or not backwards and is_before({ row = cursor[1] - 1, start_col = cursor[2] }, candidate.row, candidate.start_col)
  end) or references[backwards and #references or 1]
  if not reference and attachment.pending > 0 then
    return wait_for_references(attachment, function()
      cycle(attachment, backwards)
    end)
  end
  if not reference then
    return notify 'this answer has no resolved code references'
  end
  move_to_reference(attachment.win, reference)
end

local function enter(attachment)
  local cursor = vim.api.nvim_win_get_cursor(attachment.win)
  local reference = reference_at(attachment.references, cursor[1] - 1, cursor[2]) or reference_on_line(attachment, cursor[1] - 1)
  if reference then
    return jump_to_reference(attachment, reference)
  end
  if not attachment.options.on_missing and attachment.pending > 0 then
    return wait_for_references(attachment, function()
      enter(attachment)
    end)
  end
  if attachment.options.on_missing then
    return attachment.options.on_missing()
  end
  notify 'the cursor is not on a reference (<Tab> moves to the next one)'
end

resume_navigation = function(attachment)
  local waiting = attachment.waiting
  if not waiting or attachment.pending > 0 then
    return
  end
  attachment.waiting = nil
  vim.schedule(function()
    if not is_current(attachment, waiting.token) or vim.api.nvim_get_current_win() ~= attachment.win then
      return
    end
    if not vim.deep_equal(vim.api.nvim_win_get_cursor(attachment.win), waiting.cursor) then
      return
    end
    waiting.action()
  end)
end

function M.attach(request, buf, win, options)
  local attachment = { context = normalize_context(request), buf = buf, win = win, options = options or {}, cancellations = {}, references = {} }
  vim.keymap.set('n', '<Tab>', function()
    cycle(attachment, false)
  end, { buffer = buf, desc = 'Next AI reference' })
  vim.keymap.set('n', '<S-Tab>', function()
    cycle(attachment, true)
  end, { buffer = buf, desc = 'Previous AI reference' })
  vim.keymap.set('n', '<CR>', function()
    enter(attachment)
  end, { buffer = buf, desc = 'Jump to AI reference' })
  vim.api.nvim_create_autocmd('BufWipeout', {
    buffer = buf,
    once = true,
    callback = function()
      attachment.token = nil
      for _, cancel in ipairs(attachment.cancellations) do
        cancel()
      end
    end,
  })
  M.refresh(attachment)
  return attachment
end

return M
