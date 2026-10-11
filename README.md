# kickstart.nvim

## Execute code from the buffer

TypeScript, JavaScript, and Go can be executed directly, including unsaved changes:

| Key / command | Action |
| --- | --- |
| **`<leader>e`** in Normal mode | Execute the entire buffer |
| **`<leader>e`** in Visual mode | Execute only the selection (line, character, or block) |
| `:CodeRun` | Execute the entire buffer |
| `:10,20CodeRun` | Execute a line range |
| `:CodeRunSelection` | Execute the last Visual selection |
| `:CodeRunStop` | Stop the running process |
| `:CodeRunOutput` | Reopen/focus the last output |

The leader is **Space**. Output streams into a reusable bottom split while focus
stays on your code. In the output, **`q` / Esc** closes the split and **Ctrl-C**
stops execution. Closing the output lets the process continue; its output is
retained. Starting another run stops the previous one. The header shows the
runtime, exit status, source lines, and working directory. Stderr is marked with
`[stderr]`.

For example, put this in a `.ts` buffer and press **Space e**:

```ts
function bla(a: string) {
  console.log(a)
}
bla("asd")
```

### JavaScript/TypeScript runtime and imports

- An installed **project-local `tsx`** is preferred, searching upward from the
  source directory (including workspace-level installs), then `tsx` on PATH.
  It supports JSX/TSX, extensionless imports, and tsconfig path aliases.
  Install it in a project with `npm install --save-dev tsx` when needed.
- Otherwise, **Node.js 22.7+** executes JS and TS directly; a current Node LTS
  release is recommended. TypeScript uses `--experimental-transform-types` for
  annotations, enums, and parameter properties. Node does not read `tsconfig.json`,
  support JSX/TSX, or transform decorators. Native ESM relative imports must have
  extensions, e.g. `import { helper } from './helper.ts'`.
- Neither runtime type-checks the code. These are fresh script executions: use
  `console.log`, `console.dir`, etc. to display values. Variables do not persist
  between runs; a selection must include the imports and definitions it needs.

JS/TS code is copied to a unique temporary sibling of the source file, retaining its
extension (`.ts`, `.mts`, `.cts`, `.js`, `.mjs`, `.cjs`, `.tsx`, or `.jsx`). This
keeps relative imports, package module settings, and ancestor `node_modules`
resolution working. The working directory is the nearest package root, then the
Git root, then the source directory. Unnamed scratch buffers use Neovim's current
directory; set `:setfiletype typescript` or `javascript` first.

The original file is never saved by the runner. Temporary files are removed on
completion, stop, startup failure, and Neovim exit. The source directory must be
writable. Selected code is padded with blank lines to preserve source line
numbers; paths in stack traces are displayed as the original source path.
Only the executed buffer/selection uses unsaved content; imported files are read
from disk. File-identity APIs such as `import.meta.url` and `__filename` refer to
the temporary sibling during execution.

The previous diagnostic shortcut is now **`<leader>de`**.

### Go buffers and snippets

The same **Space e** shortcut runs Go using the installed `go` CLI:

- A complete buffer with `package main` and `func main()` runs as a standalone
  program, including unsaved changes.
- Selected statements, or a scratch buffer without a `package` clause, are
  wrapped in `func main()` automatically. Functions and imports stay at package
  scope, along with type and `var`/`const` declarations in snippets that define
  functions. Ordinary statement-only snippets keep their declarations local.
  For example, this also works:

  ```go
  func bla(a string) {
      fmt.Println(a)
  }
  bla("asd")
  ```

- Snippets reuse relevant imports from the source buffer. `fmt` is available
  automatically when used. If **`goimports`** is installed, the runner also infers
  other missing imports and removes unused imports for snippets. It is optional;
  install it with `go install golang.org/x/tools/cmd/goimports@latest` if needed.
- The working directory is the nearest **`go.mod`** root, then a **`go.work`**
  root, then the source directory. The Go CLI uses the project's module,
  workspace, dependency, vendor, and toolchain settings normally.

