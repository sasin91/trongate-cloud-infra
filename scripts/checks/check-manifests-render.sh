#!/bin/sh
# LESSON: a manifest that does not render is a rollout that fails at 3am, not at review.
#
# Everything else in this directory reads the repository as text. This check is
# the one that asks whether the text is actually a set of manifests: every
# kustomization builds, and every document it emits validates against the
# schema for its API version. A typo in a field name is accepted by YAML,
# accepted by kustomize, and silently ignored by the API server -- the object
# applies, the setting does not exist, and nothing anywhere reports it.
#
# SEVERITY: boundary. A repository that does not render is not standing
# configuration in any state -- it is a rollout that will half-apply.
#
# Tools: kustomize (or kubectl) and kubeconform. Both are installed by the
# workflow. Locally, a missing tool SKIPS rather than fails, so a contributor
# without them can still run every other check.
#
# POSIX sh: no bashisms, so this runs the same in CI and on a developer machine.

set -u

NAME="manifests-render"
ROOT="${REPO_ROOT:-$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)}"
STRICT_UNKNOWN="${KUBECONFORM_STRICT:-1}"
status=0
built=0
failed=0

say() { printf '[%s] %s\n' "$NAME" "$*"; }
fail() {
    printf '[%s] FAIL (boundary): %s\n' "$NAME" "$*"
    if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
        printf '::error title=%s (boundary)::%s\n' "$NAME" "$*"
    fi
    failed=$((failed + 1))
    status=1
}

# -- tools ------------------------------------------------------------------

if command -v kustomize >/dev/null 2>&1; then
    BUILD="kustomize build --enable-helm"
elif command -v kubectl >/dev/null 2>&1; then
    BUILD="kubectl kustomize"
else
    say "SKIP: neither kustomize nor kubectl is installed"
    say "RESULT: SKIP -- 0 boundary failure(s), 0 report(s)"
    exit 0
fi

if command -v kubeconform >/dev/null 2>&1; then
    VALIDATE="kubeconform -summary -ignore-missing-schemas"
    if [ "$STRICT_UNKNOWN" = "1" ]; then
        VALIDATE="$VALIDATE -strict"
    fi
else
    VALIDATE=""
    say "note: kubeconform is not installed; manifests will be built but not schema-validated"
fi

# -- targets ----------------------------------------------------------------

targets=$(find "$ROOT" \
    -type d \( -name .git -o -name .terraform -o -name node_modules -o -name vendor \) -prune -o \
    -type f \( -name kustomization.yaml -o -name kustomization.yml \) -print | sort)

if [ -z "$targets" ]; then
    say "SKIP: no kustomizations in the repository yet"
    say "RESULT: SKIP -- 0 boundary failure(s), 0 report(s)"
    exit 0
fi

tmp="${TMPDIR:-/tmp}/checks-render.$$"
list="$tmp.list"
trap 'rm -f "$tmp" "$tmp.err" "$list"' EXIT INT TERM
printf '%s\n' "$targets" >"$list"

# Read from a file rather than a pipe: a `while` loop on the right of a pipe
# runs in a subshell, and every failure counted inside it would be discarded on
# the way out -- a check that reports PASS having found problems.
while IFS= read -r file; do
    [ -n "$file" ] || continue
    dir=$(dirname "$file")
    rel=${dir#"$ROOT"/}

    # A Component is a fragment: it is built by whatever includes it, never alone.
    if grep -qE '^kind:[[:space:]]*Component[[:space:]]*$' "$file" 2>/dev/null; then
        say "note: $rel is a Component; built through its consumers"
        continue
    fi

    if ! $BUILD "$dir" >"$tmp" 2>"$tmp.err"; then
        fail "$rel does not build: $(tr '\n' ' ' <"$tmp.err" | cut -c1-400)"
        continue
    fi
    built=$((built + 1))

    if [ -n "$VALIDATE" ]; then
        # SOPS-encrypted files carry a top-level `sops:` metadata block that
        # kustomize-controller strips while decrypting. It is not part of any
        # Kubernetes schema, so -strict rejects every encrypted Secret unless
        # it is removed here first, the same way the cluster sees it.
        if ! awk '/^sops:/ { skip = 1; next } skip && /^[^ ]/ { skip = 0 } !skip' "$tmp"             | $VALIDATE - >"$tmp.err" 2>&1; then
            fail "$rel builds but does not validate: $(tr '\n' ' ' <"$tmp.err" | cut -c1-400)"
        fi
    fi
done <"$list"

say "note: built $built kustomization(s)"
if [ "$status" -eq 0 ]; then
    say "RESULT: PASS -- 0 boundary failure(s), 0 report(s)"
else
    say "RESULT: FAIL -- $failed boundary failure(s), 0 report(s)"
    say "lesson: a manifest that does not render is a rollout that half-applies"
fi
exit "$status"
