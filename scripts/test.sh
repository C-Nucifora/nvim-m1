#!/usr/bin/env bash
# Run the nvim-m1 test suite headless with plenary-busted.
#
#   scripts/test.sh
#
# Locates plenary via $PLENARY_PATH or the lazy.nvim data dir, and (for the
# end-to-end specs) puts any locally-built m1 toolchain binaries on $PATH.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
stack="$(cd "$here/.." && pwd)"

# Isolate the data dir so the parser integration spec compiles its
# tree-sitter `m1.so` into a throwaway location (fresh each run) instead of the
# developer's real ~/.local/share/nvim — keeps runs hermetic and ensures the
# parser is always rebuilt from scratch, so a provisioning regression fails.
XDG_DATA_HOME="$(mktemp -d)"
export XDG_DATA_HOME
trap 'rm -rf "$XDG_DATA_HOME"' EXIT

# Built toolchain binaries (release, then debug) so e2e specs find m1-lint etc.
for tool in m1-lint m1-fmt m1-lsp m1-project; do
  for profile in release debug; do
    d="$stack/$tool/target/$profile"
    [ -x "$d/$tool" ] && PATH="$d:$PATH"
  done
done
export PATH

export PLENARY_PATH="${PLENARY_PATH:-$HOME/.local/share/nvim/lazy/plenary.nvim}"

# tree-sitter-m1 sibling checkout (m1-tools layout) so the parser integration
# spec can build + load the grammar. Harmless if absent (that spec is pending).
if [ -z "${TREE_SITTER_M1_PATH:-}" ] && [ -d "$stack/tree-sitter-m1" ]; then
  export TREE_SITTER_M1_PATH="$stack/tree-sitter-m1"
fi

nvim --headless --noplugin -u "$here/tests/minimal_init.lua" \
  -c "PlenaryBustedDirectory $here/tests { minimal_init = '$here/tests/minimal_init.lua', sequential = true }" \
  "$@"
