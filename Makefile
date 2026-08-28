# The building args, they will be injected into binary file.
WORKDIR=$(shell pwd)
PKG_VERSION_PATH="github.com/ucloud/uk8s-cni-vpc/pkg/version"
GO_VERSION=$(shell go version)
BUILD_TIME=$(shell date +%F-%Z/%T)
COMMIT_ID=$(shell git rev-parse HEAD)
COMMIT_ID_SHORT=$(shell git rev-parse --short HEAD)
LDFLAGS= -ldflags  "-X '${PKG_VERSION_PATH}.CNIVersion=${CNI_VERSION}' -X ${PKG_VERSION_PATH}.BuildTime=${BUILD_TIME} -X ${PKG_VERSION_PATH}.ProgramCommitID=${COMMIT_ID}"
CNIVPC_INIT_LDFLAGS= -ldflags  "-X '${PKG_VERSION_PATH}.CNIVersion=${CNI_VERSION}' -X ${PKG_VERSION_PATH}.BuildTime=${BUILD_TIME} -X ${PKG_VERSION_PATH}.ProgramCommitID=${COMMIT_ID}"

# If current commit is tagged, use tag as version, else, use dev-${COMMIT_ID} as version
CNI_VERSION=$(shell git tag --points-at ${COMMIT_ID})
CNI_VERSION:=$(if $(CNI_VERSION),$(CNI_VERSION),dev-${COMMIT_ID_SHORT})
CNI_VERSION:=$(shell echo ${CNI_VERSION} | sed -e "s/^v//")

# Go args, the cni-vpc only support Linux os.
export GOOS=linux
export GO111MODULE=on
export GOARCH=$(TARGETARCH)
export CGO_ENABLED=0

DOCKER_DEPLOY_BUCKET=uhub.service.ucloud.cn/uk8s
DOCKER_TEST_BUCKET=uhub.service.ucloud.cn/wxyz
REGISTRY?=uhub.service.ucloud.cn/andrew
PLATFORM?=linux/amd64
CNIVPC_INIT_RELEASE_VERSION=2.0.0-alpha.5
CNIVPC_INIT_GO_VERSION=go1.21.13

DOCKER_LABEL:=$(if $(DEPLOY),$(CNI_VERSION),dev-$(COMMIT_ID_SHORT))
DOCKER_LABEL:=$(if $(IMAGE_TAG),$(IMAGE_TAG),$(DOCKER_LABEL))
DOCKER_BUCKET:=$(if $(DEPLOY),$(DOCKER_DEPLOY_BUCKET),$(DOCKER_TEST_BUCKET))

CNIVPC_IMAGE:=$(DOCKER_BUCKET)/cni-vpc-node:$(DOCKER_LABEL)
CNIVPC_INIT_IMAGE:=$(REGISTRY)/cni-vpc-init:$(DOCKER_LABEL)
CNIVPC_INIT_STAGING_IMAGE:=$(REGISTRY)/cni-vpc-init:$(CNIVPC_INIT_RELEASE_VERSION)
CNIVPC_INIT_PRODUCTION_IMAGE:=$(DOCKER_DEPLOY_BUCKET)/cni-vpc-init:$(CNIVPC_INIT_RELEASE_VERSION)
CNIVPC_INIT_STAGING_DIGEST?=
CNIVPC_INIT_STAGING_REFERENCE:=$(REGISTRY)/cni-vpc-init@$(CNIVPC_INIT_STAGING_DIGEST)
IPAMD_IMAGE:=$(DOCKER_BUCKET)/cni-vpc-ipamd:$(DOCKER_LABEL)
VIP_CONTROLLER_IMAGE:=$(DOCKER_BUCKET)/vip-controller:$(DOCKER_LABEL)

DOCKER_CMD:=$(if $(DOCKER_CMD),$(DOCKER_CMD),docker)

all: cnivpc

.PHONY: cnivpc-bin
cnivpc-bin:
	CGO_ENABLED=0 GOOS="linux" GOARCH="amd64" go build ${LDFLAGS} -o ./bin/cnivpc ./cmd/cnivpc
	CGO_ENABLED=0 GOOS="linux" GOARCH="amd64" go build ${LDFLAGS} -o ./bin/cnivpctl ./cmd/cnivpctl

.PHONY: cnivpc-init-bin
cnivpc-init-bin:
	CGO_ENABLED=0 GOOS="linux" GOARCH="amd64" go build ${CNIVPC_INIT_LDFLAGS} -o ./bin/cnivpc ./cmd/cnivpc
	CGO_ENABLED=0 GOOS="linux" GOARCH="amd64" go build ${CNIVPC_INIT_LDFLAGS} -o ./bin/cnivpc-init ./cmd/cnivpc-init

