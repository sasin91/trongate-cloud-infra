#!/usr/bin/env python3
"""LESSON: "supported" is not "available", and availability is not static.

The provider's API distinguishes the instance types a location *supports* from
those it currently *has*. Configuration written against the former validates,
plans and applies cleanly -- then fails at the moment you need to scale, which
is by definition the worst moment. Observed on a live cluster:

    primary  pool type   supported=True   available=False
    fallback pool type   supported=True   available=False

The fallback had been added specifically to fix a scale-out failure. It named
the previous generation of a line whose current generation was in stock. Every
layer of tooling reported success, and the presence of a fallback stopped
anyone looking.

WHY THIS RUNS ON A SCHEDULE, NOT ONLY BEFORE APPLY: a pool created when its
type was in stock keeps that type in its configuration forever. Stock changes;
the configuration does not. A check that only runs in the apply path passes on
the day it is written and is never consulted again -- and the failure it exists
to catch appears months later, with no commit to attribute it to.

Corollary worth stating: treat a fallback that has never once been provisioned
as unproven, not as insurance.

SEVERITY:
  boundary -- a declared pool naming a type that is not currently available in
              its location. This is capacity-critical: the cluster cannot grow,
              and it discovers that under load.
  config   -- a type marked deprecated but still available; a pool whose
              location cannot be determined from the configuration.

CREDENTIALS: a read-only provider API token, supplied as $HCLOUD_TOKEN or
$HCLOUD_TOKEN_READ_ONLY. It is never printed, never written to a file, and
never passed on a command line. No kubeconfig and no cluster access is
involved: this check talks to the provider's API and to nothing else.
"""

import json
import os
import re
import sys
import urllib.error
import urllib.request

sys.dont_write_bytecode = True  # no __pycache__ in a repository that does not ignore it
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _common as c  # noqa: E402

LESSON = "a pool naming an unavailable type cannot scale, and nothing reports it until it must"

API_BASE = os.environ.get("HCLOUD_API_BASE", "https://api.hetzner.cloud/v1")
POOL_LISTS = (
    "control_plane_nodepools",
    "agent_nodepools",
    "autoscaler_nodepools",
    # Where the pools are actually authored before being mapped into the
    # module's inputs. Reading only the module inputs would find a `for`
    # comprehension and no instance types at all.
    "autoscaler_pools",
    "nodepools",
)

REFERENCE = re.compile(r"^(var|local)\.([A-Za-z_][\w-]*)$")
# Any other dotted expression: an iteration variable in a `for` comprehension,
# a module output, a data source. A list built by re-mapping another list is
# not a second declaration, and the list it re-maps is scanned in its own right.
OTHER_REFERENCE = re.compile(r"^[A-Za-z_][\w-]*\.[\w.\[\]\"-]+$")
REMAPPED = "re-mapped from another list"
SCALAR_ASSIGNMENT = re.compile(
    r'(?m)^\s*([A-Za-z_][\w-]*)\s*=\s*("([^"]*)"|[0-9]+(?:\.[0-9]+)?)\s*$'
)


def token():
    for name in ("HCLOUD_TOKEN_READ_ONLY", "HCLOUD_TOKEN", "HCLOUD_API_TOKEN"):
        value = os.environ.get(name)
        if value:
            return value.strip(), name
    return None, None


def api_get(path, secret):
    """GET a paginated collection. The token goes in a header and nowhere else."""
    results = []
    page = 1
    while True:
        url = "%s%s%spage=%d&per_page=50" % (
            API_BASE,
            path,
            "&" if "?" in path else "?",
            page,
        )
        request = urllib.request.Request(
            url,
            headers={
                "Authorization": "Bearer %s" % secret,
                "User-Agent": "hcloud-k3s-platform-kit/checks",
                "Accept": "application/json",
            },
        )
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                payload = json.load(response)
        except urllib.error.HTTPError as exc:
            if exc.code in (401, 403):
                raise RuntimeError(
                    "the provider rejected the API token (HTTP %d). Check the secret; a "
                    "read-only token is sufficient." % exc.code
                )
            raise RuntimeError("provider API returned HTTP %d for %s" % (exc.code, path))
        except urllib.error.URLError as exc:
            raise RuntimeError("could not reach the provider API: %s" % exc.reason)
        key = [k for k in payload if k not in ("meta",)]
        results.extend(payload[key[0]])
        pagination = (payload.get("meta") or {}).get("pagination") or {}
        if not pagination.get("next_page"):
            return results
        page = pagination["next_page"]


