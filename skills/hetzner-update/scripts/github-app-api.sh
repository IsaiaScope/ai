#!/usr/bin/env bash
# Usage: ssh main-vps "bash -s GET /app/hook/config" < github-app-api.sh
#        ssh main-vps "bash -s GET '/app/hook/deliveries?per_page=100'" < github-app-api.sh
#        ssh main-vps "bash -s POST /app/hook/deliveries/<id>/attempts" < github-app-api.sh   # redeliver
# Extra curl flags go INSIDE the quoted remote string, not after the < redirect,
# or ssh treats them as the remote command.
# Runs ON the VPS. Reads the GitHub App creds from the multica-backend container,
# signs a 9-minute JWT, runs the given curl args against api.github.com. Prints no secret.
set -euo pipefail
umask 077
K=$(mktemp); trap 'shred -u "$K" 2>/dev/null || rm -f "$K"' EXIT
docker exec multica-backend sh -c 'printf %s "$GITHUB_APP_PRIVATE_KEY"' > "$K"
APP=$(docker exec multica-backend sh -c 'printf %s "$GITHUB_APP_ID"')
b64() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
now=$(date +%s)
h=$(printf '{"alg":"RS256","typ":"JWT"}' | b64)
p=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' $((now-60)) $((now+540)) "$APP" | b64)
s=$(printf '%s.%s' "$h" "$p" | openssl dgst -sha256 -sign "$K" -binary | b64)
JWT="$h.$p.$s"
method="$1"; path="$2"; shift 2
curl -sS -X "$method" -H "Authorization: Bearer $JWT" -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" "$@" "https://api.github.com$path"
