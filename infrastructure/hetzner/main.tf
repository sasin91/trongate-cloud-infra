provider "hcloud" {
  token = var.hcloud_token
}

# -----------------------------------------------------------------------------
# Autoscaler pools, declared once.
#
# This list is the single source for two things that must never disagree: the
# pools handed to the module, and the priority-expander ConfigMap that tells the
# autoscaler which pool to prefer. Two places that can disagree eventually will,
# and here the disagreement is silent — a pool the expander has no rule for is
# not considered for expansion at all.
#
# `priority` is DECLARED, not derived from position in the list. Numbering by
# index means deleting or reordering an entry silently renumbers the rest, and
# the autoscaler's behaviour would change because of a diff that looks cosmetic.
# Higher wins.
# -----------------------------------------------------------------------------
locals {
  autoscaler_pools = [
    {
      # Primary: the cost-optimised x86 line, in the primary location.
      #
      # CHECK THAT THIS TYPE IS CURRENTLY AVAILABLE IN THIS LOCATION, not merely
      # supported. The provider API distinguishes them; configuration written
      # against "supported" validates, plans and applies cleanly, then fails at
      # the moment you need to scale. Re-check on a schedule, not once: a pool
      # created when its type was in stock keeps that type forever, and stock
      # moves while the configuration does not.
      name        = "autoscaled"
      server_type = var.autoscaler_server_type
      location    = var.autoscaler_location
      min_nodes   = 0
      max_nodes   = var.autoscaler_max_nodes
      priority    = 100
    },

    # ── Insurance: a second location. Ships commented out. ────────────────────
    #
    # The cost-optimised line above was present in a single location when this
    # was written (observed 2026-08-03). This pool sits in a different one, on
    # the line stocked everywhere, and costs roughly FOUR TIMES as much per core
    # — the ticket that decided this recorded about EUR 16/month against about
    # EUR 69/month for the same 8 vCPU / 16 GB shape.
    #
    # Those figures and that single-location observation are DATED, and were not
    # re-verified when this file was written. Check current price, current shape
    # and current availability before uncommenting; the fallback type may not
    # even be a like-for-like swap on vCPU count.
    #
    # You pay for it only when the primary type cannot be had AND you need
    # capacity, which is what insurance is supposed to cost. Both pools idle at
    # zero nodes, so an uncommented-but-unused pool costs nothing.
    #
    # Uncommenting this block is the ONLY edit required. The priority expander
    # below is generated from this list, so the rule preferring the cheap pool
    # and the rule permitting this one both appear automatically.
    #
    # Treat it as UNPROVEN until it has provisioned a node at least once. A
    # fallback naming an equally unavailable type protects nobody, and its
    # presence is what stops anyone from looking. All autoscaler pools must
    # share one architecture, so this differs by type and location only.
    #
    # {
    #   name        = "autoscaled-fallback"
    #   server_type = var.autoscaler_fallback_server_type
    #   location    = var.autoscaler_fallback_location
    #   min_nodes   = 0
    #   max_nodes   = var.autoscaler_max_nodes
    #   priority    = 10
    # },
  ]

  # The node-group name the autoscaler sees is "<cluster_name>-<pool name>",
  # which is why use_cluster_name_in_node_name is pinned explicitly below.
  # Anchored so "autoscaled" cannot also match "autoscaled-fallback".
  autoscaler_priority_rules = join("\n", [
    for pool in local.autoscaler_pools :
    "${pool.priority}:\n  - ^${var.cluster_name}-${pool.name}$"
  ])

  autoscaler_priority_expander_manifest = yamlencode({
    apiVersion = "v1"
    kind       = "ConfigMap"
    metadata = {
      # Name and namespace are fixed by the autoscaler: it reads exactly this
      # name, in the namespace it runs in. The module already grants its service
      # account get/update on this ConfigMap, so nothing else is needed.
      name      = "cluster-autoscaler-priority-expander"
      namespace = "kube-system"
    }
    data = {
      priorities = local.autoscaler_priority_rules
    }
  })
}

# Duplicate priority values are a silent failure upstream: when two entries
# share a value, only one of the lists is used and nothing reports it. This is a
# warning here and belongs as a hard failure in CI, where the check runs whether
# or not anyone is looking at a plan.
check "autoscaler_priorities_are_unique" {
  assert {
    condition     = length(distinct([for pool in local.autoscaler_pools : pool.priority])) == length(local.autoscaler_pools)
    error_message = "Autoscaler pool priorities must be unique — the priority expander silently uses only one list when two share a value."
  }
}

