# trongate.cloud infrastructure

This repository is [hcloud-k3s-platform-kit](https://github.com/sasin91/hcloud-k3s-platform-kit)
tuned for trongate.cloud: two x86 nodes (cx33) behind a Hetzner load balancer
in fsn1, for about EUR 36 a month, with the
trongate.cloud platform (`sasin91/trongate.cloud`, `deploy/k8s`) reconciled by
Flux beside the kit's own layers.

Everything that differs from the kit carries a `TRONGATE-CLOUD` comment, so
`git grep -n TRONGATE-CLOUD` is the complete diff in prose. The kit is the
`upstream` remote (fetch only), so kit fixes arrive with
`git fetch upstream && git merge upstream/main`.

Nothing here has been applied anywhere. Prices and availability below were read
from the Hetzner API on 2026-10-03.

---

## 1. The profile

| | Kit default | This repository (decided 2026-10-04) |
|---|---|---|
| Nodes | 3 control planes (cpx22) + 2 agents (cpx32) | 1 control plane that also runs workloads + 1 agent, both cx33 (x86, 4 vCPU / 8 GB / 80 GB), fsn1 |
| Architecture | x86 | x86 only, everywhere: the cluster, customer builds, dev machines |
| Autoscaler | cpx32, 0 to 5 | cx33, 0 to 1 |
| Ingress entry | Hetzner lb11 | Hetzner lb11 in fsn1, Traefik 2 replicas (one per node) with a PDB, as the kit |
| cert-manager / metrics-server | 2 replicas + PDBs | 1 replica, no PDBs |
| Certificates | HTTP-01, HTTPS listener commented | HTTP-01 for trongate.cloud and registry.trongate.cloud (DNS at Porkbun); DNS-01 through Hetzner DNS for the customer-app wildcard *.trongate.dev |
| OS updates | unattended + kured | off; patch by hand (section 6) |
| Observability | VM stack, VictoriaLogs, Tempo, OTel, blackbox, Grafana, alerting | metrics only: VictoriaMetrics single (15d on 10Gi), vmagent, kube-state-metrics, node-exporter |
| Memory guards | module defaults | control plane reserves 2.5 GiB for k3s (a kube-hetzner cx23 control plane measured ~2.5 GiB outside pods), eviction thresholds on both nodes, PriorityClass `trongate-platform` for MariaDB, Valkey, app and worker, build quota 2 pods / 8 GiB, JuiceFS cache 1 GiB |

Why two cx33 and not one cx43: on 2026-10-03/04 cx43 (8 vCPU / 16 GB, EUR
15.99) and every ARM CAX type were out of stock in every EU location, cpx42
cost EUR 69.49, and cx33 was in stock (fsn1 only by 08:43 UTC on 2026-10-04,
hence fsn1). Trade-offs accepted:

- The control plane stays a cx33. Changing its type may replace the server,
  and replacing a single etcd member is a rebuild from snapshot. Grow by adding
  agents; check that `tofu plan` says update in place before any type change.
- 80 GB of disk per node holds tenant images, the JuiceFS cache and build
  scratch space.
- Volumes attach to one node; if that node dies, the pod moves only after the
  CSI driver force-detaches (minutes).
- One control plane: not HA. A control-plane reboot stops the API; the load
  balancer keeps serving through the agent's Traefik.

### Growing out of it

1. `autoscaler_max_nodes = 2..n` for more burst, or `agent_count = 2..n` for
   fixed capacity (cx33 or cx43 agents).
2. HA: `control_plane_count = 3`. Grow only, never shrink.
3. Turn observability back on piece by piece (`platform/observability/`);
   each disabled piece says what to restore with it.

---

## 2. Cost

Net prices from the Hetzner API (`hcloud server-type list`, `/v1/pricing`),
fsn1, 2026-10-04. Add 25 % VAT if billed to a private customer in Denmark.

| Item | Detail | EUR / month |
|---|---|---:|
| 2 x cx33 | 4 vCPU (Intel, shared), 8 GB, 80 GB disk each | 16.98 |
| Primary IPv4 x 2 | one per node (IPv6 free) | 1.00 |
| Load balancer lb11 | fsn1 | 7.49 |
| Block volumes | 50 GB at 0.0572/GB: shared MariaDB 20, platform MariaDB 10, Valkey 10, VictoriaMetrics 10 | 2.86 |
| Object Storage | base price, 1 TB storage + 1 TB egress across all buckets (third-party summary of Hetzner's price list, July 2026; not in the API) | 6.49 |
| DNS | trongate.cloud at Porkbun; trongate.dev zone in Hetzner DNS | 0.00 |
| OS snapshot | Leap Micro x86, ~1-2 GB at 0.0143/GB | 0.03 |
| **Steady state** | | **~34.85** |
| Autoscaled cx33 | only while the autoscaler holds it, hourly | 0 to 8.49 |
| Rejected | one cx43 ~26 (out of stock); cpx42 ~80; CAX31 (arm) ~31 (out of stock, second architecture); OVH Managed Kubernetes ~57 (b2-15 node EUR 48.05 + LB 6 + volumes, OVH catalog API) | |

### Capacity (estimated before the first spike)

| | Memory |
|---|---:|
| Node capacity, 2 x cx33 | ~15.2 GiB |
| Kubelet reservations (control plane 2.5 GiB + eviction, agent 1 GiB + eviction) | ~4.1 GiB |
| Fixed services: MariaDB shared-1 1.5Gi, platform MariaDB 384Mi, Valkey 896Mi, app, worker, Sablier, registry, operators, Flux, cert-manager, Traefik x2, CCM/CSI, metrics stack | ~5.6 GiB |
| **Left for tenant apps and builds** | **~5.5 GiB** |

That is roughly 55 awake apps at the 96Mi request in `Manifests::APP_RESOURCES`
before the autoscaler adds a third cx33. Spike 1 replaces the guess.

---

## 3. arm64 check (historical: the cluster is x86)

Every image the cluster runs was looked up in its registry on 2026-10-03
(manifest list platforms). All have `linux/arm64` (and `linux/amd64`, so moving to x86 later changes nothing here).

| Group | Images (tag) |
|---|---|
| Flux v2.9.3 | source-controller v1.9.3, kustomize-controller v1.9.4, helm-controller v1.6.3, notification-controller v1.9.2 |
| Kit controllers | cert-manager controller/webhook/cainjector/startupapicheck v1.21.1, traefik v3.7.9, metrics-server v0.8.1, system-upgrade-controller v0.20.1, rancher/kubectl v1.30.3, rancher/k3s-upgrade v1.35.6-k3s1 |
| Added here | registry 3.1.2 |
| Observability | victoria-metrics / vmagent / vmalert v1.148.0, victoria-logs v1.52.0, VM operator, Vector, Grafana, kube-state-metrics v2.17.0, node-exporter, blackbox-exporter |
| kube-hetzner add-ons | hcloud CCM v1.33.0, hcloud CSI v2.21.2, cluster-autoscaler v1.33.3, kured 1.23.0, klipper-lb v0.4.13 |
| mariadb-operator 26.10.1 | operator 26.10.1, mariadb 12.3.3, maxscale 23.08.13-2, mysqld-exporter v0.15.1 |
| JuiceFS CSI 0.33.0 | juicefs-csi-driver v0.33.0, juicedata/mount ce, sig-storage livenessprobe / node-driver-registrar / provisioner / resizer |
| trongate.cloud | sablier 1.18.0, valkey 9.1-alpine, moby/buildkit v0.33.1-rootless |
| Railpack v0.40.1 | railpack-frontend v0.40.1, railpack-builder and railpack-runtime mise-2026.9.15, and the FrankenPHP image its PHP provider builds on, `dunglas/frankenphp:php8.4-trixie` |
| Platform image bases | dunglas/frankenphp:1.12-php8.4-bookworm, php:8.4-cli-bookworm |

**Flagged:**

- The platform images are built in the cluster by trongate.cloud's worker
  (task `build_platform`) on every push to its main, for linux/amd64, pushed to
  `registry.trongate.cloud/platform/*` as `main-{commit time}-{sha}`, and
  rolled out by Flux image automation (`apps/trongate-cloud/image-automation`).
  `bin/push-images.sh` on a PC is the fallback.
- The cluster is x86 since 2026-10-04, so this table now only says the stack
  could move to ARM without image changes.

---

## 4. How trongate.cloud is wired in

`clusters/production/trongate-cloud.yaml` holds a second GitRepository
(`sasin91/trongate.cloud`, only `deploy/k8s/`, read-only deploy key) and four
Kustomizations, in `deploy/k8s/README.md`'s bootstrap order:

```
infrastructure ─→ trongate-cloud-operators ─┬─→ trongate-cloud-secrets
                                            └─→ trongate-cloud ←─ platform
platform ─→ trongate-cloud-registry
```

- **Operators** (`apps/trongate-cloud/operators`): mariadb-operator 26.10.1 and
  JuiceFS CSI 0.33.0 in the kit's shape. trongate.cloud's own
  `deploy/k8s/operators` cannot run under the kit's Flux lockdown (no service
  account, HelmReleases outside flux-system, version ranges), so it is not
  reconciled; its values are copied.
- **Secrets** (`apps/trongate-cloud/secrets`): the SOPS copies of
  trongate.cloud's `secrets.example.yaml` files.
- **trongate-cloud**: `./deploy/k8s` from the app repository, with three
  patches: `PLATFORM_GATEWAY_NAME=platform` (the kit's Gateway), the control
  panel's HTTPRoute pinned to the `https-platform` listener, and shared-1 at
  20Gi instead of 50Gi.
- **Registry** (`apps/trongate-cloud/registry`): `registry.trongate.cloud`,
  distribution 3.1.2 on the `trongate-cloud-registry` bucket, htpasswd with a
  `push` user (the worker) and a `pull` user (the nodes, via
  `registries_config`).

The Gateway (`platform/configs/gateway.yaml`) has the kit's HTTP listener plus
`https-platform` (trongate.cloud, routes from `trongate-cloud` only),
`https-registry` (registry.trongate.cloud, routes from `registry` only) and
`https-apps` (`*.trongate.dev`, routes from namespaces labelled
`platform.example.com/managed=tenant`, which the worker writes on every
`tc-team-*`). The `traefik` namespace already carries
`platform.example.com/role=gateway` from the kit, which trongate.cloud's tenant
NetworkPolicies rely on.

Two kit policies had to bend:

- Traefik's CRD provider is **on**, because a Gateway API `ExtensionRef` can only
  name a Traefik Middleware when it is, and Sablier is one. The new
  `deny-traefik-routes` admission policy refuses IngressRoute / TCP / UDP so
  HTTPRoute stays the only way to claim a hostname.
- The kit's hostname admission policy now **skips namespaces labelled
  `app.kubernetes.io/managed-by=trongate-cloud`**. It requires a per-namespace
  domain annotation the worker does not write; trongate.cloud's own
  `trongate-worker-objects` policy guards those routes instead.

`scripts/checks/check-ingress-ha.py` gained a recorded-waiver comment
(`# ingress-ha waiver: <reason>`), the same pattern the prune check uses, so the
single replica reports instead of failing CI. All kit checks pass and every
kustomization renders (`kubectl kustomize`), including trongate.cloud's
`deploy/k8s` with the three patches.

---

## 5. Provisioning runbook

Nothing below has been run. Steps marked **(costs money)** create billable
resources.

### 5.0 Tools on your machine

`tofu` >= 1.10.1, `packer`, `hcloud`, `kubectl`, `flux` (v2.9.3, for
`scripts/generate-flux-components.sh` and `flux get`), `sops` 3.13, `age` 1.3,
the `aws` CLI (for `scripts/bootstrap-buckets.sh`), `openssl`, and `htpasswd`
(or any bcrypt tool). On Windows, read the kit's line-ending lesson
(`infrastructure/hetzner/README.md`): this clone already has
`core.autocrlf=false`, but the module OpenTofu downloads uses your global git
config.

### 5.1 Hetzner console

1. **Project `trongate-cloud`.** Its own project, separate from anything else you run.
   Check its limits: at least 2 servers and 4 primary IPs (the node, plus the
   autoscaled node, dual stack).
2. **API token** in that project, Read & Write. Add it as its own CLI context so
   nothing ever runs against the other projects by accident:
   `hcloud context create trongate-cloud`.
3. **Object storage credential** (Security, S3 credentials) in that project.
   Hetzner credentials reach every bucket in the project; one per consumer
   (OpenTofu/etcd, JuiceFS, registry, backups) at least makes rotation local.
4. **Buckets in fsn1.** Names are global across Hetzner customers; change the
   prefix if taken, and keep the files below in step.
   - `trongate-cloud-fsn1-tofu-state` (versioned) and
     `trongate-cloud-fsn1-etcd-snapshots` (expiring):
     `scripts/bootstrap-buckets.sh` with
     `S3_ENDPOINT=https://fsn1.your-objectstorage.com S3_REGION=fsn1`.
   - `trongate-cloud-fsn1-juicefs`, `trongate-cloud-fsn1-registry`,
     `trongate-cloud-fsn1-backups`.
   Done 2026-10-04: all five exist in fsn1, state versioned, snapshots expire
   after 30 days. (The first set was in hel1 and was deleted, empty, when the
   cluster moved to fsn1.)
5. **DNS** (decided 2026-10-03).
   - `trongate.cloud` stays at Porkbun. Its exact hostnames get certificates
     over HTTP-01, which needs no DNS credentials.
   - Customer apps live on their own domain, `{slug}.trongate.dev`, so an app
     can never set cookies the control panel at trongate.cloud receives.
     The `*.trongate.dev` wildcard needs DNS-01, so the `trongate.dev` zone is
     hosted in Hetzner DNS (project Trongate.cloud) and Porkbun, the
     registrar, delegates to Hetzner's nameservers. The cluster's DNS-01 token
     is the project token it already holds for the cloud controller.
6. **SSH key**: generate one locally. Do not upload it to the project; the
   module registers it and fails on a duplicate.

### 5.2 Keys and repositories

1. `age-keygen -o age.agekey`. Private half into your password manager. Put the
   public key in both places in `.sops.yaml`.
2. Create the private GitHub repository `sasin91/trongate-cloud-infra`, add it
   as `origin`, push (I have not done this).
3. Two read-only deploy keys:
   `ssh-keygen -t ed25519 -N "" -f infra-deploy-key` (add to
   trongate-cloud-infra) and `ssh-keygen -t ed25519 -N "" -f trongate-cloud-deploy-key`
   (add to trongate.cloud, Settings, Deploy keys, read-only).
4. `clusters/production/flux-system/gotk-sync.yaml`: `url:
   ssh://git@github.com/sasin91/trongate-cloud-infra.git`. Commit before
   applying (the kit explains why).
5. `./scripts/generate-flux-components.sh` and commit the real
   `gotk-components.yaml`.

### 5.3 Secrets, all encrypted before they are committed

| File | From | Then uncomment in |
|---|---|---|
| `platform/observability/secrets/grafana-admin.sops.yaml` | its `.example` | `platform/observability/secrets/kustomization.yaml` |
| `apps/trongate-cloud/secrets/{databases,cache,files,trongate-cloud}.sops.yaml` | trongate.cloud's `deploy/k8s/*/secrets.example.yaml` | `apps/trongate-cloud/secrets/kustomization.yaml` |
| `apps/trongate-cloud/registry/secrets/registry-config.sops.yaml` | its `.example` | `apps/trongate-cloud/registry/secrets/kustomization.yaml` |

`sops --encrypt --in-place <file>` for each. Values to keep consistent:

- `juicefs-secret.bucket`: `https://trongate-cloud-fsn1-juicefs.fsn1.your-objectstorage.com`
  (the example says fsn1), and the same password in `juicefs-meta` and `metaurl`.
- `registry-push` in `trongate-cloud.sops.yaml`: a dockerconfigjson for
  `registry.trongate.cloud` with the registry's `push` user.
- `APP_KEY`, `MCP_SECRET`, `DB_PASSWORD`: trongate.cloud's `scripts/setup-env.sh`.

The DNS token and registry config are not optional in practice: without the
first no certificate is issued and the `platform` layer waits on the Gateway;
without the second the registry never starts.

### 5.4 Build the node **(costs money)**

```bash
export TF_VAR_hcloud_token=...            # trongate-cloud project
export TF_VAR_object_storage_access_key=...
export TF_VAR_object_storage_secret_key=...
export TF_VAR_state_passphrase='...'      # 16+ chars, password manager
export TF_VAR_ssh_public_key="$(cat ~/.ssh/trongate-cloud.pub)"
export TF_VAR_registries_config='
configs:
  "registry.trongate.cloud":
    auth:
      username: pull
      password: <pull password>
'
cd infrastructure/hetzner
cp backend.hcl.example backend.hcl
tofu init -backend-config=backend.hcl
python ../../scripts/checks/check-fetched-module-line-endings.py
python ../../scripts/checks/check-pool-availability.py   # needs HCLOUD_TOKEN
# x86 snapshot, about 5 minutes on a temporary cx23 (the template's default,
# in stock on 2026-10-04). The template pins Packer to exactly 1.16.0 (winget
# installs newer; use the release zip):
packer init  .terraform/modules/kube_hetzner/packer-template/hcloud-leapmicro-snapshots.pkr.hcl
packer build -only='hcloud.leapmicro-x86-snapshot' .terraform/modules/kube_hetzner/packer-template/hcloud-leapmicro-snapshots.pkr.hcl
tofu plan     # expect 1 server, no load balancer
tofu apply
tofu output -raw kubeconfig > ../../trongate-cloud.kubeconfig   # gitignored
```

The platform images come from `registry.trongate.cloud/platform/*`, the same
registry and pull credential as tenant images (trongate.cloud PR #2). Once the
registry answers, set the trongate.cloud repository variable
`PLATFORM_REGISTRY_READY=true` and run its Images workflow; until then the app
and worker pods wait on image pulls.

### 5.5 DNS records

All pointing at the node's IPv4 (there is no load balancer;
`tofu output control_planes_public_ipv4`):

- Porkbun: `trongate.cloud` and `*.trongate.cloud` (covers `registry`).
- Hetzner DNS, zone `trongate.dev`: `trongate.dev` (the CNAME target customers
  use for custom domains) and `*.trongate.dev`. A low TTL (300) until the
node is final; rebuilding the node changes the address.

### 5.6 Flux **(the cluster starts pulling and running everything)**

```bash
export KUBECONFIG=$PWD/trongate-cloud.kubeconfig
kubectl apply -k clusters/production/flux-system   # creates CRDs, 2 errors expected
kubectl apply -k clusters/production/flux-system   # succeeds
kubectl -n flux-system create secret generic sops-age --from-file=age.agekey=age.agekey
ssh-keyscan github.com > known_hosts
kubectl -n flux-system create secret generic flux-system \
  --from-file=identity=infra-deploy-key --from-file=identity.pub=infra-deploy-key.pub \
  --from-file=known_hosts=known_hosts
kubectl -n flux-system create secret generic trongate-cloud-deploy-key \
  --from-file=identity=trongate-cloud-deploy-key --from-file=identity.pub=trongate-cloud-deploy-key.pub \
  --from-file=known_hosts=known_hosts
flux get kustomizations --watch
```

Expected order: `flux-system`, `infrastructure` (gateway-api-crds,
platform-crds, platform-releases), then `platform` and
`trongate-cloud-operators` side by side, then `trongate-cloud-secrets`,
`trongate-cloud`, `trongate-cloud-registry`, `observability-*`, `tenants`.
`trongate-cloud-secrets` may fail once with "namespace not found" and succeed a
minute later (`apps/trongate-cloud/secrets/kustomization.yaml` explains).

### 5.7 Certificates

`kubectl get certificate -n traefik` until all three are Ready on the staging
issuer. Then set `cert-manager.io/cluster-issuer: letsencrypt-dns01` in
`platform/configs/gateway.yaml`, commit, push, and delete the three staging
Secrets so they reissue.

### 5.8 Schema and first check

Once `kubectl -n trongate-cloud get mariadb platform` is Ready, apply
trongate.cloud's `db/001_*.sql` onwards (not `000`) through a port-forward to
`platform`, as `deploy/k8s/README.md` step 4 describes. Then
`https://trongate.cloud/` should answer and the worker log should say
`Poll loop started`.

---

## 6. Running it

- **OS patches**: unattended updates are off (one node, attached volumes). Once
  a month: `ssh root@<node> transactional-update` then `reboot` at a quiet hour;
  everything is down for a minute or two. Kubernetes patch releases still arrive
  through the system-upgrade-controller Plan (`v1.35` channel).
- **Alerts you will see on day one**: the kit's `TenantGuardrailMatchesNothing`
  fires, because there are no kit-template tenants. Its tenant-guarantee rules
  do not cover `tc-team-*` namespaces; silence or adapt them.
- **Teardown**: the kit's order still holds (`scripts/teardown.sh`, then
  `tofu destroy`), and volumes from Retain classes stay billed until deleted.

---

## 7. Open items found while wiring

Ranked by how soon they bite.

1. **Build pods reaching the registry is unverified.** trongate.cloud#2 added
   an egress rule from buildkitd to Traefik (kube-proxy short-cuts the load
   balancer address to the Traefik pod, which the private-range rule blocked).
   The first tenant deploy confirms it.
2. **Custom domains** (trongate.cloud branch `port/custom-domains`): the worker
   gives each routed custom domain its own Gateway in the tenant namespace, with
   one HTTPS listener and a certificate from the HTTP-01-only ClusterIssuer
   `letsencrypt-tenants` (`platform/configs/cluster-issuers.yaml`), whose
   challenges attach to a per-namespace HTTP Gateway `acme-http01`. The platform
   Gateway is untouched (Flux owns it; Traefik 3.7 does not support
   ListenerSet). A domain is routed only once its DNS reaches the load balancer.
   Unverified until the first custom domain is live: Traefik serving several
   Gateways on the same entrypoints, and the challenge route on `acme-http01`
   winning over the platform Gateway's `http-to-https` route. Not done: CAA
   records for trongate.cloud and trongate.dev with `accounturi` limited to
   the platform issuers' ACME accounts, so `letsencrypt-tenants` could not get
   those names even if trongate.cloud's admission policy were bypassed.
3. **Registry**: no garbage collection yet (needs a read-only window), one
   registry-wide push credential (trongate.cloud's open item), and distribution
   v3's S3 driver against Hetzner Object Storage is untested.
4. **JuiceFS mount pod resources**: the CSI driver's default for the shared mount
   pod may reserve more memory than the rest of trongate.cloud's tenants; check
   and set `mountPodResources` if so.
5. Everything trongate.cloud's README already lists under "needs a live cluster".

## 8. First spikes once the cluster is up

1. **Memory per FrankenPHP app pod.** Deploy a typical Trongate app, then
   `kubectl top pod -n tc-team-<id>` idle and under load (for example `hey -z 60s`).
   Resident memory sets apps per node and therefore the price per app; compare
   with the 96Mi request / 256Mi limit in `Manifests::APP_RESOURCES`.
2. **Cold start through Sablier.** Let an app idle past the 15m session
   (`Manifests::SABLIER_SESSION`), then time the first request
   (`curl -w '%{time_total}'`) and the pod's start in `kubectl get events`.
   Separate image pull (first time on the node) from container start.
3. **JuiceFS latency.** In a tenant pod on `tenant-files`: small-file create and
   read loops, a 10 MB upload, and the same while the shared-1 MariaDB is
   restarted (metadata lives there).
4. **Whether the admission policies allow what the worker sends.** Run one real
   deploy and read the worker's task log for `denied the request`; check the
   tenant Namespace, Deployment, Service, HTTPRoute, Middleware, PVC, Secrets and
   the MariaDB Database/User/Grant against both `trongate-worker-tenants-only`
   and `trongate-worker-objects`, plus the kit's `deny-traefik-routes` (the
   worker writes a Middleware, which it allows).
5. **Cross-namespace `mariaDbRef`.** Confirm the tenant's Database, User and
   Grant in `tc-team-<id>` become Ready against `shared-1` in `databases` with
   operator 26.10.1, and that the app can log in.
6. Added by this repository: open item 1 (build pod to registry), and a push and
   pull through `registry.trongate.cloud` to prove the S3 driver.
