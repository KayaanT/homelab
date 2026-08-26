#!/usr/bin/env bash
# Substitutes the placeholders in homelab.env across every manifest, in place.
# Idempotent only in the sense that re-running after editing homelab.env will
# NOT re-substitute already-replaced values - use git to revert first:
#   git checkout -- . && ./scripts/configure.sh
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
source ./homelab.env

declare -A MAP=(
  [__DOMAIN__]="$DOMAIN"
  [__NODE_IP__]="$NODE_IP"
  [__NODE_NAME__]="$NODE_NAME"
  [__LB_RANGE_START__]="$LB_RANGE_START"
  [__LB_RANGE_END__]="$LB_RANGE_END"
  [__GITHUB_REPO__]="$GITHUB_REPO"
  [__ACME_EMAIL__]="$ACME_EMAIL"
  [__TAILNET_NAME__]="$TAILNET_NAME"
  [__LAN_CIDR__]="$LAN_CIDR"
  [__NIC_REGEX__]="$NIC_REGEX"
)

for k in "${!MAP[@]}"; do
  v="${MAP[$k]}"
  case "$v" in
    *CHANGEME*|*example.com*|yourtailnet*) echo "WARNING: $k is still a default ($v)" >&2 ;;
  esac
  # -i '' on BSD/macOS sed, -i on GNU
  if sed --version >/dev/null 2>&1; then SED=(sed -i); else SED=(sed -i ''); fi
  grep -rl "$k" --include='*.yaml' --include='*.md' . 2>/dev/null \
    | grep -v '^./.git' \
    | xargs -r "${SED[@]}" "s|${k}|${v//|/\\|}|g" || true
done

echo
echo "Remaining placeholders (should be none):"
grep -rn '__[A-Z_]*__' --include='*.yaml' . | grep -v '^./.git' || echo "  none"
