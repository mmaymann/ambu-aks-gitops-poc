# Runbook

## OIDC issuer

```bash
az aks show -g rg-ambu-platform-ne -n aks-ambu-platform-ne \
  --query oidcIssuerProfile.issuer -o tsv
```

Compositions in this PoC compose in-cluster ConfigMaps (Upbound Azure providers are not installed). Re-point those bases at Azure CRDs when a provider package actually installs.

## Tear down

```bash
az group delete -n rg-ambu-platform-ne --yes
```
