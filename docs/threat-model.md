# Threat model

Scope: one team namespace (`team-a`) on a shared cluster, where a few people and a CI pipeline deploy workloads. The cluster itself (control plane, nodes, CNI) is out of scope.

## What is protected

- The node and the other tenants' pods.
- Secrets in the namespace and the API credentials of people and the pipeline.
- What runs: the image that was reviewed, not whatever the tag points to today.
- The network position of every pod.

## Who it defends against

- A developer, or a stolen developer account, that ships an unsafe workload by mistake or on purpose.
- A leaked CI token.
- A compromised container that tries to reach the node or its neighbours.
- A copy-pasted manifest that nobody read closely.

## Threats and controls

| Threat | Control | Checked by |
|---|---|---|
| Privileged pod, host namespaces, hostPath to reach the node | Pod Security `restricted` on `team-a`, `baseline` on `legacy-apps`; Kyverno `disallow-hostpath` | kyverno test, e2e |
| Container runs as root | Kyverno `require-run-as-non-root`; securityContext in the good example | kyverno test, e2e, kube-linter, trivy config |
| Mutable image, nobody knows what runs | Kyverno `disallow-latest-tag`; pinned tag in the good example | kyverno test, e2e |
| One container eats the node's memory | Kyverno `require-resource-limits`; ResourceQuota on the namespace | kyverno test, e2e |
| Developer reads Secrets or execs into a pod | `developer` role has no Secrets and no `pods/exec` | e2e (`kubectl auth can-i`) |
| Leaked CI token changes RBAC, deletes things or touches other namespaces | `ci-deployer` is namespaced, no delete, no Secrets, no RBAC; token is short-lived | e2e (`kubectl auth can-i`) |
| Compromised pod talks to anything | default-deny for ingress and egress, DNS and one ingress path opened by hand | e2e applies the objects |
| Secret committed to git | gitleaks over files and history | CI |
| Known CVEs in the image | trivy image, fails on fixable CRITICAL | CI |
| A manifest drifts back to unsafe | kubeconform, kube-linter, trivy config; the bad examples must keep being caught | CI |

## Not covered

- **NetworkPolicy enforcement.** It depends on the CNI. The e2e job only proves the API server accepts the objects, not that traffic is blocked.
- **Image provenance.** No signature check, no registry allow list. A pinned tag can still be repushed.
- **Runtime.** No detection of what a running container does, no audit log pipeline.
- **Cluster hardening.** Secrets encryption at rest, etcd, kubelet settings, node OS, API server exposure.
- **Whoever controls the controls.** An admin can edit the policies or the Pod Security labels. `kube-system` and `kyverno` are excluded from the policies on purpose.
- **Kyverno being down.** It sits in the admission path. What happens when the webhook is unreachable depends on its failure policy, which is not tuned here.
- **Gaps in matching.** Policies match Pods, Deployments, StatefulSets, DaemonSets, Jobs and CronJobs. A pod created by a custom controller is caught at the Pod level only.
- **Service accounts.** A developer who can create Deployments can pick any ServiceAccount in the namespace.
- **No exception process.** There is no PolicyException workflow. The policies apply to `legacy-apps` too, so a workload that really needs an exception means editing the policy.
