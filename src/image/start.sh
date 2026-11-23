#!/usr/bin/env bash
# SystemLink Server image start hook. dockur's /run/entry.sh sources this file before anything else
# (under set -Eeuo pipefail), so it must not exit on success; it ends with "return 0".
#   Ephemeral (default): $STORAGE has no disk -> create a qcow2 overlay on top of the read-only image disk
#                        (/images/base.qcow2 or /images/configs/$SLS_CONFIG.qcow2) and copy the VM state files.
#   Persistent:          a volume mounted at $STORAGE already holds data.qcow2 from an earlier run -> reuse it.
# It also stages the guest agent (/opt/sls/guest), the runtime settings (SLS_ADMIN_PASSWORD, SLS_LICENSE_USER,
# /licenses/*.lic) for the agent, and shows the agent log in "docker logs" with an [agent] prefix.
: "${SLS_CONFIG:=base}"
: "${STORAGE:=/storage}"
slsImages=/images
slsShared=/shared
slsLog() { echo "[sls] $(date -u +%Y-%m-%dT%H:%M:%S.%3NZ) $*"; }

if [[ "$SLS_CONFIG" == "base" ]]; then
  slsBacking="$slsImages/base.qcow2"
else
  slsBacking="$slsImages/configs/$SLS_CONFIG.qcow2"
fi

if [ ! -f "$slsBacking" ]; then
  slsLog "ERROR: configuration '$SLS_CONFIG' not found. Available: base $(ls "$slsImages/configs" 2>/dev/null | sed 's/\.qcow2$//' | tr '\n' ' ')"
  exit 64
fi

mkdir -p "$STORAGE"
if [ -s "$STORAGE/data.qcow2" ]; then
  slsCurrent=$(qemu-img info --output=json "$STORAGE/data.qcow2" | jq -r '."backing-filename" // "none"')
  slsLog "persistent mode: reusing $STORAGE/data.qcow2 (backing $slsCurrent)"
  if [[ "$slsCurrent" != "$slsBacking" ]]; then
    slsLog "WARNING: SLS_CONFIG=$SLS_CONFIG ignored, the existing disk is based on $slsCurrent"
  fi
else
  qemu-img create -q -f qcow2 -b "$slsBacking" -F qcow2 "$STORAGE/data.qcow2"
  cp "$slsImages/state/"windows.* "$STORAGE/"
  slsLog "ephemeral overlay created on $slsBacking"
fi

export DISK_FMT=qcow2
if [ -z "${DISK_SIZE:-}" ]; then
  # Same as the image disk, so dockur neither resizes nor warns about shrinking.
  slsBytes=$(qemu-img info --output=json "$STORAGE/data.qcow2" | jq -r '."virtual-size"')
  export DISK_SIZE="$(( slsBytes / 1073741824 ))G"
fi
slsLog "disk ready: config=$SLS_CONFIG size=$DISK_SIZE"

# ---- guest agent and runtime settings (the shared folder is \\host.lan\Data in the guest)
mkdir -p "$slsShared/agent" "$slsShared/runtime" "$slsShared/cmd" "$slsShared/cmd-out"
rm -rf "$slsShared/guest" "$slsShared/runtime/licenses" "$slsShared/cmd/"* "$slsShared/cmd-out/"*
rm -f "$slsShared/runtime/config.json" "$slsShared/agent/"{ready,runtime,status,boot}.json
cp -r /opt/sls/guest "$slsShared/guest"
if [ -f "$slsShared/agent/agent.log" ]; then mv -f "$slsShared/agent/agent.log" "$slsShared/agent/agent.previous.log"; fi
if [ -n "${SLS_ADMIN_PASSWORD:-}" ] || [ -n "${SLS_LICENSE_USER:-}" ]; then
  (umask 077; jq -n --arg p "${SLS_ADMIN_PASSWORD:-}" --arg u "${SLS_LICENSE_USER:-}" \
    '{adminPassword: $p, licenseUser: $u}' >"$slsShared/runtime/config.json")
  slsLog "runtime settings: admin password $([ -n "${SLS_ADMIN_PASSWORD:-}" ] && echo requested || echo unchanged), license user ${SLS_LICENSE_USER:-none}"
fi
slsLics=$(find /licenses -maxdepth 1 -type f -name '*.lic' 2>/dev/null | wc -l)
if [ "$slsLics" -gt 0 ]; then
  mkdir -p "$slsShared/runtime/licenses"
  cp /licenses/*.lic "$slsShared/runtime/licenses/"
  slsLog "license files staged: $slsLics"
fi
(
  set +Eeu; trap - ERR
  tail -n +1 -F "$slsShared/agent/agent.log" 2>/dev/null | sed -u 's/^/[agent] /'
) &

# A Windows bugcheck would make QEMU exit 0 (it looks like a power off). Pause the guest instead; sls-panic-watch
# records it in $STORAGE/sls-panic.txt (the healthcheck then fails) and logs "[sls] ... Windows bugcheck". With HV=N
# (image default) the guest only reports a bugcheck to QEMU through the hv-crash enlightenment, so add just that one.
rm -f "$STORAGE/sls-panic.txt" "$STORAGE/sls-panic.ppm"
if [[ "${SLS_PANIC_PAUSE:-Y}" == [Yy]* ]]; then
  export ARGUMENTS="-action panic=pause${ARGUMENTS:+ $ARGUMENTS}"
  if [[ "${HV:-}" == [Nn]* ]] && [[ ",${CPU_FLAGS:-}," != *,hv-crash,* ]]; then
    export CPU_FLAGS="${CPU_FLAGS:+$CPU_FLAGS,}hv-crash"
  fi
  ( set +Eeu; trap - ERR; SLS_PANIC_DIR="$STORAGE" /usr/local/bin/sls-panic-watch ) &
fi

# dockur writes smb.conf and starts smbd after this hook; disable SMB leases once it runs.
if [[ "${SLS_SMB_NOLEASE:-Y}" == [Yy]* ]]; then
  ( set +Eeu; trap - ERR; /usr/local/bin/sls-smb-nolease -w 300 ) &
fi

return 0