.PHONY: push-cnivpc-init-image
push-cnivpc-init-image: verify-cnivpc-init-release verify-cnivpc-init-clean-worktree verify-cnivpc-init-staging-tag-absent cnivpc-init-bin
	$(DOCKER_CMD) buildx build --platform $(PLATFORM) --push -t $(CNIVPC_INIT_IMAGE) -f dockerfiles/cnivpc-init/Dockerfile .
	@echo "Build done: $(CNIVPC_INIT_IMAGE)"

.PHONY: verify-cnivpc-init-release
verify-cnivpc-init-release:
	@test "$(CNI_VERSION)" = "$(CNIVPC_INIT_RELEASE_VERSION)" || { echo "ERROR: CNI_VERSION must be $(CNIVPC_INIT_RELEASE_VERSION)"; exit 1; }
	@test "$(DOCKER_LABEL)" = "$(CNIVPC_INIT_RELEASE_VERSION)" || { echo "ERROR: IMAGE_TAG must be $(CNIVPC_INIT_RELEASE_VERSION)"; exit 1; }
	@test "$(PLATFORM)" = "linux/amd64" || { echo "ERROR: PLATFORM must be linux/amd64"; exit 1; }
	@test "$(word 3,$(GO_VERSION))" = "$(CNIVPC_INIT_GO_VERSION)" || { echo "ERROR: Go toolchain must be $(CNIVPC_INIT_GO_VERSION)"; exit 1; }
	@test -z "$(DEPLOY)" || { echo "ERROR: push-cnivpc-init-image only publishes to staging; use promote-cnivpc-init-image for production"; exit 1; }
	@test "$(REGISTRY)" != "$(DOCKER_DEPLOY_BUCKET)" || { echo "ERROR: REGISTRY must not be the production bucket $(DOCKER_DEPLOY_BUCKET)"; exit 1; }

.PHONY: verify-cnivpc-init-clean-worktree
verify-cnivpc-init-clean-worktree:
	@test -z "$$(git status --porcelain=v1 --untracked-files=all -- . ':(exclude)docs/**')" || { echo "ERROR: commit release changes before building an image (docs/ is ignored)"; exit 1; }

.PHONY: verify-cnivpc-init-staging-tag-absent
verify-cnivpc-init-staging-tag-absent:
	@output="$$( $(DOCKER_CMD) buildx imagetools inspect "$(CNIVPC_INIT_IMAGE)" 2>&1 )"; status=$$?; \
	if [ "$$status" -eq 0 ]; then \
		echo "ERROR: refusing to overwrite existing staging image $(CNIVPC_INIT_IMAGE)"; \
		exit 1; \
	fi; \
	case "$$output" in \
		*"not found"*|*"manifest unknown"*|*"no such manifest"*) ;; \
		*) printf '%s\n' "$$output"; echo "ERROR: unable to prove staging tag is absent"; exit 1 ;; \
	esac

.PHONY: promote-cnivpc-init-image
promote-cnivpc-init-image: verify-cnivpc-init-promotion verify-cnivpc-init-production-tag-absent
	$(DOCKER_CMD) buildx imagetools create --prefer-index=false --tag "$(CNIVPC_INIT_PRODUCTION_IMAGE)" "$(CNIVPC_INIT_STAGING_REFERENCE)"
	@if ! actual_digest="$$( $(DOCKER_CMD) buildx imagetools inspect --format '{{.Manifest.Digest}}' "$(CNIVPC_INIT_PRODUCTION_IMAGE)" )"; then \
		echo "ERROR: unable to inspect promoted production image"; \
		exit 1; \
	fi; \
	if [ "$$actual_digest" != "$(CNIVPC_INIT_STAGING_DIGEST)" ]; then \
		echo "ERROR: production digest $$actual_digest differs from staging digest $(CNIVPC_INIT_STAGING_DIGEST)"; \
		exit 1; \
	fi
	@echo "Promoted: $(CNIVPC_INIT_PRODUCTION_IMAGE)@$(CNIVPC_INIT_STAGING_DIGEST)"

