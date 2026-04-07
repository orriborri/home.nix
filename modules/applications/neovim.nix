{ pkgs, ... }:

{
  programs.neovim = {
    enable = true;
    defaultEditor = true;
    viAlias = true;
    vimAlias = true;
    vimdiffAlias = true;

    plugins = with pkgs.vimPlugins; [
      # Plugin manager
      lazy-nvim

      # LSP
      nvim-lspconfig
      mason-nvim
      mason-lspconfig-nvim

      # Completion
      nvim-cmp
      cmp-nvim-lsp
      cmp-buffer
      cmp-path
      luasnip
      cmp_luasnip

      # Treesitter
      nvim-treesitter.withAllGrammars

      # Fuzzy finder
      telescope-nvim
      telescope-fzf-native-nvim
      telescope-file-browser-nvim
      plenary-nvim

      # File explorer
      nvim-tree-lua

      # Git
      gitsigns-nvim
      vim-fugitive
      vim-gitgutter

      # UI
      lualine-nvim
      nvim-web-devicons
      which-key-nvim

      # Code navigation
      trouble-nvim

      # Formatting
      conform-nvim

      # Vim plugins
      base16-vim
      ctrlp-vim
      editorconfig-vim
      vim-markdown
      vim-surround

      # Colorscheme
      catppuccin-nvim
    ];

    extraPackages = with pkgs; [
      # Language servers
      nodePackages.typescript-language-server
      nodePackages.vscode-langservers-extracted # HTML, CSS, JSON, ESLint
      lua-language-server
      nil # Nix LSP
      pyright
      ruff
      
      # Formatters
      nodePackages.prettier
      stylua
      nixpkgs-fmt
      
      # Tools
      ripgrep
      fd
      tree-sitter
    ];

    initLua = ''
      -- Basic settings
      vim.opt.number = true
      vim.opt.relativenumber = true
      vim.opt.expandtab = true
      vim.opt.shiftwidth = 2
      vim.opt.tabstop = 2
      vim.opt.smartindent = true
      vim.opt.wrap = false
      vim.opt.swapfile = false
      vim.opt.backup = false
      vim.opt.undofile = true
      vim.opt.hlsearch = false
      vim.opt.incsearch = true
      vim.opt.termguicolors = true
      vim.opt.scrolloff = 8
      vim.opt.signcolumn = "yes"
      vim.opt.updatetime = 50
      vim.opt.colorcolumn = "120"
      
      vim.g.mapleader = " "
      
      -- Colorscheme
      require("catppuccin").setup()
      vim.cmd.colorscheme "catppuccin"
      
      -- LSP setup
      require("mason").setup()
      require("mason-lspconfig").setup({
        ensure_installed = { "ts_ls", "eslint", "lua_ls" },
        automatic_installation = false,
      })
      
      local capabilities = require("cmp_nvim_lsp").default_capabilities()

      vim.lsp.config("pyright", {
        capabilities = capabilities,
        settings = {
          pyright = { disableOrganizeImports = true },
        },
      })

      vim.lsp.config("ts_ls", { capabilities = capabilities })
      vim.lsp.config("eslint", { capabilities = capabilities })
      vim.lsp.config("lua_ls", { capabilities = capabilities })
      vim.lsp.config("nil_ls", { capabilities = capabilities })
      vim.lsp.config("ruff", { capabilities = capabilities })

      vim.lsp.enable("ts_ls")
      vim.lsp.enable("eslint")
      vim.lsp.enable("lua_ls")
      vim.lsp.enable("nil_ls")
      vim.lsp.enable("ruff")
      vim.lsp.enable("pyright")
      
      local map = vim.keymap.set

      -- LSP keybindings
      map("n", "K", vim.lsp.buf.hover, { desc = "Hover documentation" })
      map("n", "gd", vim.lsp.buf.definition, { desc = "Goto definition" })
      map("n", "gD", vim.lsp.buf.declaration, { desc = "Goto declaration" })
      map("n", "gi", vim.lsp.buf.implementation, { desc = "Goto implementation" })
      map("n", "gr", vim.lsp.buf.references, { desc = "Goto references" })
      map("n", "gt", vim.lsp.buf.type_definition, { desc = "Goto type definition" })
      map("n", "<leader>ca", vim.lsp.buf.code_action, { desc = "Code action" })
      map("n", "<leader>rn", vim.lsp.buf.rename, { desc = "Rename symbol" })
      map("n", "[d", vim.diagnostic.goto_prev, { desc = "Previous diagnostic" })
      map("n", "]d", vim.diagnostic.goto_next, { desc = "Next diagnostic" })
      map("n", "<leader>cd", vim.diagnostic.open_float, { desc = "Line diagnostics" })
      
      -- Completion setup
      local cmp = require("cmp")
      local luasnip = require("luasnip")
      
      cmp.setup({
        snippet = {
          expand = function(args)
            luasnip.lsp_expand(args.body)
          end,
        },
        mapping = cmp.mapping.preset.insert({
          ["<C-b>"] = cmp.mapping.scroll_docs(-4),
          ["<C-f>"] = cmp.mapping.scroll_docs(4),
          ["<C-Space>"] = cmp.mapping.complete(),
          ["<C-e>"] = cmp.mapping.abort(),
          ["<CR>"] = cmp.mapping.confirm({ select = true }),
          ["<Tab>"] = cmp.mapping(function(fallback)
            if cmp.visible() then
              cmp.select_next_item()
            else
              fallback()
            end
          end, { "i", "s" }),
        }),
        sources = cmp.config.sources({
          { name = "nvim_lsp" },
          { name = "luasnip" },
          { name = "buffer" },
          { name = "path" },
        }),
      })
      
      -- Treesitter
      require("nvim-treesitter").setup({
        highlight = { enable = true },
        indent = { enable = true },
      })
      
      -- Telescope
      local builtin = require("telescope.builtin")
      local telescope = require("telescope")

      telescope.setup({
        extensions = {
          file_browser = {
            hijack_netrw = true,
          },
        },
      })
      telescope.load_extension("fzf")
      telescope.load_extension("file_browser")

      map("n", "<leader><space>", builtin.find_files, { desc = "Find files" })
      map("n", "<leader>/", builtin.live_grep, { desc = "Live grep" })
      map("n", "<leader>,", builtin.buffers, { desc = "Switch buffer" })
      map("n", "<leader>sd", builtin.diagnostics, { desc = "Search diagnostics" })
      map("n", "<leader>ss", builtin.lsp_document_symbols, { desc = "Search document symbols" })
      map("n", "<leader>sS", builtin.lsp_workspace_symbols, { desc = "Search workspace symbols" })
      map("n", "<leader>ff", builtin.find_files, { desc = "Find files" })
      map("n", "<leader>fg", builtin.live_grep, { desc = "Live grep" })
      map("n", "<leader>fb", builtin.buffers, { desc = "Buffers" })
      map("n", "<leader>fe", function()
        telescope.extensions.file_browser.file_browser({
          path = vim.fn.expand("%:p:h"),
          select_buffer = true,
        })
      end, { desc = "File browser" })
      map("n", "<leader>fh", builtin.help_tags, { desc = "Help tags" })
      
      -- Nvim-tree
      require("nvim-tree").setup()
      map("n", "<leader>e", ":NvimTreeToggle<CR>", { desc = "Toggle file explorer" })
      
      -- Gitsigns
      require("gitsigns").setup({
        on_attach = function(bufnr)
          local gs = package.loaded.gitsigns
          local opts = function(desc) return { buffer = bufnr, desc = desc } end
          map("n", "<leader>gb", function() gs.blame_line({ full = true }) end, opts("Blame line"))
          map("n", "<leader>gB", ":Git blame<CR>", opts("Blame file"))
          map("n", "<leader>gp", gs.preview_hunk, opts("Preview hunk"))
          map("n", "<leader>gr", gs.reset_hunk, opts("Reset hunk"))
          map("n", "]h", gs.next_hunk, opts("Next hunk"))
          map("n", "[h", gs.prev_hunk, opts("Previous hunk"))
        end,
      })
      
      -- Lualine
      require("lualine").setup({
        options = {
          theme = "catppuccin",
        },
      })
      
      -- Which-key
      require("which-key").setup()
      require("which-key").add({
        { "<leader>c", group = "code" },
        { "<leader>f", group = "find" },
        { "<leader>g", group = "git" },
        { "<leader>r", group = "refactor" },
        { "<leader>s", group = "search" },
        { "<leader>x", group = "trouble" },
        { "g", group = "goto" },
        { "[", group = "prev" },
        { "]", group = "next" },
      })
      
      -- Trouble
      require("trouble").setup()
      map("n", "<leader>xx", ":Trouble<CR>", { desc = "Toggle trouble" })

      -- Formatting
      require("conform").setup({
        formatters_by_ft = {
          python = { "ruff_format" },
        },
        format_on_save = {
          timeout_ms = 500,
          lsp_format = "fallback",
        },
      })
      map("n", "<leader>cf", function()
        require("conform").format({ async = true })
      end, { desc = "Format file" })
    '';
  };
}
