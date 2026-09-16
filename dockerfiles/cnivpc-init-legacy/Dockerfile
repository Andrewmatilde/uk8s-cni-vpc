# Reuse the released CNI binary without rebuilding historical source code.
ARG NODE_IMAGE=uhub.service.ucloud.cn/uk8s/cni-vpc-node:1.3.4
ARG INIT_IMAGE=uhub.service.ucloud.cn/uk8s/cni-vpc-init:2.0.6
FROM ${NODE_IMAGE} AS historical-node
FROM ${INIT_IMAGE}

ARG NODE_IMAGE
ARG INIT_IMAGE
LABEL cnivpc.node-source="${NODE_IMAGE}" \
      cnivpc.init-source="${INIT_IMAGE}"

COPY --from=historical-node --chmod=0755 /usr/local/bin/cnivpc /app/cnivpc
ENTRYPOINT ["/usr/local/bin/cnivpc-init"]
