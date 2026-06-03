# nvim-m1

Neovim plugin for [M1 script](https://github.com/C-Nucifora/m1-tools) (`.m1scr`). Provides LSP, tree-sitter highlighting, format-on-save, and standalone linting in a single `setup()` call — the Neovim equivalent of [m1-vscode](https://github.com/nedlane/m1-vscode).

## Requirements

- Neovim ≥ 0.10
- [lazy.nvim](https://github.com/folke/lazy.nvim) (or any plugin manager)
- [nvim-treesitter](https://github.com/nvim-treesitter/nvim-treesitter)
- [nvim-lspconfig](https://github.com/neovim/nvim-lspconfig)
- Optional: [conform.nvim](https://github.com/stevearc/conform.nvim), [nvim-lint](https://github.com/mfussenegger/nvim-lint)
- The `m1-lsp`, `m1-fmt` and `m1-lint` binaries on `$PATH` (run `:checkhealth nvim-m1`)

On Neovim 0.11+ the server is registered with the native `vim.lsp.config`/`vim.lsp.enable`
API; on 0.10 it falls back to nvim-lspconfig. Format-on-save uses conform.nvim when
present and otherwise falls back to LSP formatting; standalone lint uses nvim-lint when
present and otherwise a built-in runner — so both work with zero optional dependencies.

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
    -- Path to the m1-lsp binary (default: search $PATH for "m1-lsp")
    server_path = nil,
    -- Format .m1scr buffers on save (m1-fmt via conform.nvim, else LSP)
    format_on_save = true,
    -- Lint .m1scr buffers on save (m1-lint via nvim-lint, else built-in runner)
    lint_on_save = true,
  },
}
```

### Options

| Key | Default | Description |
| --- | --- | --- |
| `server_path` | `nil` | Path to the m1-lsp binary; `nil` searches `$PATH`. |
| `project_path` | `nil` | Path to the m1-project binary (Project.m1prj editor; powers `:M1CreateChannel` etc.); `nil` searches `$PATH`. |
| `format_on_save` | `true` | Format `.m1scr` on write with m1-fmt. |
| `lint_on_save` | `true` | Lint `.m1scr` on write with m1-lint. |
| `filetypes` | `{ "m1scr" }` | Script filetypes to wire. |
| `attach_m1prj` | `true` | Also attach m1-lsp to `Project.m1prj` (rename a channel from its declaration). |
| `root_markers` | `{ "Project.m1prj", ".git" }` | Files marking a project root. |
| `auto_install_parser` | `true` | Run `:TSInstall m1` if the parser is missing. |
| `lint_on_insert_leave` | `false` | Also lint on `InsertLeave`. |
| `capabilities` / `on_attach` | — | Forwarded to the LSP client. |
| `settings` | `{}` | Unified m1-lsp config (lint/format/diagnostics), e.g. `{ lint = { max_line_length = 100 }, diagnostics = { ignore = { "T041" } } }`. A workspace `m1-tools.toml` overrides it. |

### Configuration

`settings` is the convenient per-setup config. For **project-level** config shared
with teammates (and the VS Code extension), commit an `m1-tools.toml` to the project
root — the server discovers and applies it, **overriding** `settings`. It configures
the same lint thresholds, formatter options, and cross-source diagnostic
`ignore`/`select` (any lint `L*` or typecheck `T*` code). Generate one pre-filled
with all defaults via `:M1GenerateConfig`.

### Commands

| Command | Action |
| --- | --- |
| `:M1Format` | Format the current buffer now. |
| `:M1FormatToggle` | Toggle format-on-save for this session. |
| `:M1Lint` | Lint the current buffer now. |
| `:M1GenerateConfig` | Write a default `m1-tools.toml` to the project root. |
| `:M1CreateChannel` | Create a channel in `Project.m1prj` (prompts for name/type/unit/security). |
| `:M1SetSecurity` | Set a component's security/access level. |
| `:M1SetCallRate` | Set a script's execution rate (picked from the project's clocks). |
| `:checkhealth nvim-m1` | Verify Neovim version, toolchain binaries, parser and integrations. |

The last three edit `Project.m1prj` through the [`m1-project`](https://github.com/nedlane/m1-project)
binary (the same tool the VS Code extension uses) — the language server stays
read-only and reloads automatically after an edit. Put `m1-project` on `$PATH`
(or set `project_path`); `:checkhealth nvim-m1` reports whether it's found.

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

## Development

```sh
scripts/test.sh   # headless plenary-busted suite
```

The suite covers config resolution, the m1-lint JSON parser, setup wiring, and an
end-to-end lint run against the real `m1-lint` binary (when it is on `$PATH`). Test
fixtures are synthetic — no project data is checked in.

## License

GPL-3.0-or-later — see [LICENSE](LICENSE).
