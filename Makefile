# Copyright 2021 The Kubernetes Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# If you update this file, please follow
# https://suva.sh/posts/well-documented-makefiles

# Ensure Make is run with bash shell as some syntax below is bash-specific
SHELL:=/usr/bin/env bash

# Path to main repo
ROOT:=$(shell dirname $(realpath $(firstword $(MAKEFILE_LIST))))

.DEFAULT_GOAL:=help

# Use GOPROXY environment variable if set
GOPROXY := $(shell go env GOPROXY)
ifeq ($(GOPROXY),)
GOPROXY := https://proxy.golang.org
endif
export GOPROXY

# Active module mode, as we use go modules to manage dependencies
export GO111MODULE=on

# This option is for running docker manifest command
export DOCKER_CLI_EXPERIMENTAL := enabled

# Directories
TOOLS_DIR := $(ROOT)/hack/tools
TOOLS_BIN_DIR := $(TOOLS_DIR)/bin
BIN_DIR := bin
GO_APIDIFF_BIN := $(BIN_DIR)/go-apidiff
GO_APIDIFF := $(TOOLS_DIR)/$(GO_APIDIFF_BIN)

export PATH := $(abspath $(TOOLS_BIN_DIR)):$(PATH)

# Kubebuilder
export KUBEBUILDER_ENVTEST_KUBERNETES_VERSION ?= 1.22.0
export KUBEBUILDER_CONTROLPLANE_START_TIMEOUT ?= 60s
export KUBEBUILDER_CONTROLPLANE_STOP_TIMEOUT ?= 60s

# Binaries.
# Need to use abspath so we can invoke these from subdirectories
CONTROLLER_GEN := $(abspath $(TOOLS_BIN_DIR)/controller-gen)
GOLANGCI_LINT := $(TOOLS_BIN_DIR)/golangci-lint
KUSTOMIZE := $(abspath $(TOOLS_BIN_DIR)/kustomize)
SETUP_ENVTEST := $(abspath $(TOOLS_BIN_DIR)/setup-envtest)
GOTESTSUM := $(abspath $(TOOLS_BIN_DIR)/gotestsum)
GINKGO := $(abspath $(TOOLS_BIN_DIR)/ginkgo)
ENVSUBST := $(abspath $(TOOLS_BIN_DIR)/envsubst)

# Define Docker related variables. Releases should modify and double check these vars.
REGISTRY ?= gcr.io/$(shell gcloud config get-value project)
PROD_REGISTRY ?= k8s.gcr.io/cluster-api

STAGING_REGISTRY ?= gcr.io/k8s-staging-cluster-api
STAGING_BUCKET ?= artifacts.k8s-staging-cluster-api.appspot.com

# Image name
IMAGE_NAME ?= cluster-api-operator
CONTROLLER_IMG ?= $(REGISTRY)/$(IMAGE_NAME)

# It is set by Prow GIT_TAG, a git-based tag of the form vYYYYMMDD-hash, e.g., v20210120-v0.3.10-308-gc61521971
TAG ?= dev
ARCH ?= amd64
ALL_ARCH = amd64 arm arm64 ppc64le s390x

# Set build time variables including version details
LDFLAGS := $(shell $(ROOT)/hack/version.sh)

# E2E configuration
GINKGO_NOCOLOR ?= false
GINKGO_ARGS ?=
ARTIFACTS ?= $(ROOT)/_artifacts
E2E_CONF_FILE ?= $(ROOT)/test/e2e/config/operator-dev.yaml
E2E_CONF_FILE_ENVSUBST ?= $(ROOT)/test/e2e/config/operator-dev-envsubst.yaml
SKIP_CLEANUP ?= false
SKIP_CREATE_MGMT_CLUSTER ?= false

# Relase
RELEASE_TAG := $(shell git describe --abbrev=0 2>/dev/null)
RELEASE_ALIAS_TAG ?= $(PULL_BASE_REF)
RELEASE_DIR := out

all: generate test operator

help:  ## Display this help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[0-9A-Za-z_-]+:.*?##/ { printf "  \033[36m%-45s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

## --------------------------------------
## Hack / Tools
## --------------------------------------

kustomize: $(KUSTOMIZE) ## Build a local copy of kustomize.
go-apidiff: $(GO_APIDIFF) ## Build a local copy of apidiff
ginkgo: $(GINKGO) ## Build a local copy of ginkgo
envsubst: $(ENVSUBST) ## Build a local copy of envsubst

$(CONTROLLER_GEN): $(TOOLS_DIR)/go.mod # Build controller-gen from tools folder.
	cd $(TOOLS_DIR); go build -tags=tools -o $(BIN_DIR)/controller-gen sigs.k8s.io/controller-tools/cmd/controller-gen

