# SystemLink Server image. DISK_IMAGE is the disk layer image produced by the build's Image stage: the pinned dockur
# image + /images/base.qcow2 (sealed SystemLink disk) + /images/state/windows.*. The layers below are small and change
# without touching the disk layer.
ARG DISK_IMAGE
FROM ${DISK_IMAGE}
COPY --chmod=755 start.sh /run/start.sh
COPY --chmod=755 healthcheck.sh /run/sls-healthcheck.sh
COPY --chmod=755 bin/ /usr/local/bin/
COPY guest/ /opt/sls/guest/
# DISK_SIZE empty: start.sh uses the disk's own virtual size (dockur's 64G default would log a shrink warning).
# An explicit larger -e DISK_SIZE grows the disk.
# HV=N: no Hyper-V enlightenments. With them Windows bugchecks (stop 0x4A) on nested KVM (Docker Desktop's WSL2
# engine, cloud CI runners); -e HV=Y turns them back on.
ENV VERSION=2022 DISK_FMT=qcow2 DISK_SIZE= RAM_SIZE=8G CPU_CORES=4 SLS_CONFIG=base HV=N
RUN mkdir -p /shared /licenses
HEALTHCHECK --interval=5s --timeout=10s --start-period=15m --retries=3 CMD ["/run/sls-healthcheck.sh"]
ARG SLS_VERSION=unknown
ARG SLS_FEED_VERSION=unknown
ARG NIPM_VERSION=unknown
ARG SLS_PRODUCTS=unknown
ARG WINDOWS_VERSION=unknown
ARG WINDOWS_EVAL_EXPIRES=unknown
ARG DOCKUR_IMAGE=unknown
ARG BUILD_ID=unknown
ARG CREATED=unknown
ARG REVISION=unknown
ARG SOURCE=unknown
ARG ADMIN_PASSWORD_LABEL=custom
LABEL org.opencontainers.image.title="SystemLink Server" \
      org.opencontainers.image.description="NI SystemLink Server in a Windows VM (QEMU/KVM, dockurr/windows). Needs /dev/kvm." \
      org.opencontainers.image.version="${SLS_VERSION}" \
      org.opencontainers.image.created="${CREATED}" \
      org.opencontainers.image.revision="${REVISION}" \
      org.opencontainers.image.source="${SOURCE}" \
      com.ni.sls.version="${SLS_VERSION}" \
      com.ni.sls.feed-version="${SLS_FEED_VERSION}" \
      com.ni.sls.nipm-version="${NIPM_VERSION}" \
      com.ni.sls.products="${SLS_PRODUCTS}" \
      com.ni.sls.windows-version="${WINDOWS_VERSION}" \
      com.ni.sls.windows-eval-expires="${WINDOWS_EVAL_EXPIRES}" \
      com.ni.sls.dockur-image="${DOCKUR_IMAGE}" \
      com.ni.sls.build-id="${BUILD_ID}" \
      com.ni.sls.admin-password="${ADMIN_PASSWORD_LABEL}" \
      com.ni.sls.config="base"
