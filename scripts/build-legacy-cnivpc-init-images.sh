#!/usr/bin/env bash
set -euo pipefail

# Pass only versions confirmed missing from the image repositories.
if [[ $# -eq 0 ]]; then
  echo "Usage: $0 CNI_VERSION [CNI_VERSION ...]" >&2
  exit 1
fi

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
for version in "$@"; do
  docker buildx build --platform linux/amd64 --push \
    --build-arg "NODE_IMAGE=uhub.service.ucloud.cn/uk8s/cni-vpc-node:${version}" \
    --build-arg "INIT_IMAGE=uhub.service.ucloud.cn/uk8s/cni-vpc-init:2.0.6" \
    -t "uhub.service.ucloud.cn/uk8s/cni-vpc-init:${version}" \
    -f "$ROOT/dockerfiles/cnivpc-init-legacy/Dockerfile" \
    "$ROOT/dockerfiles/cnivpc-init-legacy"
done
