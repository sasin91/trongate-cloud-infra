#!/usr/bin/env python3
"""LESSON: an unpinned dependency is a latent breaking change.

A module, chart, base, image or action referenced without an explicit version
constraint means the next upgrade can cross a major version boundary without a
line changing in this repository -- renamed variables, reshaped inputs, a
raised minimum tool version, all in one tag. Every floating default observed
while building this kit resolved to a mutable tag polled on an interval.

SEVERITY: boundary. A reference that can change underneath you is not standing
configuration, it is an open door to code you have not read.
Unbounded-but-present constraints (">= 2.0" with no upper bound) report rather
than fail: a constraint exists, it is simply wider than it looks.
"""

import os
import re
import sys

sys.dont_write_bytecode = True  # no __pycache__ in a repository that does not ignore it
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _common as c  # noqa: E402

LESSON = "an unpinned reference is a latent breaking change -- pin it"

MUTABLE_REFS = {"main", "master", "trunk", "head", "latest", "stable", "develop", "dev"}
LOCAL_PREFIXES = ("./", "../", "/")
SHA_RE = re.compile(r"^[0-9a-f]{40}$|^[0-9a-f]{64}$")
FLOATING_MAJOR_RE = re.compile(r"^v?\d+$")
TEMPLATED_RE = re.compile(r"\{\{|\$\{|\$\(")


def unbounded(constraint):
    """A constraint with a floor and no ceiling still admits the next major."""
    if not constraint:
        return False
    text = constraint.strip()
    if "<" in text or "~>" in text or text.startswith("="):
        return False
    return text.startswith(">") or text == "*"


def check_hcl(check):
    found = 0
    for path in c.hcl_files(check.root):
        text = c.strip_hcl_comments(c.read_text(path))

        for header, block, line in c.hcl_blocks(text, r'(?m)^\s*module\s+"[^"]+"'):
            found += 1
            name = header.split('"')[1] if '"' in header else header
            source = c.hcl_attr(block, "source")
            version = c.hcl_attr(block, "version")
            if not source:
                check.report("module %r declares no source" % name, path, line)
                continue
            if source.startswith(LOCAL_PREFIXES):
                continue  # a local module is versioned by this repository
            if source.startswith(("git::", "git@")) or ".git" in source:
                ref = source.split("?ref=")[1].split("&")[0] if "?ref=" in source else None
                if not ref:
                    check.boundary(
                        "module %r has a git source with no ?ref= constraint: %s" % (name, source),
                        path,
                        line,
                    )
                elif ref.lower() in MUTABLE_REFS:
                    check.boundary(
                        "module %r is pinned to the mutable ref %r" % (name, ref), path, line
                    )
                continue
            if not version:
                check.boundary(
                    "module %r references the registry source %s with no version constraint"
                    % (name, source),
                    path,
                    line,
                )
            elif unbounded(version):
                check.report(
                    "module %r constraint %r has no upper bound" % (name, version), path, line
                )

        for _, block, line in c.hcl_blocks(text, r"(?m)^\s*required_providers\s*"):
            for name, inner in re.findall(r"([A-Za-z_][\w-]*)\s*=\s*\{([^}]*)\}", block):
                found += 1
                version = c.hcl_attr(inner, "version") or (
                    re.search(r'version\s*=\s*"([^"]*)"', inner).group(1)
                    if re.search(r'version\s*=\s*"([^"]*)"', inner)
                    else None
                )
                if not version:
                    check.boundary("provider %r has no version constraint" % name, path, line)
                elif unbounded(version):
                    check.report(
                        "provider %r constraint %r has no upper bound" % (name, version), path, line
                    )
    return found


