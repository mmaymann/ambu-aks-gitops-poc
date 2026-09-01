#!/usr/bin/env bash
# Bootstrap the first AKS cluster, then hand control to Crossplane + Argo CD.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
[[ -f "${ROOT}/.env" ]] && source "${ROOT}/.env"

: "${AZURE_SUBSCRIPTION_ID:?Set AZURE_SUBSCRIPTION_ID in .env}"
AZURE_LOCATION="${AZURE_LOCATION:-northeurope}"
# AKS can live in another region if northeurope has 0 vCPU quota (same resource group is fine).
AKS_LOCATION="${AKS_LOCATION:-${AZURE_LOCATION}}"
PLATFORM_RG="${PLATFORM_RG:-rg-ambu-platform-ne}"
AKS_NAME="${AKS_NAME:-aks-ambu-platform-ne}"
# Restricted subscriptions: Ds_v5 blocked, DCadsv6 often has 0 quota. Prefer a family with remaining vCPU.
AKS_NODE_VM_SIZE="${AKS_NODE_VM_SIZE:-Standard_EC2as_v5}"
AKS_NODE_COUNT="${AKS_NODE_COUNT:-1}"
GITHUB_ORG="${GITHUB_ORG:-mmaymann}"
GITHUB_REPO="${GITHUB_REPO:-ambu-aks-gitops-poc}"
GITOPS_REVISION="${GITOPS_REVISION:-main}"
CROSSPLANE_VERSION="${CROSSPLANE_VERSION:-1.18.2}"
ARGOCD_VERSION="${ARGOCD_VERSION:-7.8.2}"

az account set --subscription "${AZURE_SUBSCRIPTION_ID}"

echo "==> Registering Azure resource providers (new subscriptions start unregistered)"
PROVIDERS=(
  Microsoft.ContainerService
  Microsoft.Network
  Microsoft.Compute
  Microsoft.Storage
  Microsoft.ManagedIdentity
  Microsoft.Authorization
)
for ns in "${PROVIDERS[@]}"; do
  state="$(az provider show --namespace "${ns}" --query registrationState -o tsv 2>/dev/null || true)"
  if [[ "${state}" != "Registered" ]]; then
    echo "    ${ns} (${state:-NotRegistered}) → registering"
    az provider register --namespace "${ns}" --wait >/dev/null
  else
    echo "    ${ns} already registered"
  fi
done

echo "==> VM family quota in ${AKS_LOCATION} (need remaining ≥ 2 for AKS)"
az vm list-usage --location "${AKS_LOCATION}" \
  --query "sort_by([?contains(name.value, 'Family') && currentValue < limit], &name.value).{family:name.localizedValue, used:currentValue, limit:limit}" \
  -o table || true
echo "    Using SKU ${AKS_NODE_VM_SIZE}. Override AKS_NODE_VM_SIZE / AKS_LOCATION in .env if the table is empty."
echo "    Full table: ./scripts/quota.sh ${AKS_LOCATION}"

echo "==> Resource group ${PLATFORM_RG} (${AZURE_LOCATION})"
az group create \
  --name "${PLATFORM_RG}" \
  --location "${AZURE_LOCATION}" \
  --tags Owner=platform CostCenter=endo-intelligence DataClass=demo-nonclinical Project=ambu-aks-gitops-poc \
  >/dev/null

# Azure CLI still sends docker_bridge_cidr; the 2025 AKS API dropped that field (harmless WARNING).
az_quiet() {
  local err
  err="$(mktemp)"
  if ! "$@" >/dev/null 2>"${err}"; then
    grep -v 'docker_bridge_cidr' "${err}" >&2 || true
    rm -f "${err}"
    return 1
  fi
  grep -v 'docker_bridge_cidr' "${err}" >&2 || true
  rm -f "${err}"
}

