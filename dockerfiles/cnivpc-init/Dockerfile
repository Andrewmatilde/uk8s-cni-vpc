FROM uhub.service.ucloud.cn/library/alpine@sha256:4d889c14e7d5a73929ab00be2ef8ff22437e7cbc545931e52554a7b00e123d8b

COPY --chmod=0755 bin/cnivpc /app/cnivpc
COPY --chmod=0755 bin/cnivpc-init /usr/local/bin/cnivpc-init

ENTRYPOINT ["/usr/local/bin/cnivpc-init"]