For a quick check, select `fmt.Println("hello")` and press **Space e**. An unnamed
scratch buffer also works after `:setfiletype go`.

Each run uses a hidden temporary subdirectory beside the source, containing an
isolated `main.go`. This lets a snippet import the source's package without
mixing generated `package main` files into it. The directory is cleaned up on
completion, stop, startup failure, and Neovim exit. Compiler errors and panic
traces retain source file/line locations through Go line directives.

Selections are fresh standalone programs: include the definitions or local
variables you need, or import their package. Imported files are read from disk.
For a whole library buffer that is not a runnable `package main`, select a snippet
to test or write a `main` program that imports it. The Go helper's own compilation
and snippet compilation both happen asynchronously; the first run may take longer
while Go warms its build cache.

### Configuration and additional languages

The implementation lives in `lua/ivan/code_runner.lua`, with separate adapters in
`lua/ivan/runners/node.lua` and `lua/ivan/runners/go.lua`. Change its existing setup
call in `lua/ivan/init.lua` to configure it:

```lua
require('ivan.code_runner').setup {
  key = '<leader>e', -- false disables the execution mappings; commands still work.
  height = 12,
  node = {
    executable = 'node',
    args = {}, -- Additional native Node arguments.
    tsx = true, -- false always uses native Node.
  },
  go = {
    executable = 'go',
    args = {}, -- Additional go run flags, e.g. { '-race' }.
    goimports = 'goimports', -- false disables optional import inference.
  },
}
```

Runners are registered by Neovim filetype, so Rust, Python, Bash, and others
can be added independently of the selection, output, and process-management UI.
Use `setup { runners = { filetype = adapter } }` or `register_runner(filetype, adapter)`.
For example, this adds Bash execution:

```lua
require('ivan.code_runner').register_runner('sh', {
  prepare = function(context)
    return { cmd = { 'bash' }, stdin = context.code, label = 'Bash' }
  end,
})
```

`prepare(context)` returns a process plan or `nil, error`. Context includes
`bufnr`, `filetype`, `path` (nil for unnamed buffers), `directory`, `cwd`, `code`,
`first_line`, and `last_line`. Plans provide `cmd` (an argv list), with optional
`cwd`, `env`, `stdin`, `label`, `path` (a temporary path to remap in output), and
`cleanup()` (called once). Processes run asynchronously with stdin closed after
any supplied input. File-based adapters can use
`require('ivan.utils.code_execution').tempfile(context, extension, prefix)`;
it returns `path, cleanup` or `nil, error`.

Run the headless integration checks with:

```sh
nvim --headless -u NONE -l tests/code_runner.lua
nvim --headless -u NONE -l tests/go_runner.lua
```

Set `NVIM_CODE_RUNNER_TSX` to an installed `tsx` executable to also check its
project-local lookup, path aliases, and JSX support.

## AI editing and questions

The local plugin in `lua/ivan/claude.lua` supports **OpenCode** (the default)
and **Claude Code**. Install and authenticate the CLI you want to use.

- `<leader>cb`: choose the backend (OpenCode or Claude).
- `<leader>cm`: choose its model; OpenCode's `default` uses its configured model.
- `<leader>cp`: prettify the selection or file.
- `<leader>ce`: edit with an instruction.
- `<leader>ca`: ask about the selection or file.
- `H`: get a short AI explanation of the symbol under the cursor.
- `<leader>cr` / `<leader>cf`: retry / refine or follow up.
- `<leader>ct` / `<leader>cw`: toggle thinking / show returned reasoning.
- `<leader>co`: reopen the last answer.

Backend, per-backend models, and thinking are remembered across restarts.
Both backends read project files for questions and edits; proposed edits are
applied to Neovim buffers and remain unsaved. OpenCode's thinking toggle requests
the `high` model variant when enabled; variant support depends on the model.

### AI hover

Place the cursor on a function, variable, type, or other symbol and press `H`.
It uses the backend, model, and thinking setting selected with `<leader>cb`,
`<leader>cm`, and `<leader>ct`. The prompt includes the LSP hover documentation
and the current buffer, including unsaved changes. The model can search and read
other project files when needed. It also works without an LSP server.

