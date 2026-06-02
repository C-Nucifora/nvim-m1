# nvim-m1

Neovim plugin for [M1 script](https://github.com/C-Nucifora/m1-tools) (`.m1scr`). Provides LSP, tree-sitter highlighting, format-on-save, and standalone linting in a single `setup()` call — the Neovim equivalent of [m1-vscode](https://github.com/nedlane/m1-vscode).

## Requirements

- Neovim ≥ 0.10
- [lazy.nvim](https://github.com/folke/lazy.nvim) (or any plugin manager)
- [nvim-treesitter](https://github.com/nvim-treesitter/nvim-treesitter)
- [nvim-lspconfig](https://github.com/neovim/nvim-lspconfig)
- Optional: [conform.nvim](https://github.com/stevearc/conform.nvim), [nvim-lint](https://github.com/mfussenegger/nvim-lint)

## Installation

```lua
-- lazy.nvim
{
  "C-Nucifora/nvim-m1",
  dependencies = {
    "nvim-treesitter/nvim-treesitter",
    "neovim/nvim-lspconfig",
    { "stevearc/conform.nvim", optional = true },
    { "mfussenegger/nvim-lint", optional = true },
  },
  ft = "m1scr",
  opts = {
    -- Path to m1-lsp binary (default: searches $PATH, then bundled binary)
    server_path = nil,
    -- Enable format-on-save via conform.nvim (requires conform.nvim)
    format_on_save = true,
    -- Enable standalone lint via nvim-lint (requires nvim-lint)
    lint_on_save = true,
  },
}
```

## Features

| Feature | Provider |
| --- | --- |
| Syntax highlighting | tree-sitter-m1 |
| Diagnostics (syntax + lint + types) | m1-lsp |
| Hover, completion, go-to-definition | m1-lsp |
| Find references, rename | m1-lsp |
| Inlay type-hints | m1-lsp |
| Semantic tokens | m1-lsp |
| Format-on-save | conform.nvim + m1-fmt |
| Standalone lint | nvim-lint + m1-lint |

## Status

> **Scaffold.** Plugin structure is in place; full implementation in progress.
> Track progress in the [open issues](https://github.com/C-Nucifora/nvim-m1/issues).

## License

GPL-3.0-or-later — see [LICENSE](LICENSE).
