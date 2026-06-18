# spectra-dex

Dex is Spectra's OIDC provider. It federates GitHub (org `SpectraIDP`) and emits
group claims `SpectraIDP:<team-slug>`, which the kube-apiserver and Vault both
trust as the identity boundary.

Deployed as the Helm release `dex` in namespace `dex`
(`helm repo: https://charts.dexidp.io`, chart `dex`). Values live in
[`k8s/dex-values.yaml`](k8s/dex-values.yaml).

## Upgrade / apply config

```bash
helm upgrade dex dex/dex -n dex --version 0.24.0 -f k8s/dex-values.yaml --wait
```

Client secrets are NOT in git. Each static client reads its secret from a k8s
Secret via dex's native `secretEnv` (dex does not expand `$VARs` in static client
secrets — only `secretEnv` works). The secrets are:

| Static client | k8s Secret (ns `dex`) | Used by |
|---|---|---|
| `kubernetes` | `kubernetes-oauth-client` | spectl / kubeconfig OIDC login |
| `grafana`    | `grafana-oauth-client`    | Grafana SSO |
| `vault`      | `vault-oauth-client`      | Vault UI/CLI SSO (see below) |

## Vault SSO

The `vault` static client lets developers log in to `vault.spectraidp.com` with
GitHub (via dex) and get **team-scoped** access — the human counterpart to the
Kubernetes-auth path ESO, the secrets-adapter, and the deploy-controller use.
Without it, Vault only offered token login and the Environments-panel Vault deep
links were dead for humans.

One-time setup (idempotent, re-runnable):

```bash
# 1. create the dex client secret (mirror of grafana-oauth-client)
kubectl -n dex create secret generic vault-oauth-client \
  --from-literal=client-secret="$(head -c 32 /dev/urandom | base64 | tr -d '\n=+/' | cut -c1-40)"

# 2. add the `vault` static client to dex-values.yaml (already done) + upgrade dex
helm upgrade dex dex/dex -n dex --version 0.24.0 -f k8s/dex-values.yaml --wait

# 3. wire Vault's oidc auth method to dex + map dex groups -> team policies
./scripts/vault-oidc-setup.sh
```

[`scripts/vault-oidc-setup.sh`](scripts/vault-oidc-setup.sh) enables Vault's
`oidc` auth method (purely additive — it does NOT touch the existing
`kubernetes`/`token` methods), configures it against dex, creates the `spectra`
role, and for every `spectra-team-<slug>` policy the secrets-adapter has
provisioned, creates an **external identity group** carrying that policy, aliased
to the dex group `SpectraIDP:<slug>`. So a developer who is a GitHub member of
team `<slug>` logs in and gets CRUD over exactly that team's secret subtree.

Re-run the script after onboarding a new team (its `spectra-team-<slug>` policy
must exist first). Login:

```bash
vault login -method=oidc -path=oidc role=spectra
# or: open https://vault.spectraidp.com -> Other -> OIDC -> role "spectra"
```

### Rollback

```bash
kubectl -n vault exec vault-0 -- vault auth disable oidc   # removes the oidc method + role + aliases
# revert the `vault` client from dex-values.yaml, then helm upgrade dex
kubectl -n dex delete secret vault-oauth-client
```
