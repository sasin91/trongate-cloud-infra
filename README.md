# trongate.cloud infrastructure

This repository runs [trongate.cloud](https://trongate.cloud): the cluster, its Flux configuration and its SOPS-encrypted secrets. It is a deployment of hcloud-k3s-platform-kit, described below. What trongate.cloud changed and why is in [TRONGATE-CLOUD.md](TRONGATE-CLOUD.md); the application itself lives in [sasin91/trongate.cloud](https://github.com/sasin91/trongate.cloud).

An independent service. Not affiliated with or endorsed by the Trongate project.

---

## hcloud-k3s-platform-kit

A decided k3s platform for Hetzner Cloud — GitOps delivery, encrypted secrets, observability, multi-tenancy, and the operational guardrails that come from having got these things wrong before.

**This is not another cluster installer.** Creating a k3s cluster on Hetzner is a solved problem. This is what you install afterwards, and it is mostly a set of decisions with the reasoning attached.

---

## Why this and not an afternoon with an LLM

Ask a good model for a k3s platform on Hetzner and you will get one. It will be coherent, it will be conventional, and most of it will work. That is genuinely most of the value, and this kit does not pretend otherwise — it is the same shapes, built with the same tools, arrived at the same way.

The difference is a day or two of tokens you don't spend, and one specific category of failure you don't have to find yourself.

Everything in [LESSONS.md](LESSONS.md) is a thing that **reported success**:

- A line-ending default rewrote a file inside a fetched module, a policy failed to compile at boot, and the orchestrator never started — while every server reported healthy and SSH worked fine.
- A delivery tool derived a Helm release name from the namespace it targeted. That renamed two Services. The components exporting to them kept exporting to the old names. No error in any component — just an empty trace store.
- The same rename pushed a generated label past 63 bytes, wedging a release that could neither install nor uninstall, because the hook required to remove it was itself the invalid object.
- A placeholder contact address in an issuer produced an ACME rejection, no certificate, an unresolvable listener, and a gateway that would not accept routes — presenting as a routing problem four layers from its cause.
- A load balancer annotation left at `CHANGE-ME` reported a successful release, then failed silently in the cloud controller for fifty minutes.

None of those are exotic. Each is what happens when a plausible default meets a real provider, and none of them announce themselves — which is exactly why a generated config that looks right can be wrong for a week. They were found by building this on a real cluster, breaking it, and reading the API server rather than the manifests.

**What you get:** decisions already made and defended, the guardrails that keep them true, and a list of failures whose only cheap source is somebody else having had them.

**What you should still do:** read it, fork it, and disagree with it — the reasoning is attached to every decision specifically so you can. It is opinionated infrastructure, not a black box, and an opinion you haven't examined is worse than one you generated yourself.

---

## Built on

This kit consumes [**terraform-hcloud-kube-hetzner**](https://github.com/mysticaltech/terraform-hcloud-kube-hetzner) (MIT) as a pinned module dependency. That project solves cluster creation — image building, cloud-init, HA control planes, cloud controller and CSI wiring, coordinated node upgrades — and none of it is reimplemented here.

It is a dependency, not a fork. See [NOTICE](NOTICE).

---

## What's in it

| Layer | Choice | Why |
|---|---|---|
| Infrastructure | **OpenTofu**, module pinned to a major version | State *and plan files* encrypt client-side; Terraform has no equivalent |
| State | S3-compatible object storage, versioned, native locking | Verified working, not assumed — see below |
| Delivery | **Flux**, controller manifests committed | Pruning, drift correction, health assertions. No token, no write-back to your repo |
| Secrets | **SOPS + age** | Exactly one secret is applied by hand and cannot be encrypted. Everything else lives encrypted in git |
| Networking | **Flannel** | Already enforces NetworkPolicy. Cilium documented as opt-in for FQDN egress |
| Certificates | **cert-manager** only | The ingress runs no ACME client, so it runs more than one replica |
| Routing | **Gateway API** for HTTP | Platform owns the Gateway, tenants own Routes, and `allowedRoutes` decides who may attach |
| Observability | VictoriaMetrics stack, Vector → VictoriaLogs, Tempo, Grafana | Not exposed by default. Reached by port-forward |
| Databases | **none by default** | MariaDB, CloudNativePG and Valkey all ship commented out |
| Tenancy | Namespace per tenant, generated with its guarantees | Quota, limits, NetworkPolicy, PDB, backup, pod security, service account and RBAC |
| Backups | restic, one repository per namespace | The provider's block volumes have no snapshots at all |

### Defaults that cost money and are on anyway

Three-node HA control plane · etcd snapshots to object storage · a `Retain` StorageClass beside the deleting default · a backup CronJob generated with every tenant.

---

## Day zero

```bash
# 0. Check the instance types in your config are AVAILABLE, not merely supported.
#    Do this before every apply, not only on a schedule. On 2026-08-04 an entire
#    instance line went unavailable across all three datacentres of this region
#    within a day of being recorded as available, and the apply failed halfway.
python scripts/checks/check-pool-availability.py

# 0b. CHECK YOUR PROJECT'S RESOURCE LIMITS in the provider console. There is
#     no API for these, so no check can do it for you.
#
#     This kit's DEFAULT SHAPE IS FIVE SERVERS -- three control planes and two
#     agents -- before the autoscaler adds a single node. A fresh project on
#     this provider can be capped lower: the verification project for this
#     repository was limited to four, so applying the defaults failed with
#     `server limit reached (resource_limit_exceeded)` after creating four of
#     them. Primary IPs are quota'd separately and independently.
#
#     Budget the ceiling as: 3 control planes + agent_count + autoscaler_max_nodes.
#
#     AND GET THE CONTROL PLANE COUNT RIGHT THE FIRST TIME. Growing it later is
#     safe. SHRINKING IT DESTROYS THE CLUSTER: OpenTofu removes the servers, etcd
#     membership is not something it manages, and a three-member cluster that
#     loses two members can never reach quorum again. The API server does not
#     come back, and what you are shown is a provisioner timeout that mentions
#     none of this. Verified the hard way on this repository's own cluster.

# 1. Generate an object-storage credential in the provider console.
#    This step cannot be automated — the provider CLI has no object-storage commands.

# 2. Create the two buckets (state, versioned — snapshots, expiring)
./scripts/bootstrap-buckets.sh

# 3. Build the OS snapshot the nodes boot from. REQUIRED, and easy to miss:
#    the node module looks the image up by label and fails the plan if it is
#    absent. Nothing creates it for you.
packer init  hcloud-leapmicro-snapshots.pkr.hcl
packer build -only='hcloud.leapmicro-x86-snapshot' hcloud-leapmicro-snapshots.pkr.hcl

# 4. Build the cluster. The check between init and apply is not optional on
#    Windows, and is cheap everywhere else.
tofu init
python scripts/checks/check-fetched-module-line-endings.py
tofu apply

# 5. Point the sync at YOUR fork -- as a COMMIT, before anything is applied.
#    Edit `url` and `ref.branch` in clusters/<name>/flux-system/gotk-sync.yaml,
#    then commit and push. Doing this afterwards with `kubectl edit` does not
#    work: that file is reconciled by the Kustomization it defines, so the edit
#    is reverted every interval and the only way to hold it is to suspend the
#    reconciler you are trying to start.
#
#    A PUBLIC fork needs no credential -- use the https:// URL and delete the
#    secretRef. A PRIVATE fork needs a read-only deploy key, which is then a
#    second hand-applied secret. See the comments in that file.

# 6. Generate the root of trust and install Flux.
#    Apply TWICE. The first apply creates the custom resource definitions and
#    then fails on the resources that use them -- kubectl does not wait for a
#    definition it created in the same pass to become established. The second
#    apply succeeds. This is expected, not a fault.
age-keygen -o age.agekey
kubectl apply -k clusters/<name>/flux-system   # creates CRDs, reports 2 errors
kubectl apply -k clusters/<name>/flux-system   # now succeeds
kubectl create secret generic sops-age \
  --namespace flux-system --from-file=age.agekey=age.agekey

# 7. Create the Grafana admin credential, encrypted to that key, and commit it.
#    There is no default password. Grafana will not start without this secret,
#    an unstarted Grafana keeps the observability layer from reporting Ready,
#    and the layers chained behind it therefore never apply. So a missing
#    credential presents as "tenants never deploy", several layers away.
#
#    THREE fork-specific edits are needed, and none can be shipped for you:
#      a) .sops.yaml -- replace the placeholder recipient with the PUBLIC key
#         age-keygen printed above. Encrypting against the placeholder yields a
#         file that looks encrypted and that this cluster cannot read.
#      b) the secret itself, encrypted to that recipient
#      c) platform/observability/secrets/kustomization.yaml -- uncomment the
#         entry naming it. NOT ../controllers/kustomization.yaml: kustomize
#         refuses to load a file from outside its own directory, so controllers
#         references the secrets DIRECTORY instead.
#
#    See platform/observability/secrets/grafana-admin.sops.yaml.example
cp platform/observability/secrets/grafana-admin.sops.yaml.example \
   platform/observability/secrets/grafana-admin.sops.yaml
# ...put a real password in it, then encrypt to your own recipient:
sops --encrypt --in-place --encrypted-regex '^(data|stringData)$' \
     --age <your age PUBLIC key> \
     platform/observability/secrets/grafana-admin.sops.yaml
# ...then uncomment the entry in secrets/kustomization.yaml
git add -A && git commit && git push
```

Step 3 is not optional and is the most likely place a first run stops. The
module resolves its image by label selector, so a project without the snapshot
fails with `Resource (image) was not found using label selector` — which reads
like a permissions problem and is not one. The Packer template comes from the
upstream module; see `infrastructure/hetzner/README.md`.

No personal access token. No admin-scoped credential. Nothing written back into your repository on your behalf. You can read exactly what will be applied before applying it, and the Flux version is a line in your own diff.

**Exactly one secret in the whole system is created by hand and cannot be encrypted** — the age key. Store it in a password manager. For more than one operator, encrypt to multiple recipients rather than sharing a private key.

---

## Teardown

**In this order, or it fails partway and leaves things billing.**

```bash
scripts/teardown.sh              # list what the CLUSTER created (deletes nothing)
scripts/teardown.sh --delete     # remove those first
tofu destroy                     # now this can complete
scripts/teardown.sh              # re-list: a teardown you have not re-listed is unverified
```

`tofu destroy` removes what OpenTofu created. It does not remove what the
*cluster* created while running — autoscaler servers, a load balancer per
`LoadBalancer` Service, a volume per `PersistentVolumeClaim` — because none of
those were ever in its state.

They are not inert leftovers. An autoscaler-created server stays attached to the
private network, so destroying the **network** fails, and the run dies with an
error naming the network rather than the node holding it. Observed exactly that
on this kit: a destroy that had already reported removing everything it knew
about.

---

## Guardrails

Checks are split by *where the truth lives*, not by severity.

**In CI, failing the pull request** — every module and chart reference carries an explicit version · no duplicate YAML keys · controller manifests not stale against upstream · ingress declares more than one replica and a disruption budget · no ACME resolver alongside cert-manager · dashboard anonymous access off · every controller carries the multi-tenancy lockdown flags · every tenant reconciliation names a service account · pruning not disabled without a recorded reason.

**Against the provider API, on a schedule** — every declared nodepool names an instance type *currently available* in its location. Availability is not static, and a pool created when its type was in stock keeps that type forever.

**Inside the cluster, surfaced as alerts** — tenants missing a guarantee · alert rules verified against the running evaluator rather than the repo · pools carrying taints nothing tolerates.

No kubeconfig is ever placed in a CI system.

> **Security boundaries fail. Standing configuration reports.** An absent quota is a gap for somebody to close; an absent privilege boundary is a hole to stop. Conflating them trains people to ignore both.

---

## Deliberately not included

- **A private registry.** It is a hostname, a certificate, credentials, a storage decision and a garbage-collection policy. Most adopters on day one run images they did not build. Available as an add-on.
- **A public route to the dashboard.** Every alternative is a way of *defending* an internet-facing observability dashboard. None is as safe as not having one.
- **An egress nodepool.** A floating address does nothing without a CNI that implements egress gateway or a workload pinned to the node holding it. Shipping the pool without the mechanism is dead cost.
- **A mail stack**, in any form.
- **Arm nodepools.** x86 is cheaper at identical specs on this provider, and at the time of writing no Arm instance type was available in any datacentre in the region. Platform components stay multi-architecture because that costs nothing.

---

## Example tenants

**There are none, deliberately.** The tenant template generates the quota, limit range, NetworkPolicy, disruption budget, backup job, pod-security level, service account and RBAC. That *is* the tenancy model — a workload occupying a namespace demonstrates nothing the template does not already state.

`tenants/kustomization.yaml` ships with an empty resource list. Do not delete it because it looks pointless: without it the reconciler scans the directory, finds the template with its tokens unreplaced, and applies a namespace named after a placeholder — cleanly, and without error.

---

## Status — read this before trusting anything

Parts of this kit have now been **run on a real cluster**. Where a claim is verified it says so; where it is not, it says that too.

**Verified on a live cluster, 2026-08-04, across four full build/teardown cycles:**

- The node layer builds and tears down cleanly. A **three-node HA control plane** forms, all members `Ready` with etcd, on the pinned Kubernetes version.
- **The entire reconciliation chain converges from this repository with no manual intervention** — 9 of 9 Kustomizations and 8 of 8 HelmReleases `Ready`, including the tenants layer. The `dependsOn` chain gates in the right order: CRDs, then releases, then the configs that consume them.
- **The multi-tenancy lockdown flags are live on the running controllers**, in the correct per-controller matrix — verified by reading container arguments off the cluster, not by inspecting patch files.
- **SOPS decryption works end to end.** A secret encrypted to the cluster's age recipient, committed to git, is decrypted by kustomize-controller and applied — and the component that needs it starts.
- **The hostname-authorisation admission policy compiles and enforces.** A route claiming another tenant's hostname is refused; so is a route declaring no hostname at all, which would otherwise inherit a shared listener's and claim everything it serves.
- **cert-manager issued a real certificate** from Let's Encrypt for a domain pointed at the cluster.
- **Ingress runs HA for real** — two replicas across two nodes with a disruption budget, and the Gateway reports `Programmed`.
- **Traces reach the trace store with Kubernetes context attached.** A request made from a laptop over the public internet arrives as a span carrying `url.path`, the status code, and the `k8s.pod.name` / `k8s.namespace.name` / `k8s.node.name` of the ingress pod that served it — stamped by the collector, which is the entire reason it sits in the path.
- Object storage supports conditional writes, so native state locking is real, and default Go SDK checksums work, so no workaround ships.
- **A tenant generated from the template serves real traffic.** A namespace created from `_template`, its workload reconciled by its own service account under `restricted` pod security, its route attached to the platform Gateway through `allowedRoutes`, and the page fetched over the public internet with a Let's Encrypt certificate the system trust store validates — no `-k`, no override.
- **Teardown is complete only with `scripts/teardown.sh` run first** — see Teardown above. This is a correction: the earlier claim that `destroy` alone was clean held only for clusters that had never autoscaled, served a `LoadBalancer` Service, or bound a PVC.

**Not yet verified:**

- **Backups restoring.** The CronJob is generated with every tenant; no restore has been exercised.
- **Autoscaler scale-out under real pressure.** The verification project's server quota left no headroom to test it.
- **A control plane surviving the loss of a member.** Three members formed and were healthy; no member was killed to watch the remaining two carry on.

Prices and instance availability quoted anywhere here are dated observations, not permanent properties — see `LESSONS.md` for how fast that turned out to matter.

---

## Why the decisions are what they are

Every decision was worked as a ticket with its reasoning, alternatives and evidence recorded. Start at the [decision map](../../issues/1); each entry links to the ticket holding the detail.

The lessons those decisions produced live in [LESSONS.md](LESSONS.md) — stated as mechanisms with public citations, so they are verifiable by someone who has never seen the cluster that taught them.

---

## Licence

MIT. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