$(KUSTOMIZE): # Build kustomize from tools folder.
	$(ROOT)/hack/ensure-kustomize.sh

$(SETUP_ENVTEST): $(TOOLS_DIR)/go.mod # Build setup-envtest from tools folder.
	cd $(TOOLS_DIR); go build -tags=tools -o $(BIN_DIR)/setup-envtest sigs.k8s.io/controller-runtime/tools/setup-envtest

$(GOTESTSUM): $(TOOLS_DIR)/go.mod # Build gotestsum from tools folder.
	cd $(TOOLS_DIR); go build -tags=tools -o $(BIN_DIR)/gotestsum gotest.tools/gotestsum

$(GOLANGCI_LINT): .github/workflows/golangci-lint.yml # Download golanci-lint using hack script into tools folder.
	hack/ensure-golangci-lint.sh \
		-b $(TOOLS_DIR)/$(BIN_DIR) \
		$(shell cat .github/workflows/golangci-lint.yml | grep version | sed 's/.*version: //')

$(GO_APIDIFF): $(TOOLS_DIR)/go.mod # Build go-apidiff from tools folder.
	cd $(TOOLS_DIR); go build -tags=tools -o $(GO_APIDIFF_BIN) github.com/joelanford/go-apidiff

$(GINKGO): ## Build ginkgo.
	cd $(TOOLS_DIR); go build -tags=tools -o $(BIN_DIR)/ginkgo github.com/onsi/ginkgo/ginkgo

$(ENVSUBST): ## Build envsubst from tools folder.
	cd $(TOOLS_DIR); go build -tags=tools -o $(BIN_DIR)/envsubst github.com/drone/envsubst/v2/cmd/envsubst

.PHONY: cert-mananger
cert-manager: # Install cert-manager on the cluster. This is used for development purposes only.
	$(ROOT)/hack/cert-manager.sh

## --------------------------------------
## Testing
## --------------------------------------

ARTIFACTS ?= ${ROOT}/_artifacts

KUBEBUILDER_ASSETS ?= $(shell $(SETUP_ENVTEST) use --use-env -p path $(KUBEBUILDER_ENVTEST_KUBERNETES_VERSION))

.PHONY: test
test: $(SETUP_ENVTEST) ## Run unit and integration tests
	KUBEBUILDER_ASSETS="$(KUBEBUILDER_ASSETS)" go test ./... $(TEST_ARGS)

.PHONY: test-verbose
test-verbose: ## Run tests with verbose settings.
	TEST_ARGS="$(TEST_ARGS) -v" $(MAKE) test

.PHONY: test-junit
test-junit: $(SETUP_ENVTEST) $(GOTESTSUM) ## Run tests with verbose setting and generate a junit report
	set +o errexit; (KUBEBUILDER_ASSETS="$(KUBEBUILDER_ASSETS)" go test -json ./... $(TEST_ARGS); echo $$? > $(ARTIFACTS)/junit.exitcode) | tee $(ARTIFACTS)/junit.stdout
	$(GOTESTSUM) --junitfile $(ARTIFACTS)/junit.xml --raw-command cat $(ARTIFACTS)/junit.stdout
	exit $$(cat $(ARTIFACTS)/junit.exitcode)

## --------------------------------------
## Binaries
## --------------------------------------

.PHONY: operator
operator: ## Build operator binary
	go build -trimpath -ldflags "$(LDFLAGS)" -o $(BIN_DIR)/operator sigs.k8s.io/cluster-api-operator

## --------------------------------------
## Lint / Verify
## --------------------------------------

.PHONY: lint
lint: $(GOLANGCI_LINT) ## Lint the codebase
	$(GOLANGCI_LINT) run -v $(GOLANGCI_LINT_EXTRA_ARGS)

.PHONY: lint-fix
lint-fix: $(GOLANGCI_LINT) ## Lint the codebase and run auto-fixers if supported by the linter
	GOLANGCI_LINT_EXTRA_ARGS=--fix $(MAKE) lint

.PHONY: apidiff
apidiff: $(GO_APIDIFF) ## Check for API differences
	$(GO_APIDIFF) $(shell git rev-parse origin/main) --print-compatible

.PHONY: verify
verify:
	$(MAKE) verify-modules
	$(MAKE) verify-gen

.PHONY: verify-modules
verify-modules: modules
	@if !(git diff --quiet HEAD -- go.sum go.mod $(TOOLS_DIR)/go.mod $(TOOLS_DIR)/go.sum); then \
		git diff; \
		echo "go module files are out of date"; exit 1; \
	fi

