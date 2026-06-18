#!/usr/bin/env bash
#
# vault-oidc-setup.sh — wire Vault's OIDC auth to dex so developers can log in to
# vault.spectraidp.com with GitHub (via dex) and get TEAM-SCOPED access.
#
# This is the human half of Branch V. ESO, the secrets-adapter, and the
# deploy-controller authenticate to Vault with the KUBERNETES auth method (as
# service accounts). Humans had no path in — vault.spectraidp.com only offered
# token login. This script adds the `oidc` auth method (purely additive; it does
# NOT touch the existing kubernetes/token methods) and maps each dex group
# `SpectraIDP:<slug>` to the `spectra-team-<slug>` policy the secrets-adapter
# already provisions. So a developer who is a GitHub member of team <slug> logs
# in and gets CRUD over exactly that team's secret subtree.
#
# Identity is the boundary, same as everywhere else: group membership (not the
# individual) carries the policy, via a Vault EXTERNAL identity group whose alias
# is the dex group name.
#
# Idempotent — safe to re-run. Re-run it after onboarding a team whose policy
# didn't exist when this last ran (or let the secrets-adapter own that; see
# README). Drives Vault through `kubectl exec` into the vault-0 pod, which holds a
# root-capable token via its token helper — so no root token ever leaves the pod
# or lands in your shell history.
#
# Requirements: kubectl (talking to the platform cluster) + jq on the host.
# Usage:
#   ./vault-oidc-setup.sh                    # uses defaults below
#   VAULT_NS=vault DEX_NS=dex ./vault-oidc-setup.sh
#
set -euo pipefail

VAULT_NS="${VAULT_NS:-vault}"
VAULT_POD="${VAULT_POD:-vault-0}"
DEX_NS="${DEX_NS:-dex}"
OIDC_CLIENT_SECRET_NAME="${OIDC_CLIENT_SECRET_NAME:-vault-oauth-client}"

# dex issuer (must equal the `config.issuer` in dex-values.yaml — Vault validates
# the ID-token issuer against this discovery URL).
DEX_ISSUER="${DEX_ISSUER:-https://dex.spectraidp.com}"
VAULT_HOST="${VAULT_HOST:-https://vault.spectraidp.com}"
OIDC_CLIENT_ID="${OIDC_CLIENT_ID:-vault}"
ROLE_NAME="${ROLE_NAME:-spectra}"

# kubectl path: the snap wrapper drops redirected stdout — prefer the real binary.
KUBECTL="${KUBECTL:-/snap/kubectl/current/kubectl}"
command -v "$KUBECTL" >/dev/null 2>&1 || KUBECTL=kubectl

# Run a vault CLI command inside the vault pod (root token via the pod's helper).
# NB: no `-i` — every call passes args, not stdin. With `-i`, an exec inside the
# `while read` loop below would inherit and drain the loop's stdin (the policy-list
# pipe), silently stopping after the first team.
vault() { "$KUBECTL" -n "$VAULT_NS" exec "$VAULT_POD" -- env VAULT_ADDR=http://127.0.0.1:8200 vault "$@"; }

echo "==> Reading dex OIDC client secret from ${DEX_NS}/${OIDC_CLIENT_SECRET_NAME}"
CLIENT_SECRET="$("$KUBECTL" -n "$DEX_NS" get secret "$OIDC_CLIENT_SECRET_NAME" \
  -o jsonpath='{.data.client-secret}' | base64 -d)"
[ -n "$CLIENT_SECRET" ] || { echo "ERROR: empty client-secret in ${OIDC_CLIENT_SECRET_NAME}"; exit 1; }

echo "==> Enabling the oidc auth method (idempotent)"
if vault auth list -format=json | jq -e '."oidc/"' >/dev/null 2>&1; then
  echo "    oidc/ already enabled — leaving it"
else
  vault auth enable oidc
fi

echo "==> Configuring auth/oidc/config against dex (${DEX_ISSUER})"
vault write auth/oidc/config \
  oidc_discovery_url="$DEX_ISSUER" \
  oidc_client_id="$OIDC_CLIENT_ID" \
  oidc_client_secret="$CLIENT_SECRET" \
  default_role="$ROLE_NAME" >/dev/null

echo "==> Writing the default role '${ROLE_NAME}'"
# user_claim=email → token display name; groups_claim=groups → drives the external
# group mapping below. Base policy is just `default`; team policies attach via the
# identity groups. Redirect URIs MUST match the dex client (dex-values.yaml).
vault write "auth/oidc/role/${ROLE_NAME}" \
  user_claim="email" \
  groups_claim="groups" \
  oidc_scopes="openid,profile,email,groups" \
  bound_audiences="$OIDC_CLIENT_ID" \
  allowed_redirect_uris="${VAULT_HOST}/ui/vault/auth/oidc/oidc/callback,${VAULT_HOST}/oidc/callback,http://localhost:8250/oidc/callback" \
  token_policies="default" \
  token_ttl="1h" \
  token_max_ttl="2h" >/dev/null

# The OIDC auth mount accessor — group aliases bind to this.
OIDC_ACCESSOR="$(vault auth list -format=json | jq -r '."oidc/".accessor')"
[ -n "$OIDC_ACCESSOR" ] && [ "$OIDC_ACCESSOR" != "null" ] || { echo "ERROR: no oidc accessor"; exit 1; }
echo "==> OIDC mount accessor: ${OIDC_ACCESSOR}"

echo "==> Mapping dex groups -> team policies for existing teams"
# Source of truth for "which teams exist" = the spectra-team-<slug> policies the
# secrets-adapter already provisions. For each, ensure an EXTERNAL identity group
# carrying that policy, aliased to the dex group name `SpectraIDP:<slug>`.
mapped=0
while IFS= read -r policy; do
  case "$policy" in
    spectra-team-*) : ;;
    *) continue ;;
  esac
  slug="${policy#spectra-team-}"
  group_name="vault-${policy}"          # internal Vault identity-group name
  dex_group="SpectraIDP:${slug}"        # the claim dex emits for this GitHub team

  # Upsert the external identity group with the team policy attached (write-by-name
  # is an upsert, so this is safe to re-run).
  vault write "identity/group" \
    name="$group_name" \
    type="external" \
    policies="$policy" >/dev/null
  group_json="$(vault read -format=json "identity/group/name/${group_name}")"
  group_id="$(echo "$group_json" | jq -r '.data.id')"

  # An external group has exactly one alias. `vault write identity/group-alias`
  # CREATES (it does not upsert by name), so guard on the existing alias to stay
  # idempotent — only create when the group has no alias on this oidc mount yet.
  existing_alias="$(echo "$group_json" | jq -r --arg m "$OIDC_ACCESSOR" \
    'if (.data.alias.id // "") != "" and .data.alias.mount_accessor == $m then .data.alias.id else "" end')"
  if [ -n "$existing_alias" ]; then
    echo "    ${dex_group}  ->  ${policy}  (alias exists, skipped)"
  else
    vault write "identity/group-alias" \
      name="$dex_group" \
      mount_accessor="$OIDC_ACCESSOR" \
      canonical_id="$group_id" >/dev/null
    echo "    ${dex_group}  ->  ${policy}"
  fi
  mapped=$((mapped + 1))
done < <(vault policy list)

echo "==> Done. Mapped ${mapped} team(s)."
echo "    Test:  vault login -method=oidc -path=oidc role=${ROLE_NAME}"
echo "    Or open ${VAULT_HOST} -> Other -> OIDC -> role '${ROLE_NAME}'."
