# Every tool runs from a pinned container image, so a laptop and the CI runner
# execute the same versions. Only docker and make are needed (yamllint from pip).
SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

K8S_VERSION := 1.34.0
KUBECONFORM := ghcr.io/yannh/kubeconform:v0.7.0-alpine
KUBE_LINTER := ghcr.io/stackrox/kube-linter:v0.8.3
KYVERNO_CLI := ghcr.io/kyverno/kyverno-cli:v1.19.2
TRIVY       := ghcr.io/aquasecurity/trivy:0.76.2
GITLEAKS    := ghcr.io/gitleaks/gitleaks:v8.30.1
ACTIONLINT  := rhysd/actionlint:1.7.12
export KUBE_LINTER KYVERNO_CLI TRIVY

RUN       := docker run --rm -v "$(CURDIR)":/work -w /work
# Vulnerability DB and checks bundle are cached in a named volume between runs.
RUN_TRIVY := $(RUN) -v sbl-trivy-cache:/root/.cache

# The CRD schemas for Kyverno come from a public catalog; the built-in kinds
# come from the kubeconform default location.
CRD_CATALOG := https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json

IMAGE := $(shell awk '/image:/ {print $$2; exit}' examples/good/deployment.yaml)

.PHONY: check lint policy-test negative scan-config scan-image secrets workflow-lint e2e help

help:
	@echo "check          lint + policy-test + negative + scan-config + secrets (no cluster needed)"
	@echo "lint           yamllint, kubeconform, kube-linter"
	@echo "policy-test    kyverno test"
	@echo "negative       examples/bad must be caught, examples/good must be clean"
	@echo "scan-config    trivy config on the manifests"
	@echo "scan-image     trivy image on the image used by examples/good"
	@echo "secrets        gitleaks over the files and the git history"
	@echo "workflow-lint  actionlint"
	@echo "e2e            scripts/e2e.sh against the current kubectl context"

check: lint policy-test negative scan-config secrets

lint:
	yamllint -s .
	$(RUN) $(KUBECONFORM) -strict -summary -kubernetes-version $(K8S_VERSION) \
		-schema-location default -schema-location '$(CRD_CATALOG)' \
		baseline policies examples/good
	$(RUN) $(KUBE_LINTER) lint --config .kube-linter.yaml baseline examples/good

policy-test:
	$(RUN) $(KYVERNO_CLI) test tests/kyverno

negative:
	scripts/check-examples.sh

# trivy config takes one target at a time.
scan-config:
	$(RUN_TRIVY) $(TRIVY) config --quiet --ignorefile .trivyignore.yaml --exit-code 1 baseline
	$(RUN_TRIVY) $(TRIVY) config --quiet --ignorefile .trivyignore.yaml --exit-code 1 examples/good

# Fails on fixable CRITICAL findings only. HIGH is printed so it is visible.
scan-image:
	$(RUN_TRIVY) $(TRIVY) image --quiet --ignore-unfixed --severity HIGH,CRITICAL $(IMAGE)
	$(RUN_TRIVY) $(TRIVY) image --quiet --ignore-unfixed --severity CRITICAL --exit-code 1 $(IMAGE)

secrets:
	$(RUN) -e GIT_CONFIG_COUNT=1 -e GIT_CONFIG_KEY_0=safe.directory -e GIT_CONFIG_VALUE_0=/work \
		$(GITLEAKS) git --no-banner --redact /work
	$(RUN) $(GITLEAKS) dir --no-banner --redact /work

workflow-lint:
	$(RUN) $(ACTIONLINT)

e2e:
	scripts/e2e.sh
