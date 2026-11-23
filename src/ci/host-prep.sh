#!/usr/bin/env bash
# Prepares a GitHub-hosted Ubuntu runner for SystemLink Server image work (run by sls-build-image and
# sls-start-server): KVM/TUN usable from a container, enough free space in the Docker data
# root, optional ghcr.io login and license file.
#
# Environment:
#   MIN_FREE_GB     free GB required in the Docker data root; space is only reclaimed when below it (default 60)
#   REGISTRY_LOGIN  'true' to log in to ghcr.io with REGISTRY_TOKEN as REGISTRY_USER (default github.actor)
#   LICENSE_B64     optional base64 license file; written to $RUNNER_TEMP/sls-licenses/sls.lic, the folder is
#                   exported as SLS_LICENSE_DIR
# Step outputs: docker-free-gb, license-dir
set -euo pipefail
MIN_FREE_GB=${MIN_FREE_GB:-60}

docker run --rm --device /dev/kvm --device /dev/net/tun alpine:3 sh -c 'test -c /dev/kvm && test -c /dev/net/tun' \
  || { echo "::error::/dev/kvm or /dev/net/tun is not usable from a container"; exit 1; }

docker_free_gb() { docker run --rm alpine:3 df -k / | awk 'NR==2 {print int($4/1048576)}'; }
free=$(docker_free_gb)
echo "Docker free: ${free} GB (need ${MIN_FREE_GB})"
if [ "$free" -lt "$MIN_FREE_GB" ]; then
  root_dev=$(stat -c %d /); mnt_dev=$(stat -c %d /mnt 2>/dev/null || echo "$root_dev")
  mnt_free=$(df -k --output=avail /mnt 2>/dev/null | awk 'NR==2 {print int($1/1048576)}')
  if [ "$mnt_dev" != "$root_dev" ] && [ "${mnt_free:-0}" -gt "$free" ]; then
    echo "Moving the Docker data root to /mnt/docker (${mnt_free} GB free)"
    sudo systemctl stop docker docker.socket
    sudo mkdir -p /mnt/docker
    sudo jq '. + {"data-root": "/mnt/docker"}' /etc/docker/daemon.json 2>/dev/null > /tmp/daemon.json \
      || echo '{"data-root": "/mnt/docker"}' > /tmp/daemon.json
    sudo mv /tmp/daemon.json /etc/docker/daemon.json
    sudo systemctl start docker
  fi
  free=$(docker_free_gb)
fi
if [ "$free" -lt "$MIN_FREE_GB" ]; then
  echo "Removing preinstalled toolchains not used by SystemLink image work"
  sudo rm -rf /usr/share/dotnet /usr/local/lib/android /opt/ghc /usr/local/.ghcup \
    /usr/local/share/boost /opt/hostedtoolcache/CodeQL
  docker image prune -af >/dev/null
  free=$(docker_free_gb)
fi
if [ -n "${GITHUB_OUTPUT:-}" ]; then echo "docker-free-gb=$free" >> "$GITHUB_OUTPUT"; fi
if [ "$free" -lt "$MIN_FREE_GB" ]; then
  echo "::error::Docker has ${free} GB free, ${MIN_FREE_GB} GB required"
  exit 1
fi

if [ "${REGISTRY_LOGIN:-false}" = "true" ]; then
  [ -n "${REGISTRY_TOKEN:-}" ] || { echo "::error::registry login requested without a token"; exit 1; }
  echo "$REGISTRY_TOKEN" | docker login ghcr.io -u "${REGISTRY_USER:-${GITHUB_ACTOR:-sls}}" --password-stdin
fi

if [ -n "${LICENSE_B64:-}" ]; then
  dir="${RUNNER_TEMP:-/tmp}/sls-licenses"
  mkdir -p "$dir"; chmod 700 "$dir"
  echo "$LICENSE_B64" | base64 -d > "$dir/sls.lic"
  chmod 600 "$dir/sls.lic"
  if [ -n "${GITHUB_ENV:-}" ]; then echo "SLS_LICENSE_DIR=$dir" >> "$GITHUB_ENV"; fi
  if [ -n "${GITHUB_OUTPUT:-}" ]; then echo "license-dir=$dir" >> "$GITHUB_OUTPUT"; fi
fi

line="Host: $(nproc) vCPU, $(free -g | awk '/^Mem:/ {print $2}') GB RAM, Docker ${free} GB free at $(docker info --format '{{.DockerRootDir}}'), $(. /etc/os-release; echo "$PRETTY_NAME"), pwsh $(pwsh -NoLogo -NoProfile -Command '$PSVersionTable.PSVersion.ToString()')"
echo "$line"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then echo "$line" >> "$GITHUB_STEP_SUMMARY"; fi
