#!/usr/bin/env python3
"""LESSON: a workaround outlives its cause, and the ingress is where it hurts.

An ingress controller running its own ACME client has to be pinned to a single
replica, because replicas race each other over locally stored certificate
state. Once certificate issuance moves to a controller that stores into
Secrets, that reason is gone -- but the single replica usually stays, and so
does the PodDisruptionBudget that was disabled because a single replica made it
pointless. The most traffic-critical component in the cluster ends up a single
point of failure in exchange for a problem nobody has any more.

A cluster that applies unattended OS updates drains nodes, and a drain evicts
pods that have no disruption budget protecting them.

SEVERITY:
  boundary -- fewer than two replicas, or no disruption budget. Both are the
              difference between a node drain being routine and being an
              outage, and both are the residue of a removed constraint.
  config   -- no anti-affinity or topology spread. Standing configuration: the
              replicas exist, they may simply share a node.
"""

import os
import re
import sys

sys.dont_write_bytecode = True  # no __pycache__ in a repository that does not ignore it
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _common as c  # noqa: E402

LESSON = "when you remove a cause, go and hunt its effects -- the ingress kept both"

# TRONGATE-CLOUD: a single-node cluster cannot hold two ingress replicas. A
# comment "# ingress-ha waiver: <reason>" in the declaring file downgrades the
# replica and disruption-budget findings from boundary to report -- the same
# recorded-reason pattern check-prune-enabled.py uses. Remove the waiver when
# the second node arrives.
WAIVER = re.compile(r"#\s*ingress-ha waiver:\s*\S")

REPLICA_KEYS = ("replicas", "replicaCount")
PDB_KEYS = ("podDisruptionBudget", "poddisruptionbudget", "pdb")
SPREAD_KEYS = ("affinity", "topologySpreadConstraints", "podAntiAffinity")


def is_ingress_doc(doc, parsed):
    name = (c.name_of(doc) or "").lower()
    chart = c.get(doc, "spec", "chart", "spec", "chart")
    chart = chart.lower() if isinstance(chart, str) else ""
    kind = c.kind_of(doc) or ""
    if kind in ("HelmRelease", "HelmChartConfig", "Deployment", "DaemonSet"):
        if c.mentions(name, c.INGRESS_NAMES) or c.mentions(chart, c.INGRESS_NAMES):
            return True
    return False


def first_number(node, keys):
    for dotted, value in c.find_values(node, keys):
        if isinstance(value, bool):
            continue
        if isinstance(value, int):
            return dotted, value
        if isinstance(value, str) and value.strip().isdigit():
            return dotted, int(value.strip())
    return None, None


def pdb_declared(node, text):
    for _, value in c.find_values(node, PDB_KEYS):
        if isinstance(value, dict):
            enabled = value.get("enabled")
            if enabled is False:
                return False
            return True
        if value is True:
            return True
        if value is False:
            return False
    lowered = text.lower()
    if "poddisruptionbudget" in lowered:
        return True
    return None


def body(check):
    docs = list(c.yaml_documents(check.root))
    ingress_docs = [(parsed, doc) for parsed, doc in docs if is_ingress_doc(doc, parsed)]

    standalone_pdbs = [
        (parsed, doc) for parsed, doc in docs if c.kind_of(doc) == "PodDisruptionBudget"
    ]

    # kube-hetzner exposes the replica count as a variable rather than a chart value.
    for path in c.hcl_files(check.root):
        text = c.strip_hcl_comments(c.read_text(path))
        for key in ("ingress_replica_count", "traefik_replica_count", "nginx_replica_count"):
            value = c.hcl_attr(text, key)
            if value is None:
                continue
            try:
                count = int(value)
            except ValueError:
                continue
            if 0 < count < 2:
                check.boundary(
                    "%s = %d -- the ingress is a single point of failure and a node drain "
                    "takes it out" % (key, count),
                    path,
                    c.find_line(text, key),
                )

    if not ingress_docs:
        check.skip("no ingress controller declaration found yet")
        return

    for parsed, doc in ingress_docs:
        name = c.name_of(doc) or "<unnamed>"
        waived = bool(WAIVER.search(parsed.text))
        flag = check.report if waived else check.boundary
        if waived:
            check.note("%s carries a recorded ingress-ha waiver; replica and PDB findings report only" % name)
        kind = c.kind_of(doc)
        node = c.helm_values(doc) if kind in ("HelmRelease", "HelmChartConfig") else doc
        if kind == "HelmChartConfig":
            # k3s ships chart values as a block of YAML inside valuesContent.
            content = c.get(doc, "spec", "valuesContent")
            if isinstance(content, str):
                node = c.YamlFile(parsed.path, content).docs[0] or {}

        # A DaemonSet runs one pod per node; a replica count does not apply.
        is_daemonset = kind == "DaemonSet" or any(
            str(value).lower() == "daemonset"
            for _, value in c.find_values(node, ("kind",))
            if isinstance(value, str)
        )

        if is_daemonset:
            check.note("%s is a DaemonSet; replica count not applicable" % name)
        else:
            dotted, count = first_number(node, REPLICA_KEYS)
            if count is None:
                flag(
                    "%s declares no replica count; every common ingress chart defaults to one"
                    % name,
                    parsed.path,
                    parsed.line_of("spec"),
                )
            elif count < 2:
                flag(
                    "%s declares %s = %d; the ingress terminates every connection passing "
                    "through it" % (name, dotted, count),
                    parsed.path,
                    c.find_line(parsed.text, dotted.split(".")[-1]),
                )

        declared = pdb_declared(node, parsed.text)
        if declared is None:
            related = [
                p
                for p, d in standalone_pdbs
                if c.mentions(str(d), c.INGRESS_NAMES) or c.mentions(c.name_of(d) or "", c.INGRESS_NAMES)
            ]
            declared = bool(related)
        if not declared:
            flag(
                "%s has no PodDisruptionBudget; an unattended-upgrade node drain evicts it "
                "without one" % name,
                parsed.path,
                parsed.line_of("spec"),
            )

        if not any(True for _ in c.find_values(node, SPREAD_KEYS)):
            check.report(
                "%s declares no anti-affinity or topology spread; its replicas may all sit on "
                "one node" % name,
                parsed.path,
                parsed.line_of("spec"),
            )

    check.note("inspected %d ingress declaration(s)" % len(ingress_docs))


if __name__ == "__main__":
    c.main("ingress-ha", LESSON, __doc__, body)