The result is requested as 2–3 short sentences (at most 60 words) and appears in
a small Markdown window next to the cursor. Press `H` again to focus it; `q` or
`Esc` closes it. Moving the cursor or entering Insert mode dismisses it.

Inside the focused hover, press **`<leader>cf`** to ask another question about
the symbol, or **Enter** when the cursor is not on a code reference.
Follow-ups include the original LSP/file context,
the summary, and all earlier questions and answers. Answers stay in the same
window, where you can scroll and keep asking questions. The initial summary
stays short; follow-ups can provide more detail or code examples when requested.
Each question uses the currently selected backend/model. Cached hovers remember
their conversations, so reopening one lets you continue where you left off.

Summaries are cached in memory for the current Neovim session (up to 128 entries).
Repeated requests while a summary is being generated share the same request.
Cache entries are tied to the symbol location, backend/model/thinking settings,
and project buffer versions; editing a loaded project buffer or saving a project
file invalidates the relevant context. Use `:AIHover!` to regenerate after
external file changes, or `:AIHoverClearCache` to clear all summaries. `:AIHover`
also works as an alternative to the shortcut.

### Navigable AI code references

In a focused AI hover or full AI answer:

- **Tab / Shift-Tab** moves to the next / previous reference, wrapping around.
- **Enter** on an underlined reference closes the answer window and jumps to
  the actual source location in the window you asked from, including other files.
  Brackets, backticks, and the link destination also accept Enter. In a full AI
  answer, Enter anywhere on a line with exactly one reference opens that reference.
- **`<leader>cf`** asks a follow-up while you are reading either answer window.
- After jumping, **`]l` / `[l`** walks through the answer's source location list.

The model is asked to link verified symbols and code snippets as
``[`functionName`](src/file.go:42)``. File-only links and plain file paths also
work; without a line number they open at the beginning of the file. Citations
support `path:line[:column]`, line ranges, `#L42` anchors, named line references,
paths with spaces, local `file://` links, and reference-style Markdown links.
Paths are checked relative to the project and the source file; abbreviated paths
can be resolved through a background project-file lookup when the match is unique.
Plain backtick-formatted symbols and function calls are resolved through LSP
document/workspace symbols when an unambiguous definition is available.

References are refreshed as follow-up answers arrive. If Tab or Enter in a full
answer arrives before reference lookup finishes, navigation waits for the result;
moving the cursor or closing/updating the answer cancels that pending action.
File, line, and column targets are checked against loaded buffers (including
unsaved content) or disk. Ambiguous filenames and invalid source locations are
not guessed.

The existing `require('ivan.claude').setup()` entry point still works. You can
also configure it explicitly:

```lua
require('ivan.claude').setup { backend = 'opencode', model = 'openai/gpt-5.4' }
```

The hover shortcut and window can be configured separately:

```lua
require('ivan.claude').setup {
  hover = {
    key = 'H', -- Set to false to use only :AIHover or a custom mapping.
    max_width = 72,
    max_height = 12,
    lsp_timeout_ms = 1500, -- Continue with available context if the LSP is slow.
    cache_size = 128, -- Set to 0 to disable caching.
  },
}
```

For a custom mapping, call `require('ivan.ai_hover').hover()`.

Explicit setup values override saved preferences on startup. Future CLI backends
can be registered through `setup { backends = { name = adapter } }`. An adapter
provides `label`, `default_model`, `models(callback)`,
`prepare(handler, model, thinking, prompt)` (returning a command list and
`vim.system` options), and `parse(result, handler)` (returning
`{ text, structured, thoughts }` or `nil, error`). Structured edits contain
`replacement` and `file_edits` entries with `path`, `find`, and `replace`.

## Introduction

A starting point for Neovim that is:

* Small
* Single-file
* Completely Documented

**NOT** a Neovim distribution, but instead a starting point for your configuration.

## Installation

### Install Neovim