.PHONY: verify-gen
verify-gen: generate
	@if !(git diff --quiet HEAD); then \
		git diff; \
		echo "generated files are out of date, run make generate"; exit 1; \
	fi

## --------------------------------------
## Generate / Manifests
## --------------------------------------

.PHONY: generate
generate: $(CONTROLLER_GEN) ## Generate code
	$(MAKE) generate-manifests
	$(MAKE) generate-go

.PHONY: generate-go
generate-go: $(CONTROLLER_GEN) ## Runs Go related generate targets for the operator
	$(CONTROLLER_GEN) \
		object:headerFile=$(ROOT)/hack/boilerplate/boilerplate.generatego.txt \
		paths=./api/...

.PHONY: generate-manifests
generate-manifests: $(CONTROLLER_GEN) ## Generate manifests for the operator e.g. CRD, RBAC etc.
	$(CONTROLLER_GEN) \
		paths=./api/... \
		paths=./controllers/... \
		paths=./webhook/... \
		crd:crdVersions=v1 \
		rbac:roleName=manager-role \
		output:crd:dir=./config/crd/bases \
		output:rbac:dir=./config/rbac \
		output:webhook:dir=./config/webhook \
		webhook

.PHONY: modules
modules: ## Runs go mod to ensure modules are up to date.
	go mod tidy
	cd $(TOOLS_DIR); go mod tidy

## --------------------------------------
## Docker
## --------------------------------------

.PHONY: docker-pull-prerequisites
docker-pull-prerequisites:
	docker pull docker.io/docker/dockerfile:1.1-experimental
	docker pull docker.io/library/golang:1.17.0
	docker pull gcr.io/distroless/static:latest

.PHONY: docker-build
docker-build: ## Build the docker image for management cluster operator
	DOCKER_BUILDKIT=1 docker build --build-arg goproxy=$(GOPROXY) --build-arg ARCH=$(ARCH) --build-arg ldflags="$(LDFLAGS)" . -t $(CONTROLLER_IMG)-$(ARCH):$(TAG)
	$(MAKE) set-manifest-image MANIFEST_IMG=$(CONTROLLER_IMG)-$(ARCH) MANIFEST_TAG=$(TAG) TARGET_RESOURCE="./config/default/manager_image_patch.yaml"
	$(MAKE) set-manifest-pull-policy TARGET_RESOURCE="./config/default/manager_pull_policy.yaml"

.PHONY: docker-push
docker-push: ## Push the docker image
	docker push $(CONTROLLER_IMG)-$(ARCH):$(TAG)

## --------------------------------------
## Docker — All ARCH
## --------------------------------------

.PHONY: docker-build-all ## Build all the architecture docker images
docker-build-all: $(addprefix docker-build-,$(ALL_ARCH))

docker-build-%:
	$(MAKE) ARCH=$* docker-build

.PHONY: docker-push-all ## Push all the architecture docker images
docker-push-all: $(addprefix docker-push-,$(ALL_ARCH))
	$(MAKE) docker-push-manifest

docker-push-%:
	$(MAKE) ARCH=$* docker-push

.PHONY: docker-push
docker-push-operator: ## Push the fat manifest docker image for the operator image.
	## Minimum docker version 18.06.0 is required for creating and pushing manifest images.
	docker manifest create --amend $(CONTROLLER_IMG):$(TAG) $(shell echo $(ALL_ARCH) | sed -e "s~[^ ]*~$(CONTROLLER_IMG)\-&:$(TAG)~g")
	@for arch in $(ALL_ARCH); do docker manifest annotate --arch $${arch} ${CONTROLLER_IMG}:${TAG} ${CONTROLLER_IMG}-$${arch}:${TAG}; done
	docker manifest push --purge $(CONTROLLER_IMG):$(TAG)
	$(MAKE) set-manifest-image MANIFEST_IMG=$(CONTROLLER_IMG) MANIFEST_TAG=$(TAG) TARGET_RESOURCE="./config/default/manager_image_patch.yaml"
	$(MAKE) set-manifest-pull-policy TARGET_RESOURCE="./config/default/manager_pull_policy.yaml"

.PHONY: set-manifest-pull-policy
set-manifest-pull-policy:
	$(info Updating kustomize pull policy file for manager resources)
	sed -i'' -e 's@imagePullPolicy: .*@imagePullPolicy: '"$(PULL_POLICY)"'@' $(TARGET_RESOURCE)

.PHONY: set-manifest-image
set-manifest-image:
	$(info Updating kustomize image patch file for manager resource)
	sed -i'' -e 's@image: .*@image: '"${MANIFEST_IMG}:$(MANIFEST_TAG)"'@' $(TARGET_RESOURCE)

