#!/usr/bin/env bash
# Show VM-family quota in a region. AKS needs remaining ≥ 2 vCPU on the family you pick.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
[[ -f "${ROOT}/.env" ]] && source "${ROOT}/.env"

LOCATION="${1:-${AKS_LOCATION:-${AZURE_LOCATION:-northeurope}}}"
: "${AZURE_SUBSCRIPTION_ID:?Set AZURE_SUBSCRIPTION_ID in .env}"
az account set --subscription "${AZURE_SUBSCRIPTION_ID}"

echo "VM family quota in ${LOCATION} (used / limit). Remaining 0 = AKS cannot use that family."
echo
az vm list-usage --location "${LOCATION}" \
  --query "sort_by([?contains(name.value, 'Family')], &name.value).{family:name.localizedValue, used:currentValue, limit:limit}" \
  -o table
echo
echo "AKS-allowed SKUs in this region for this subscription:"
az aks get-versions --location "${LOCATION}" -o none 2>/dev/null || true
az vm list-skus --location "${LOCATION}" --resource-type virtualMachines --query "[].name" -o tsv 2>/dev/null | head -5 >/dev/null
echo "(Use the SKU list Azure printed on the last AKS error, plus a family above with remaining ≥ 2.)"
echo
echo "If northeurope is empty, try: $0 westeurope   or   $0 swedencentral"
echo "Then set AKS_LOCATION and AKS_NODE_VM_SIZE in .env"
