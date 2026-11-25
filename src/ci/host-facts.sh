#!/usr/bin/env bash
# Host facts of a GitHub-hosted runner for SystemLink Server image work: CPU model, hypervisor and the kvm_amd /
# kvm_intel module parameters (nested-KVM stability depends on them, docs/history/workflow-test-plan.md §8).
#
# Environment:
#   FACTS_DIR    optional; writes $FACTS_DIR/runner.json
#   RUNNER_ID    optional; recorded in runner.json
#   REJECT_CPUS  optional extended regex; exits 1 when the CPU model matches (fail fast on known-bad hosts)
# Step outputs (when GITHUB_OUTPUT is set): host-cpu, hypervisor, kvm, cpu-stability (crashy, reliable or unknown,
# from host-cpus.tsv)
#
# Logs a "sls-host-cpu-v1" facts record for scraping (Write-SlsHostCpuRecord.ps1), and a warning (crashy) or notice
# (unknown) annotation.
set -euo pipefail

cpu=$(lscpu | sed -n 's/^Model name:[[:space:]]*//p' | head -1)
hv=$(lscpu | sed -n 's/^Hypervisor vendor:[[:space:]]*//p' | head -1)
kvm=$(for m in kvm_amd kvm_intel; do
  [ -d "/sys/module/$m/parameters" ] || continue
  for f in /sys/module/$m/parameters/*; do printf '%s=%s ' "$(basename "$f")" "$(cat "$f" 2>/dev/null)"; done
done)
kvm=${kvm% }
IFS=$'\t' read -r stability evidence < <(bash "$(dirname "${BASH_SOURCE[0]}")/host-cpu-stability.sh" "$cpu") || true
stability=${stability:-unknown}

if [ -n "${FACTS_DIR:-}" ]; then
  mkdir -p "$FACTS_DIR"
  jq -n --arg cpu "$cpu" --arg hv "$hv" --arg kvm "$kvm" --arg runner "${RUNNER_ID:-}" --arg stability "$stability" \
    --arg vcpu "$(nproc)" --arg memGB "$(free -g | awk '/^Mem:/ {print $2}')" \
    '{runner: $runner, cpu: $cpu, cpuStability: $stability, hypervisor: $hv, kvm: $kvm, vcpu: ($vcpu | tonumber), memGB: ($memGB | tonumber)}' \
    > "$FACTS_DIR/runner.json"
fi

line="Host CPU: $cpu (hypervisor ${hv:-none}); $(nproc) vCPU, $(free -g | awk '/^Mem:/ {print $2}') GB RAM; kvm: ${kvm:-n/a}"
stability_line="Host CPU stability: $stability (${evidence:-not in src/ci/host-cpus.tsv})"
echo "$line"
echo "$stability_line"
pwsh -NoProfile -File "$(dirname "${BASH_SOURCE[0]}")/Write-SlsHostCpuRecord.ps1" -Event facts -Cpu "$cpu" -Stability "$stability" \
  "hypervisor=$hv" "vcpu=$(nproc)" "mem_gb=$(free -g | awk '/^Mem:/ {print $2}')" "kvm=$kvm" ||
  echo "::warning::could not write the host CPU record"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then printf '%s\n\n%s\n' "$line" "$stability_line" >> "$GITHUB_STEP_SUMMARY"; fi
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  { echo "host-cpu=$cpu"; echo "hypervisor=$hv"; echo "kvm=$kvm"; echo "cpu-stability=$stability"; } >> "$GITHUB_OUTPUT"
fi
case "$stability" in
  crashy) echo "::warning title=Crash-prone host CPU::$cpu has had Windows guest bugchecks on nested KVM ($evidence)" ;;
  unknown) echo "::notice title=Unclassified host CPU::$cpu is not in src/ci/host-cpus.tsv; add it once its CI runs show whether it is reliable" ;;
esac

if [ -n "${REJECT_CPUS:-}" ] && echo "$cpu" | grep -Eq -- "$REJECT_CPUS"; then
  echo "::error::host CPU '$cpu' matches reject-cpus '$REJECT_CPUS'; re-run the job to get another host"
  exit 1
fi
