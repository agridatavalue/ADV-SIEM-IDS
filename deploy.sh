#!/usr/bin/env bash
# Deploy the IDS connectors to an EXISTING Kubernetes cluster.
#
#   ./deploy.sh --context <kube-context> [--namespace ids] [--values chart/values.yaml]
#
# This creates no cluster and loads no images: the cluster already exists and pulls
# the connector images from ghcr.io, which are public.
#
# The target context must be named explicitly. Defaulting to whatever
# `kubectl config current-context` happens to be is how things get deployed to
# the wrong cluster.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PATH="$HOME/.local/bin:$PATH"

CTX=""
NS="ids"
VALUES="$HERE/chart/values.yaml"
RELEASE="sovity-ui-connector"
ASSUME_YES=0

while [ $# -gt 0 ]; do
  case "$1" in
    --context)   CTX="${2:-}"; shift 2 ;;
    --namespace) NS="${2:-}"; shift 2 ;;
    --values)    VALUES="${2:-}"; shift 2 ;;
    --yes)       ASSUME_YES=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done

step() { echo; echo "=============== $* ==============="; }
die()  { echo "ERROR: $*" >&2; exit 1; }

step "0. preflight"
for t in kubectl helm; do
  command -v "$t" >/dev/null 2>&1 || die "$t not found. Run ./install-tools.sh"
done
[ -n "$CTX" ] || die "--context is required. Available:
$(kubectl config get-contexts -o name 2>/dev/null | sed 's/^/    /')"
kubectl config get-contexts -o name 2>/dev/null | grep -qx "$CTX" \
  || die "context '$CTX' not found in your kubeconfig"
[ -f "$VALUES" ] || die "values file not found: $VALUES"

# Refuse to run with the shipped placeholders still in place - they would produce
# an ingress no controller claims and a database nobody can log in to.
if grep -q 'CHANGEME' "$VALUES"; then
  echo "  $VALUES still contains CHANGEME placeholders:"
  grep -n 'CHANGEME' "$VALUES" | sed 's/^/    /'
  echo "  see SECRETS.md for what each one is and how to supply it"
  die "fill these in (or pass a different --values) before deploying"
fi

echo "  target cluster : $(kubectl --context "$CTX" config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null)"
echo "  context        : $CTX"
echo "  namespace      : $NS"
echo "  values         : ${VALUES#$HERE/}"
echo "  release        : $RELEASE"

if [ "$ASSUME_YES" -ne 1 ]; then
  printf '\nDeploy to this cluster? [y/N] '
  read -r reply
  case "$reply" in y|Y|yes) ;; *) echo "aborted"; exit 1 ;; esac
fi

K="kubectl --context $CTX -n $NS"

step "1. namespace"
kubectl --context "$CTX" create namespace "$NS" >/dev/null 2>&1 && echo "  created $NS" || echo "  $NS already exists"

step "2. connector chart"
helm --kube-context "$CTX" upgrade --install "$RELEASE" "$HERE/chart" \
  -n "$NS" -f "$VALUES" --wait --timeout 10m \
  | grep -E '^(NAME|NAMESPACE|STATUS|REVISION):' || true

step "3. pods"
$K get pods

step "done"
$K get pods,svc,ingress
CONSUMER=$(grep -E '^\s+consumerHost:' "$VALUES" | awk '{print $2}')
PROVIDER=$(grep -E '^\s+providerHost:' "$VALUES" | awk '{print $2}')
cat <<EOF

UIs (once DNS points at your ingress controller):
    https://${CONSUMER}
    https://${PROVIDER}

Watch it:              k9s --context $CTX -n $NS
Verify:                ./verify.sh --context $CTX
Remove the release:    ./teardown.sh --context $CTX
EOF