.PHONY: verify-cnivpc-init-promotion
verify-cnivpc-init-promotion:
	@printf '%s\n' "$(CNIVPC_INIT_STAGING_DIGEST)" | grep -Eq '^sha256:[0-9a-f]{64}$$' || { echo "ERROR: CNIVPC_INIT_STAGING_DIGEST must be a sha256 digest"; exit 1; }
	@test "$(REGISTRY)" != "$(DOCKER_DEPLOY_BUCKET)" || { echo "ERROR: REGISTRY must identify the staging bucket, not production"; exit 1; }
	@if ! tag_digest="$$( $(DOCKER_CMD) buildx imagetools inspect --format '{{.Manifest.Digest}}' "$(CNIVPC_INIT_STAGING_IMAGE)" )"; then \
		echo "ERROR: unable to inspect staging image $(CNIVPC_INIT_STAGING_IMAGE)"; \
		exit 1; \
	fi; \
	if [ "$$tag_digest" != "$(CNIVPC_INIT_STAGING_DIGEST)" ]; then \
		echo "ERROR: staging tag resolves to $$tag_digest, expected $(CNIVPC_INIT_STAGING_DIGEST)"; \
		exit 1; \
	fi; \
	if ! actual_digest="$$( $(DOCKER_CMD) buildx imagetools inspect --format '{{.Manifest.Digest}}' "$(CNIVPC_INIT_STAGING_REFERENCE)" )"; then \
		echo "ERROR: unable to inspect staging digest reference"; \
		exit 1; \
	fi; \
	if [ "$$actual_digest" != "$(CNIVPC_INIT_STAGING_DIGEST)" ]; then \
		echo "ERROR: staging reference resolved to $$actual_digest, expected $(CNIVPC_INIT_STAGING_DIGEST)"; \
		exit 1; \
	fi

.PHONY: verify-cnivpc-init-production-tag-absent
verify-cnivpc-init-production-tag-absent:
	@output="$$( $(DOCKER_CMD) buildx imagetools inspect "$(CNIVPC_INIT_PRODUCTION_IMAGE)" 2>&1 )"; status=$$?; \
	if [ "$$status" -eq 0 ]; then \
		echo "ERROR: refusing to overwrite existing production image $(CNIVPC_INIT_PRODUCTION_IMAGE)"; \
		exit 1; \
	fi; \
	case "$$output" in \
		*"not found"*|*"manifest unknown"*|*"no such manifest"*) ;; \
		*) printf '%s\n' "$$output"; echo "ERROR: unable to prove production tag is absent"; exit 1 ;; \
	esac

.PHONY: cnivpc
cnivpc: cnivpc-bin
	$(DOCKER_CMD) build -t $(CNIVPC_IMAGE) -f dockerfiles/cnivpc/Dockerfile .
	$(DOCKER_CMD) push $(CNIVPC_IMAGE)
	@echo "Build done: $(CNIVPC_IMAGE)"

.PHONY: ipamd
ipamd:
	CGO_ENABLED=0 GOOS="linux" GOARCH="amd64" go build ${LDFLAGS} -o ./bin/cnivpc-ipamd ./cmd/cnivpc-ipamd
	$(DOCKER_CMD) build -t $(IPAMD_IMAGE) -f dockerfiles/ipamd/Dockerfile .
	$(DOCKER_CMD) push $(IPAMD_IMAGE)
	@echo "Build done: $(IPAMD_IMAGE)"

.PHONY: vip-controller
vip-controller:
	CGO_ENABLED=0 GOOS="linux" GOARCH="amd64" go build ${LDFLAGS} -o ./bin/vip-controller ./cmd/vip-controller
	$(DOCKER_CMD) build -t $(VIP_CONTROLLER_IMAGE) -f dockerfiles/vip-controller/Dockerfile .
	$(DOCKER_CMD) push $(VIP_CONTROLLER_IMAGE)
	@echo "Build done: $(VIP_CONTROLLER_IMAGE)"

.PHONY: release-ip
release-ip:
	CGO_ENABLED=0 GOOS="linux" GOARCH="amd64" go build -o ./bin/release-ip ./cmd/release-ip

.PHONY: fmt
fmt:
	@command -v goimports >/dev/null || { echo "ERROR: goimports not installed"; exit 1; }
	@exit $(shell find ./* \
	  -type f \
	  -name '*.go' \
	  -print0 | sort -z | xargs -0 -- goimports $(or $(FORMAT_FLAGS),-w) | wc -l | bc)

.PHONY: check-fmt
check-fmt:
	@./scripts/check-fmt.sh

.PHONY: install-check
install-check:
	@go install github.com/client9/misspell/cmd/misspell@latest
	@go install github.com/gordonklaus/ineffassign@latest
	@go install golang.org/x/tools/cmd/goimports@latest

.PHONY: check
check:
	@echo "==> check ineffassign"
	@ineffassign ./...
	@echo "==> check spell"
	@find . -type f -name '*.go' | xargs misspell -error
	@echo "==> go vet"
	@go vet ./...

.PHONY: version
version:
	@echo ${CNI_VERSION}

.PHONY: clean
clean:
	@rm -rf ./bin

.PHONY: install-grpc
install-grpc:
	@go install github.com/golang/protobuf/protoc-gen-go@latest

.PHONY: generate-grpc
generate-grpc:
	@command -v protoc >/dev/null || { echo "ERROR: protoc not installed"; exit 1; }
	@command -v protoc-gen-go >/dev/null || { echo "ERROR: protoc-gen-go not installed"; exit 1; }
	@protoc --go_out=plugins=grpc:./rpc ./rpc/ipamd.proto

.PHONY: generate-k8s
generate-k8s:
	@bash hack/update-codegen.sh
