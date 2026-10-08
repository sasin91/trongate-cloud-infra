# TRONGATE-CLOUD single-node profile. Loaded automatically by `tofu plan/apply`.
#
# COMMITTED ON PURPOSE, and therefore NO SECRETS IN THIS FILE: it is the one
# *.tfvars the .gitignore lets through. Tokens, keys, the state passphrase and
# registries_config come from the environment (TF_VAR_...) or the gitignored
# terraform.tfvars, exactly as the kit describes.
#
# Shape: two cx33 (x86, 4 vCPU / 8 GB / 80 GB each, EUR 8.49/month net, fsn1):
# a control plane that also runs workloads and one fixed agent, behind a
# Hetzner lb11 (EUR 7.49), plus an autoscaler pool that idles at 0 and may add
# ONE more cx33 under pressure.
#
# One architecture, x86 (decided 2026-10-04). Chosen over waiting for cx43
# (8 vCPU / 16 GB, EUR 15.99, out of stock in every EU location 2026-10-03/04)
# because cx33 was in stock (fsn1 only, 2026-10-04 08:43 UTC, so the cluster and
# its buckets moved from hel1 to fsn1); same total RAM in two pieces, ~EUR 1.50/month more.
# Trade-offs accepted 2026-10-04 (TRONGATE-CLOUD.md section 1): the control
# plane stays a cx33 (changing its type may replace it, and a single etcd
# member replaced is a rebuild), 80 GB disk per node, volumes attach to one node.
#
# Growing out of this, in order of cost:
#   - autoscaler_max_nodes > 1                     more burst capacity
#   - agent_count = 1, allow_scheduling... = false  a fixed worker
#   - enable_klipper_lb = false + the LB annotations in ingress.yaml (lb11)
#   - control_plane_count = 3                       HA; grow only, never shrink

cluster_name   = "trongate-cloud"
network_region = "eu-central"

enabled_architectures = ["x86"]

control_plane_location            = "fsn1"
control_plane_server_type         = "cx33"
control_plane_count               = 1
allow_scheduling_on_control_plane = true

# k3s server + etcd measured at ~2.5 GiB outside pods on a kube-hetzner
# control plane (sampled 2026-10-04); reserve accordingly so the scheduler
# does not overcommit the node, and evict before the kernel OOM-kills.
control_plane_kubelet_args = [
  "kube-reserved=cpu=250m,memory=2048Mi,ephemeral-storage=1Gi",
  "system-reserved=cpu=250m,memory=512Mi",
  "eviction-hard=memory.available<300Mi,nodefs.available<10%",
]

# One fixed agent: workloads that must not move (MariaDB and Valkey volumes,
# Traefik's second replica) and the bulk of the apps.
agent_location    = "fsn1"
agent_server_type = "cx33"
agent_count       = 1
agent_kubelet_args = [
  "kube-reserved=cpu=50m,memory=512Mi,ephemeral-storage=1Gi",
  "system-reserved=cpu=250m,memory=512Mi",
  "eviction-hard=memory.available<300Mi,nodefs.available<10%",
]

autoscaler_location    = "fsn1"
autoscaler_server_type = "cx33"
autoscaler_max_nodes   = 1

# The commented-out fallback pool in main.tf must also be x86 if enabled.
autoscaler_fallback_location    = "nbg1"
autoscaler_fallback_server_type = "cx33"

# Hetzner lb11 in front (decided 2026-10-04): a stable address that survives
# node rebuilds, and ingress on both nodes. See ingress.yaml.
enable_klipper_lb        = false
automatically_upgrade_os = false

# Object storage in the same location as the node (free internal traffic).
object_storage_endpoint_host = "fsn1.your-objectstorage.com"
object_storage_region        = "fsn1"
etcd_snapshot_bucket         = "trongate-cloud-fsn1-etcd-snapshots"