echo "==> AKS ${AKS_NAME} in ${AKS_LOCATION} (${AKS_NODE_COUNT} × ${AKS_NODE_VM_SIZE}, OIDC + Workload Identity)"
if ! az aks show --resource-group "${PLATFORM_RG}" --name "${AKS_NAME}" >/dev/null 2>&1; then
  az_quiet az aks create \
    --resource-group "${PLATFORM_RG}" \
    --name "${AKS_NAME}" \
    --location "${AKS_LOCATION}" \
    --node-count "${AKS_NODE_COUNT}" \
    --node-vm-size "${AKS_NODE_VM_SIZE}" \
    --enable-oidc-issuer \
    --enable-workload-identity \
    --enable-managed-identity \
    --network-plugin azure \
    --network-plugin-mode overlay \
    --generate-ssh-keys \
    --tags Owner=platform CostCenter=endo-intelligence DataClass=demo-nonclinical
else
  echo "    cluster already exists"
fi

az aks get-credentials --resource-group "${PLATFORM_RG}" --name "${AKS_NAME}" --overwrite-existing

echo "==> Helm repos"
helm repo add crossplane-stable https://charts.crossplane.io/stable >/dev/null
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null
helm repo update >/dev/null

echo "==> Crossplane ${CROSSPLANE_VERSION}"
helm upgrade --install crossplane crossplane-stable/crossplane \
  --namespace crossplane-system \
  --create-namespace \
  --version "${CROSSPLANE_VERSION}" \
  --wait

echo "==> Argo CD ${ARGOCD_VERSION}"
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --create-namespace \
  --version "${ARGOCD_VERSION}" \
  --values "${ROOT}/scripts/argocd-values.yaml" \
  --wait

REPO_URL="https://github.com/${GITHUB_ORG}/${GITHUB_REPO}.git"
echo "==> Root Application → ${REPO_URL} @ ${GITOPS_REVISION}"
kubectl apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: ambu-root
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: ${REPO_URL}
    targetRevision: ${GITOPS_REVISION}
    path: gitops/apps
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
EOF

wait_for_svc() {
  local ns=$1 name=$2
  echo "==> Waiting for svc/${name} in ${ns} (ready endpoints)"
  local i=0
  until kubectl -n "${ns}" get svc "${name}" >/dev/null 2>&1; do
    i=$((i + 1))
    if (( i > 120 )); then
      echo "timed out waiting for ${ns}/svc/${name}" >&2
      return 1
    fi
    sleep 5
  done
  # Service can exist while the Pod is still Pending; port-forward then exits.
  until [[ -n "$(kubectl -n "${ns}" get endpoints "${name}" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null)" ]]; do
    i=$((i + 1))
    if (( i > 120 )); then
      echo "timed out waiting for endpoints on ${ns}/svc/${name}" >&2
      return 1
    fi
    sleep 5
  done
}

start_port_forward() {
  local ns=$1 svc=$2 local_port=$3 remote_port=$4
  # AKS often drops the port-forward stream; reconnect until the machine reboots.
  pkill -f "kubectl -n ${ns} port-forward svc/${svc} ${local_port}:" >/dev/null 2>&1 || true
  nohup bash -c "
    while true; do
      kubectl -n '${ns}' port-forward 'svc/${svc}' '${local_port}:${remote_port}' || true
      sleep 2
    done
  " >/tmp/ambu-port-forward-${local_port}.log 2>&1 &
  disown || true
}

echo
echo "Bootstrap complete."
echo "  Argo CD admin password:"
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
echo
echo

wait_for_svc endointelligence-dev endointelligence
wait_for_svc komoplane komoplane
wait_for_svc argocd argocd-server

start_port_forward endointelligence-dev endointelligence 8080 80
start_port_forward komoplane komoplane 8081 8090
start_port_forward argocd argocd-server 8082 80

echo "  Demo site                        →  http://127.0.0.1:8080"
echo "  ControlPlane (Komoplane)        →  http://127.0.0.1:8081"
echo "  GitOps (ArgoCD) Login: admin / (password above)  →  http://127.0.0.1:8082"
