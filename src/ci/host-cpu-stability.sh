#!/usr/bin/env bash
# Classifies a host CPU model with host-cpus.tsv. Prints "<stability><TAB><evidence>"; stability is crashy, reliable
# or unknown (evidence empty).
#
# Usage: host-cpu-stability.sh "<lscpu model name>"
# Environment: HOST_CPUS_FILE optional table (default: host-cpus.tsv next to this script)
set -euo pipefail

cpu=${1:?usage: host-cpu-stability.sh MODEL}
file=${HOST_CPUS_FILE:-"$(dirname "${BASH_SOURCE[0]}")/host-cpus.tsv"}

while IFS=$'\t' read -r stability pattern evidence; do
  case "$stability" in '' | '#'*) continue ;; esac
  evidence=${evidence%$'\r'}
  if printf '%s\n' "$cpu" | grep -Eq -- "$pattern"; then
    printf '%s\t%s\n' "$stability" "$evidence"
    exit 0
  fi
done < "$file"
printf 'unknown\t\n'