def check_flux_and_kustomize(check):
    found = 0
    for parsed, doc in c.yaml_documents(check.root):
        kind = c.kind_of(doc)
        name = c.name_of(doc) or "<unnamed>"
        api = c.api_of(doc) or ""

        if kind == "HelmRelease":
            found += 1
            version = c.get(doc, "spec", "chart", "spec", "version")
            chart_ref = c.get(doc, "spec", "chartRef")
            if version is None and chart_ref is None:
                check.boundary(
                    "HelmRelease %r declares no chart version" % name,
                    parsed.path,
                    parsed.line_of("chart"),
                )
            elif isinstance(version, str) and (version == "*" or unbounded(version)):
                check.report(
                    "HelmRelease %r chart version %r has no upper bound" % (name, version),
                    parsed.path,
                    parsed.line_of("version"),
                )

        if kind == "HelmChart":
            found += 1
            if c.get(doc, "spec", "version") is None:
                check.boundary(
                    "HelmChart %r declares no version" % name, parsed.path, parsed.line_of("spec")
                )

        if kind == "OCIRepository":
            found += 1
            ref = c.get(doc, "spec", "ref") or {}
            if isinstance(ref, dict):
                tag = ref.get("tag")
                if ref.get("digest"):
                    pass
                elif isinstance(tag, str) and tag.lower() in MUTABLE_REFS:
                    check.boundary(
                        "OCIRepository %r follows the mutable tag %r" % (name, tag),
                        parsed.path,
                        parsed.line_of("tag"),
                    )
                elif not tag and not ref.get("semver"):
                    check.boundary(
                        "OCIRepository %r has no tag, semver or digest constraint" % name,
                        parsed.path,
                        parsed.line_of("ref"),
                    )

        if kind == "GitRepository":
            found += 1
            ref = c.get(doc, "spec", "ref") or {}
            if isinstance(ref, dict) and ref.get("branch") and not ref.get("commit"):
                # The cluster's own sync source legitimately follows a branch.
                check.report(
                    "GitRepository %r follows branch %r; it moves under you"
                    % (name, ref.get("branch")),
                    parsed.path,
                    parsed.line_of("branch"),
                )

        if kind == "Kustomization" and api.startswith("kustomize.config.k8s.io"):
            found += 1
            entries = []
            for key in ("resources", "bases", "components"):
                value = doc.get(key)
                if isinstance(value, list):
                    entries.extend((key, item) for item in value if isinstance(item, str))
            for key, entry in entries:
                remote = (
                    "://" in entry
                    or entry.startswith(("github.com/", "git@", "gitlab.com/", "bitbucket.org/"))
                )
                if not remote:
                    continue
                if "?ref=" in entry or "?version=" in entry:
                    ref = re.split(r"\?(?:ref|version)=", entry)[1].split("&")[0]
                    if ref.lower() in MUTABLE_REFS:
                        check.boundary(
                            "%s entry pinned to the mutable ref %r: %s" % (key, ref, entry),
                            parsed.path,
                            c.find_line(parsed.text, entry),
                        )
                else:
                    check.boundary(
                        "remote %s entry has no ?ref= constraint: %s" % (key, entry),
                        parsed.path,
                        c.find_line(parsed.text, entry),
                    )
            charts = doc.get("helmCharts")
            if isinstance(charts, list):
                for chart in charts:
                    if isinstance(chart, dict) and not chart.get("version"):
                        check.boundary(
                            "helmCharts entry %r has no version" % chart.get("name", "<unnamed>"),
                            parsed.path,
                            parsed.line_of("helmCharts"),
                        )

        # Container images: an implicit or mutable tag is the same failure.
        #
        # One exception, and it is a real one: an upgrade Plan names an image
        # with no tag on purpose, because the controller appends the version it
        # resolved from the plan's channel or version field. Pinning a tag
        # there freezes every node while the plan goes on reporting success --
        # an upgrade that appears to be happening. The version constraint
        # exists; it is one field away from the image.
        if kind == "Plan" and api.startswith("upgrade.cattle.io"):
            if c.get(doc, "spec", "channel") or c.get(doc, "spec", "version"):
                continue

        # TRONGATE-CLOUD: an ImageRepository's image is the repository Flux
        # scans for tags, never something that runs; its ImagePolicy decides
        # the tag, and the setter writes it into a pinned newTag.
        if kind == "ImageRepository" and api.startswith("image.toolkit.fluxcd.io"):
            continue

        for path_tuple, value in c.walk(doc):
            if not path_tuple or path_tuple[-1] != "image" or not isinstance(value, str):
                continue
            if TEMPLATED_RE.search(value):
                continue
            found += 1
            last = value.rsplit("/", 1)[-1]
            if "@" in value:
                continue  # digest-pinned
            if ":" not in last:
                check.boundary(
                    "image %r has no tag, so it follows :latest" % value,
                    parsed.path,
                    c.find_line(parsed.text, value),
                )
            elif last.rsplit(":", 1)[1].lower() in MUTABLE_REFS:
                check.boundary(
                    "image %r follows a mutable tag" % value,
                    parsed.path,
                    c.find_line(parsed.text, value),
                )
    return found


def check_actions(check):
    workflows = os.path.join(check.root, ".github", "workflows")
    if not os.path.isdir(workflows):
        return 0
    found = 0
    for path in c.iter_files(workflows, c.YAML_SUFFIXES):
        text = c.read_text(path)
        for number, line in enumerate(text.splitlines(), 1):
            match = re.search(r"^\s*(?:-\s*)?uses:\s*['\"]?([^'\"\s]+)", line)
            if not match:
                continue
            uses = match.group(1)
            if uses.startswith(("./", "../")):
                continue
            found += 1
            if "@" not in uses:
                check.boundary("action %r has no version reference" % uses, path, number)
                continue
            ref = uses.rsplit("@", 1)[1]
            if ref.lower() in MUTABLE_REFS:
                check.boundary("action %r follows a mutable ref" % uses, path, number)
            elif FLOATING_MAJOR_RE.match(ref):
                check.report(
                    "action %r is pinned to a floating major tag; the tag is moved by its owner"
                    % uses,
                    path,
                    number,
                )
    return found


def body(check):
    found = check_hcl(check) + check_flux_and_kustomize(check) + check_actions(check)
    if found == 0:
        check.skip("no module, chart, base, image or action references found yet")
    else:
        check.note("inspected %d reference(s)" % found)


if __name__ == "__main__":
    c.main("version-pins", LESSON, __doc__, body)
