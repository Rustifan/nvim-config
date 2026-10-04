local M = { label = 'OpenCode', default_model = 'default' }

function M.models(callback)
  vim.system(
    { 'opencode', 'models' },
    { text = true },
    vim.schedule_wrap(function(result)
      if result.code ~= 0 then
        vim.notify('OpenCode: ' .. vim.trim(result.stderr), vim.log.levels.ERROR)
        return
      end
      local models = { 'default' }
      for model in result.stdout:gmatch '[^\r\n]+' do
        table.insert(models, model)
      end
      callback(models)
    end)
  )
end

function M.prepare(handler, model, thinking, prompt)
  local system_prompt = handler.system_prompt
  if handler.schema then
    system_prompt = system_prompt .. '\nReturn ONLY a JSON object matching this schema, without code fences:\n' .. handler.schema
  end
  local permission = { ['*'] = 'deny' }
  if handler.tools then
    permission.read, permission.glob, permission.grep = 'allow', 'allow', 'allow'
  end
  local config = {
    share = 'disabled',
    agent = { nvim_editor = { mode = 'primary', prompt = system_prompt, permission = permission } },
  }
  local command = { 'opencode', 'run', '--format', 'json', '--agent', 'nvim_editor' }
  if model ~= 'default' then
    vim.list_extend(command, { '--model', model })
  end
  if thinking then
    vim.list_extend(command, { '--thinking', '--variant', 'high' })
  end
  return command, { stdin = prompt, env = { OPENCODE_CONFIG_CONTENT = vim.json.encode(config) } }
end

local function decode_events(stdout)
  local events = {}
  for line in stdout:gmatch '[^\r\n]+' do
    local ok, event = pcall(vim.json.decode, line)
    if ok and type(event) == 'table' then
      table.insert(events, event)
    end
  end
  return events
end

local function event_text(events, kind)
  local parts = {}
  for _, event in ipairs(events) do
    local text = event.type == kind and vim.tbl_get(event, 'part', 'text')
    if type(text) == 'string' then
      table.insert(parts, text)
    end
  end
  return table.concat(parts, '\n\n')
end

function M.parse(result, handler)
  local events = decode_events(result.stdout)
  local error_event = vim.iter(events):find(function(event)
    return event.type == 'error'
  end)
  if error_event then
    return nil, vim.tbl_get(error_event, 'error', 'data', 'message') or vim.inspect(error_event.error)
  end
  if result.code ~= 0 then
    return nil, vim.trim(result.stderr ~= '' and result.stderr or result.stdout)
  end
  local text = event_text(events, 'text')
  if text == '' then
    return nil, 'OpenCode returned no response'
  end
  local thoughts = event_text(events, 'reasoning')
  if not handler.schema then
    return { text = text, thoughts = thoughts ~= '' and thoughts or nil }
  end
  local json = text:match '^%s*```[^\n]*\n(.-)\n?```%s*$' or text
  local ok, structured = pcall(vim.json.decode, json)
  if not ok or type(structured) ~= 'table' or type(structured.replacement) ~= 'string' or type(structured.file_edits) ~= 'table' then
    return nil, 'OpenCode returned an invalid edit (<leader>cr to retry)'
  end
  for _, edit in ipairs(structured.file_edits) do
    if type(edit) ~= 'table' or type(edit.path) ~= 'string' or type(edit.find) ~= 'string' or type(edit.replace) ~= 'string' then
      return nil, 'OpenCode returned an invalid file edit (<leader>cr to retry)'
    end
  end
  return { text = text, structured = structured, thoughts = thoughts ~= '' and thoughts or nil }
end

return M
