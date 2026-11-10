#!/usr/bin/env bash
# Runs against the current kubectl context. Needs Kyverno installed and
# cluster-admin, because the RBAC checks use impersonation.
set -euo pipefail
cd "$(dirname "$0")/.."

failed=0
ok()   { printf 'ok    %s\n' "$*"; }
nope() { printf 'FAIL  %s\n' "$*"; failed=$((failed + 1)); }

# --- setup -------------------------------------------------------------------
kubectl apply -f baseline/namespaces.yaml
kubectl apply -R -f baseline/
kubectl apply -f policies/
# Ready only means the policy compiled; the webhook can lag, so the checks below retry.
kubectl wait --for=jsonpath='{.status.conditionStatus.ready}'=true \
  validatingpolicies.policies.kyverno.io --all --timeout=180s

# --- 1. RBAC -----------------------------------------------------------------
DEV="--as=dev-user --as-group=team-a-developers"
RO="--as=ro-user --as-group=team-a-readonly"
PIPELINE="--as=system:serviceaccount:team-a:ci-deployer"

# can <yes|no> "<identity flags>" <kubectl auth can-i args...>
can() {
  local want=$1 who=$2 got
  shift 2
  # shellcheck disable=SC2086
  got=$(kubectl auth can-i $who "$@" 2>/dev/null || true)
  if [ "$got" = "$want" ]; then ok "can-i $* ($who) = $want"; else nope "can-i $* ($who): wanted $want, got '$got'"; fi
}

can yes "$DEV" create deployments.apps -n team-a
can yes "$DEV" delete deployments.apps -n team-a
can yes "$DEV" create pods --subresource=portforward -n team-a
can no  "$DEV" create pods --subresource=exec -n team-a
can no  "$DEV" get secrets -n team-a
can no  "$DEV" list secrets -n team-a
can no  "$DEV" update networkpolicies.networking.k8s.io -n team-a
can no  "$DEV" create rolebindings.rbac.authorization.k8s.io -n team-a
can no  "$DEV" create deployments.apps -n default

can yes "$PIPELINE" patch deployments.apps -n team-a
can yes "$PIPELINE" create services -n team-a
can no  "$PIPELINE" delete deployments.apps -n team-a
can no  "$PIPELINE" get secrets -n team-a
can no  "$PIPELINE" create rolebindings.rbac.authorization.k8s.io -n team-a
can no  "$PIPELINE" create deployments.apps -n default
can no  "$PIPELINE" create namespaces

can yes "$RO" list deployments.apps -n team-a
can yes "$RO" get pods --subresource=log -n team-a
can no  "$RO" create deployments.apps -n team-a
can no  "$RO" get secrets -n team-a

# --- admission helpers -------------------------------------------------------
# expect_rejected <file> <regex> [namespace]
# A manifest that gets through is retried: the webhook may not serve the policies yet.
expect_rejected() {
  local file=$1 pattern=$2 ns=${3:-} out i
  local args=(--dry-run=server -f "$file")
  [ -n "$ns" ] && args+=(-n "$ns")
  for i in $(seq 1 30); do
    if out=$(kubectl apply "${args[@]}" 2>&1); then
      sleep 2
      continue
    fi
    if grep -Eq "$pattern" <<<"$out"; then
      ok "rejected $file${ns:+ in $ns}"
    else
      nope "rejected $file${ns:+ in $ns}, but not by '$pattern':"; echo "$out"
    fi
    return
  done
  nope "$file${ns:+ in $ns} was accepted after $i tries"
}

expect_accepted() {
  local file=$1 ns=$2 out
  if out=$(kubectl apply --dry-run=server -f "$file" -n "$ns" 2>&1); then
    ok "accepted $file in $ns"
  else
    nope "accepted $file in $ns:"; echo "$out"
  fi
}

# --- 2. Kyverno rejects the bad Deployments ----------------------------------
# Match the policy name or its message: the webhook wording changes between versions.
expect_rejected examples/bad/bad-latest-tag.yaml 'disallow-latest-tag|mutable image tag'
expect_rejected examples/bad/bad-root.yaml       'require-run-as-non-root|runAsNonRoot must be true|UID 0'
expect_rejected examples/bad/bad-no-limits.yaml  'require-resource-limits|resources.limits.memory'
expect_rejected examples/bad/bad-hostpath.yaml   'disallow-hostpath|hostPath volumes'

# --- 3. Pod Security Admission -----------------------------------------------
# Bare Pods: for a Deployment PSA only warns, the pod is refused later.
expect_rejected examples/bad/bad-privileged-pod.yaml 'violates PodSecurity "restricted' team-a
expect_rejected examples/bad/bad-privileged-pod.yaml 'violates PodSecurity "baseline' legacy-apps
expect_rejected examples/bad/bad-restricted-only.yaml 'violates PodSecurity "restricted' team-a
expect_accepted examples/bad/bad-restricted-only.yaml legacy-apps

# --- 4. the good example -----------------------------------------------------
expect_accepted examples/good/deployment.yaml team-a
kubectl apply -f examples/good/
if kubectl -n team-a rollout status deployment/web --timeout=180s; then
  ok "good example rolled out"
else
  nope "good example did not roll out"
  kubectl -n team-a get pods,events
fi

echo
if [ "$failed" -eq 0 ]; then echo "e2e: all checks passed"; else echo "e2e: $failed check(s) failed"; fi
exit $((failed > 0))
