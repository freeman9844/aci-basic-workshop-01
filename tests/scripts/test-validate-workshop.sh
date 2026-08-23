#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VALIDATOR="$ROOT/tests/validate-workshop.sh"

grep -Fq 'relative.startswith(".superpowers/sdd/")' "$VALIDATOR"

printf 'PASS: validator ignores generated SDD review artifacts\n'