Kickstart.nvim targets *only* the latest
['stable'](https://github.com/neovim/neovim/releases/tag/stable) and latest
['nightly'](https://github.com/neovim/neovim/releases/tag/nightly) of Neovim.
If you are experiencing issues, please make sure you have the latest versions.

### Install External Dependencies

External Requirements:
- Basic utils: `git`, `make`, `unzip`, C Compiler (`gcc`)
- [ripgrep](https://github.com/BurntSushi/ripgrep#installation),
  [fd-find](https://github.com/sharkdp/fd#installation)
- Clipboard tool (xclip/xsel/win32yank or other depending on the platform)
- A [Nerd Font](https://www.nerdfonts.com/): optional, provides various icons
  - if you have it set `vim.g.have_nerd_font` in `init.lua` to true
- Emoji fonts (Ubuntu only, and only if you want emoji!) `sudo apt install fonts-noto-color-emoji`
- Language Setup:
  - If you want to write Typescript, you need `npm`
  - If you want to write Golang, you will need `go`
  - etc.

> [!NOTE]
> See [Install Recipes](#Install-Recipes) for additional Windows and Linux specific notes
> and quick install snippets

### Install Kickstart

> [!NOTE]
> [Backup](#FAQ) your previous configuration (if any exists)

Neovim's configurations are located under the following paths, depending on your OS:

| OS | PATH |
| :- | :--- |
| Linux, MacOS | `$XDG_CONFIG_HOME/nvim`, `~/.config/nvim` |
| Windows (cmd)| `%localappdata%\nvim\` |
| Windows (powershell)| `$env:LOCALAPPDATA\nvim\` |

#### Recommended Step

[Fork](https://docs.github.com/en/get-started/quickstart/fork-a-repo) this repo
so that you have your own copy that you can modify, then install by cloning the
fork to your machine using one of the commands below, depending on your OS.

> [!NOTE]
> Your fork's URL will be something like this:
> `https://github.com/<your_github_username>/kickstart.nvim.git`

You likely want to remove `lazy-lock.json` from your fork's `.gitignore` file
too - it's ignored in the kickstart repo to make maintenance easier, but it's
[recommended to track it in version control](https://lazy.folke.io/usage/lockfile).

#### Clone kickstart.nvim

> [!NOTE]
> If following the recommended step above (i.e., forking the repo), replace
> `nvim-lua` with `<your_github_username>` in the commands below

<details><summary> Linux and Mac </summary>

```sh
git clone https://github.com/nvim-lua/kickstart.nvim.git "${XDG_CONFIG_HOME:-$HOME/.config}"/nvim
```

</details>

<details><summary> Windows </summary>

If you're using `cmd.exe`:

```
git clone https://github.com/nvim-lua/kickstart.nvim.git "%localappdata%\nvim"
```

If you're using `powershell.exe`

```
git clone https://github.com/nvim-lua/kickstart.nvim.git "${env:LOCALAPPDATA}\nvim"
```

</details>

### Post Installation

Start Neovim

```sh
nvim
```

That's it! Lazy will install all the plugins you have. Use `:Lazy` to view
the current plugin status. Hit `q` to close the window.

#### Read The Friendly Documentation

Read through the `init.lua` file in your configuration folder for more
information about extending and exploring Neovim. That also includes
examples of adding popularly requested plugins.

> [!NOTE]
> For more information about a particular plugin check its repository's documentation.


### Getting Started

[The Only Video You Need to Get Started with Neovim](https://youtu.be/m8C0Cq9Uv9o)

### FAQ

* What should I do if I already have a pre-existing Neovim configuration?
  * You should back it up and then delete all associated files.
  * This includes your existing init.lua and the Neovim files in `~/.local`
    which can be deleted with `rm -rf ~/.local/share/nvim/`
* Can I keep my existing configuration in parallel to kickstart?
  * Yes! You can use [NVIM_APPNAME](https://neovim.io/doc/user/starting.html#%24NVIM_APPNAME)`=nvim-NAME`
    to maintain multiple configurations. For example, you can install the kickstart
    configuration in `~/.config/nvim-kickstart` and create an alias:
    ```
    alias nvim-kickstart='NVIM_APPNAME="nvim-kickstart" nvim'
    ```
    When you run Neovim using `nvim-kickstart` alias it will use the alternative
    config directory and the matching local directory
    `~/.local/share/nvim-kickstart`. You can apply this approach to any Neovim
    distribution that you would like to try out.
* What if I want to "uninstall" this configuration:
  * See [lazy.nvim uninstall](https://lazy.folke.io/usage#-uninstalling) information
* Why is the kickstart `init.lua` a single file? Wouldn't it make sense to split it into multiple files?
  * The main purpose of kickstart is to serve as a teaching tool and a reference
    configuration that someone can easily use to `git clone` as a basis for their own.
    As you progress in learning Neovim and Lua, you might consider splitting `init.lua`
    into smaller parts. A fork of kickstart that does this while maintaining the
    same functionality is available here:
    * [kickstart-modular.nvim](https://github.com/dam9000/kickstart-modular.nvim)
  * Discussions on this topic can be found here:
    * [Restructure the configuration](https://github.com/nvim-lua/kickstart.nvim/issues/218)
    * [Reorganize init.lua into a multi-file setup](https://github.com/nvim-lua/kickstart.nvim/pull/473)

### Install Recipes

Below you can find OS specific install instructions for Neovim and dependencies.

After installing all the dependencies continue with the [Install Kickstart](#Install-Kickstart) step.

#### Windows Installation

<details><summary>Windows with Microsoft C++ Build Tools and CMake</summary>
Installation may require installing build tools and updating the run command for `telescope-fzf-native`

See `telescope-fzf-native` documentation for [more details](https://github.com/nvim-telescope/telescope-fzf-native.nvim#installation)

This requires:

- Install CMake and the Microsoft C++ Build Tools on Windows

```lua
{'nvim-telescope/telescope-fzf-native.nvim', build = 'cmake -S. -Bbuild -DCMAKE_BUILD_TYPE=Release && cmake --build build --config Release && cmake --install build --prefix build' }
```
</details>
<details><summary>Windows with gcc/make using chocolatey</summary>
Alternatively, one can install gcc and make which don't require changing the config,
the easiest way is to use choco:

1. install [chocolatey](https://chocolatey.org/install)
either follow the instructions on the page or use winget,
run in cmd as **admin**:
```
winget install --accept-source-agreements chocolatey.chocolatey
```

2. install all requirements using choco, exit the previous cmd and
open a new one so that choco path is set, and run in cmd as **admin**:
```
choco install -y neovim git ripgrep wget fd unzip gzip mingw make
```
</details>
<details><summary>WSL (Windows Subsystem for Linux)</summary>

```
wsl --install
wsl
sudo add-apt-repository ppa:neovim-ppa/unstable -y
sudo apt update
sudo apt install make gcc ripgrep unzip git xclip neovim
```
</details>

#### Linux Install
<details><summary>Ubuntu Install Steps</summary>

```
sudo add-apt-repository ppa:neovim-ppa/unstable -y
sudo apt update
sudo apt install make gcc ripgrep unzip git xclip neovim
```
</details>
<details><summary>Debian Install Steps</summary>

```
sudo apt update
sudo apt install make gcc ripgrep unzip git xclip curl

# Now we install nvim
curl -LO https://github.com/neovim/neovim/releases/latest/download/nvim-linux-x86_64.tar.gz
sudo rm -rf /opt/nvim-linux-x86_64
sudo mkdir -p /opt/nvim-linux-x86_64
sudo chmod a+rX /opt/nvim-linux-x86_64
sudo tar -C /opt -xzf nvim-linux-x86_64.tar.gz

# make it available in /usr/local/bin, distro installs to /usr/bin
sudo ln -sf /opt/nvim-linux-x86_64/bin/nvim /usr/local/bin/
```
</details>
<details><summary>Fedora Install Steps</summary>

```
sudo dnf install -y gcc make git ripgrep fd-find unzip neovim
```
</details>

<details><summary>Arch Install Steps</summary>

```
sudo pacman -S --noconfirm --needed gcc make git ripgrep fd unzip neovim
```
</details>
