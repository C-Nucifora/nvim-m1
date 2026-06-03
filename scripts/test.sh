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

# Built toolchain binaries (release, then debug) so e2e specs find m1-lint etc.
for tool in m1-lint m1-fmt m1-lsp m1-project; do
  for profile in release debug; do
    d="$stack/$tool/target/$profile"
    [ -x "$d/$tool" ] && PATH="$d:$PATH"
  done
done
export PATH

export PLENARY_PATH="${PLENARY_PATH:-$HOME/.local/share/nvim/lazy/plenary.nvim}"

nvim --headless --noplugin -u "$here/tests/minimal_init.lua" \
  -c "PlenaryBustedDirectory $here/tests { minimal_init = '$here/tests/minimal_init.lua', sequential = true }" \
  "$@"
