# AGENTS.md — nvim-m1

Guidance for coding agents working in this repository.

## Purpose

The Neovim client for the M1 toolchain — feature parity with `m1-vscode` is
the standing goal. Like the VS Code extension it is a thin client: language
intelligence comes from the bundled `m1-lsp`, project mutations go through
the `m1-project` CLI; this plugin wires them into Neovim (LSP setup, parser
provisioning, conform/nvim-lint integration, `:M1*` commands).

## Things that are deliberate (don't "fix" them)

- **The plugin provisions its own parser** (compiles tree-sitter-m1's
  sources to a site `parser/m1.so` and registers queries directly). It must
  not depend on a particular nvim-treesitter branch — the `main` rewrite
  removed the runtime `:TSInstall`/`install_info` path this used to rely on.
- **The toolchain is bundled and pinned** (versions in the plugin source;
  releases cut from the `VERSION` file). Self-heal/downloads must run
  **async** — installing on the UI thread froze first-open once already.
  `$PATH`/explicit-path binaries always win over bundled ones.
- **Two LSP wiring paths on purpose:** native `vim.lsp.config`/`enable` on
  Neovim 0.11+, nvim-lspconfig fallback on 0.10. Keep both working; note the
  native `vim.lsp.config` is a callable table, not a plain table.
- **The server stays read-only** — every `Project.m1prj` mutation shells out
  to `m1-project`, then the model reloads. Don't write project XML from Lua.
- **Project mutations are queued per project** (with rename folded into the
  same queue) so concurrent edits can't interleave and lose changes.

## Gotchas that have bitten before

- `BufReadPost` fires before an async LSP attach completes — gate autocmd
  *registration*, not just a runtime check, or you get duplicate
  lint diagnostics.
- A live `m1-lsp` keeps running across a toolchain update; stale behaviour
  after `:M1Update` usually needs `:LspRestart`, not debugging.
- Nested `vim.wait()` deadlocks headless Neovim — keep the test suite free
  of it.
- `vim.api.nvim_exec2` returns its output under the `output` key.

## Build / test gate

```sh
scripts/test.sh                          # headless plenary-busted suite
stylua --check lua/ plugin/              # separate CI job
```

The end-to-end lint spec uses the real `m1-lint` from `$PATH` when present.
Headless tests can't see UI-thread stalls or attach races — verify UX-facing
changes in a real interactive Neovim against a real project.

## Releases

Cut from the `VERSION` file on `main` (release.yml tags `vX.Y.Z`). Bumping
the bundled toolchain pins is the last step of a toolchain release cascade —
keep the pinned versions mutually compatible (the lsp/fmt/lint/project
releases that were tested together).
