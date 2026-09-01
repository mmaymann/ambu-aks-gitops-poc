# Ambu AKS GitOps PoC

Proof of concept for a **Senior Cloud Architect** platform at Ambu: Azure Kubernetes Service as the runtime, **Crossplane** as the Azure control plane, and **Argo CD** as the GitOps delivery path.

The sample workload is **Ambu EndoIntelligence** — a static Nginx product site that represents an EU-hosted endoscopy intelligence portal (demo data only).

## What this demonstrates

| Capability | How it shows up in the repo |
|---|---|
| Azure landing zone thinking | Hub resource group, AKS (OIDC + Workload Identity), tags |
| Control-plane as code | Crossplane XRDs + Compositions (`XAmbuPlatform`, `XEndoIntelligence`) |
| GitOps | Argo CD App-of-Apps, AppProject isolation, Kustomize overlays |
| Identity | AKS OIDC issuer + Workload Identity on the app ServiceAccount |
| EU data residency | Default region `northeurope`, no US region in manifests |
| Secure delivery | Unprivileged Nginx, NetworkPolicy, PDB, non-root container |
| Platform vs product | `platform/` (shared Azure) vs `apps/endointelligence` (product team) |

This is a **design-complete PoC**, not a production Ambu environment. Secrets, private clusters, and Front Door WAF should be wired to real subscriptions before any clinical data is involved.

## Architecture

```
                 GitHub (this repo)
                        │
                        │  Application + ApplicationSet
                        ▼
              ┌─────────────────────┐
              │   Argo CD (AKS)     │
              │  App-of-Apps root   │
              └─────────┬───────────┘
           ┌────────────┼────────────┐
           ▼            ▼            ▼
     Crossplane    Platform XR    EndoIntelligence
     XRDs          (in-cluster    (Nginx, Ingress,
     + claims      markers)       NetworkPolicy)
           │
           ▼
     Azure Resource Manager
     (northeurope)
```

Chicken-and-egg is explicit: **one bootstrap AKS cluster** is created with Azure CLI. After that, Crossplane and Argo CD own the rest of the platform and the product.

See [docs/architecture.md](docs/architecture.md) for the full design (network, identity, GitOps topology, and interview talking points).

## Repository layout

```
apps/endointelligence/   Nginx product (ConfigMap + Kustomize overlays)
cluster/                 Namespaces applied by Argo CD
gitops/apps/             Argo CD App-of-Apps + AppProjects
infra/crossplane/        XRDs, Compositions, Claims
scripts/                 bootstrap.sh, quota.sh, argocd-values.yaml
```

## Prerequisites

- Azure subscription with `Owner` or `User Access Administrator` + `Contributor`
- Azure CLI ≥ 2.61, `kubectl`, `helm`

## Quick start

```bash
git clone https://github.com/mmaymann/ambu-aks-gitops-poc.git
cd ambu-aks-gitops-poc
cp .env.example .env          # set AZURE_SUBSCRIPTION_ID, AZURE_TENANT_ID and GITHUB_ORG
./scripts/bootstrap.sh        # AKS + Crossplane + Argo CD (~10–15 min)
```

- Demo site (Nginx): http://127.0.0.1:8080
- ControlPlane (Crossplane + Komoplane): http://127.0.0.1:8081
- GitOps (Argo CD): http://127.0.0.1:8082

## Environments

| Overlay | Namespace | Replicas | Ingress host |
|---|---|---|---|
| `dev` | `endointelligence-dev` | 1 | `endo-dev.ambu.local` |
| `prod` | `endointelligence-prod` | 3 | `endointelligence.ambu.local` |

Hosts are for lab / `/etc/hosts` or a private DNS zone. Swap to a real Azure DNS + TLS issuer in a follow-up.

## Design decisions (short)

1. **Crossplane over raw Terraform in-cluster** — Azure resources become Kubernetes claims that product teams can request without ARM templates. Terraform remains valid for brownfield landing zones; this PoC shows the Kubernetes-native path.
2. **Argo CD over Flux** — clearer App-of-Apps story for mixed platform + product teams, and a UI architects can walk through in an interview.
3. **North Europe** — Ambu is Danish; default data residency is EU.
4. **Bootstrap cluster is thin** — CLI only creates the RG, AKS, Crossplane, and Argo CD. GitOps owns XRDs, claims, ingress, and the product.

## Disclaimer

Not affiliated with Ambu A/S. Product names and UI copy are fictional and for architecture demonstration only. Do not process patient or device data with this stack.
