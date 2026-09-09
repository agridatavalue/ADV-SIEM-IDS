#!/usr/bin/env bash
# Remove the IDS connectors from a cluster.
#
#   ./teardown.sh --context <kube-context> [--namespace ids] [--yes]
#   ./teardown.sh --context <ctx> --delete-data      # ALSO deletes the databases
#
# This uninstalls the Helm release. It does NOT delete the cluster or the
# namespace — this runs against real clusters that host other things.
#
# The database PVCs carry helm.sh/resource-policy: keep, so they survive by
# design. --delete-data removes them, which destroys every asset, agreement and
# transfer record. There is no undo.
set -euo pipefail

export PATH="$HOME/.local/bin:$PATH"

CTX=""
NS="ids"
RELEASE="sovity-ui-connector"
DELETE_DATA=0
ASSUME_YES=0

while [ $# -gt 0 ]; do
  case "$1" in
    --context)     CTX="${2:-}"; shift 2 ;;
    --namespace)   NS="${2:-}"; shift 2 ;;
    --delete-data) DELETE_DATA=1; shift ;;
    --yes)         ASSUME_YES=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done

die() { echo "ERROR: $*" >&2; exit 1; }
[ -n "$CTX" ] || die "--context is required (refusing to guess which cluster to tear down)"
kubectl config get-contexts -o name 2>/dev/null | grep -qx "$CTX" \
  || die "context '$CTX' not found in your kubeconfig"

K="kubectl --context $CTX -n $NS"

echo "target cluster : $(kubectl --context "$CTX" config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null)"
echo "context        : $CTX"
echo "namespace      : $NS"
echo "release        : $RELEASE"
if [ "$DELETE_DATA" -eq 1 ]; then
  echo
  echo "*** --delete-data given: the database volumes will be DESTROYED ***"
  $K get pvc 2>/dev/null | sed 's/^/    /'
fi

if [ "$ASSUME_YES" -ne 1 ]; then
  printf '\nProceed? [y/N] '
  read -r reply
  case "$reply" in y|Y|yes) ;; *) echo "aborted"; exit 1 ;; esac
fi

echo
echo "=== helm release ==="
helm --kube-context "$CTX" -n "$NS" uninstall "$RELEASE" 2>&1 | sed 's/^/  /' || true

echo
echo "=== what remains ==="
$K get all 2>/dev/null | sed 's/^/  /' || echo "  nothing"
echo "  --- PVCs (kept unless --delete-data) ---"
$K get pvc 2>/dev/null | sed 's/^/  /' || echo "  none"

if [ "$DELETE_DATA" -eq 1 ]; then
  echo
  echo "=== deleting database volumes ==="
  for pvc in postgres-pvc postgres-provider-pvc; do
    $K delete pvc "$pvc" --ignore-not-found 2>&1 | sed 's/^/  /'
  done
fi

echo
echo "The namespace '$NS' and the cluster itself are untouched."
