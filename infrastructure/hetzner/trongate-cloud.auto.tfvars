# TRONGATE-CLOUD single-node profile. Loaded automatically by `tofu plan/apply`.
#
# COMMITTED ON PURPOSE, and therefore NO SECRETS IN THIS FILE: it is the one
# *.tfvars the .gitignore lets through. Tokens, keys, the state passphrase and
# registries_config come from the environment (TF_VAR_...) or the gitignored
# terraform.tfvars, exactly as the kit describes.
#
# Shape: one CAX31 (arm64, 8 vCPU / 16 GB / 160 GB, EUR 20.99/month net,
# hel1) that is both control plane and worker, Traefik on the node's own IPv4
# via k3s servicelb (no Hetzner LB), and an autoscaler pool that idles at 0 and
# may add ONE more CAX31 under pressure.
#
# Why ARM, observed 2026-10-03 in fsn1/nbg1/hel1:
#   cax31  arm  8 vCPU / 16 GB  EUR 20.99  available       <- this file
#   cx43   x86  8 vCPU / 16 GB  EUR 15.99  UNAVAILABLE everywhere
#   cpx42  x86  8 vCPU / 16 GB  EUR 69.49  available
# Every image the cluster runs publishes linux/arm64 (TRONGATE-CLOUD.md, 3).
# Moving to x86 later: enabled_architectures = ["x86"] and every *_server_type
# below; a type change replaces the server.
#
# Growing out of this, in order of cost:
#   - autoscaler_max_nodes > 1                     more burst capacity
#   - agent_count = 1, allow_scheduling... = false  a fixed worker
#   - enable_klipper_lb = false + the LB annotations in ingress.yaml (lb11)
#   - control_plane_count = 3                       HA; grow only, never shrink

cluster_name   = "trongate-cloud"
network_region = "eu-central"

enabled_architectures = ["arm"]

control_plane_location            = "hel1"
control_plane_server_type         = "cax31"
control_plane_count               = 1
allow_scheduling_on_control_plane = true

# No fixed agents. The type is still declared (and arm) because the module
# validates every pool's architecture, populated or not.
agent_location    = "hel1"
agent_server_type = "cax31"
agent_count       = 0

autoscaler_location    = "hel1"
autoscaler_server_type = "cax31"
autoscaler_max_nodes   = 1

# The commented-out fallback pool in main.tf must also be arm if enabled.
autoscaler_fallback_location    = "fsn1"
autoscaler_fallback_server_type = "cax31"

enable_klipper_lb        = true
automatically_upgrade_os = false

# Object storage in the same location as the node (free internal traffic).
object_storage_endpoint_host = "hel1.your-objectstorage.com"
object_storage_region        = "hel1"
etcd_snapshot_bucket         = "trongate-cloud-etcd-snapshots"
