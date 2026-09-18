return {
  {
    dir = vim.fn.stdpath 'config',
    name = 'ivan-mongo-runner',
    lazy = false,
    config = function()
      -- Mongo migration runner
      local mongo_data_file = vim.fn.stdpath('data') .. '/mongo_databases.json'

      local mongo_databases = {
        { label = 'local/kompare-platform', url = 'mongodb://localhost/kompare-platform' },
      }
      local mongo_current_db = 1 -- Index of currently selected database

      -- urls are mongosh connection strings, so the scheme is optional: db4.kompare.pw/kompare is valid
      local function mongo_split_url(url)
        local scheme, rest = url:match '^([%w%+]+://)(.*)$'
        local body, query = (rest or url):match '^([^?]*)(%?.*)$'
        local authority, database = (body or rest or url):match '^([^/]*)/(.*)$'
        return {
          scheme = scheme or '',
          authority = authority or body or rest or url,
          database = database ~= '' and database or nil,
          query = query or '',
        }
      end

      local function mongo_url_db(url)
        return mongo_split_url(url).database
      end

      local function mongo_url_with_db(url, database)
        local parts = mongo_split_url(url)
        return parts.scheme .. parts.authority .. '/' .. database .. parts.query
      end

      local function mongo_url_without_db(url)
        local parts = mongo_split_url(url)
        local separator = parts.query ~= '' and '/' or ''
        return parts.scheme .. parts.authority .. separator .. parts.query
      end

      -- the database belongs in the entry, not in the url, so a picked one always wins
      local function mongo_stored_entry(db)
        return {
          label = db.label,
          url = mongo_url_without_db(db.url),
          database = db.database or mongo_url_db(db.url),
          protected = db.protected,
        }
      end

      local function mongo_save()
        local entries = vim.tbl_map(mongo_stored_entry, mongo_databases)
        local data = vim.fn.json_encode({ databases = entries, current = mongo_current_db })
        vim.fn.writefile({ data }, mongo_data_file)
      end

      local function mongo_load()
        if vim.fn.filereadable(mongo_data_file) == 1 then
          local content = vim.fn.readfile(mongo_data_file)
          if #content > 0 then
            local ok, data = pcall(vim.fn.json_decode, content[1])
            if ok and data then
              if data.databases and #data.databases > 0 then
                mongo_databases = vim.tbl_map(mongo_stored_entry, data.databases)
              end
              if data.current and data.current >= 1 and data.current <= #mongo_databases then
                mongo_current_db = data.current
              end
            end
          end
        end
      end

      -- Load saved databases on startup
      mongo_load()

      local function mongo_get_current()
        return mongo_databases[mongo_current_db]
      end

      local function mongo_with_current_db(on_db)
        local db = mongo_get_current()
        if not db then
          vim.notify('No MongoDB database selected!', vim.log.levels.ERROR)
          return
        end
        on_db(db)
      end

      local function mongo_is_protected(db)
        return db ~= nil and db.protected == true
      end

      local function mongo_active_db(db)
        return db.database or mongo_url_db(db.url)
      end

      local function mongo_active_url(db)
        local database = mongo_active_db(db)
        if not database then return db.url end
        return mongo_url_with_db(db.url, database)
      end

      local function mongo_db_suffix(db)
        return '  › ' .. (mongo_active_db(db) or '(no db)')
      end

      local function mongo_db_display(db)
        local protection = mongo_is_protected(db) and '  [PROTECTED]' or ''
        return db.label .. mongo_db_suffix(db) .. protection
      end

      local function mongo_add_database(label, url, protected)
        table.insert(mongo_databases, mongo_stored_entry({ label = label, url = url, protected = protected }))
        mongo_save()
        vim.notify('Added MongoDB: ' .. mongo_db_display(mongo_databases[#mongo_databases]))
      end

      local function mongo_current_marker(index)
        if index ~= mongo_current_db then return '  ' end
        return '* '
      end

      local function mongo_database_items(with_marker)
        local items = {}
        for index, db in ipairs(mongo_databases) do
          local prefix = with_marker and mongo_current_marker(index) or ''
          table.insert(items, prefix .. mongo_db_display(db))
        end
        return items
      end

      local function mongo_set_protection(idx, protected)
        local db = mongo_databases[idx]
        if not db then return end
        db.protected = protected
        mongo_save()
        vim.notify((protected and 'Protected: ' or 'Unprotected: ') .. db.label)
      end

      local function mongo_toggle_protection()
        vim.ui.select(mongo_database_items(), {
          prompt = 'Toggle protection (confirm before every query):',
        }, function(_, idx)
          if not idx then return end
          mongo_set_protection(idx, not mongo_is_protected(mongo_databases[idx]))
        end)
      end

      local function mongo_select_database()
        vim.ui.select(mongo_database_items(true), {
          prompt = 'Select MongoDB database:',
        }, function(_, idx)
          if idx then
            mongo_current_db = idx
            mongo_save()
            local db = mongo_get_current()
            vim.notify('Selected: ' .. mongo_db_display(db))
          end
        end)
      end

      local mongo_tracked_buffers = {}
      local mongo_update_preview_buffers = {}
      local mongo_transferred_windows = {}
      local mongo_result_queries = {} -- buf -> { db, code, raw }
      local mongo_generate_update_preview
      local mongo_track_result_window
      local mongo_show_links

      local function mongo_trim_lines(lines)
        local trimmed = vim.deepcopy(lines)
        while #trimmed > 0 and trimmed[#trimmed] == '' do
          table.remove(trimmed)
        end
        return trimmed
      end

      local function mongo_buffer_text(buf)
        return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
      end

      local function mongo_set_window_options(win)
        vim.api.nvim_set_option_value('wrap', false, { win = win })
        vim.api.nvim_set_option_value('number', true, { win = win })
        vim.api.nvim_set_option_value('relativenumber', true, { win = win })
      end

      local function mongo_open_buffer_in_tab(source_win)
        local buf = vim.api.nvim_get_current_buf()
        if vim.api.nvim_get_current_win() ~= source_win then
          vim.cmd 'wincmd T'
          return
        end

        mongo_transferred_windows[source_win] = true

        vim.cmd 'tabnew'
        vim.api.nvim_win_set_buf(0, buf)
        local tab_win = vim.api.nvim_get_current_win()
        mongo_set_window_options(tab_win)
        if mongo_tracked_buffers[buf] then
          mongo_track_result_window(buf, tab_win)
        end

        if vim.api.nvim_win_is_valid(source_win) then
          vim.api.nvim_win_close(source_win, true)
        end
      end

      -- the confirm float has to sit above the result/preview floats it is spawned over, yet below
      -- the vim.ui.select picker that asks for the final yes (telescope-ui-select renders at 50)
      local mongo_float_zindex = 40
      local mongo_confirm_zindex = 45

      local function mongo_float_height(line_count)
        return math.min(line_count + 3, vim.o.lines - 6)
      end

      local function mongo_open_float(lines, title, filetype, opts)
        local options = opts or {}
        local buf = vim.api.nvim_create_buf(false, true)
        if options.name then
          vim.api.nvim_buf_set_name(buf, options.name)
        end
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
        vim.api.nvim_set_option_value('buftype', options.buftype or 'nofile', { buf = buf })
        vim.api.nvim_set_option_value('bufhidden', options.bufhidden or 'wipe', { buf = buf })
        vim.api.nvim_set_option_value('swapfile', false, { buf = buf })
        vim.api.nvim_set_option_value('modifiable', options.modifiable ~= false, { buf = buf })
        vim.api.nvim_set_option_value('filetype', filetype, { buf = buf })

        local width = math.min(120, vim.o.columns - 6)
        local height = mongo_float_height(#lines)
        local win = vim.api.nvim_open_win(buf, true, {
          relative = 'editor',
          width = width,
          height = height,
          row = (vim.o.lines - height) / 2,
          col = (vim.o.columns - width) / 2,
          style = 'minimal',
          border = 'rounded',
          title = title,
          title_pos = 'center',
          footer = options.footer,
          footer_pos = options.footer and 'center' or nil,
          zindex = options.zindex or mongo_float_zindex,
        })

        mongo_set_window_options(win)
        vim.keymap.set('n', '<C-w>T', function()
          mongo_open_buffer_in_tab(win)
        end, { buffer = buf, desc = 'Open Mongo window in tab' })
        return buf, win
      end

      local function mongo_detect_find_operation(code)
        local trimmed = code:gsub('^%s+', ''):gsub('%s+$', '')
        local collection = trimmed:match("^db%.getCollection%s*%(%s*['\"]([^'\"]+)['\"]%s*%)%s*%.findOne%s*%(")
          or trimmed:match('^db%.([%w_%-]+)%s*%.findOne%s*%(')
        if collection then
          return { collection = collection, operation = 'findOne' }
        end

        collection = trimmed:match("^db%.getCollection%s*%(%s*['\"]([^'\"]+)['\"]%s*%)%s*%.find%s*%(")
          or trimmed:match('^db%.([%w_%-]+)%s*%.find%s*%(')
        if collection then
          return { collection = collection, operation = 'find' }
        end

        return nil
      end

      local function mongo_decoded_json_value(text)
        local ok, value = pcall(vim.fn.json_decode, text)
        if not ok then return nil end
        return value
      end

      local mongo_section_marker = '@@MONGO_SECTION@@'
      local mongo_section_end_marker = '@@MONGO_SECTION_END@@'
      local mongo_max_eval_length = 100000

      local function mongo_char_set(text)
        local set = {}
        for index = 1, #text do
          set[text:sub(index, index)] = true
        end
        return set
      end

      local mongo_regex_allowed_before = mongo_char_set('([{,;:=!&|?+-*/%^~<>')
      local mongo_open_brackets = mongo_char_set('([{')
      local mongo_close_brackets = mongo_char_set(')]}')
      local mongo_unfinished_tail = mongo_char_set('.,+-*/%=&|!<>?:^~([{')
      local mongo_continuation_head = mongo_char_set('.,)]}+-*/%=&|<>?:^([`')

      local mongo_declaration_keywords = {
        ['const'] = true, ['let'] = true, ['var'] = true, ['function'] = true,
        ['class'] = true, ['async'] = true, ['if'] = true, ['for'] = true,
        ['while'] = true, ['do'] = true, ['switch'] = true, ['try'] = true,
        ['throw'] = true, ['return'] = true, ['import'] = true, ['export'] = true,
      }

      local function mongo_strip_leading_trivia(text)
        local rest = text:gsub('^%s+', '')
        while true do
          if rest:sub(1, 2) == '//' then
            local line_end = rest:find('\n')
            rest = line_end and rest:sub(line_end + 1):gsub('^%s+', '') or ''
          elseif rest:sub(1, 2) == '/*' then
            local comment_end = rest:find('*/', 3, true)
            rest = comment_end and rest:sub(comment_end + 2):gsub('^%s+', '') or ''
          else
            return (rest:gsub('%s+$', ''))
          end
        end
      end

      -- Statements are also split on newlines, since mongosh scripts often omit semicolons.
      local function mongo_split_statements(code)
        local statements = {}
        local stack = {}
        local mode = 'code'
        local start = 1
        local index = 1
        local last = nil

        local function flush(stop)
          local text = code:sub(start, stop)
          if text:match('%S') then
            table.insert(statements, text)
          end
          start = stop + 1
          last = nil
        end

        local function significant_after(from)
          local cursor = from
          while cursor <= #code do
            local char = code:sub(cursor, cursor)
            local pair = code:sub(cursor, cursor + 1)
            if char:match('%s') then
              cursor = cursor + 1
            elseif pair == '//' then
              cursor = (code:find('\n', cursor) or #code) + 1
            elseif pair == '/*' then
              local comment_end = code:find('*/', cursor + 2, true)
              cursor = comment_end and comment_end + 2 or #code + 1
            else
              return char
            end
          end
          return nil
        end

        while index <= #code do
          local char = code:sub(index, index)
          local pair = code:sub(index, index + 1)

          if mode == 'line_comment' then
            if char == '\n' then
              mode = 'code'
            else
              index = index + 1
            end
          elseif mode == 'block_comment' then
            if pair == '*/' then
              mode = 'code'
              index = index + 2
            else
              index = index + 1
            end
          elseif mode == 'single' or mode == 'double' then
            local quote = mode == 'single' and "'" or '"'
            if char == '\\' then
              index = index + 2
            elseif char == quote then
              mode = 'code'
              last = quote
              index = index + 1
            else
              index = index + 1
            end
          elseif mode == 'template' then
            if char == '\\' then
              index = index + 2
            elseif pair == '${' then
              table.insert(stack, 'template')
              mode = 'code'
              index = index + 2
            elseif char == '`' then
              mode = 'code'
              last = '`'
              index = index + 1
            else
              index = index + 1
            end
          elseif mode == 'regex' then
            if char == '\\' then
              index = index + 2
            elseif char == '[' then
              mode = 'regex_class'
              index = index + 1
            elseif char == '/' then
              mode = 'code'
              last = '/'
              index = index + 1
            else
              index = index + 1
            end
          elseif mode == 'regex_class' then
            if char == '\\' then
              index = index + 2
            elseif char == ']' then
              mode = 'regex'
              index = index + 1
            else
              index = index + 1
            end
          elseif pair == '//' then
            mode = 'line_comment'
            index = index + 2
          elseif pair == '/*' then
            mode = 'block_comment'
            index = index + 2
          elseif char == '/' and (last == nil or mongo_regex_allowed_before[last]) then
            mode = 'regex'
            index = index + 1
          elseif char == "'" then
            mode = 'single'
            index = index + 1
          elseif char == '"' then
            mode = 'double'
            index = index + 1
          elseif char == '`' then
            mode = 'template'
            index = index + 1
          elseif mongo_open_brackets[char] then
            table.insert(stack, 'bracket')
            last = char
            index = index + 1
          elseif mongo_close_brackets[char] then
            if table.remove(stack) == 'template' then
              mode = 'template'
            else
              last = char
            end
            index = index + 1
          elseif char == ';' and #stack == 0 then
            flush(index)
            index = index + 1
          elseif char == '\n' and #stack == 0 and last and not mongo_unfinished_tail[last] then
            local head = significant_after(index + 1)
            if head and not mongo_continuation_head[head] then
              flush(index)
            end
            index = index + 1
          else
            if char:match('%S') then last = char end
            index = index + 1
          end
        end

        flush(#code)
        return statements
      end

      local function mongo_is_expression(body)
        if body == '' then return false end

        local word = body:match('^[%a_$][%w_$]*')
        return not (word and mongo_declaration_keywords[word])
      end

      local function mongo_emit_snippet(index, expression)
        local meta = 'JSON.stringify(Array.isArray(__mongoDocs) ? { index: ' .. index
          .. ', count: __mongoDocs.length } : { index: ' .. index .. ' })'

        return table.concat({
          'try {',
          '  const __mongoValue = (',
          expression,
          '  );',
          [[  const __mongoDocs = __mongoValue && typeof __mongoValue.toArray === 'function' ? __mongoValue.toArray() : __mongoValue;]],
          [[  print(']] .. mongo_section_marker .. [[' + ]] .. meta .. ');',
          [[  print(typeof __mongoDocs === 'undefined' ? 'undefined' : EJSON.stringify(__mongoDocs, null, 2));]],
          '} catch (__mongoError) {',
          [[  print(']] .. mongo_section_marker .. [[' + JSON.stringify({ index: ]] .. index .. [[, error: true }));]],
          [[  print(String((__mongoError && __mongoError.message) || __mongoError));]],
          '}',
          [[print(']] .. mongo_section_end_marker .. [[');]],
        }, '\n')
      end

      local function mongo_build_script(code)
        local parts = {}
        local sections = {}

        for _, text in ipairs(mongo_split_statements(code)) do
          local body = mongo_strip_leading_trivia(text)
          if mongo_is_expression(body) then
            local expression = body:gsub('%s*;%s*$', '')
            table.insert(sections, { index = #sections + 1, statement = expression })
            table.insert(parts, mongo_emit_snippet(#sections, expression))
          else
            table.insert(parts, text)
          end
        end

        return table.concat(parts, '\n'), sections
      end

      local function mongo_parse_sections(output, sections)
        local results = {}
        local printed = {}
        local current = nil

        for _, line in ipairs(output) do
          local meta_text = line:match('^' .. vim.pesc(mongo_section_marker) .. '(.*)$')
          if meta_text then
            local meta = mongo_decoded_json_value(meta_text) or {}
            local section = sections[meta.index]
            current = {
              index = meta.index,
              count = meta.count,
              error = meta.error == true,
              statement = section and section.statement or '',
              lines = {},
            }
            table.insert(results, current)
          elseif line == mongo_section_end_marker then
            if current then
              current.lines = mongo_trim_lines(current.lines)
            end
            current = nil
          elseif current then
            table.insert(current.lines, line)
          elseif line ~= '' then
            table.insert(printed, line)
          end
        end

        if #printed > 0 then
          table.insert(results, 1, { statement = '(printed output)', lines = printed })
        end

        return results
      end

      local function mongo_find_section(results, index)
        for _, result in ipairs(results) do
          if result.index == index then return result end
        end
        return nil
      end

      local function mongo_result_label(statement)
        local label = statement:gsub('%s+', ' ')
        if vim.fn.strchars(label) > 96 then
          return vim.fn.strcharpart(label, 0, 95) .. '…'
        end
        return label
      end

      local function mongo_result_summary(result)
        if result.error then return 'error' end
        if not result.count then return 'value' end
        return result.count .. (result.count == 1 and ' doc' or ' docs')
      end

      local function mongo_has_object_id(text)
        return text:find('"_id"%s*:%s*{%s*"%$oid"') ~= nil
      end

      local function mongo_is_valid_json(text)
        local ok = pcall(vim.fn.json_decode, text)
        return ok
      end

      local function mongo_script_file(code)
        local path = vim.fn.tempname() .. '.js'
        vim.fn.writefile(vim.split(code, '\n'), path)
        return path
      end

      local function mongo_command(db, flag, script)
        return { 'mongosh', mongo_active_url(db), '--norc', '--quiet', flag, script }
      end

      local function mongo_start_job(db, code, on_exit, extra_env)
        -- --eval passes the script as a single argv entry, which dies with E2BIG once a document is
        -- embedded in it, so anything past one argument's worth of code runs from a file instead
        local script_file = #code > mongo_max_eval_length and mongo_script_file(code) or nil
        local cmd = script_file and mongo_command(db, '--file', script_file) or mongo_command(db, '--eval', code)
        local env = vim.tbl_extend('force', { NO_COLOR = '1' }, extra_env or {})
        local output = {}
        local errors = {}

        local started, job = pcall(vim.fn.jobstart, cmd, {
          env = env,
          stdout_buffered = true,
          stderr_buffered = true,
          on_stdout = function(_, data)
            if data then
              for _, line in ipairs(data) do
                table.insert(output, line)
              end
            end
          end,
          on_stderr = function(_, data)
            if data then
              for _, line in ipairs(data) do
                table.insert(errors, line)
              end
            end
          end,
          on_exit = function(_, exit_code)
            vim.schedule(function()
              if script_file then os.remove(script_file) end
              on_exit(exit_code, mongo_trim_lines(output), mongo_trim_lines(errors))
            end)
          end,
        })

        if not started or job <= 0 then
          if script_file then os.remove(script_file) end
          vim.notify('Failed to start mongosh' .. (started and '' or ': ' .. tostring(job)), vim.log.levels.ERROR)
        end
      end

      local mongo_list_databases_script =
        'JSON.stringify(db.adminCommand({ listDatabases: 1, nameOnly: true }).databases.map(entry => entry.name))'

      local function mongo_set_db(db, database)
        db.database = database
        mongo_save()
        vim.notify('Using database: ' .. mongo_db_display(db))
      end

      local function mongo_input_db(db, on_done)
        vim.ui.input({ prompt = 'Database name on ' .. db.label .. ': ' }, function(name)
          if not name or name == '' then return end
          mongo_set_db(db, vim.trim(name))
          if on_done then on_done() end
        end)
      end

      local function mongo_parse_names(exit_code, output)
        if exit_code ~= 0 or #output == 0 then return nil end
        local ok, names = pcall(vim.fn.json_decode, table.concat(output, ''))
        if not ok or type(names) ~= 'table' or #names == 0 then return nil end
        return names
      end

      local function mongo_pick_db(db, on_done)
        mongo_start_job(db, mongo_list_databases_script, function(exit_code, output, errors)
          local names = mongo_parse_names(exit_code, output)
          if not names then
            vim.notify('Could not list databases on ' .. db.label .. ': ' .. (errors[1] or output[1] or 'no output'), vim.log.levels.WARN)
            mongo_input_db(db, on_done)
            return
          end

          vim.ui.select(names, { prompt = 'Use database on ' .. db.label .. ':' }, function(name)
            if not name then return end
            mongo_set_db(db, name)
            if on_done then on_done() end
          end)
        end)
      end

      local mongo_list_collections_script = 'JSON.stringify(db.getCollectionNames())'

      local function mongo_collection_accessor(collection)
        if collection:match '^[%a_][%w_]*$' then return 'db.' .. collection end
        return "db.getCollection('" .. collection .. "')"
      end

      local function mongo_find_snippet(collection)
        return {
          mongo_collection_accessor(collection),
          '    .find({})',
          '    .sort({_id: -1})',
          '    .limit(10)',
        }
      end

      local function mongo_insert_lines(win, lines)
        if not vim.api.nvim_win_is_valid(win) then return end
        local buf = vim.api.nvim_win_get_buf(win)
        local row = vim.api.nvim_win_get_cursor(win)[1]
        local current = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or ''
        local start = vim.trim(current) == '' and row - 1 or row
        vim.api.nvim_buf_set_lines(buf, start, row, false, lines)
        vim.api.nvim_win_set_cursor(win, { start + 1, 0 })
      end

      local function mongo_pick_collection(db, win)
        mongo_start_job(db, mongo_list_collections_script, function(exit_code, output, errors)
          local names = mongo_parse_names(exit_code, output)
          if not names then
            vim.notify('Could not list collections on ' .. db.label .. ': ' .. (errors[1] or output[1] or 'no output'), vim.log.levels.WARN)
            return
          end

          vim.ui.select(names, { prompt = 'Collection on ' .. mongo_db_display(db) .. ':' }, function(name)
            if not name then return end
            mongo_insert_lines(win, mongo_find_snippet(name))
          end)
        end)
      end

      local function mongo_close_window(win)
        if vim.api.nvim_win_is_valid(win) then
          vim.api.nvim_win_close(win, true)
        end
      end

      local function mongo_close_keymaps(buf, win, desc)
        local close = function()
          mongo_close_window(win)
        end
        vim.keymap.set('n', 'q', close, { buffer = buf, desc = desc })
        vim.keymap.set('n', '<Esc>', close, { buffer = buf, desc = desc })
      end

      local function mongo_confirm_lines(db, code)
        return vim.list_extend({ '// ' .. mongo_active_url(db), '' }, vim.split(code, '\n'))
      end

      local function mongo_set_lines(buf, lines)
        vim.api.nvim_set_option_value('modifiable', true, { buf = buf })
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
        vim.api.nvim_set_option_value('modifiable', false, { buf = buf })
      end

      local function mongo_ask_database_name(db, win, on_confirm)
        vim.ui.input({ prompt = 'Type ' .. db.label .. ' to run: ' }, function(answer)
          mongo_close_window(win)
          if vim.trim(answer or '') ~= db.label then
            vim.notify('Mongo run cancelled: database name did not match', vim.log.levels.WARN)
            return
          end
          on_confirm()
        end)
      end

      local function mongo_confirm_run(db, code, on_confirm, display_code)
        local shown = display_code or code
        local wraps_code = shown ~= code
        local views = { mongo_confirm_lines(db, shown), mongo_confirm_lines(db, code) }
        local buf, win = mongo_open_float(views[1], ' PROTECTED DB [' .. db.label .. '] ', 'javascript', {
          modifiable = false,
          zindex = mongo_confirm_zindex,
          footer = wraps_code and ' <CR> run · <Tab> wrapped script · q cancel ' or ' <CR> run · q cancel ',
        })

        local view = 1
        if wraps_code then
          vim.keymap.set('n', '<Tab>', function()
            view = view == 1 and 2 or 1
            mongo_set_lines(buf, views[view])
            vim.api.nvim_win_set_height(win, mongo_float_height(#views[view]))
          end, { buffer = buf, desc = 'Toggle wrapped Mongo script' })
        end

        local function cancel()
          mongo_close_window(win)
          vim.notify('Mongo run cancelled', vim.log.levels.WARN)
        end

        vim.keymap.set('n', 'q', cancel, { buffer = buf, desc = 'Cancel Mongo run' })
        vim.keymap.set('n', '<Esc>', cancel, { buffer = buf, desc = 'Cancel Mongo run' })
        vim.keymap.set('n', '<CR>', function()
          mongo_ask_database_name(db, win, on_confirm)
        end, { buffer = buf, desc = 'Confirm Mongo run' })
      end

      local function mongo_run_job(db, code, on_exit, display_code)
        if not mongo_is_protected(db) then
          mongo_start_job(db, code, on_exit)
          return
        end

        mongo_confirm_run(db, code, function()
          mongo_start_job(db, code, on_exit)
        end, display_code)
      end

      local function mongo_ejson_preview_script(collection, edited_text)
        return [[
      const __collectionName = ]] .. vim.fn.json_encode(collection) .. [[;
      const __collection = db.getCollection(__collectionName);
      const __edited = EJSON.parse(]] .. vim.fn.json_encode(edited_text) .. [[);
      const __docs = Array.isArray(__edited) ? __edited : (__edited ? [__edited] : []);
      const __isPlainObject = value => value && typeof value === 'object' && !Array.isArray(value) && !value._bsontype && !(value instanceof Date);
      const __sameValue = (left, right) => EJSON.stringify(left) === EJSON.stringify(right);
      const __indent = level => '  '.repeat(level);
      const __literal = (value, level = 0) => {
        if (value && value._bsontype === 'ObjectId') return `ObjectId("${value.toHexString()}")`;
        if (value instanceof Date) return `ISODate("${value.toISOString()}")`;
        if (Array.isArray(value)) {
          if (value.length === 0) return '[]';

          const items = value.map(item => `${__indent(level + 1)}${__literal(item, level + 1)}`);
          return `[\n${items.join(',\n')}\n${__indent(level)}]`;
        }
        if (__isPlainObject(value)) {
          const entries = Object.entries(value);
          if (entries.length === 0) return '{}';

          const fields = entries.map(([key, item]) => `${__indent(level + 1)}${JSON.stringify(key)}: ${__literal(item, level + 1)}`);
          return `{\n${fields.join(',\n')}\n${__indent(level)}}`;
        }
        if (typeof value === 'undefined') return 'undefined';
        return JSON.stringify(value);
      };
      const __diffToSet = (edited, live, prefix = '') => {
        if (!__isPlainObject(edited) || !__isPlainObject(live)) {
          return prefix && !__sameValue(edited, live) ? { set: { [prefix]: edited }, unset: {} } : { set: {}, unset: {} };
        }

        const changed = Object.keys(edited).reduce((changes, key) => {
          if (key === '_id') return changes;

          const path = prefix ? `${prefix}.${key}` : key;
          const editedValue = edited[key];
          const liveValue = live ? live[key] : undefined;
          const nested = __isPlainObject(editedValue) && __isPlainObject(liveValue)
            ? __diffToSet(editedValue, liveValue, path)
            : (!__sameValue(editedValue, liveValue) ? { set: { [path]: editedValue }, unset: {} } : { set: {}, unset: {} });

          return {
            set: { ...changes.set, ...nested.set },
            unset: { ...changes.unset, ...nested.unset },
          };
        }, { set: {}, unset: {} });

        return Object.keys(live).reduce((changes, key) => {
          if (key === '_id' || Object.prototype.hasOwnProperty.call(edited, key)) return changes;

          const path = prefix ? `${prefix}.${key}` : key;
          return {
            set: changes.set,
            unset: { ...changes.unset, [path]: '' },
          };
        }, changed);
      };
      const __renderSet = changes => Object.entries(changes)
        .map(([key, value]) => `      ${JSON.stringify(key)}: ${__literal(value, 3)}`)
        .join(',\n');
      const __renderUnset = changes => Object.keys(changes)
        .map(key => `      ${JSON.stringify(key)}: ""`)
        .join(',\n');
      const __renderUpdate = changes => {
        const operators = [];
        if (Object.keys(changes.set).length > 0) {
          operators.push(`    $set: {\n${__renderSet(changes.set)}\n    }`);
        }
        if (Object.keys(changes.unset).length > 0) {
          operators.push(`    $unset: {\n${__renderUnset(changes.unset)}\n    }`);
        }

        return operators.join(',\n');
      };
      const __operations = __docs.flatMap(doc => {
        if (!doc || !doc._id) return [];

        const live = __collection.findOne({ _id: doc._id });
        if (!live) return [`// Skipped missing live document: ${EJSON.stringify(doc._id)}`];

        const changes = __diffToSet(doc, live);
        if (Object.keys(changes.set).length === 0 && Object.keys(changes.unset).length === 0) return [];

        return [`db.getCollection(${JSON.stringify(__collectionName)}).updateOne(\n  { _id: ${__literal(doc._id)} },\n  {\n${__renderUpdate(changes)}\n  }\n);`];
      });

      if (__operations.length === 0) {
        print('__NO_MONGO_UPDATES__');
      } else {
        print(__operations.join('\n\n'));
      }
      ]]
      end

      local function mongo_open_update_preview(db, lines)
        local buf = mongo_open_float(lines, ' Mongo update preview [' .. db.label .. '] ', 'javascript')
        mongo_update_preview_buffers[buf] = true
      end

      mongo_generate_update_preview = function(buf)
        local state = mongo_tracked_buffers[buf]
        if not state or state.processing or not vim.api.nvim_buf_is_valid(buf) then
          return
        end

        state.processing = true
        mongo_tracked_buffers[buf] = nil

        local edited_text = state.saved_text
        if not edited_text then
          return
        end

        if edited_text == state.original_text then
          return
        end

        local script = mongo_ejson_preview_script(state.collection, edited_text)
        -- skips the protected-db gate on purpose: this script only findOnes the live docs to diff
        -- them, and the updateOne it prints stays gated until you run the preview
        mongo_start_job(state.db, script, function(exit_code, output, errors)
          local output_text = table.concat(output, '\n')
          if exit_code ~= 0 then
            vim.notify('Could not build Mongo update preview', vim.log.levels.ERROR)
            local error_output = vim.list_extend(vim.deepcopy(output), errors)
            mongo_open_float(error_output, ' Mongo update preview error [' .. state.db.label .. '] ', 'javascript')
            return
          end

          if output_text == '__NO_MONGO_UPDATES__' or output_text == '' then
            vim.notify('No Mongo changes detected')
            return
          end

          mongo_open_update_preview(state.db, output)
        end)
      end

      mongo_track_result_window = function(buf, win)
        vim.api.nvim_create_autocmd('WinClosed', {
          pattern = tostring(win),
          once = true,
          callback = function()
            if mongo_transferred_windows[win] then
              mongo_transferred_windows[win] = nil
              return
            end

            mongo_generate_update_preview(buf)
            vim.schedule(function()
              if vim.api.nvim_buf_is_valid(buf) then
                vim.api.nvim_buf_delete(buf, { force = true })
              end
            end)
          end,
        })
      end

      local function mongo_track_result_buffer(buf, win, state)
        mongo_tracked_buffers[buf] = state

        vim.api.nvim_create_autocmd('BufWriteCmd', {
          buffer = buf,
          callback = function()
            local current = mongo_buffer_text(buf)
            if not mongo_is_valid_json(current) then
              vim.notify('Mongo result is not valid JSON; update preview not saved', vim.log.levels.ERROR)
              return
            end

            state.saved_text = current
            vim.api.nvim_set_option_value('modified', false, { buf = buf })
            vim.notify('Mongo result saved; close window to preview update')
          end,
        })

        vim.api.nvim_create_autocmd({ 'BufDelete', 'BufWipeout' }, {
          buffer = buf,
          once = true,
          callback = function()
            mongo_generate_update_preview(buf)
          end,
        })

        mongo_track_result_window(buf, win)
      end

      local function mongo_refresh_render(buf, win, lines)
        local cursor = vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_cursor(win) or nil
        vim.api.nvim_set_option_value('modifiable', true, { buf = buf })
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
        vim.api.nvim_set_option_value('modified', false, { buf = buf })

        if win >= 0 and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_config(win).relative ~= '' then
          vim.api.nvim_win_set_height(win, mongo_float_height(#lines))
        end

        if cursor and win >= 0 and vim.api.nvim_win_is_valid(win) then
          local last = vim.api.nvim_buf_line_count(buf)
          vim.api.nvim_win_set_cursor(win, { math.min(cursor[1], last), cursor[2] })
        end
      end

      local function mongo_refresh_result(buf)
        local q = mongo_result_queries[buf]
        if not q or not q.section then
          vim.notify('Not a refreshable Mongo result window', vim.log.levels.WARN)
          return
        end

        local script, sections = mongo_build_script(q.code)
        mongo_run_job(q.db, script, function(exit_code, output)
          if exit_code ~= 0 then
            vim.notify('Mongo refresh failed (exit ' .. exit_code .. ')', vim.log.levels.ERROR)
            return
          end

          local result = mongo_find_section(mongo_parse_sections(output, sections), q.section)
          if not result or #result.lines == 0 then
            vim.notify('Mongo refresh returned no output', vim.log.levels.WARN)
            return
          end
          if not vim.api.nvim_buf_is_valid(buf) then
            return
          end

          local win = (vim.fn.win_findbuf(buf))[1] or -1
          mongo_refresh_render(buf, win, result.lines)

          local state = mongo_tracked_buffers[buf]
          if state then
            state.original_text = table.concat(result.lines, '\n')
          end
          vim.notify('Mongo result refreshed')
        end, q.code)
      end

      local function mongo_open_output_float(db, exit_code, output, errors)
        local lines = vim.deepcopy(output)
        for _, line in ipairs(errors or {}) do
          table.insert(lines, '[stderr] ' .. line)
        end
        table.insert(lines, 1, '--- Mongosh Output (exit: ' .. exit_code .. ') ---')
        table.insert(lines, 2, '--- Database: ' .. db.label .. ' ---')
        table.insert(lines, 3, '')
        mongo_open_float(lines, ' Mongosh [' .. db.label .. '] ', 'javascript')
      end

      local function mongo_register_result_keymaps(buf, db, code, result, collection)
        if not result.index then return end

        mongo_result_queries[buf] = { db = db, code = code, section = result.index, collection = collection }
        vim.keymap.set('n', '<leader>mr', function()
          mongo_refresh_result(buf)
        end, { buffer = buf, desc = '[M]ongo [R]efresh result' })
        vim.keymap.set('n', '<leader>ml', function()
          mongo_show_links(buf)
        end, { buffer = buf, desc = '[M]ongo [L]inks for document' })
        vim.api.nvim_create_autocmd({ 'BufDelete', 'BufWipeout' }, {
          buffer = buf,
          once = true,
          callback = function()
            mongo_result_queries[buf] = nil
          end,
        })
      end

      local function mongo_open_result_section(db, code, result)
        if result.error then
          mongo_open_float(result.lines, ' Mongo error [' .. db.label .. '] ', 'javascript')
          return
        end

        local text = table.concat(result.lines, '\n')
        local tracked = mongo_detect_find_operation(result.statement)
        local title = ' Mongo result [' .. db.label .. '] '

        if not tracked or not mongo_has_object_id(text) then
          local plain_buf = mongo_open_float(result.lines, title, 'json')
          mongo_register_result_keymaps(plain_buf, db, code, result, tracked and tracked.collection)
          return
        end

        local buf, win = mongo_open_float(result.lines, title, 'json', {
          bufhidden = 'hide',
          buftype = 'acwrite',
          name = 'mongo-result://' .. tracked.collection .. '/' .. tostring(vim.loop.hrtime()),
        })
        mongo_register_result_keymaps(buf, db, code, result, tracked.collection)
        mongo_track_result_buffer(buf, win, {
          db = db,
          collection = tracked.collection,
          original_text = text,
        })
      end

      local function mongo_open_results_index(db, code, results)
        local lines = {}
        for position, result in ipairs(results) do
          table.insert(lines, string.format('%2d  %-9s %s', position, mongo_result_summary(result), mongo_result_label(result.statement)))
        end

        local buf, win = mongo_open_float(lines, ' Mongo results [' .. db.label .. '] ', 'text', { modifiable = false })
        vim.api.nvim_set_option_value('cursorline', true, { win = win })

        vim.keymap.set('n', '<CR>', function()
          local result = results[vim.api.nvim_win_get_cursor(win)[1]]
          if result then
            mongo_open_result_section(db, code, result)
          end
        end, { buffer = buf, desc = 'Open Mongo result' })

        mongo_close_keymaps(buf, win, 'Close Mongo results')
      end

      local function run_mongosh(input, is_file, opts)
        local options = opts or {}
        local db = mongo_get_current()
        if not db then
          vim.notify('No MongoDB database selected!', vim.log.levels.ERROR)
          return
        end

        if not mongo_active_db(db) then
          mongo_pick_db(db, function()
            run_mongosh(input, is_file, opts)
          end)
          return
        end

        local code = is_file and table.concat(vim.fn.readfile(input), '\n') or input
        local script, sections = mongo_build_script(code)

        if options.raw or #sections == 0 then
          mongo_run_job(db, code, function(exit_code, output, errors)
            mongo_open_output_float(db, exit_code, output, errors)
          end)
          return
        end

        mongo_run_job(db, script, function(exit_code, output, errors)
          if exit_code ~= 0 then
            mongo_open_output_float(db, exit_code, output, errors)
            return
          end

          local results = mongo_parse_sections(output, sections)
          if #results == 0 then
            mongo_open_output_float(db, exit_code, output, errors)
            return
          end
          if #results == 1 then
            mongo_open_result_section(db, code, results[1])
            return
          end

          mongo_open_results_index(db, code, results)
        end, code)
      end


      -- Collection copy: mongosh always connects to the target, the source is only ever read
      local mongo_copy_marker = '__MONGO_COPY__'

      local mongo_copy_modes = {
        { key = 'replace', label = 'Replace — drop the target collection, then copy' },
        { key = 'merge', label = 'Merge — upsert by _id, keep target-only documents' },
        { key = 'create', label = 'Create — abort if the target collection exists' },
      }

      -- the mongosh cli accepts a scheme-less connection string, but connect() inside a script folds
      -- the query string into the database name unless the uri is absolute
      local function mongo_copy_source_uri(db)
        local url = mongo_active_url(db)
        local absolute = mongo_split_url(url).scheme ~= '' and url or 'mongodb://' .. url
        if absolute:match 'readPreference=' then return absolute end
        return absolute .. (absolute:find('?', 1, true) and '&' or '?') .. 'readPreference=secondaryPreferred'
      end

      local function mongo_copy_script_header(spec)
        return [[
      const __source = connect(process.env.MONGO_COPY_SOURCE_URI).getCollection(]] .. vim.fn.json_encode(spec.source_collection) .. [[);
      const __targetName = ]] .. vim.fn.json_encode(spec.target_collection) .. [[;
      ]]
      end

      local function mongo_copy_preflight_script(spec)
        return mongo_copy_script_header(spec) .. [[
      const __infos = db.getCollectionInfos({ name: __targetName });
      const __exists = __infos.length > 0;

      print(']] .. mongo_copy_marker .. [[' + EJSON.stringify({
        sourceCount: __source.estimatedDocumentCount(),
        sourceIndexes: __source.getIndexes().filter(index => index.name !== '_id_').length,
        targetExists: __exists,
        targetType: __exists ? __infos[0].type : '',
        targetCount: __exists ? db.getCollection(__targetName).estimatedDocumentCount() : 0,
      }));
      ]]
      end

      local function mongo_copy_script(spec)
        return mongo_copy_script_header(spec) .. [[
      const __mode = ]] .. vim.fn.json_encode(spec.mode.key) .. [[;
      const __batchSize = 500;
      const __existing = db.getCollectionInfos({ name: __targetName });

      if (__mode === 'create' && __existing.length > 0) {
        throw new Error(`Target collection ${__targetName} already exists`);
      }
      if (__mode === 'replace' && __existing.length > 0) {
        db.getCollection(__targetName).drop();
      }

      const __target = db.getCollection(__targetName);
      const __total = __source.countDocuments({});
      const __cursor = __source.find({});
      const __operation = doc => __mode === 'merge'
        ? { replaceOne: { filter: { _id: doc._id }, replacement: doc, upsert: true } }
        : { insertOne: { document: doc } };

      // mongosh awaits driver calls inside Array.prototype callbacks but not inside an Array.from
      // mapper, where hasNext() reads as false, so the slots are allocated first and drained with map
      const __batchSlots = Array.from({ length: __batchSize });
      const __takeBatch = () => __batchSlots
        .map(() => __cursor.hasNext() ? __cursor.next() : null)
        .filter(doc => doc !== null);

      const __passes = Array.from({ length: Math.ceil(__total / __batchSize) + 1 });
      const __written = __passes.reduce(totals => {
        const docs = __takeBatch();
        if (docs.length === 0) return totals;

        const result = __target.bulkWrite(docs.map(__operation), { ordered: false });
        return {
          copied: totals.copied + docs.length,
          inserted: totals.inserted + result.insertedCount + result.upsertedCount,
          replaced: totals.replaced + result.modifiedCount,
        };
      }, { copied: 0, inserted: 0, replaced: 0 });

      const __indexes = __source.getIndexes().filter(index => index.name !== '_id_');
      const __indexErrors = __indexes.flatMap(index => {
        const { key, v, ns, background, ...options } = index;
        try {
          __target.createIndex(key, options);
          return [];
        } catch (error) {
          return [`${index.name}: ${error.message}`];
        }
      });

      print(']] .. mongo_copy_marker .. [[' + EJSON.stringify({
        copied: __written.copied,
        inserted: __written.inserted,
        replaced: __written.replaced,
        indexes: __indexes.length - __indexErrors.length,
        indexErrors: __indexErrors,
        targetCount: __target.countDocuments({}),
      }));
      ]]
      end

      local function mongo_copy_payload(output)
        for _, line in ipairs(output) do
          if line:sub(1, #mongo_copy_marker) == mongo_copy_marker then
            return line:sub(#mongo_copy_marker + 1)
          end
        end
        return nil
      end

      local function mongo_copy_decode(output)
        local payload = mongo_copy_payload(output)
        if not payload then return nil end

        local ok, decoded = pcall(vim.fn.json_decode, payload)
        if not ok or type(decoded) ~= 'table' then return nil end
        return decoded
      end

      local function mongo_copy_target_entry(target, database)
        return vim.tbl_extend('force', vim.deepcopy(target), { database = database })
      end

      local function mongo_copy_endpoint(db, collection)
        return db.label .. '  › ' .. (mongo_active_db(db) or '(no db)') .. '  › ' .. collection
      end

      local function mongo_copy_from_line(spec)
        return 'FROM   ' .. mongo_copy_endpoint(spec.source, spec.source_collection)
      end

      local function mongo_copy_to_line(spec)
        return 'TO     ' .. mongo_copy_endpoint(spec.target, spec.target_collection)
      end

      -- the source connection string carries credentials, so it travels in the environment instead
      -- of the script file mongosh reads for anything past mongo_max_eval_length
      local function mongo_copy_job(spec, script, on_result)
        mongo_start_job(spec.target, script, function(exit_code, output, errors)
          local decoded = exit_code == 0 and mongo_copy_decode(output) or nil
          if not decoded then
            mongo_open_output_float(spec.target, exit_code, output, errors)
            return
          end
          on_result(decoded)
        end, { MONGO_COPY_SOURCE_URI = mongo_copy_source_uri(spec.source) })
      end

      local function mongo_copy_warning_lines(spec, stats)
        if not stats.targetExists or stats.targetCount == 0 then
          return { '', 'Target is empty — nothing will be overwritten.' }
        end
        if spec.mode.key == 'replace' then
          return {
            '',
            string.format('WARNING  the target already holds %s documents.', stats.targetCount),
            'They will be DROPPED, together with their indexes, before the copy.',
          }
        end
        return {
          '',
          string.format('WARNING  the target already holds %s documents.', stats.targetCount),
          'Documents sharing an _id with the source will be overwritten.',
        }
      end

      local function mongo_copy_plan_lines(spec, stats)
        local plan = {
          mongo_copy_from_line(spec),
          string.format('       %s documents · %s indexes · read only', stats.sourceCount, stats.sourceIndexes),
          '',
          mongo_copy_to_line(spec),
          '',
          'MODE   ' .. spec.mode.label,
        }
        return vim.list_extend(plan, mongo_copy_warning_lines(spec, stats))
      end

      local function mongo_copy_result_lines(spec, result)
        local lines = {
          mongo_copy_from_line(spec),
          mongo_copy_to_line(spec),
          '',
          string.format('copied %s documents (%s inserted · %s replaced)', result.copied, result.inserted, result.replaced),
          string.format('target now holds %s documents', result.targetCount),
          string.format('indexes recreated: %s', result.indexes),
        }
        if #(result.indexErrors or {}) == 0 then return lines end

        return vim.list_extend(vim.list_extend(lines, { '', 'index errors:' }), result.indexErrors)
      end

      local function mongo_copy_open_result(spec, result)
        local buf, win = mongo_open_float(mongo_copy_result_lines(spec, result), ' Mongo copy done ', 'text', {
          modifiable = false,
          footer = ' q close ',
        })
        mongo_close_keymaps(buf, win, 'Close Mongo copy result')
      end

      local function mongo_copy_run(spec)
        vim.notify('Copying ' .. spec.source_collection .. ' → ' .. mongo_copy_endpoint(spec.target, spec.target_collection))
        mongo_copy_job(spec, mongo_copy_script(spec), function(result)
          mongo_copy_open_result(spec, result)
        end)
      end

      local function mongo_copy_confirm(spec, stats)
        local overwrites = stats.targetExists and stats.targetCount > 0
        local title = overwrites and ' MONGO COPY — WILL OVERWRITE ' or ' Mongo copy '
        local buf, win = mongo_open_float(mongo_copy_plan_lines(spec, stats), title, 'text', {
          modifiable = false,
          zindex = mongo_confirm_zindex,
          footer = overwrites and ' <CR> confirm (asks for the target label) · q cancel ' or ' <CR> run copy · q cancel ',
        })

        local function cancel()
          mongo_close_window(win)
          vim.notify('Mongo copy cancelled', vim.log.levels.WARN)
        end

        vim.keymap.set('n', 'q', cancel, { buffer = buf, desc = 'Cancel Mongo copy' })
        vim.keymap.set('n', '<Esc>', cancel, { buffer = buf, desc = 'Cancel Mongo copy' })
        vim.keymap.set('n', '<CR>', function()
          if overwrites then
            mongo_ask_database_name(spec.target, win, function()
              mongo_copy_run(spec)
            end)
            return
          end

          mongo_close_window(win)
          mongo_copy_run(spec)
        end, { buffer = buf, desc = 'Confirm Mongo copy' })
      end

      local function mongo_copy_preflight(spec)
        mongo_copy_job(spec, mongo_copy_preflight_script(spec), function(stats)
          if stats.targetType == 'view' then
            vim.notify('Target ' .. spec.target_collection .. ' is a view, not a collection', vim.log.levels.ERROR)
            return
          end
          if stats.targetExists and spec.mode.key == 'create' then
            vim.notify('Target collection already exists — pick Replace or Merge', vim.log.levels.WARN)
            return
          end
          mongo_copy_confirm(spec, stats)
        end)
      end

      local function mongo_copy_same_namespace(spec)
        return mongo_active_url(spec.source) == mongo_active_url(spec.target)
          and spec.source_collection == spec.target_collection
      end

      local function mongo_copy_choose_mode(spec)
        vim.ui.select(mongo_copy_modes, {
          prompt = 'Copy into ' .. mongo_copy_endpoint(spec.target, spec.target_collection) .. ':',
          format_item = function(mode)
            return mode.label
          end,
        }, function(mode)
          if not mode then return end
          mongo_copy_preflight(vim.tbl_extend('force', spec, { mode = mode }))
        end)
      end

      local function mongo_copy_choose_target_collection(spec)
        vim.ui.input({
          prompt = 'Target collection on ' .. mongo_db_display(spec.target) .. ': ',
          default = spec.source_collection,
        }, function(name)
          if not name or vim.trim(name) == '' then return end

          local filled = vim.tbl_extend('force', spec, { target_collection = vim.trim(name) })
          if mongo_copy_same_namespace(filled) then
            vim.notify('Source and target are the same collection', vim.log.levels.ERROR)
            return
          end
          mongo_copy_choose_mode(filled)
        end)
      end

      local mongo_copy_new_database = '+ new database…'

      local function mongo_copy_ordered_databases(target, names)
        local active = mongo_active_db(target)
        if not active or not vim.tbl_contains(names, active) then return names end

        local rest = vim.tbl_filter(function(name)
          return name ~= active
        end, names)
        return vim.list_extend({ active }, rest)
      end

      local function mongo_copy_database_items(target, names)
        local ordered = mongo_copy_ordered_databases(target, names)
        return vim.list_extend(vim.deepcopy(ordered), { mongo_copy_new_database })
      end

      local function mongo_copy_choose_target_database(spec)
        local function continue(name)
          if not name or vim.trim(name) == '' then return end
          mongo_copy_choose_target_collection(vim.tbl_extend('force', spec, {
            target = mongo_copy_target_entry(spec.target, vim.trim(name)),
          }))
        end

        local function ask_new_database()
          vim.ui.input({ prompt = 'New database on ' .. spec.target.label .. ': ' }, continue)
        end

        mongo_start_job(spec.target, mongo_list_databases_script, function(exit_code, output)
          local names = mongo_parse_names(exit_code, output)
          if not names then
            ask_new_database()
            return
          end

          vim.ui.select(mongo_copy_database_items(spec.target, names), {
            prompt = 'Copy into which database on ' .. spec.target.label .. ':',
          }, function(name)
            if name == mongo_copy_new_database then return ask_new_database() end
            continue(name)
          end)
        end)
      end

      local function mongo_copy_choose_target(spec)
        vim.ui.select(mongo_database_items(true), {
          prompt = 'Copy ' .. spec.source_collection .. ' into which connection:',
        }, function(_, idx)
          if not idx then return end

          local target = mongo_databases[idx]
          if mongo_is_protected(target) then
            vim.notify('Refusing to copy into a protected database: ' .. target.label, vim.log.levels.ERROR)
            return
          end
          mongo_copy_choose_target_database(vim.tbl_extend('force', spec, { target = target }))
        end)
      end

      local function mongo_copy_choose_source_collection(source)
        mongo_start_job(source, mongo_list_collections_script, function(exit_code, output, errors)
          local names = mongo_parse_names(exit_code, output)
          if not names then
            vim.notify('Could not list collections on ' .. source.label .. ': ' .. (errors[1] or output[1] or 'no output'), vim.log.levels.WARN)
            return
          end

          vim.ui.select(names, { prompt = 'Copy which collection from ' .. mongo_db_display(source) .. ':' }, function(name)
            if not name then return end
            mongo_copy_choose_target({ source = source, source_collection = name })
          end)
        end)
      end

      -- Copy a collection into another database on this or any other connection
      vim.keymap.set('n', '<leader>mC', function()
        mongo_with_current_db(function(source)
          if not mongo_active_db(source) then
            mongo_pick_db(source, function()
              mongo_copy_choose_source_collection(source)
            end)
            return
          end
          mongo_copy_choose_source_collection(source)
        end)
      end, { desc = '[M]ongo [C]opy collection to another database' })
      -- Normal mode: run current file
      vim.keymap.set('n', '<leader>me', function()
        local buf = vim.api.nvim_get_current_buf()
        if mongo_update_preview_buffers[buf] then
          run_mongosh(mongo_buffer_text(buf), false, { raw = true })
          return
        end

        if vim.bo[buf].buftype == 'nofile' then
          run_mongosh(mongo_buffer_text(buf), false)
          return
        end

        local file = vim.fn.expand '%:p'
        run_mongosh(file, true)
      end, { desc = '[M]ongo [E]xecute current file' })

      -- Visual mode: run selected text
      vim.keymap.set('v', '<leader>me', function()
        -- Get visual selection
        local buf = vim.api.nvim_get_current_buf()
        vim.cmd 'normal! "vy'
        local selection = vim.fn.getreg 'v'
        run_mongosh(selection, false, { raw = mongo_update_preview_buffers[buf] == true })
      end, { desc = '[M]ongo [E]xecute selection' })

      -- Select MongoDB database
      vim.keymap.set('n', '<leader>ms', mongo_select_database, { desc = '[M]ongo [S]elect database' })

      -- Switch the database used on the current connection
      vim.keymap.set('n', '<leader>mb', function()
        mongo_with_current_db(mongo_pick_db)
      end, { desc = '[M]ongo switch data[b]ase' })

      -- Insert a find query for a collection of the current database
      vim.keymap.set('n', '<leader>mo', function()
        if not vim.bo.modifiable then
          vim.notify('Current buffer is not modifiable', vim.log.levels.WARN)
          return
        end

        local win = vim.api.nvim_get_current_win()
        mongo_with_current_db(function(db)
          if not mongo_active_db(db) then
            mongo_pick_db(db, function()
              mongo_pick_collection(db, win)
            end)
            return
          end
          mongo_pick_collection(db, win)
        end)
      end, { desc = '[M]ongo insert c[o]llection query' })

      -- Add new MongoDB database
      local function mongo_prompt_protection(label, url)
        vim.ui.select({ 'Normal database', 'Protected (production primary)' }, {
          prompt = 'Protection level for ' .. label .. ':',
        }, function(_, choice)
          if not choice then return end
          mongo_add_database(label, url, choice == 2)
        end)
      end

      vim.keymap.set('n', '<leader>ma', function()
        vim.ui.input({ prompt = 'Database label: ' }, function(label)
          if not label or label == '' then return end
          vim.ui.input({ prompt = 'MongoDB URL: ' }, function(url)
            if not url or url == '' then return end
            mongo_prompt_protection(label, url)
          end)
        end)
      end, { desc = '[M]ongo [A]dd database' })

      vim.keymap.set('n', '<leader>mp', mongo_toggle_protection, { desc = '[M]ongo toggle [P]rotection' })

      -- Show current MongoDB database
      local function mongo_status_rows(db)
        return {
          { 'Connection', string.format('%s  (%d of %d)', db.label, mongo_current_db, #mongo_databases) },
          { 'Protected', mongo_is_protected(db) and 'yes — confirm before every query' or 'no' },
          { 'Server URL', db.url },
          { 'Database', mongo_active_db(db) or '— none, you will be asked on next query' },
          { 'Runs against', mongo_active_url(db) },
        }
      end

      local function mongo_status_lines(db)
        return vim.tbl_map(function(row)
          return string.format('%-13s %s', row[1], row[2])
        end, mongo_status_rows(db))
      end

      vim.keymap.set('n', '<leader>mc', function()
        mongo_with_current_db(function(db)
          local buf, win = mongo_open_float(mongo_status_lines(db), ' Mongo status ', 'text', {
            modifiable = false,
            footer = ' <leader>ms connection · <leader>mb database · <leader>mo collection · q close ',
          })
          mongo_close_keymaps(buf, win, 'Close Mongo status')
        end)
      end, { desc = '[M]ongo show [C]urrent database' })

      -- Delete a MongoDB database
      vim.keymap.set('n', '<leader>md', function()
        if #mongo_databases <= 1 then
          vim.notify('Cannot delete the last database', vim.log.levels.WARN)
          return
        end

        vim.ui.select(mongo_database_items(), {
          prompt = 'Delete MongoDB database:',
        }, function(_, idx)
          if idx then
            local removed = table.remove(mongo_databases, idx)
            if mongo_current_db > #mongo_databases then
              mongo_current_db = #mongo_databases
            end
            mongo_save()
            vim.notify('Deleted: ' .. removed.label)
          end
        end)
      end, { desc = '[M]ongo [D]elete database' })

      local function mongo_quote_json_string(text)
        return vim.fn.json_encode(text)
      end

      local function mongo_pair_value_node(pair)
        return pair:field('value')[1]
      end

      local function mongo_pair_key(pair)
        local key_node = pair:field('key')[1]
        if not key_node then return nil end

        return vim.treesitter.get_node_text(key_node, 0):gsub('^["\']', ''):gsub('["\']$', '')
      end

      local function mongo_table_key_count(value)
        return vim.tbl_count(value)
      end

      local function mongo_object_id_value(value)
        if type(value) ~= 'table' then return nil end
        if mongo_table_key_count(value) ~= 1 then return nil end
        if type(value['$oid']) ~= 'string' then return nil end
        return value['$oid']
      end

      local function mongo_is_object_id_value(value)
        return mongo_object_id_value(value) ~= nil
      end

      local function mongo_is_object_id_node(node)
        return mongo_is_object_id_value(mongo_decoded_json_value(vim.treesitter.get_node_text(node, 0)))
      end

      local function mongo_is_dbref_value(value)
        if type(value) ~= 'table' then return false end
        if type(value['$ref']) ~= 'string' then return false end
        return value['$id'] ~= nil
      end

      local function mongo_is_dbref_node(node)
        return mongo_is_dbref_value(mongo_decoded_json_value(vim.treesitter.get_node_text(node, 0)))
      end

      local function mongo_is_dbref_object_id_node(node)
        if not mongo_is_object_id_node(node) then return false end

        local parent_pair = node:parent()
        if not parent_pair or parent_pair:type() ~= 'pair' then return false end
        if mongo_pair_key(parent_pair) ~= '$id' then return false end

        local dbref_node = parent_pair:parent()
        return dbref_node and dbref_node:type() == 'object' and mongo_is_dbref_node(dbref_node)
      end

      local function mongo_format_json_value(text, opts)
        local options = opts or {}
        if options.inside_dbref then return text end

        local object_id = mongo_object_id_value(mongo_decoded_json_value(text))
        if object_id then return 'ObjectId(' .. mongo_quote_json_string(object_id) .. ')' end
        return text
      end

      -- Get JSON path and value at cursor position
      local function mongo_json_path_info()
        local ts = vim.treesitter
        local node = ts.get_node()
        if not node then
          vim.notify('No Treesitter node under cursor', vim.log.levels.WARN)
          return
        end

        local path_parts = {}
        local value_node
        local inside_dbref = false

        while node do
          local parent = node:parent()
          if not parent then break end

          local parent_type = parent:type()

          if parent_type == 'pair' then
            -- Get the key from the pair
            local object_node = parent:parent()
            local pair_is_object_id = object_node
              and object_node:type() == 'object'
              and mongo_is_object_id_node(object_node)
              and not mongo_is_dbref_object_id_node(object_node)
            local key = mongo_pair_key(parent)
            if key and not pair_is_object_id then table.insert(path_parts, 1, key) end
            value_node = value_node or (pair_is_object_id and object_node or mongo_pair_value_node(parent))
            inside_dbref = inside_dbref
              or (object_node and object_node:type() == 'object' and mongo_is_dbref_node(object_node))
          elseif parent_type == 'array' then
            -- Only include array index if the array is a value inside a pair (object property)
            local array_parent = parent:parent()
            if array_parent and array_parent:type() == 'pair' then
              -- Find index of current node in array
              local index = 0
              for child in parent:iter_children() do
                if child:id() == node:id() then break end
                -- Skip punctuation nodes
                local child_type = child:type()
                if child_type ~= ',' and child_type ~= '[' and child_type ~= ']' then
                  index = index + 1
                end
              end
              table.insert(path_parts, 1, tostring(index))
            end
            value_node = value_node or node
            -- If array is at root level (not inside a pair), skip the index
          end

          node = parent
        end

        if #path_parts == 0 then
          vim.notify('Could not determine JSON path', vim.log.levels.WARN)
          return
        end

        return {
          path = table.concat(path_parts, '.'),
          value = value_node and ts.get_node_text(value_node, 0) or nil,
          inside_dbref = inside_dbref,
        }
      end

      -- Copy JSON path at cursor position
      local function mongo_copy_json_path()
        local info = mongo_json_path_info()
        if not info then return end

        local path = mongo_quote_json_string(info.path)
        vim.fn.setreg('+', path)
        vim.notify('Copied: ' .. path)
      end

      local function mongo_copy_json_path_with_value()
        local info = mongo_json_path_info()
        if not info then return end

        if not info.value then
          vim.notify('Could not determine JSON value', vim.log.levels.WARN)
          return
        end

        local text = mongo_quote_json_string(info.path) .. ': ' .. mongo_format_json_value(info.value, {
          inside_dbref = info.inside_dbref,
        })
        vim.fn.setreg('+', text)
        vim.notify('Copied: ' .. text)
      end

      vim.keymap.set('n', '<leader>my', mongo_copy_json_path, { desc = '[M]ongo [Y]ank JSON path' })
      vim.keymap.set('n', '<leader>mY', mongo_copy_json_path_with_value, { desc = '[M]ongo [Y]ank JSON path with value' })

      local mongo_links_file = vim.fn.stdpath('data') .. '/mongo_links.json'

      local mongo_links_seed_lines = {
        '{',
        '  "KompareOffer": [',
        '    {',
        '      "db": "local/kompare-platform",',
        '      "links": [',
        '        { "label": "New KPAS", "path": "http://kp.loc:3003/kompare-offer/<id>" },',
        '        { "label": "Old KPAS", "path": "http://kp.loc/administracija/kpas/osiguranje-auto-ponude/<id>/" }',
        '      ]',
        '    }',
        '  ],',
        '  "SellingOpportunity": [',
        '    {',
        '      "db": "local/kompare-platform",',
        '      "links": [',
        '        { "label": "New KPAS", "path": "http://kp.loc:3003/selling-opportunity/<id>" },',
        '        { "label": "Old KPAS", "path": "http://kp.loc/administracija/kpas/osiguranje-auto-prodajne-prilike/<id>/" }',
        '      ]',
        '    }',
        '  ]',
        '}',
      }

      local function mongo_links_seed()
        if vim.fn.filereadable(mongo_links_file) == 1 then return end
        vim.fn.writefile(mongo_links_seed_lines, mongo_links_file)
      end

      local function mongo_links_load()
        mongo_links_seed()
        local content = table.concat(vim.fn.readfile(mongo_links_file), '\n')
        return mongo_decoded_json_value(content) or {}
      end

      local function mongo_document_node_at_cursor()
        local node = vim.treesitter.get_node()
        while node do
          local parent = node:parent()
          local parent_type = parent and parent:type()
          local grandparent = parent and parent:parent()
          local root_object = node:type() == 'object' and parent_type == 'document'
          local root_array_object = node:type() == 'object'
            and parent_type == 'array'
            and grandparent
            and grandparent:type() == 'document'
          if root_object or root_array_object then return node end
          node = parent
        end
        return nil
      end

      local function mongo_document_id_at_cursor()
        local doc_node = mongo_document_node_at_cursor()
        if not doc_node then return nil end

        local doc = mongo_decoded_json_value(vim.treesitter.get_node_text(doc_node, 0))
        if type(doc) ~= 'table' then return nil end
        return mongo_object_id_value(doc._id)
      end

      local function mongo_links_for(collection, db_label)
        local entries = mongo_links_load()[collection] or {}
        for _, entry in ipairs(entries) do
          if entry.db == db_label then return entry.links or {} end
        end
        return {}
      end

      mongo_show_links = function(buf)
        local q = mongo_result_queries[buf]
        if not q or not q.collection then
          vim.notify('No collection tracked for this Mongo result', vim.log.levels.WARN)
          return
        end

        local id = mongo_document_id_at_cursor()
        if not id then
          vim.notify('Could not find document _id under cursor', vim.log.levels.WARN)
          return
        end

        local links = mongo_links_for(q.collection, q.db.label)
        if #links == 0 then
          vim.notify('No links configured for ' .. q.collection .. ' @ ' .. q.db.label .. ' — <leader>mL to edit', vim.log.levels.WARN)
          return
        end

        local lines = {}
        for _, link in ipairs(links) do
          if #lines > 0 then table.insert(lines, '') end
          table.insert(lines, '# ' .. link.label)
          table.insert(lines, (link.path:gsub('<id>', id)))
        end
        mongo_open_float(lines, ' Mongo links [' .. q.collection .. '] ', 'markdown')
      end

      vim.keymap.set('n', '<leader>mL', function()
        mongo_links_seed()
        vim.cmd.edit(mongo_links_file)
      end, { desc = '[M]ongo edit [L]inks config' })
    end,
  },
}