module "kube_hetzner" {
  # Consumed as a published module, not forked. Upstream solves cluster creation
  # — image building, cloud-init, HA control planes, cloud controller and CSI
  # wiring, coordinated node upgrades — and none of that is reimplemented here.
  #
  # Pinned to the current major. `~> 3.0` accepts 3.x and refuses 4.0: an
  # unpinned source is a latent breaking change, and this module's own migration
  # notes show what a major costs — renamed inputs, inverted booleans, changed
  # nested shapes, all in one tag. Read MIGRATION.md before widening this.
  source  = "kube-hetzner/kube-hetzner/hcloud"
  version = "~> 3.0"

  providers = {
    hcloud = hcloud
  }

  hcloud_token = var.hcloud_token
  cluster_name = var.cluster_name

  ssh_public_key  = var.ssh_public_key
  ssh_private_key = var.ssh_private_key

  # The autoscaler's priority rules are built from this prefix. Pinned
  # explicitly rather than inherited, because flipping it to false would leave
  # the generated regexes matching nothing — and a node group matching no rule
  # is simply never expanded, with no error anywhere.
  use_cluster_name_in_node_name = true

  # x86 only. At the time of the decision the Arm line was cheaper per hour on
  # paper but more expensive at identical vCPU/memory/disk, and no Arm type was
  # available in ANY location in this region — not one type missing, the whole
  # architecture. A default nobody can provision is not a default.
  #
  # Platform components stay multi-architecture because that costs nothing; this
  # setting is about what the kit will provision, not what it can run.
  #
  # TRONGATE-CLOUD: a variable so a profile can choose arm (CAX). The default is
  # still the kit's ["x86"]; trongate-cloud.auto.tfvars sets ["arm"], and every
  # nodepool, autoscaler pools included, must then be a CAX type. Observed
  # 2026-10-03: cax21/31/41 available in fsn1, nbg1 and hel1.
  enabled_architectures = var.enabled_architectures

  network_region = var.network_region

  # ---------------------------------------------------------------------------
  # Control plane: three nodes, on purpose, and it costs money.
  #
  # Three is the smallest HA etcd quorum. It must be an ODD number — two nodes
  # is strictly worse than one, because either failure loses quorum instead of
  # only one of them doing so.
  #
  # One nodepool in one location, spread across physical hosts by the module's
  # placement group. Splitting etcd across locations survives a datacenter but
  # pays the inter-datacenter round trip on every etcd write, forever. That is a
  # latency decision, not a free upgrade — make it deliberately if you make it.
  #
  # CHECK THAT THIS TYPE IS CURRENTLY AVAILABLE IN ITS LOCATION, not merely
  # supported; the two are different fields in the provider API.
  # ---------------------------------------------------------------------------
  control_plane_nodepools = [
    {
      name        = "control-plane"
      server_type = var.control_plane_server_type
      location    = var.control_plane_location
      labels      = []
      taints      = []
      # TRONGATE-CLOUD: a variable, default 3 (the kit's value). The single-node
      # profile sets 1. Growing 1 -> 3 later is safe; shrinking is not (above).
      count = var.control_plane_count
    }
  ]

  # TRONGATE-CLOUD: single-node profile switches. Defaults keep the kit's shape.
  #
  # allow_scheduling_on_control_plane: with agent_count = 0 the control plane is
  # the only place workloads can run.
  #
  # enable_klipper_metal_lb: Traefik's LoadBalancer Service is served by k3s
  # servicelb on the node's own IPv4 (the module then opens 80/443 in the
  # firewall) and the cloud controller stops creating Hetzner load balancers
  # (HCLOUD_LOAD_BALANCERS_ENABLED=false). kube-hetzner only does this by itself
  # when control planes + agents + autoscaler max add up to exactly 1, and the
  # 0-1 autoscaler pool makes it 2, so it is set explicitly. Moving to a Hetzner
  # LB later is this flag plus the annotations in
  # platform/controllers/releases/ingress.yaml (see TRONGATE-CLOUD.md).
  allow_scheduling_on_control_plane = var.allow_scheduling_on_control_plane
  enable_klipper_metal_lb           = var.enable_klipper_lb

