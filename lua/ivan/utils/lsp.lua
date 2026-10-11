local M = {}

local function stop_timer(timer)
  if not timer or timer:is_closing() then
    return
  end
  timer:stop()
  timer:close()
end

function M.request_all(buf, method, params, timeout_ms, callback)
  local clients = vim.lsp.get_clients { bufnr = buf, method = method }
  if #clients == 0 then
    callback {}
    return function() end
  end
  local encodings = {}
  for _, client in ipairs(clients) do
    encodings[client.id] = client.offset_encoding
  end
  local results, count, expected = {}, 0, #clients
  local finished, timer, cancel
  local function finish()
    if finished then
      return
    end
    finished = true
    stop_timer(timer)
    if cancel then
      cancel()
    end
    callback(results)
  end
  local ids
  ids, cancel = vim.lsp.buf_request(buf, method, params, function(err, result, ctx)
    if finished then
      return
    end
    count = count + 1
    results[ctx.client_id] = { error = err, result = not err and result or nil, encoding = encodings[ctx.client_id] }
    if count >= expected then
      finish()
    end
  end, function() end)
  expected = vim.tbl_count(ids)
  if expected == 0 or count >= expected then
    finish()
  end
  if not finished then
    timer = vim.defer_fn(finish, timeout_ms)
  end
  return function()
    finished = true
    stop_timer(timer)
    cancel()
  end
end

return M
