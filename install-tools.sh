#!/usr/bin/env bash
# Install kubectl, helm and k9s into ~/.local/bin. No sudo required.
#
# Deliberately does NOT install a local cluster runtime (kind, minikube): this
# chart targets a cluster that already exists. Point it at kind or minikube if you
# want a throwaway one — nothing here assumes a managed cluster.
set -euo pipefail

BIN="$HOME/.local/bin"
mkdir -p "$BIN"
WORK="$(mktemp -d)"
cd "$WORK"

if ! command -v kubectl >/dev/null 2>&1; then
  echo "installing kubectl..."
  KVER=$(curl -fsSL https://dl.k8s.io/release/stable.txt)
  curl -fsSLo kubectl "https://dl.k8s.io/release/${KVER}/bin/linux/amd64/kubectl"
  install -m 0755 kubectl "$BIN/kubectl"
fi

if ! command -v helm >/dev/null 2>&1; then
  echo "installing helm 3..."
  HELM_VER=$(curl -fsSL 'https://api.github.com/repos/helm/helm/releases?per_page=100' \
    | grep -o '"tag_name": *"v3[^"]*"' | head -1 | sed 's/.*"\(v3[^"]*\)"/\1/')
  curl -fsSLo helm.tgz "https://get.helm.sh/helm-${HELM_VER}-linux-amd64.tar.gz"
  tar -xzf helm.tgz
  install -m 0755 linux-amd64/helm "$BIN/helm"
fi

if ! command -v k9s >/dev/null 2>&1; then
  echo "installing k9s..."
  K9S_VER=$(curl -fsSL https://api.github.com/repos/derailed/k9s/releases/latest \
    | grep -o '"tag_name": *"[^"]*"' | head -1 | sed 's/.*"\(v[^"]*\)"/\1/')
  curl -fsSLo k9s.tgz "https://github.com/derailed/k9s/releases/download/${K9S_VER}/k9s_Linux_amd64.tar.gz"
  tar -xzf k9s.tgz k9s
  install -m 0755 k9s "$BIN/k9s"
fi

rm -rf "$WORK"
echo
kubectl version --client=true -o yaml 2>/dev/null | grep gitVersion | head -1
helm version --short
k9s version --short 2>/dev/null || k9s version 2>/dev/null | head -2

echo
echo "Contexts kubectl can see:"
kubectl config get-contexts 2>/dev/null || echo "  none - you need a kubeconfig for the target cluster"
echo
echo "k9s is a terminal UI for watching the cluster; deployment itself is helm."
echo "If a command is not found, open a new shell ($BIN joins PATH at login)."