  # kube-hetzner: "Should be disabled for single-node clusters" (attached volumes
  # and unattended reboots do not mix). The single-node profile turns it off and
  # patches the OS by hand on a schedule; see TRONGATE-CLOUD.md.
  automatically_upgrade_os = var.automatically_upgrade_os

  # TRONGATE-CLOUD: k3s registries.yaml. Nodes pull tenant images from the
  # platform registry (registry.trongate.cloud) with a pull-only credential, so
  # tenant namespaces need no imagePullSecrets. Empty by default.
  registries_config = var.registries_config

  # ---------------------------------------------------------------------------
  # Agents: a small fixed pool for everything that must not move.
  #
  # Ingress, storage and anything carrying a disruption budget live here rather
  # than on autoscaled nodes, so scale-down is never the thing that breaks them.
  #
  # CHECK CURRENT AVAILABILITY of this type in its location, not merely support.
  #
  # DELIBERATELY ABSENT: an egress nodepool. Upstream's example ships one. A
  # dedicated node holding a stable outbound address does nothing unless the CNI
  # implements an egress gateway or the workload is pinned to that node —
  # otherwise traffic leaves from wherever the pod happens to be scheduled and
  # the pool, the address and its reverse DNS are all inert. Flannel (below)
  # implements no egress gateway, so shipping the pool would be dead cost that
  # looks like a solved problem. If you need one, ship the mechanism with it.
  # ---------------------------------------------------------------------------
  agent_nodepools = [
    {
      name        = "agent"
      server_type = var.agent_server_type
      location    = var.agent_location
      labels      = []
      taints      = []
      count       = var.agent_count
    }
  ]

  # ---------------------------------------------------------------------------
  # Autoscaler
  # ---------------------------------------------------------------------------
  autoscaler_nodepools = [
    for pool in local.autoscaler_pools : {
      name        = pool.name
      server_type = pool.server_type
      location    = pool.location
      min_nodes   = pool.min_nodes
      max_nodes   = pool.max_nodes
      # No taints. A taint that no pending workload tolerates makes a pool that
      # can never scale: the autoscaler cannot simulate a pod fitting there, so
      # it never scales up regardless of demand, and nothing reports an error.
      # If you add one here, add the matching toleration in the same change.
    }
  ]

  # Prefer the cheap pool, then fall back to least-waste for anything the
  # priority rules tie on.
  #
  # Upstream's documented behaviour when the ConfigMap is absent or malformed is
  # to SKIP the priority expander and continue to the next one — so this arg is
  # safe to ship before the ConfigMap exists, and the cluster degrades to
  # least-waste rather than failing. See outputs.tf for how the ConfigMap is
  # produced and why applying it is not done from here.
  cluster_autoscaler_extra_args = ["--expander=priority,least-waste"]

  # ---------------------------------------------------------------------------
  # Networking
  # ---------------------------------------------------------------------------

  # Flannel, the module default, stated explicitly so it reads as a decision.
  #
  # k3s with flannel already enforces NetworkPolicy. The gap in an unpoliced
  # multi-tenant cluster is AUTHORSHIP, not capability — swapping to a more
  # capable plugin does not write a single policy, and would hide the real
  # problem behind a better tool. Policies belong to the tenant layer.
  #
  # Cilium is opt-in and only for things flannel genuinely cannot do: FQDN-based
  # egress policy, an egress gateway, Hubble. Setting cni_plugin = "cilium" is
  # not a drop-in — it changes kube-proxy, Gateway API and upgrade behaviour.
  cni_plugin            = "flannel"
  enable_network_policy = true

  # ---------------------------------------------------------------------------
  # etcd snapshots to object storage. On, and it costs money.
  #
  # Pointed at the SNAPSHOTS bucket, never the state bucket — that bucket
  # carries an expiry rule, and the state bucket must never be within reach of
  # one. See variables.tf for the two-sided retention story.
  #
  # k3s wants a bare host here; the s3 backend in versions.tf wants a URL. Same
  # endpoint, two shapes, and the backend block cannot read a variable — if you
  # change one, change the other.
  # ---------------------------------------------------------------------------
  etcd_s3_backup = {
    etcd-s3-endpoint            = var.object_storage_endpoint_host
    etcd-s3-access-key          = var.object_storage_access_key
    etcd-s3-secret-key          = var.object_storage_secret_key
    etcd-s3-bucket              = var.etcd_snapshot_bucket
    etcd-s3-region              = var.object_storage_region
    etcd-s3-folder              = var.cluster_name
    etcd-snapshot-schedule-cron = var.etcd_snapshot_schedule_cron
    etcd-snapshot-retention     = var.etcd_snapshot_retention
  }

