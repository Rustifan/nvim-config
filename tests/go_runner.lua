-- Run with: nvim --headless -u NONE -l tests/go_runner.lua
vim.opt.runtimepath:append(vim.fn.getcwd())
vim.g.mapleader = ' '
vim.env.GOPROXY = 'off'
vim.env.GOSUMDB = 'off'
local root = assert(vim.uv.fs_mkdtemp '/tmp/opencode/nvim-go-runner-XXXXXX')
local messages = {}
vim.notify = function(message)
  messages[#messages + 1] = message
end

local function write(path, code)
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  assert(vim.fn.writefile(vim.split(code, '\n', { plain = true }), path) == 0)
end

write(root .. '/go.mod', 'module example.test/live\n\ngo 1.22\n')
write(root .. '/internal/message/message.go', 'package message\nfunc Value() string { return "module-import" }')
write(root .. '/pkg/library.go', 'package library\nfunc Value() string { return "own-package" }')
vim.fn.mkdir(root .. '/src', 'p')
local runner = require 'ivan.code_runner'
runner.setup { go = { goimports = false } }
local source_win = vim.api.nvim_get_current_win()

local function source(name, lines)
  vim.api.nvim_set_current_win(source_win)
  local buf = vim.api.nvim_create_buf(true, false)
  if name then
    vim.api.nvim_buf_set_name(buf, root .. '/' .. name)
  end
  vim.api.nvim_win_set_buf(source_win, buf)
  vim.bo[buf].filetype = 'go'
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
  assert(vim.wait(60000, predicate, 10), 'timed out waiting for Go: ' .. text())
end

local function finished(code)
  await(function()
    return vim.b[output()].code_run_exit_code ~= nil
  end)
  if code ~= nil then
    assert(vim.b[output()].code_run_exit_code == code, text())
  end
  return text()
end

local function keys(value)
  vim.api.nvim_feedkeys(vim.keycode(value), 'mx', false)
end

local function no_tempfiles()
  local paths = vim.fn.glob(root .. '/**/.nvim-run-*', false, true)
  assert(#paths == 0, 'Go execution directories were not cleaned up: ' .. vim.inspect(paths))
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

test('Space e executes an unsaved Go main buffer without saving or stealing focus', function()
  write(root .. '/src/unsaved.go', 'package main\nfunc main() { println("on-disk") }')
  local buf = source('src/unsaved.go', { 'package main', 'import "fmt"', 'func main() { fmt.Println("unsaved") }' })
  keys ' e'
  assert(finished(0):find('\nunsaved\n', 1, true), text())
  assert(vim.api.nvim_get_current_win() == source_win and vim.api.nvim_get_current_buf() == buf)
  assert(vim.bo[buf].modified and vim.fn.readfile(root .. '/src/unsaved.go')[2]:find('on-disk', 1, true))
  assert(vim.b[output()].code_run_cwd == root)
  no_tempfiles()
end)

test('Statements in a scratch buffer get main and fmt without goimports', function()
  local cwd = vim.fn.getcwd()
  vim.api.nvim_set_current_win(source_win)
  vim.cmd('lcd ' .. vim.fn.fnameescape(root))
  source(nil, { 'value := "scratch"', 'fmt.Println(value)' })
  vim.cmd 'CodeRun'
  assert(finished(0):find('\nscratch\n', 1, true), text())
  assert(vim.b[output()].code_run_cwd == root)
  vim.cmd('lcd ' .. vim.fn.fnameescape(cwd))
  no_tempfiles()
end)

test('Functions, types, globals, and calls can be mixed in a snippet', function()
  source('src/functions.go', {
    'type Message struct { Value string }',
    'var prefix = "go-"',
    'func bla(a string) { fmt.Println(prefix + a) }',
    'bla(Message{Value: "snippet"}.Value)',
  })
  runner.run()
  assert(finished(0):find('\ngo-snippet\n', 1, true), text())
end)

test('Statement snippets preserve local var declaration scope and evaluation order', function()
  source('src/locals.go', {
    'import s "strings"; value := "scoped"',
    'var upper = s.ToUpper(value)',
    'fmt.Println(upper)',
  })
  runner.run()
  assert(finished(0):find('\nSCOPED\n', 1, true), text())
end)

test('A selection reuses aliased imports from the buffer and drops unused imports', function()
  source('src/selection.go', {
    'package library',
    'import (',
    '  f "fmt"',
    '  str "strings"',
    '  "time"',
    ')',
    'func example() {',
    '  f.Println(str.ToUpper("selected"))',
    '}',
  })
  vim.api.nvim_win_set_cursor(source_win, { 8, 0 })
  keys 'V'
  keys ' e'
  assert(finished(0):find('\nSELECTED\n', 1, true), text())
  assert(vim.fn.mode() == 'n')
end)

test('Character selection executes a Go statement without surrounding invalid code', function()
  local code = 'fmt.Println("café")'
  source('src/character.go', { 'BAD ' .. code .. ' BAD' })
  vim.api.nvim_win_set_cursor(source_win, { 1, 4 })
  keys 'v'
  vim.api.nvim_win_set_cursor(source_win, { 1, 4 + #code - 1 })
  keys ' e'
  assert(finished(0):find('\ncafé\n', 1, true), text())
end)

test('Go lexical splitting handles raw strings, comments, loops, and function literals', function()
  source('src/scanning.go', {
    'func value() string { return `func main() {;}` } /* comment',
    'with a newline */',
    'for i := 0; i < 2; i++ { fmt.Println(value()) }',
    'func() { fmt.Println("literal") }()',
  })
  runner.run()
  assert(finished(0):find('\nfunc main() {;}\nfunc main() {;}\nliteral\n', 1, true), text())
end)

test('Local names that shadow fmt do not trigger an unused fmt import', function()
  source('src/shadow.go', {
    'fmt := struct { Println func(string) }{func(value string) { println(value) }}',
    'fmt.Println("shadowed")',
  })
  runner.run()
  assert(finished(0):find('[stderr] shadowed', 1, true), text())
end)

test('Internal module imports resolve from the Go module root', function()
  source('src/module.go', {
    'import message "example.test/live/internal/message"',
    'fmt.Println(message.Value())',
  })
  runner.run()
  assert(finished(0):find('\nmodule-import\n', 1, true), text())
end)

test('Importing the source package works without generated files contaminating it', function()
  source('pkg/library.go', { 'import lib "example.test/live/pkg"', 'fmt.Println(lib.Value())' })
  runner.run()
  assert(finished(0):find('\nown-package\n', 1, true), text())
  assert(vim.fn.readfile(root .. '/pkg/library.go')[1] == 'package library')
  no_tempfiles()
end)

test('Nested go.mod takes priority over JavaScript project roots', function()
  write(root .. '/nested/go.mod', 'module example.test/nested\n\ngo 1.22\n')
  write(root .. '/nested/src/package.json', '{}')
  source('nested/src/main.go', { 'import "os"', 'cwd, _ := os.Getwd()', 'fmt.Println(cwd)' })
  runner.run()
  assert(finished(0):find('\n' .. root .. '/nested\n', 1, true), text())
  assert(vim.b[output()].code_run_cwd == root .. '/nested')
end)

test('Workspace imports resolve through go.work', function()
  write(root .. '/workspace/go.work', 'go 1.22\nuse (\n./a\n./b\n)\n')
  write(root .. '/workspace/a/go.mod', 'module example.test/a\n\ngo 1.22\n')
  write(root .. '/workspace/b/go.mod', 'module example.test/b\n\ngo 1.22\n')
  write(root .. '/workspace/b/value.go', 'package b\nfunc Value() string { return "workspace" }')
  vim.fn.mkdir(root .. '/workspace/a/src', 'p')
  source('workspace/a/src/main.go', { 'import "example.test/b"', 'fmt.Println(b.Value())' })
  runner.run()
  assert(finished(0):find('\nworkspace\n', 1, true), text())
end)

test('Compiler diagnostics map a selected line back to the original file', function()
  source('src/error with spaces.go', { 'BAD', '', '', '', '', '', 'unknownName()', 'BAD' })
  vim.cmd '7,7CodeRun'
  local result = finished(1)
  assert(result:find('error with spaces.go:7', 1, true) and result:find('undefined: unknownName', 1, true), result)
  assert(not result:find('.nvim-run-', 1, true), result)
  no_tempfiles()
end)

test('Whole library buffers report how to execute their code', function()
  source('src/library.go', { 'package library', 'func Value() string { return "library" }' })
  runner.run()
  assert(finished(1):find('whole Go files must be package main with func main()', 1, true), text())
  no_tempfiles()
end)

test('Syntax errors and unavailable runtimes clean up or avoid execution files', function()
  source('src/syntax.go', { 'fmt.Println(' })
  runner.run()
  assert(finished(1):find('expected', 1, true), text())
  no_tempfiles()
  runner.setup { go = { executable = 'nvim-nonexistent-go-executable' } }
  source('src/missing-runtime.go', { 'println("test")' })
  runner.run()
  assert(messages[#messages]:find('Go is not installed', 1, true))
  no_tempfiles()
  runner.setup { go = { goimports = false } }
end)

if vim.fn.executable 'goimports' == 1 then
  test('goimports infers standard imports and preserves compact function panic locations', function()
    runner.setup()
    source('src/inferred.go', { 'fmt.Println(strings.ToUpper("inferred"), math.Sqrt(9))' })
    runner.run()
    assert(finished(0):find('\nINFERRED 3\n', 1, true), text())
    source('src/import-semicolon.go', { 'import s "strings"; fmt.Println(s.ToUpper("semicolon"))' })
    runner.run()
    assert(finished(0):find('\nSEMICOLON\n', 1, true), text())
    source('src/panic.go', { 'BAD', '', '', '', 'func fail() { panic("snippet-panic") }; fail()', 'BAD' })
    vim.cmd '5,5CodeRun'
    local result = finished(1)
    assert(result:find('panic: snippet-panic', 1, true) and result:find('panic.go:5', 1, true), result)
    assert(not result:find('.nvim-run-', 1, true), result)
    no_tempfiles()
  end)
end

test('Go output streams before exit and stopping also terminates the compiled program', function()
  local marker = root .. '/should-not-be-created'
  source('src/stopping.go', {
    'import "time"',
    'import "os"',
    'fmt.Println("running")',
    'time.Sleep(2 * time.Second)',
    'os.WriteFile(' .. vim.json.encode(marker) .. ', []byte("still alive"), 0600)',
    'select {}',
  })
  runner.run()
  await(function()
    return text():find('\nrunning\n', 1, true) ~= nil
  end)
  assert(vim.b[output()].code_run_exit_code == nil)
  vim.cmd 'CodeRunStop'
  assert(finished():find(': stopped ---', 1, true), text())
  vim.wait(2500, function()
    return vim.fn.filereadable(marker) == 1
  end)
  assert(vim.fn.filereadable(marker) == 0, 'the compiled program kept running after Stop')
  no_tempfiles()
end)

test('Neovim exit removes Go execution directories while a program is running', function()
  source('src/shutdown.go', { 'import "time"', 'fmt.Println("shutdown-ready")', 'time.Sleep(time.Hour)' })
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
print('Passed ' .. passed .. ' Go runner integration tests')
vim.cmd 'qa!'
