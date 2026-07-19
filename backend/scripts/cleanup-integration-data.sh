#!/usr/bin/env bash
#
# Deletes residue left by the live integration suite (MoomoIntegrationTests) and
# by any app run against moomo-c7a37.
#
# Why this exists rather than the tests cleaning up after themselves:
# `firestore.rules` sets `allow delete: if false` on users/{uid} and
# publicProfiles/{uid} on purpose — a real account deletion has to remove photos,
# messages and call history too, so it belongs to a server-side job that does not
# exist yet. A client, including a test client, therefore cannot delete its own
# documents. Deleting the Firebase Auth account does NOT cascade to Firestore.
#
# So cleanup runs here, with admin credentials, out of band.
#
# Usage:
#   ./cleanup-integration-data.sh            # dry run: list what would go
#   ./cleanup-integration-data.sh --confirm  # actually delete
#
# Refuses to run against anything but moomo-c7a37.

set -euo pipefail

PROJECT="moomo-c7a37"
BASE="https://firestore.googleapis.com/v1/projects/${PROJECT}/databases/(default)/documents"
DRY_RUN=1
[[ "${1:-}" == "--confirm" ]] && DRY_RUN=0

# This project has never shipped, so every account in it is a test artifact.
# The guard is here anyway: if this is ever pointed at a project with real
# users, it must not be the thing that deletes them.
if [[ "$PROJECT" != "moomo-c7a37" ]]; then
  echo "Refusing: this script only ever targets moomo-c7a37." >&2
  exit 1
fi

TOKEN="$(gcloud auth print-access-token 2>/dev/null)"
AUTH=(-H "Authorization: Bearer ${TOKEN}" -H "X-Goog-User-Project: ${PROJECT}")

if (( DRY_RUN )); then
  echo "DRY RUN — nothing will be deleted. Re-run with --confirm to delete."
else
  echo "DELETING integration residue from ${PROJECT}."
fi
echo

delete_collection() {
  local collection="$1"
  echo "=== ${collection} ==="
  local names
  names="$(curl -s "${AUTH[@]}" "${BASE}/${collection}?pageSize=300" \
    | python3 -c "import sys,json;[print(d['name']) for d in json.load(sys.stdin).get('documents',[])]")"

  if [[ -z "$names" ]]; then
    echo "  (empty)"
    return
  fi

  while IFS= read -r name; do
    local id="${name##*/}"
    if (( DRY_RUN )); then
      echo "  would delete ${collection}/${id}"
      continue
    fi
    # The onboarding draft is a subcollection; deleting the parent leaves it
    # orphaned, so it goes first.
    curl -s -o /dev/null -X DELETE "${AUTH[@]}" \
      "${BASE}/${collection}/${id}/private/onboarding" || true
    local code
    code="$(curl -s -o /dev/null -w "%{http_code}" -X DELETE "${AUTH[@]}" "${BASE}/${collection}/${id}")"
    echo "  deleted ${collection}/${id} -> HTTP ${code}"
  done <<< "$names"
}

delete_collection users
delete_collection publicProfiles

echo
echo "=== auth accounts ==="
ACCOUNTS="$(curl -s "${AUTH[@]}" \
  "https://identitytoolkit.googleapis.com/v1/projects/${PROJECT}/accounts:batchGet?maxResults=500" \
  | python3 -c "import sys,json;[print(u['localId']) for u in json.load(sys.stdin).get('users',[])]")"

if [[ -z "$ACCOUNTS" ]]; then
  echo "  (none)"
else
  while IFS= read -r localid; do
    if (( DRY_RUN )); then
      echo "  would delete auth user ${localid}"
      continue
    fi
    code="$(curl -s -o /dev/null -w "%{http_code}" -X POST "${AUTH[@]}" \
      -H "Content-Type: application/json" -d "{\"localId\":\"${localid}\"}" \
      "https://identitytoolkit.googleapis.com/v1/projects/${PROJECT}/accounts:delete")"
    echo "  deleted auth user ${localid} -> HTTP ${code}"
  done <<< "$ACCOUNTS"
fi

echo
(( DRY_RUN )) && echo "Dry run complete." || echo "Cleanup complete."
