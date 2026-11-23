#!/usr/bin/env bash
# Healthy when the guest agent reported ready for this container start (NI services running, HTTP answering, runtime
# settings applied; start.sh removes the previous ready.json) and SystemLink answers:
#   with credentials (SLS_HEALTH_AUTH=user:password, else admin:$SLS_ADMIN_PASSWORD): authenticated 200 from the auth
#     and tag services - API usable (basic auth and the tag service lag the web server by ~15-30 s)
#   otherwise: the auth endpoint returns 401 (anonymous) or 200 - web server up
# Never healthy after a Windows bugcheck (sls-panic-watch wrote sls-panic.txt; the guest stays paused).
[ -e "${STORAGE:-/storage}/sls-panic.txt" ] && exit 1
[ -s /shared/agent/ready.json ] || exit 1
if [ -s /shared/agent/runtime.json ] && jq -e '.status == "failed"' /shared/agent/runtime.json >/dev/null 2>&1; then exit 1; fi
ip=$(cat /run/shm/qemu.ip 2>/dev/null) || exit 1
[ -n "$ip" ] || exit 1
auth=${SLS_HEALTH_AUTH:-}
if [ -z "$auth" ] && [ -n "${SLS_ADMIN_PASSWORD:-}" ]; then auth="admin:$SLS_ADMIN_PASSWORD"; fi
if [ -n "$auth" ]; then
  for path in 'niauth/v1/user' 'nitag/v2/tags?take=1'; do
    code=$(curl -s -o /dev/null -m 4 -u "$auth" -w '%{http_code}' "http://$ip/$path") || exit 1
    [[ "$code" == "200" ]] || exit 1
  done
  exit 0
fi
code=$(curl -s -o /dev/null -m 4 -w '%{http_code}' "http://$ip/niauth/v1/user") || exit 1
[[ "$code" == "200" || "$code" == "401" ]]
