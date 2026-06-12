# nvim-m1

Neovim plugin for [M1 script](https://github.com/C-Nucifora/m1-tools)
(`.m1scr`). LSP, tree-sitter highlighting, format-on-save, standalone
linting, and project-file editing in a single `setup()` call — the Neovim
equivalent of [m1-vscode](https://github.com/nedlane/m1-vscode).

**The M1 toolchain is bundled**: the install hook downloads the pinned,
prebuilt `m1-lsp` / `m1-fmt` / `m1-lint` / `m1-project` binaries for your
platform — there is nothing to install by hand, and `:checkhealth nvim-m1`
verifies the result.

## Requirements

- Neovim ≥ 0.10 (on 0.10,
  [nvim-lspconfig](https://github.com/neovim/nvim-lspconfig) is required;
  0.11+ uses the native LSP API)
- A C compiler on `$PATH` — the `m1` parser is compiled from
  [tree-sitter-m1](https://github.com/C-Nucifora/tree-sitter-m1)'s sources on
  first setup
- `curl` on `$PATH` — used to download the bundled toolchain (on macOS, also
  `codesign` from the Xcode CLT: binaries are re-signed ad-hoc so Apple
  Silicon's code-signing check doesn't kill them)
- Optional: [conform.nvim](https://github.com/stevearc/conform.nvim) for
  format-on-save, [nvim-lint](https://github.com/mfussenegger/nvim-lint) for
  standalone lint — both have built-in fallbacks when absent

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
  -- Downloads the bundled M1 toolchain for your platform on install/update.
  -- Same as running :M1Install.
  build = function()
    require("nvim-m1.install").install()
  end,
  ft = { "m1scr", "m1prj" },
  opts = {},
}
```

Binaries you provide yourself still win: anything on `$PATH` (or pointed to
via `server_path` / `project_path`) is used over the bundled toolchain.
Highlighting works through Neovim core — the plugin compiles and registers
the parser itself, so it does not depend on a particular nvim-treesitter
branch.

### Options

| Key | Default | Description |
| --- | --- | --- |
| `server_path` | `nil` | Path to the m1-lsp binary; `nil` searches `$PATH`. |
| `project_path` | `nil` | Path to the m1-project binary (powers `:M1CreateChannel` etc.); `nil` searches `$PATH`. |
| `format_on_save` | `true` | Format `.m1scr` on write with m1-fmt. |
| `lint_on_save` | `true` | Lint `.m1scr` on write with m1-lint. |
| `filetypes` | `{ "m1scr" }` | Script filetypes to wire. |
| `attach_m1prj` | `true` | Also attach m1-lsp to `Project.m1prj` (rename a channel from its declaration). |
| `root_markers` | `{ "Project.m1prj", ".git" }` | Files marking a project root. |
| `auto_install_parser` | `true` | Install the `m1` parser if missing. |
| `lint_on_insert_leave` | `false` | Also lint on `InsertLeave`. |
| `codelens` | `true` | Show m1-lsp code lenses (e.g. a script's `⚡ N Hz` rate); run the lens under the cursor with `:M1CodeLensRun`. |
| `capabilities` / `on_attach` | — | Forwarded to the LSP client. |
| `settings` | `{}` | Unified m1-lsp config (lint/format/diagnostics), e.g. `{ lint = { max_line_length = 100 } }`. A workspace `m1-tools.toml` overrides it. |

For **project-level** config shared with teammates (and the VS Code
extension), commit an `m1-tools.toml` to the project root — the server
discovers it and it overrides `settings` (see the
[m1-tools configuration docs](https://github.com/C-Nucifora/m1-tools#configuration)).
Generate one via `:M1GenerateConfig`.

### Commands

| Command | Action |
| --- | --- |
| `:M1Format` / `:M1FormatToggle` | Format the buffer now / toggle format-on-save. |
| `:M1Lint` | Lint the current buffer now. |
| `:M1GenerateConfig` | Write a default `m1-tools.toml` to the project root. |
| `:M1CreateChannel` / `:M1CreateParameter` / `:M1CreateGroup` / `:M1CreateFunction` / `:M1CreateScheduledFunction` | Create components in `Project.m1prj` (prompting for the details). |
| `:M1SetSecurity` / `:M1SetType` / `:M1SetUnit` / `:M1SetCallRate` / `:M1SetQuantity` / `:M1SetFormat` / `:M1SetDps` / `:M1SetDisplayRange` / `:M1SetValidation` | Set a component's properties (pickers driven by the project model). |
| `:M1AddTag` / `:M1RemoveTag` | Add or remove a System/Type tag. |
| `:M1RenameComponent` / `:M1DeleteComponent` | Rename (updating trigger references) or delete a component. |
| `:M1ValidateProject` | Validate `Project.m1prj` structure into the quickfix list. |
| `:M1Install` / `:M1Update` | Download the bundled toolchain at the pinned versions. |
| `:checkhealth nvim-m1` | Verify Neovim version, toolchain binaries, parser and integrations. |

The project-editing commands drive `Project.m1prj` through the
[m1-project](https://github.com/nedlane/m1-project) binary (the same tool the
VS Code extension uses) — the language server stays read-only and reloads
automatically after an edit.

### Extras

A statusline component
(`require("nvim-m1.statusline").component` — shows `m1 v<server-version>`
when attached) and which-key labels for every `:M1*` command
(`require("nvim-m1.whichkey").register()`).

## Development

```sh
scripts/test.sh   # headless plenary-busted suite
```

The suite covers config resolution, the m1-lint JSON parser, setup wiring,
and an end-to-end lint run against the real `m1-lint` binary when it is on
`$PATH`. Test fixtures are synthetic — no project data is checked in. Lua is
formatted with `stylua` (a separate CI job).

## License

GPL-3.0-or-later — see [LICENSE](LICENSE).

## Trademark

Independent, community-built open-source tooling for the MoTeC® M1 script
language. Not affiliated with, authorised, or endorsed by MoTeC Pty Ltd.
"MoTeC" and "M1" are trademarks of MoTeC Pty Ltd.
