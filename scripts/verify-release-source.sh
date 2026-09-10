#!/usr/bin/env bash
set -euo pipefail

# Read-only preflight. Prints the verified commit for release metadata.
release_tag="${1:?Usage: verify-release-source.sh TAG}"
git check-ref-format "refs/tags/$release_tag" >/dev/null || { echo 'error: Invalid release tag.' >&2; exit 1; }
[[ -z "$(git status --porcelain --untracked-files=normal)" ]] || { echo 'error: Release requires a clean working tree, including untracked files.' >&2; exit 1; }
release_commit="$(git rev-parse --verify "refs/tags/$release_tag^{commit}")" || { echo 'error: Create the release tag before building.' >&2; exit 1; }
[[ "$release_commit" == "$(git rev-parse HEAD)" ]] || { echo 'error: HEAD must equal the release tag commit.' >&2; exit 1; }
printf '%s\n' "$release_commit"
