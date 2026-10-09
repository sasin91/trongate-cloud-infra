# Guardrails

Prose gets skipped. A red build does not.

Every check here enforces a lesson that was expensive to learn, and every
script says which one in its own header. That is not decoration: **a check
whose reason is unclear gets disabled the first time it is inconvenient.** If
you are about to delete one, read its header first — the argument for keeping
it is written at the top of the file it lives in.

## The organising principle: where the truth lives

Checks are split by **where the fact being checked actually lives**, not by how
serious it is.

| Group | Truth lives in | Runs | Needs |
|---|---|---|---|
| **A** | the repository | every pull request | nothing |
| **B** | the provider's API | a daily schedule | a read-only API token |
| **C** | the running cluster | in-cluster job → alerts | a read-only service account |

This split is the reason no kubeconfig is ever placed in a build system, and
the reason findings about a running cluster land where operators already look
rather than in a build log nobody reads.

**Group C is not in this directory.** It belongs to the observability layer.
See [What group C covers](#group-c-what-this-directory-deliberately-does-not-check).

## The severity rule

> **Security boundaries fail. Standing configuration reports.** An absent quota
> is a gap for somebody to close; an absent privilege boundary is a hole to
> stop. Conflating them trains people to ignore both — and a wall of warnings
> is indistinguishable from no warnings at all.

Every finding is printed with its class, so a build log can be read in one
glance:

```
[flux-lockdown-flags] FAIL (boundary): kustomize-controller is missing --no-remote-bases ...
[ingress-ha]          REPORT (config): traefik declares no anti-affinity ...
```

`FAIL (boundary)` sets a non-zero exit code. `REPORT (config)` does not.
Running with `--strict` promotes reports to failures; the kit does not do this
by default, deliberately.

Exit codes: `0` pass, skip, or reports only · `1` at least one boundary failure
· `2` the check itself broke. A broken check is not a passing check.

## Running them

```sh
scripts/checks/run-all.sh              # every group A check
scripts/checks/run-all.sh --strict     # reports fail too
python3 scripts/checks/check-prune-enabled.py     # one check, on its own
python3 scripts/checks/check-prune-enabled.py --root /path/to/a/fork
```

Python 3 standard library and POSIX `sh` only. Nothing to install: a fork must
be able to run these on a stock machine, which is also why the YAML reader in
`_common.py` is hand-rolled rather than importing a parser. It understands the
subset of YAML that manifests and values files are written in, and it fails
soft — an unreadable file is reported, never crashed on.

Two checks use external tools when they are present: `kustomize` (or
`kubectl`) and `kubeconform`. Without them, those checks skip locally with a
message and run fully in CI, which installs both at pinned versions.

**Everything skips cleanly when its target does not exist yet.** A check that
crashes on an unfinished repository is a check somebody deletes.

## Group A — repository facts, failing the pull request

Run by `.github/workflows/guardrails.yml` on every pull request. No cluster, no
credentials, nothing worth stealing — so it runs on pull requests from forks.

| Check | Asserts | Boundary | Reports |
|---|---|---|---|
| `check-version-pins.py` | every module, provider, chart, remote base, image and action reference carries an explicit version constraint | unpinned or mutable ref (`main`, `latest`, untagged image) | a constraint with no upper bound; a source branch that moves |
| `check-duplicate-yaml-keys.py` | no duplicate key in any YAML file | a duplicate — the later key silently discards the earlier block | a file this reader cannot parse |
| `check-ingress-ha.py` | the ingress declares more than one replica and a PodDisruptionBudget | fewer than two replicas; no disruption budget | no anti-affinity or topology spread |
| `check-acme-conflict.py` | no certificate resolver on the ingress while cert-manager is present | a non-empty resolver, an ACME flag, a `certresolver` selection | — |
| `check-dashboard-auth.py` | dashboard anonymous access disabled, administrative credentials set | anonymous enabled; credentials absent, empty, a known default, or a plaintext literal in git | anonymous not *explicitly* disabled |
| `check-dashboard-not-exposed.py` | no route or ingress for the dashboard exists at all | any route, IngressRoute, HTTPRoute, LoadBalancer/NodePort Service, or `ingress.enabled: true` | a hostname declared for it |
| `check-flux-lockdown-flags.py` | every reconciliation controller carries the multi-tenancy lockdown flags it accepts | a missing flag, a flag set to `false`, a flag a binary does not define | the flags could only be read as text (no build tool available) |
| `check-tenant-service-accounts.py` | every tenant reconciliation names an explicit service account | a tenant reconciliation without one; any reconciliation without one when no `--default-service-account` lockdown exists | a platform reconciliation without one under lockdown; a named account this repository does not declare |
| `check-prune-enabled.py` | pruning is not disabled anywhere without a recorded reason | `prune: false`, or `prune` omitted (Flux defaults it to false), with no written reason | — |
| `check-state-bucket-versioning.py` | the state bucket has versioning enabled | no versioning; an expiry rule and versioning targeting the same bucket | a call whose bucket cannot be determined |
| `check-manifests-render.sh` | every kustomization builds and validates against schema | a build or validation failure | — |
| `check-rule-shadowing.py` | no alerting rule shadowed by a same-named rule of the kind an operator converts | a `PrometheusRule`/`VMRule` name collision (and the scrape equivalents) | the same object declared in several files |

### Two of these cannot be done by reading files

`check-flux-lockdown-flags.py` **builds the overlay** and reads the container
arguments of the rendered Deployments. Reading the patch files would not work,
and this is worth internalising because it is the shape of most silent
failures:

* a kustomize patch whose target matches **no** resource is applied to nothing
  and reports nothing — a typo in a controller name removes a privilege
  boundary silently; and
* a multi-document JSON 6902 patch file applies only its **first** document and
  discards the rest without an error.

Either produces a repository whose patch files contain every flag and a cluster
that receives none of them. A text-reading check would pass. It would also
verify nothing, which is worse than not existing, because it *looks* like
coverage.

The same reasoning is why `check-manifests-render.sh` exists at all: YAML
accepts a misspelled field, kustomize accepts it, and the API server ignores
it. The object applies; the setting does not exist.

## Group B — provider facts

`check-pool-availability.py`. TRONGATE-CLOUD: run by hand before `tofu apply`
(TRONGATE-CLOUD.md 5.4). The kit's daily `pool-availability` workflow was
removed: the cluster's pools are fixed, and the workflow failed every day
without a token secret.

It asserts that **every declared nodepool and autoscaler pool names an instance
type currently AVAILABLE in its location.** The provider's API distinguishes
the types a location *supports* from those it currently *has*. Configuration
written against the former validates, plans and applies cleanly — and then
cannot be provisioned at the moment you need to scale, which is by definition
the worst moment.

**Why this is a schedule and not only a pre-apply check.** A pool created when
its type was in stock keeps that type in its configuration forever. Stock
changes; the configuration does not. A check that runs only in the apply path
passes on the day it is written and is never consulted again, and the failure
it exists to catch appears months later with no commit to attribute it to.

Observed on a live cluster: a primary pool and the fallback added to protect it
both named types that were `supported=True available=False`, and nothing
reported a problem until capacity was actually needed. Treat a fallback that
has never once been provisioned as unproven, not as insurance.

Severity: **boundary** — capacity-critical. A deprecated-but-available type, or
a pool whose location cannot be resolved, reports instead.

**Where it reads the values from.** Pools are declared in `.tf` with
`var.`/`local.` references, and the values live in `terraform.tfvars` — which is
gitignored, because it also holds credentials. So the check resolves references
against variable defaults, `locals`, and the committed
`terraform.tfvars.example`, preferring a real `terraform.tfvars` when one is
present locally. A commented-out pool declares nothing and is invisible to it;
a list built by re-mapping another list is checked where that list is declared.

**If it cannot resolve a single instance type while pool declarations exist, it
fails.** Passing would mean reporting success having verified nothing, which is
the failure this check is about.

### The credential

Repository secret **`HCLOUD_TOKEN_READ_ONLY`**: a provider API token created
with **read-only** permission in the project holding the cluster.

* Passed to the check as an environment variable and sent in an `Authorization`
  header. Never echoed, logged, written to a file, or placed on a command line.
* No cluster access of any kind is involved — no kubeconfig goes into CI.
* Locally: `HCLOUD_TOKEN_READ_ONLY=... python3 scripts/checks/check-pool-availability.py`.
  With no token the check **skips**; with `--require-token` it fails instead,
  which is what the kit's scheduled workflow passed.

## Group C — what this directory deliberately does not check

These are facts about a **running cluster**. They belong to the observability
layer: an in-cluster job with a read-only service account, emitting metrics
that the shipped alerting stack turns into alerts. They are listed here so the
split is documented rather than assumed.

* **Namespaces carrying the tenant label that lack a quota, limit range,
  network policy, disruption budget or backup job.** *Reported, not failed* —
  these are generated guarantees, and generation is prospective: it covers
  tenants created after it learned to, and never revisits. Expect the first run
  on a mature cluster to find its oldest tenant. **A check that finds nothing
  there is more likely broken than clean.**
* **Alerting rules verified against the running evaluator**, not against the
  repository. A rule can be committed, applied, and still not be loaded.
  Group A only refuses to commit the name collision that causes it.
* **Pools carrying a taint that no workload tolerates.** The autoscaler can
  never simulate a pending pod fitting there, so the pool never scales up
  regardless of demand — and nothing reports an error. Deciding this needs the
  cluster's actual workloads, so it cannot be a repository check.
* **A backup that reports success having captured nothing.** This is not a
  check at all but a design requirement: a backup must assert on its output,
  not its exit status, and that belongs in the job the tenant template
  generates. A green, empty backup is worse than a failed one, because it
  silences the alarm that would have caught it.

## Not implemented here

* **Committed controller manifests going stale against upstream.** Decided as a
  *scheduled comparison that opens a pull request* rather than one that fails a
  build. It needs release-watching and write access, so it is a different kind
  of automation from anything in this directory.

## Adding or changing a check

1. **State the lesson in the header, in one or two sentences.** What went
   wrong, and what the check makes impossible. A check nobody can justify is a
   check that gets removed under time pressure.
2. **Choose the severity honestly.** Boundary means a privilege or capacity
   boundary. Everything else reports. Inflating severity is how a whole
   category of warnings gets ignored.
3. **Skip cleanly when the target is absent.** Every check runs against forks
   at every stage of completeness, including empty ones.
4. **Ask whether file text can actually decide it.** If a file can contain the
   right words while the cluster gets nothing — patches, overlays, generated
   manifests — build the output and check that instead.
5. **Add it to `run-all.sh`**, which runs every check even after one fails: a
   build that stops at the first problem trains people to fix things one
   round-trip at a time.
