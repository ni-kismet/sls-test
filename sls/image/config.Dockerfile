# SystemLink Server configuration image: a base image plus one thin qcow2 overlay (rebased on /images/base.qcow2) that
# carries preloaded data. Built by build/New-SlsConfigImage.ps1 with the overlay's folder as the build context:
#   docker build -f image/config.Dockerfile --build-arg BASE_IMAGE=... --build-arg CONFIG_NAME=demo out/configs/demo
ARG BASE_IMAGE
FROM ${BASE_IMAGE}
ARG CONFIG_NAME
ARG CONFIG_CREATED=unknown
ARG CONFIG_SOURCE=unknown
COPY --chmod=444 ${CONFIG_NAME}.qcow2 /images/configs/${CONFIG_NAME}.qcow2
ENV SLS_CONFIG=${CONFIG_NAME}
LABEL com.ni.sls.config="${CONFIG_NAME}" \
      com.ni.sls.config-created="${CONFIG_CREATED}" \
      com.ni.sls.config-source="${CONFIG_SOURCE}"
