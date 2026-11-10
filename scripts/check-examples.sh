#!/usr/bin/env bash
# Negative tests for the checks themselves. Every file in examples/bad has to be
# caught by the tools that are supposed to catch it, and examples/good has to be
# clean. A scanner that quietly stops finding things would otherwise look like
# a green build.
set -euo pipefail
cd "$(dirname "$0")/.."

: "${KUBE_LINTER:?run through make}" "${KYVERNO_CLI:?run through make}" "${TRIVY:?run through make}"

run() { docker run --rm -v "$PWD":/work -w /work "$@"; }
trivy() { run -v sbl-trivy-cache:/root/.cache "$TRIVY" config --quiet --ignorefile .trivyignore.yaml "$@"; }

fail=0
note() { printf '%-28s %s\n' "$1" "$2"; }
bad() { note "$1" "NOT CAUGHT: $2"; fail=1; }

# file | kube-linter check | trivy id | Kyverno policy ("-" means Kyverno has no say)
while IFS='|' read -r name kl trivy_id policy; do
  f="examples/bad/$name.yaml"

  # An empty answer means the tool itself failed (docker hiccup), not that it
  # found nothing, so say that instead of blaming the scanner.
  out=$(run "$KUBE_LINTER" lint --config .kube-linter.yaml "$f" 2>&1 || true)
  [ -n "$out" ] || bad "$name" "kube-linter printed nothing"
  grep -q "check: $kl," <<<"$out" || bad "$name" "kube-linter $kl"

  out=$(trivy --format json "$f" 2>&1 || true)
  [ -n "$out" ] || bad "$name" "trivy printed nothing"
  grep -q "\"ID\": \"$trivy_id\"" <<<"$out" || bad "$name" "trivy $trivy_id"

  rc=0
  out=$(run "$KYVERNO_CLI" apply policies/ --resource "$f" 2>&1) || rc=$?
  if [ "$policy" = "-" ]; then
    [ "$rc" -eq 0 ] || bad "$name" "kyverno should have nothing to say, got exit $rc"
  else
    { [ "$rc" -ne 0 ] && grep -q "policy $policy ->" <<<"$out"; } || bad "$name" "kyverno $policy"
  fi
  note "$name" "checked"
done <<'TABLE'
bad-latest-tag|latest-tag|KSV-0013|disallow-latest-tag
bad-root|run-as-non-root|KSV-0012|require-run-as-non-root
bad-no-limits|unset-memory-requirements|KSV-0018|require-resource-limits
bad-hostpath|docker-sock|KSV-0006|disallow-hostpath
bad-privileged-pod|privileged-container|KSV-0017|-
bad-restricted-only|no-read-only-root-fs|KSV-0001|-
TABLE

# Nothing in bad/ may have slipped past the table above.
listed=$(grep -c '^bad-' "$0" || true)
present=$(find examples/bad -name '*.yaml' | wc -l | tr -d ' ')
[ "$listed" -eq "$present" ] || { echo "examples/bad has $present files, table has $listed"; fail=1; }

# Good side: all of it has to pass.
run "$KUBE_LINTER" lint --config .kube-linter.yaml baseline examples/good >/dev/null || bad good "kube-linter complains"
trivy --exit-code 1 examples/good >/dev/null || bad good "trivy config complains"
run "$KYVERNO_CLI" apply policies/ \
  --resource examples/good/deployment.yaml >/dev/null || bad good "a Kyverno policy rejects it"
note good "checked"

exit "$fail"