## --------------------------------------
## Release
## --------------------------------------

$(RELEASE_DIR):
	mkdir -p $(RELEASE_DIR)/

.PHONY: release
release: clean-release ## Builds and push container images using the latest git tag for the commit.
	@if [ -z "${RELEASE_TAG}" ]; then echo "RELEASE_TAG is not set"; exit 1; fi
	@if ! [ -z "$$(git status --porcelain)" ]; then echo "Your local git repository contains uncommitted changes, use git clean before proceeding."; exit 1; fi
	git checkout "${RELEASE_TAG}"
	# Set the manifest image to the staging bucket.
	REGISTRY=$(STAGING_REGISTRY) $(MAKE) manifest-modification
	$(MAKE) release-manifests

.PHONY: manifest-modification
manifest-modification: # Set the manifest images to the staging/production bucket.
	$(MAKE) set-manifest-image \
		MANIFEST_IMG=$(PROD_REGISTRY)/$(OPERATOR_IMAGE_NAME) MANIFEST_TAG=$(RELEASE_TAG) \
		TARGET_RESOURCE="./exp/operator/config/default/manager_image_patch.yaml"
	$(MAKE) set-manifest-pull-policy PULL_POLICY=IfNotPresent TARGET_RESOURCE="./config/default/manager_pull_policy.yaml"

.PHONY: release-manifests
release-manifests: $(RELEASE_DIR) ## Builds the manifests to publish with a release
	$(KUSTOMIZE) build ./config/default > $(RELEASE_DIR)/operator-components.yaml

.PHONY: release-staging
release-staging: ## Builds and push container images to the staging bucket.
	REGISTRY=$(STAGING_REGISTRY) $(MAKE) docker-build-all docker-push-all release-alias-tag

.PHONY: release-staging-nightly
release-staging-nightly: ## Tags and push container images to the staging bucket. Example image tag: cluster-api-controller:nightly_master_20210121
	$(eval NEW_RELEASE_ALIAS_TAG := nightly_$(RELEASE_ALIAS_TAG)_$(shell date +'%Y%m%d'))
	$(MAKE) release-alias-tag TAG=$(RELEASE_ALIAS_TAG) RELEASE_ALIAS_TAG=$(NEW_RELEASE_ALIAS_TAG)
	# Set the manifest image to the production bucket.
	$(MAKE) manifest-modification REGISTRY=$(STAGING_REGISTRY) RELEASE_TAG=$(NEW_RELEASE_ALIAS_TAG)
	## Build the manifests
	$(MAKE) release-manifests
	# Example manifest location: artifacts.k8s-staging-cluster-api.appspot.com/components/nightly_master_20210121/infrastructure-components.yaml
	gsutil cp $(RELEASE_DIR)/* gs://$(STAGING_BUCKET)/components/$(NEW_RELEASE_ALIAS_TAG)

.PHONY: release-alias-tag
release-alias-tag: # Adds the tag to the last build tag.
	gcloud container images add-tag $(CONTROLLER_IMG):$(TAG) $(CONTROLLER_IMG):$(RELEASE_ALIAS_TAG)

## --------------------------------------
## Cleanup / Verification
## --------------------------------------

.PHONY: clean
clean: ## Remove all generated files
	$(MAKE) clean-bin

.PHONY: clean-bin
clean-bin: ## Remove all generated binaries
	rm -rf bin
	rm -rf $(TOOLS_BIN_DIR)

.PHONY: clean-release
clean-release: ## Remove the release folder
	rm -rf $(RELEASE_DIR)

## --------------------------------------
## E2E
## --------------------------------------

.PHONY: e2e-test
test-e2e:
	$(MAKE) release-manifests
	$(MAKE) test-e2e-run

.PHONY: test-e2e-run
test-e2e-run: $(GINKGO) $(ENVSUBST) ## Run e2e tests
	$(ENVSUBST) < $(E2E_CONF_FILE) > $(E2E_CONF_FILE_ENVSUBST) && \
	$(GINKGO) -v -trace -tags=e2e --noColor=$(GINKGO_NOCOLOR) $(GINKGO_ARGS) ./test/e2e -- \
		-e2e.artifacts-folder="$(ARTIFACTS)" \
		-e2e.config="$(E2E_CONF_FILE_ENVSUBST)"  -e2e.components=$(ROOT)/$(RELEASE_DIR)/operator-components.yaml \
		-e2e.skip-resource-cleanup=$(SKIP_CLEANUP) -e2e.use-existing-cluster=$(SKIP_CREATE_MGMT_CLUSTER) $(E2E_ARGS)