def config_files(root):
    """Every file that can hold a pool declaration or the values it references.

    `terraform.tfvars` is gitignored -- it holds credentials -- so the values a
    fork actually commits live in `terraform.tfvars.example`. A check that read
    only `.tf` would resolve every instance type to the string
    "var.something", find nothing to verify, and pass.
    """
    paths = list(c.hcl_files(root))
    for path in c.iter_files(root, (".tfvars.example", ".tfvars.sample")):
        if path not in paths:
            paths.append(path)
    return paths


def symbol_table(root):
    """{('var'|'local', name): (value, source_path)} for scalar values.

    Precedence: a real .tfvars (a fork's own values) beats the committed
    example, which beats a variable's default.
    """
    table = {}

    def put(kind, name, value, path, rank):
        key = (kind, name)
        if key not in table or rank > table[key][2]:
            table[key] = (value, path, rank)

    for path in config_files(root):
        text = c.strip_hcl_comments(c.read_text(path))

        for header, block, _ in c.hcl_blocks(text, r'(?m)^\s*variable\s+"[^"]+"'):
            name = header.split('"')[1] if '"' in header else None
            default = c.hcl_attr(block, "default")
            if name and default is not None and not default.startswith(("[", "{")):
                put("var", name, default, path, 0)

        for _, block, _ in c.hcl_blocks(text, r"(?m)^\s*locals\s*"):
            for match in SCALAR_ASSIGNMENT.finditer(block):
                put("local", match.group(1), match.group(3) or match.group(2), path, 1)

        if path.endswith((".tfvars", ".tfvars.example", ".tfvars.sample")):
            rank = 3 if path.endswith(".tfvars") else 2
            for match in SCALAR_ASSIGNMENT.finditer(text):
                put("var", match.group(1), match.group(3) or match.group(2), path, rank)

    return {key: value[:2] for key, value in table.items()}


def resolve(value, table):
    """(resolved_value, source) -- or (None, reason) when it cannot be resolved."""
    if value is None:
        return None, "not declared"
    text = str(value).strip()
    match = REFERENCE.match(text)
    if not match:
        if OTHER_REFERENCE.match(text):
            return None, REMAPPED
        return value, "literal"
    kind, name = match.group(1), match.group(2)
    if (kind, name) in table:
        resolved, source = table[(kind, name)]
        # One more hop: a tfvars value is occasionally itself a reference.
        again = REFERENCE.match(str(resolved).strip())
        if again and (again.group(1), again.group(2)) in table:
            resolved, source = table[(again.group(1), again.group(2))]
        return resolved, source
    return None, "%s.%s has no value this check can resolve" % (kind, name)


def declared_pools(root):
    """(pools, unresolved) -- pools carry resolved types and locations."""
    table = symbol_table(root)
    pools = []
    unresolved = []
    seen = set()
    for path in config_files(root):
        text = c.strip_hcl_comments(c.read_text(path))
        for list_name in POOL_LISTS:
            for obj in c.hcl_objects(text, list_name):
                raw_type = obj.get("server_type")
                if not raw_type:
                    continue
                server_type, type_source = resolve(raw_type, table)
                location, location_source = resolve(obj.get("location"), table)
                name, _ = resolve(obj.get("name"), table)
                if server_type is None:
                    unresolved.append((path, obj.get("_line"), raw_type, type_source))
                    continue
                key = (str(name), str(server_type), str(location))
                if key in seen:
                    continue
                seen.add(key)
                pools.append(
                    {
                        "list": list_name,
                        "name": name or "<unnamed>",
                        "server_type": server_type,
                        "location": location,
                        "location_reason": location_source,
                        # WHERE THE VALUE CAME FROM, which is often not where the
                        # pool is declared. A tfvars file outranks a variable
                        # default, so a failure message naming only the
                        # declaration site sends you to edit a file that does not
                        # contain the offending value.
                        "type_source": type_source,
                        "path": path,
                        "line": obj.get("_line"),
                    }
                )
    return pools, unresolved


