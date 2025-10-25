return {
  {
    -- Lua dev UX for Neovim APIs
    'folke/lazydev.nvim',
    ft = 'lua',
    opts = {
      library = {
        { path = '${3rd}/luv/library', words = { 'vim%.uv' } },
      },
    },
  },

  {
    -- Main LSP plumbing (server configs live in nvim-lspconfig, but we use vim.lsp.config/enable)
    'neovim/nvim-lspconfig',
    dependencies = {
      { 'mason-org/mason.nvim', opts = {} },
      'mason-org/mason-lspconfig.nvim',
      'WhoIsSethDaniel/mason-tool-installer.nvim',

      -- Status updates for LSP
      { 'j-hui/fidget.nvim', opts = {} },

      -- Completion caps
      'saghen/blink.cmp',
    },
    config = function()
      -----------------------------------------------------------------------
      -- FLOW (custom config) — migrated from require('lspconfig').flow.setup
      -----------------------------------------------------------------------
      -- New API: define config, then enable it.
      vim.lsp.config('flow', {
        cmd = { 'flow', 'lsp' },
        filetypes = { 'javascript', 'javascriptreact' },
        -- 0.11 uses root_markers instead of util.root_pattern
        root_markers = { '.flowconfig' },
      })
      vim.lsp.enable('flow')

      -----------------------------------------------------------------------
      -- Keymaps / behavior on LspAttach (kept from your original config)
      -----------------------------------------------------------------------
      vim.api.nvim_create_autocmd('LspAttach', {
        group = vim.api.nvim_create_augroup('kickstart-lsp-attach', { clear = true }),
        callback = function(event)
          local map = function(keys, func, desc, mode)
            mode = mode or 'n'
            vim.keymap.set(mode, keys, func, { buffer = event.buf, desc = 'LSP: ' .. desc })
          end

          map('grn', vim.lsp.buf.rename, '[R]e[n]ame')
          map('gra', vim.lsp.buf.code_action, '[G]oto Code [A]ction', { 'n', 'x' })
          map('grr', require('telescope.builtin').lsp_references, '[G]oto [R]eferences')
          map('gri', require('telescope.builtin').lsp_implementations, '[G]oto [I]mplementation')
          map('grd', require('telescope.builtin').lsp_definitions, '[G]oto [D]efinition')
          map('grD', vim.lsp.buf.declaration, '[G]oto [D]eclaration')
          map('gO', require('telescope.builtin').lsp_document_symbols, 'Open Document Symbols')
          map('gW', require('telescope.builtin').lsp_dynamic_workspace_symbols, 'Open Workspace Symbols')
          map('grt', require('telescope.builtin').lsp_type_definitions, '[G]oto [T]ype Definition')

          --- Handles 0.10 vs 0.11 client:supports_method API
          local function client_supports_method(client, method, bufnr)
            if vim.fn.has 'nvim-0.11' == 1 then
              return client:supports_method(method, bufnr)
            else
              return client.supports_method(method, { bufnr = bufnr })
            end
          end

          local client = vim.lsp.get_client_by_id(event.data.client_id)
          if client and client_supports_method(client, vim.lsp.protocol.Methods.textDocument_documentHighlight, event.buf) then
            local highlight_augroup = vim.api.nvim_create_augroup('kickstart-lsp-highlight', { clear = false })
            vim.api.nvim_create_autocmd({ 'CursorHold', 'CursorHoldI' }, {
              buffer = event.buf,
              group = highlight_augroup,
              callback = vim.lsp.buf.document_highlight,
            })
            vim.api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI' }, {
              buffer = event.buf,
              group = highlight_augroup,
              callback = vim.lsp.buf.clear_references,
            })
            vim.api.nvim_create_autocmd('LspDetach', {
              group = vim.api.nvim_create_augroup('kickstart-lsp-detach', { clear = true }),
              callback = function(event2)
                vim.lsp.buf.clear_references()
                vim.api.nvim_clear_autocmds { group = 'kickstart-lsp-highlight', buffer = event2.buf }
              end,
            })
          end

          if client and client_supports_method(client, vim.lsp.protocol.Methods.textDocument_inlayHint, event.buf) then
            map('<leader>th', function()
              vim.lsp.inlay_hint.enable(not vim.lsp.inlay_hint.is_enabled { bufnr = event.buf })
            end, '[T]oggle Inlay [H]ints')
          end
        end,
      })

      -----------------------------------------------------------------------
      -- Diagnostics (unchanged)
      -----------------------------------------------------------------------
      vim.diagnostic.config {
        severity_sort = true,
        float = { border = 'rounded', source = 'if_many' },
        underline = { severity = vim.diagnostic.severity.ERROR },
        signs = vim.g.have_nerd_font and {
          text = {
            [vim.diagnostic.severity.ERROR] = '󰅚 ',
            [vim.diagnostic.severity.WARN] = '󰀪 ',
            [vim.diagnostic.severity.INFO] = '󰋽 ',
            [vim.diagnostic.severity.HINT] = '󰌶 ',
          },
        } or {},
        virtual_text = {
          source = 'if_many',
          spacing = 2,
          format = function(diagnostic)
            return diagnostic.message
          end,
        },
      }

      -----------------------------------------------------------------------
      -- Capabilities (blink.cmp)
      -----------------------------------------------------------------------
      local capabilities = require('blink.cmp').get_lsp_capabilities()

      -----------------------------------------------------------------------
      -- Servers list (you can add more here)
      -----------------------------------------------------------------------
      local servers = {
        -- gopls = {},
        intelephense = {},
        pyright = {},
        rust_analyzer = {},
        clangd = {},
        gopls = {},
        terraformls = {}, 
        csharp_ls = {},
        lua_ls = {
          settings = {
            Lua = {
              completion = { callSnippet = 'Replace' },
              -- diagnostics = { disable = { 'missing-fields' } },
            },
          },
        },
      }

      -----------------------------------------------------------------------
      -- Ensure tools/servers are installed via Mason
      -----------------------------------------------------------------------
      local ensure_installed = vim.tbl_keys(servers or {})
      vim.list_extend(ensure_installed, {
        'stylua',
        'prettierd',
        'prettier',
      })
      require('mason-tool-installer').setup { ensure_installed = ensure_installed }

      -----------------------------------------------------------------------
      -- mason-lspconfig handlers -> define & enable via new API
      -----------------------------------------------------------------------
      require('mason-lspconfig').setup {
        ensure_installed = {}, -- we drive installs from mason-tool-installer
        automatic_installation = false,
        handlers = {
          function(server_name)
            local server = servers[server_name] or {}
            server.capabilities = vim.tbl_deep_extend('force', {}, capabilities, server.capabilities or {})

            -- Define/extend the config, then enable it.
            vim.lsp.config(server_name, server)
            vim.lsp.enable(server_name)
          end,
        },
      }
    end,
  },

  ---------------------------------------------------------------------------
  -- typescript-tools — drop lspconfig.util, use vim.fs to detect .flowconfig
  ---------------------------------------------------------------------------
  {
    'pmizio/typescript-tools.nvim',
    dependencies = { 'nvim-lua/plenary.nvim', 'neovim/nvim-lspconfig' },
    opts = {
      on_attach = function(client, bufnr)
        -- If a .flowconfig exists upwards from the current buffer, prefer Flow
        local start = vim.api.nvim_buf_get_name(bufnr)
        local found = vim.fs.find({ '.flowconfig' }, { upward = true, path = start })[1]
        if found then
          client.stop()
          return
        end
        -- your extra on_attach logic...
      end,
      settings = {
        tsserver_file_preferences = {},
      },
    },
  },
}
