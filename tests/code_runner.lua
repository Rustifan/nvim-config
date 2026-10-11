-- Run with: nvim --headless -u NONE -l tests/code_runner.lua
vim.opt.runtimepath:append(vim.fn.getcwd())
vim.g.mapleader = ' '
local root = assert(vim.uv.fs_mkdtemp '/tmp/opencode/nvim-code-runner-XXXXXX')
local messages = {}
vim.notify = function(message)
  messages[#messages + 1] = message
end

local function write(path, text)
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  assert(vim.fn.writefile(vim.split(text, '\n', { plain = true }), path) == 0)
end

write(root .. '/package.json', '{"type":"module"}')
write(root .. '/src/helper.ts', 'export function helper(value: string): string { return value.toUpperCase() }')
write(root .. '/node_modules/demo/package.json', '{"main":"index.cjs"}')
write(root .. '/node_modules/demo/index.cjs', 'module.exports = { value: "project-dependency" }')
local source_win = vim.api.nvim_get_current_win()
local runner = require 'ivan.code_runner'
runner.setup { node = { tsx = false } }

local function source(name, filetype, lines)
  vim.api.nvim_set_current_win(source_win)
  local buf = vim.api.nvim_create_buf(true, false)
  if name then
    vim.api.nvim_buf_set_name(buf, root .. '/' .. name)
  end
  vim.api.nvim_win_set_buf(source_win, buf)
  vim.bo[buf].filetype = filetype
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return buf
end

local function output()
  local buf = vim.fn.bufnr 'code-run://output'
  assert(buf > 0, 'output buffer is missing')
  return buf, table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n') .. '\n'
end

local function text()
  local _, content = output()
  return content
end

local function await(predicate)
  assert(vim.wait(10000, predicate, 10), 'timed out waiting for execution: ' .. text())
end

local function finished(code)
  await(function()
    local buf = output()
    return vim.b[buf].code_run_exit_code ~= nil
  end)
  local buf = output()
  if code ~= nil then
    assert(vim.b[buf].code_run_exit_code == code, text())
  end
  return text()
end

local function map(key, mode)
  local mapping = vim.fn.maparg(key, mode or 'n', false, true)
  assert(type(mapping.callback) == 'function', 'missing mapping: ' .. key)
  mapping.callback()
end

local function keys(value)
  vim.api.nvim_feedkeys(vim.keycode(value), 'mx', false)
end

local function no_tempfiles()
  local paths = vim.fn.glob(root .. '/**/.nvim-run-*', false, true)
  assert(#paths == 0, 'execution files were not cleaned up: ' .. vim.inspect(paths))
end

local passed = 0
local function test(name, scenario)
  local ok, failure = xpcall(scenario, debug.traceback)
  if not ok then
    runner.stop()
    vim.wait(4000, function()
      return #vim.fn.glob(root .. '/**/.nvim-run-*', false, true) == 0
    end)
    vim.fn.delete(root, 'rf')
    io.stderr:write(name .. ':\n' .. failure .. '\n')
    vim.cmd 'cquit 1'
    return
  end
  passed = passed + 1
  print('PASS ' .. name)
end

test('Normal mapping executes unsaved TypeScript without saving or stealing focus', function()
  write(root .. '/src/unsaved.ts', 'console.log("on-disk")')
  local buf = source('src/unsaved.ts', 'typescript', { 'function bla(a: string) { console.log(a) }', 'bla("asd")' })
  keys ' e'
  assert(finished(0):find('\nasd\n', 1, true), text())
  assert(vim.api.nvim_get_current_win() == source_win)
  assert(vim.api.nvim_get_current_buf() == buf and vim.bo[buf].modified)
  assert(vim.fn.readfile(root .. '/src/unsaved.ts')[1] == 'console.log("on-disk")')
  no_tempfiles()
end)

test('Native TypeScript resolves relative and node_modules imports with top-level await', function()
  source('src/imports.mts', 'typescript', {
    'import { helper } from "./helper.ts"',
    'import demo from "demo"',
    'console.log(helper(await Promise.resolve("relative")), demo.value, process.cwd())',
  })
  vim.cmd 'CodeRun'
  assert(finished(0):find('RELATIVE project-dependency ' .. root, 1, true), text())
  no_tempfiles()
end)

test('TypeScript enums and parameter properties execute through native transformation', function()
  source('src/transform.ts', 'typescript', {
    'enum Color { Red, Green }',
    'class Box { constructor(public value: Color) {} }',
    'console.log(new Box(Color.Green).value)',
  })
  runner.run()
  assert(finished(0):find('\n1\n', 1, true), text())
end)

test('CommonJS TypeScript retains require and its module scope', function()
  source('src/commonjs.cts', 'typescript', {
    'const demo = require("demo")',
    'const message: string = demo.value',
    'console.log(message, typeof __dirname)',
  })
  runner.run()
  assert(finished(0):find('project-dependency string', 1, true), text())
end)

test('JavaScript works in both explicit CommonJS and ES modules', function()
  source('src/javascript.cjs', 'javascript', { 'console.log(require("demo").value)' })
  runner.run()
  assert(finished(0):find('\nproject-dependency\n', 1, true), text())
  source('src/javascript.mjs', 'javascript', { 'import demo from "demo"; console.log(demo.value)' })
  runner.run()
  assert(finished(0):find('\nproject-dependency\n', 1, true), text())
end)

test('Visual line selection excludes invalid surrounding code and leaves registers intact', function()
  source('src/line-selection.ts', 'typescript', { 'INVALID BEFORE', 'console.log("selected-lines")', 'INVALID AFTER' })
  vim.fn.setreg('a', 'keep-register')
  vim.api.nvim_win_set_cursor(source_win, { 2, 0 })
  keys 'V'
  keys ' e'
  assert(finished(0):find('\nselected-lines\n', 1, true), text())
  assert(vim.fn.mode() == 'n')
  assert(vim.fn.getreg 'a' == 'keep-register')
end)

test('Visual character selection respects reversed selections and multibyte characters', function()
  local code = 'console.log("café")'
  source('src/character.ts', 'typescript', { 'BAD ' .. code .. ' BAD' })
  vim.api.nvim_win_set_cursor(source_win, { 1, 4 + #code - 1 })
  keys 'v'
  vim.api.nvim_win_set_cursor(source_win, { 1, 4 })
  map('<leader>e', 'x')
  assert(finished(0):find('\ncafé\n', 1, true), text())
end)

test('Visual character selection honors the exclusive selection option', function()
  local code = 'console.log("exclusive")'
  source('src/exclusive.ts', 'typescript', { code .. '!' })
  vim.o.selection = 'exclusive'
  vim.api.nvim_win_set_cursor(source_win, { 1, 0 })
  keys 'v'
  vim.api.nvim_win_set_cursor(source_win, { 1, #code })
  map('<leader>e', 'x')
  vim.o.selection = 'inclusive'
  assert(finished(0):find('\nexclusive\n', 1, true), text())
end)

test('Visual block selection executes only the selected columns', function()
  local code = 'console.log("block");'
  source('src/block.ts', 'typescript', { 'BAD ' .. code .. ' BAD', 'BAD ' .. code .. ' BAD' })
  vim.api.nvim_win_set_cursor(source_win, { 1, 4 })
  keys '<C-v>'
  vim.api.nvim_win_set_cursor(source_win, { 2, 4 + #code - 1 })
  map('<leader>e', 'x')
  assert(finished(0):find('\nblock\nblock\n', 1, true), text())
end)

test('The selection command re-executes a previous character selection', function()
  local code = 'console.log("last-selection")'
  source('src/last-selection.ts', 'typescript', { 'BAD ' .. code .. ' BAD' })
  vim.api.nvim_win_set_cursor(source_win, { 1, 4 })
  keys 'v'
  vim.api.nvim_win_set_cursor(source_win, { 1, 4 + #code - 1 })
  keys '<Esc>'
  vim.cmd 'CodeRunSelection'
  assert(finished(0):find('\nlast-selection\n', 1, true), text())
end)

test('Line ranges preserve stack-trace lines and remap source paths with spaces', function()
  source('src/error with spaces.mts', 'typescript', { 'INVALID BEFORE', '', 'throw new Error("range-failure")', 'INVALID AFTER' })
  vim.cmd '3,3CodeRun'
  local result = finished(1)
  assert(result:find('[stderr]', 1, true) and result:find('range-failure', 1, true), result)
  assert(result:find('error with spaces.mts:3:', 1, true) or result:find('error%20with%20spaces.mts:3:', 1, true), result)
  assert(not result:find('.nvim-run-', 1, true), result)
  no_tempfiles()
end)

test('Scratch buffers use the current directory and stderr flushes partial lines', function()
  local cwd = vim.fn.getcwd()
  vim.api.nvim_set_current_win(source_win)
  vim.cmd('lcd ' .. vim.fn.fnameescape(root))
  source(nil, 'typescript', { 'process.stdout.write("partial"); process.stderr.write("error-tail")' })
  runner.run()
  local result = finished(0)
  assert(result:find('\npartial\n', 1, true), result)
  assert(result:find('[stderr] error-tail', 1, true), result)
  assert(vim.b[output()].code_run_cwd == root)
  vim.cmd('lcd ' .. vim.fn.fnameescape(cwd))
  no_tempfiles()
end)

test('The nearest package root supplies cwd inside a monorepo', function()
  write(root .. '/packages/child/package.json', '{"type":"module"}')
  write(root .. '/packages/child/src/helper.ts', 'export const value = 42')
  source('packages/child/src/main.ts', 'typescript', { 'console.log(process.cwd())' })
  runner.run()
  assert(finished(0):find('\n' .. root .. '/packages/child\n', 1, true), text())
end)

test('Output streams before exit, remains available when closed, and supports stopping', function()
  source('src/streaming.mts', 'typescript', {
    'process.stdout.write("hel")',
    'setTimeout(() => process.stdout.write("lo\\n"), 50)',
    'setInterval(() => {}, 1000)',
  })
  runner.run()
  await(function()
    return text():find('\nhello\n', 1, true) ~= nil
  end)
  assert(vim.b[output()].code_run_exit_code == nil)
  vim.cmd 'CodeRunOutput'
  assert(vim.api.nvim_get_current_buf() == output())
  map 'q'
  assert(vim.api.nvim_get_current_win() == source_win)
  assert(vim.b[output()].code_run_exit_code == nil)
  vim.cmd 'CodeRunOutput'
  map '<C-c>'
  assert(finished():find(': stopped ---', 1, true), text())
  map 'q'
  no_tempfiles()
end)

test('A new run stops the old one and isolates late output', function()
  source('src/old.mts', 'typescript', { 'console.log("old-ready"); setTimeout(() => console.log("old-late"), 5000)' })
  runner.run()
  await(function()
    return text():find('old-ready', 1, true) ~= nil
  end)
  local buf = output()
  local windows = #vim.api.nvim_list_wins()
  source('src/new.mts', 'typescript', { 'console.log("new-result")' })
  runner.run()
  assert(finished(0):find('\nnew-result\n', 1, true), text())
  assert(not text():find('old-', 1, true), text())
  assert(output() == buf and #vim.api.nvim_list_wins() == windows)
  await(function()
    return #vim.fn.glob(root .. '/**/.nvim-run-*', false, true) == 0
  end)
end)

test('Unsupported filetypes and unavailable source directories report preparation errors', function()
  source('unsupported.txt', 'text', { 'not executable' })
  runner.run()
  assert(messages[#messages]:find('No runner registered for text', 1, true))
  source('missing/directory/main.ts', 'typescript', { 'console.log("cannot write")' })
  runner.run()
  assert(messages[#messages]:find('Cannot create an execution file', 1, true))
  no_tempfiles()
end)

test('Native TSX reports its required runtime', function()
  source('src/native.tsx', 'typescriptreact', { 'console.log(<div />)' })
  runner.run()
  assert(messages[#messages]:find('needs tsx', 1, true))
  no_tempfiles()
end)

test('An additional runner receives context and runs stdin asynchronously', function()
  runner.register_runner('sh', {
    prepare = function(context)
      assert(context.path == root .. '/src/custom.sh' and context.cwd == root)
      return { cmd = { 'bash' }, stdin = context.code, env = { RUNNER_TEST = 'adapter-value' }, label = 'Bash' }
    end,
  })
  source('src/custom.sh', 'sh', { 'printf "%s\\n" "$RUNNER_TEST"' })
  runner.run()
  assert(finished(0):find('\nadapter-value', 1, true), text())
end)

test('Startup failures clean up adapter resources exactly once', function()
  local cleanups = 0
  runner.register_runner('missing_runtime', {
    prepare = function(context)
      local path, cleanup = require('ivan.utils.code_execution').tempfile(context, '.txt')
      return {
        cmd = { 'nvim-code-runner-nonexistent-executable', path },
        cleanup = function()
          cleanups = cleanups + 1
          cleanup()
        end,
      }
    end,
  })
  source('src/start-failure.txt', 'missing_runtime', { 'test' })
  runner.run()
  assert(finished(-1):find('Could not start command', 1, true), text())
  assert(cleanups == 1)
  no_tempfiles()
end)

local tsx = vim.env.NVIM_CODE_RUNNER_TSX
if tsx and tsx ~= '' then
  test('Project-local tsx resolves path aliases, extensionless imports, enums, and JSX', function()
    assert(vim.fn.executable(tsx) == 1, 'NVIM_CODE_RUNNER_TSX is not executable')
    vim.fn.mkdir(root .. '/node_modules/.bin', 'p')
    assert(vim.uv.fs_symlink(tsx, root .. '/node_modules/.bin/tsx'))
    write(root .. '/tsconfig.json', '{"compilerOptions":{"paths":{"@helper":["./src/helper.ts"]},"jsx":"react"}}')
    runner.setup()
    source('src/with-tsx.tsx', 'typescriptreact', {
      'import { helper } from "@helper"',
      'import { helper as relative } from "./helper"',
      'enum Status { Ready }',
      'const React = { createElement(type: string, props: unknown) { return { type, props } } }',
      'const element = <thing label="jsx" />',
      'console.log(helper("alias"), relative("extensionless"), Status.Ready, element.type)',
    })
    runner.run()
    assert(finished(0):find('ALIAS EXTENSIONLESS 0 thing', 1, true), text())
    assert(vim.b[output()].code_run_command[1] == root .. '/node_modules/.bin/tsx')
    no_tempfiles()
  end)
end

test('Neovim exit hooks stop jobs and remove their execution files', function()
  source('src/shutdown.mts', 'typescript', { 'console.log("shutdown-ready"); setInterval(() => {}, 1000)' })
  runner.run()
  await(function()
    return text():find('shutdown-ready', 1, true) ~= nil
  end)
  assert(#vim.fn.glob(root .. '/**/.nvim-run-*', false, true) == 1)
  vim.api.nvim_exec_autocmds('VimLeavePre', {})
  no_tempfiles()
  finished()
end)

vim.fn.delete(root, 'rf')
print('Passed ' .. passed .. ' code runner integration tests')
vim.cmd 'qa!'
