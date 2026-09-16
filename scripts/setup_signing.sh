#!/usr/bin/env bash
#
# ============================================
# Purpose:           Write project.local.yml with this Mac's Apple Development team ID, then generate.
# When to use:       First-time local setup on a new machine.
# Safe to run in prod?  Yes — writes only the gitignored project.local.yml.
# Owner:             Luke F. Walton
# ============================================
# Inherited unchanged from a-new-word-every-day@e829bcc9c0dc scripts/setup_signing.sh.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ -f project.local.yml ] && ! grep -q 'YOUR_TEAM_ID_HERE' project.local.yml 2>/dev/null; then
  echo "project.local.yml already exists — delete it first to re-detect."
  exit 0
fi

TEAM=""
# Prefer the team Xcode last used for provisioning.
if defaults read com.apple.dt.Xcode IDEProvisioningTeamManagerLastSelectedTeamID &>/dev/null; then
  TEAM=$(defaults read com.apple.dt.Xcode IDEProvisioningTeamManagerLastSelectedTeamID 2>/dev/null || true)
fi

# Fall back to the OU field on the Apple Development certificate.
if [ -z "$TEAM" ]; then
  TEAM=$(security find-certificate -c "Apple Development" -p 2>/dev/null \
    | openssl x509 -noout -subject 2>/dev/null \
    | sed -n 's/.*OU=\([^,/]*\).*/\1/p' | head -1)
fi

if [ -z "$TEAM" ]; then
  echo "Could not detect a Development Team. Copy project.local.yml.example and set DEVELOPMENT_TEAM manually." >&2
  exit 1
fi

cat > project.local.yml <<EOF
# Local signing — gitignored. Auto-detected by scripts/setup_signing.sh
settings:
  base:
    DEVELOPMENT_TEAM: $TEAM
EOF

echo "Wrote project.local.yml (DEVELOPMENT_TEAM=$TEAM)"
bash scripts/generate.sh
