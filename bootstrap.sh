#!/usr/bin/env bash
# bootstrap.sh — the front door. Everything it does lives in
# scripts/setup/setup.sh; this file exists so that the first command anyone
# runs on a new machine is the obvious one.
#
#   ./bootstrap.sh                      full install
#   ./bootstrap.sh --profile frontend   one profile's skills
#   ./bootstrap.sh --dry-run            show what would happen, change nothing
#
# Safe to re-run. It converges on the same state and never appends twice.

set -Eeuo pipefail
exec "$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scripts/setup/setup.sh" "$@"