def body(check):
    require_token = "--require-token" in sys.argv
    pools, unresolved = declared_pools(check.root)

    if not pools and not unresolved:
        check.skip("no nodepools declared yet (a commented-out pool declares nothing)")
        return

    if not pools and unresolved:
        # The failure this whole check exists to prevent is a check that runs,
        # reports success, and verified nothing. Say so loudly instead.
        path, line, raw, reason = unresolved[0]
        check.boundary(
            "pool declarations were found but no instance type could be resolved from them "
            "(%s: %s) -- this check would otherwise pass while verifying nothing"
            % (raw, reason),
            path,
            line,
        )
        return

    for path, line, raw, reason in unresolved:
        if reason == REMAPPED:
            continue  # the list it re-maps is checked where it is declared
        check.report(
            "pool entry references %s, which this check cannot resolve (%s); its availability "
            "is unverified" % (raw, reason),
            path,
            line,
        )

    secret, source = token()
    if not secret:
        message = (
            "no provider API token in the environment (HCLOUD_TOKEN_READ_ONLY or "
            "HCLOUD_TOKEN); cannot check availability"
        )
        if require_token:
            check.boundary(message + " -- and --require-token was given")
            return
        check.skip(message)
        return
    check.note("using a provider API token from $%s (read-only is sufficient)" % source)

    # Availability per location comes from the server types themselves:
    # each lists `locations[]` with an `available` flag. The provider retired
    # /v1/datacenters (HTTP 410 since 2026), which is where this check used to
    # read `server_types.available` / `.supported`. A location present in a
    # type's list is "supported"; `available` is the stock flag.
    server_types = api_get("/server_types", secret)
    locations = {item["name"].lower() for item in api_get("/locations", secret)}

    by_name = {item["name"].lower(): item for item in server_types}

    available = {location: set() for location in locations}
    supported = {location: set() for location in locations}
    for server_type in server_types:
        for entry in server_type.get("locations") or []:
            location = str(entry.get("name", "")).lower()
            supported.setdefault(location, set()).add(server_type["id"])
            if entry.get("available"):
                available.setdefault(location, set()).add(server_type["id"])

    for pool in pools:
        label = "%s pool %r" % (pool["list"], pool["name"])
        origin = pool.get("type_source")
        if origin and origin != pool["path"]:
            label += " (type from %s)" % origin
        type_name = str(pool["server_type"]).lower()
        location = pool["location"]

        if not location:
            check.report(
                "%s declares no location this check can resolve; availability unverified" % label,
                pool["path"],
                pool["line"],
            )
            continue

        server_type = by_name.get(type_name)
        if server_type is None:
            check.boundary(
                "%s names instance type %r, which the provider does not list at all"
                % (label, pool["server_type"]),
                pool["path"],
                pool["line"],
            )
            continue

        location = str(location).lower()
        if location not in available:
            check.boundary(
                "%s names location %r, which the provider does not list" % (label, location),
                pool["path"],
                pool["line"],
            )
            continue

        type_id = server_type["id"]
        if type_id in available[location]:
            if server_type.get("deprecated") or server_type.get("deprecation"):
                check.report(
                    "%s names %r in %s: available, but the provider marks it deprecated"
                    % (label, server_type["name"], location),
                    pool["path"],
                    pool["line"],
                )
            else:
                check.note("%s: %s in %s is available" % (label, server_type["name"], location))
            continue

        if type_id in supported.get(location, set()):
            check.boundary(
                "%s names %r in %s: supported=True available=False. It plans and applies "
                "cleanly and cannot be provisioned when capacity is needed"
                % (label, server_type["name"], location),
                pool["path"],
                pool["line"],
            )
        else:
            check.boundary(
                "%s names %r in %s: neither supported nor available there"
                % (label, server_type["name"], location),
                pool["path"],
                pool["line"],
            )

    check.note("inspected %d declared pool(s)" % len(pools))


if __name__ == "__main__":
    c.main("pool-availability", LESSON, __doc__, body)