  # ---------------------------------------------------------------------------
  # Kubernetes version
  #
  # Pinned to a minor channel rather than "stable". "stable" is an unpinned
  # dependency wearing a reassuring name: it crosses minor boundaries on
  # somebody else's schedule, and with automatic upgrades on that happens
  # without a diff in this repository.
  #
  # Review this whenever you widen the module pin above — the module's tested
  # matrix moves with it.
  #
  # THIS MUST MATCH the channel in the GitOps layer's upgrade Plans
  # (platform/configs/k3s-upgrade-plans.yaml). They are two halves of one
  # decision written in two files, and nothing enforces the correspondence.
  #
  # Getting it wrong is not a validation error. If the Plan names a HIGHER
  # minor, the upgrade controller walks the cluster there unattended on first
  # reconcile — potentially several minors in one jump, hours after a build
  # that reported success. If it names a LOWER one, the Plan silently stops
  # delivering patches and the cluster quietly falls behind on security fixes.
  #
  # THE VERSION IS PINNED EXACTLY, AND THE CHANNEL IS LEFT ALONE. That looks
  # redundant. It is not, and the reason is worth knowing before you "simplify"
  # it back to a channel.
  #
  # The module validates this input TWICE, with DIFFERENT allowed sets:
  #
  #   variables.tf          accepts stable, latest, testing, and v1.16 .. v1.35
  #   validation-contract.tf accepts stable, latest, testing, and v1.33 ONLY
  #                          -- but only when k3s_version is empty
  #
  # So a value can satisfy the variable rule and fail the contract. Setting a
  # minor channel of v1.34 or v1.35 passes `validate` and then fails `plan`,
  # which is a genuinely confusing place to learn it. Only v1.33 works as a
  # channel, and v1.33 is three minors behind current.
  #
  # Supplying k3s_version instead lifts the contract entirely, and it is the
  # better fit anyway: an exact version is a pin, a channel is a subscription to
  # someone else's release schedule. Patch upgrades within the minor are then
  # the upgrade controller's job in the GitOps layer, deliberately, rather than
  # something that happens at build time depending on the day.
  #
  # BOTH HALVES MUST MOVE TOGETHER with platform/configs/k3s-upgrade-plans.yaml.
  # Nothing enforces that correspondence. If the Plan names a higher minor, the
  # controller walks the cluster there unattended hours after a build that
  # reported success; if lower, it silently stops delivering security patches.
  #
  # Verified by running `tofu validate` and `tofu plan` against the pinned module
  # on 2026-08-04. Reading the module's documentation would not have surfaced the
  # second validation. Channel resolutions that day: v1.35 -> v1.35.6+k3s1,
  # v1.36 -> v1.36.2+k3s1 (v1.36 is unusable here at all). Dated observations.
  # ---------------------------------------------------------------------------
  k3s_channel = "stable"
  k3s_version = "v1.35.6+k3s1"

  # ---------------------------------------------------------------------------
  # Layer boundary: this configuration builds nodes. It does not install the
  # platform.
  #
  # Ingress and certificate management are delivered by the GitOps layer, from
  # manifests you can read in your own diff. Letting the node module install
  # them too is how you end up with two ingress controllers, or an ACME client
  # running beside cert-manager — two issuers racing for the same certificate,
  # which is the failure the kit's CI guardrail exists to catch.
  # ---------------------------------------------------------------------------
  # The module installs FOUR of these by default. Every one of them is also
  # delivered by the GitOps layer, so each must be turned off here or two
  # installations take turns reconciling the same objects — and the loser is
  # whichever ran least recently, which is not a property you can reason about.
  #
  # The failure is not a crash. Both installs succeed, both report healthy, and
  # the cluster alternates between two configurations.
  ingress_controller               = "none"
  enable_cert_manager              = false
  enable_metrics_server            = false
  enable_system_upgrade_controller = false

  # Not set here, and worth a deliberate decision before you apply:
  #   firewall_kube_api_source — defaults to the whole internet
  #   firewall_ssh_source      — defaults to the whole internet
  # Narrow both to the addresses you actually administer from. They are omitted
  # rather than guessed because a wrong value here locks you out of your own
  # cluster, and a comment claiming a security posture is not the posture.
}
