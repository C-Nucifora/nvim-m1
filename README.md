# nvim-m1

Neovim plugin for [M1 script](https://github.com/C-Nucifora/m1-tools) (`.m1scr`). Provides LSP, tree-sitter highlighting, format-on-save, and standalone linting in a single `setup()` call — the Neovim equivalent of [m1-vscode](https://github.com/nedlane/m1-vscode).

## Requirements

- Neovim ≥ 0.10
- [lazy.nvim](https://github.com/folke/lazy.nvim) (or any plugin manager)
- [tree-sitter-m1](https://github.com/C-Nucifora/tree-sitter-m1) — the `m1` grammar + queries (a dependency, pulled in automatically)
- A C compiler (`cc`/`gcc`/`clang`) on `$PATH` — the parser is compiled from tree-sitter-m1's sources on first setup
- On Neovim 0.10: [nvim-lspconfig](https://github.com/neovim/nvim-lspconfig) (0.11+ uses the native LSP API)
- Optional: [conform.nvim](https://github.com/stevearc/conform.nvim), [nvim-lint](https://github.com/mfussenegger/nvim-lint)
- `curl` on `$PATH` — used once to download the bundled toolchain

**The M1 toolchain is bundled** — you don't install `m1-lsp`/`m1-fmt`/`m1-lint`/`m1-project`
yourself. The lazy.nvim `build` hook below downloads the pinned, prebuilt binaries for your
platform into `stdpath("data")/nvim-m1/bin` on install/update; `:M1Install` / `:M1Update` do it
on demand. A binary you put on `$PATH` (or point to via `server_path`/`project_path`) still wins.
`m1-lsp` alone provides diagnostics, hover, completion, formatting and rename — it embeds
m1-fmt/m1-lint/m1-typecheck — so the LSP is the only hard requirement; the rest enable the
conform.nvim / nvim-lint / project-editing paths. Run `:checkhealth nvim-m1` to verify.

Tree-sitter highlighting works through Neovim core: nvim-m1 compiles the `m1` parser from
tree-sitter-m1's sources into a site `parser/m1.so` and registers its queries directly, so
it does **not** depend on a particular nvim-treesitter branch (the `main` rewrite dropped the
runtime `:TSInstall`/`install_info` path nvim-m1 used to rely on). On Neovim 0.11+ the server
is registered with the native `vim.lsp.config`/`vim.lsp.enable` API; on 0.10 it falls back to
nvim-lspconfig. Format-on-save uses conform.nvim when present and otherwise falls back to LSP
formatting; standalone lint uses nvim-lint when present and otherwise a built-in runner.

## Installation

```lua
-- lazy.nvim
{
  "C-Nucifora/nvim-m1",
  dependencies = {
    "C-Nucifora/tree-sitter-m1", -- the m1 grammar + queries (required)
    { "nvim-treesitter/nvim-treesitter", optional = true },
    { "neovim/nvim-lspconfig", optional = true }, -- only needed on Neovim 0.10
    { "stevearc/conform.nvim", optional = true },
    { "mfussenegger/nvim-lint", optional = true },
  },
  -- Downloads the bundled M1 toolchain (m1-lsp/fmt/lint/project) for your
  -- platform on install + update. Same as running :M1Install.
  build = function()
    require("nvim-m1.install").install()
  end,
  ft = { "m1scr", "m1prj" },
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
| `:M1Install` / `:M1Update` | Download the bundled M1 toolchain at the pinned versions. |
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
| Go-to-implementation (a channel's write/producer sites) | m1-lsp |
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
