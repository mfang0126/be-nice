#!/bin/sh
# Dev-only: point the installed development app at this machine's Hermes DeepInfra
# provider. Reads the key from ~/.hermes/.env and never prints it.
set -eu
APP="$HOME/Applications/be-nice Development.app"
DOMAIN=com.benice.menubar.development
BASE_URL=https://api.deepinfra.com/v1/openai
MODEL=${1:-deepseek-ai/DeepSeek-V4.1-Flash}

[ -d "$APP" ] || { echo "missing $APP; run build-app.sh debug --install first" >&2; exit 1; }
key=$(sed -n 's/^DEEPINFRA_API_KEY=//p' "$HOME/.hermes/.env" | tail -1 | tr -d '"'"'"'\r')
[ -n "$key" ] || { echo "DEEPINFRA_API_KEY not found in ~/.hermes/.env" >&2; exit 1; }

defaults write "$DOMAIN" be-nice.model.baseURL "$BASE_URL"
defaults write "$DOMAIN" be-nice.model.id "$MODEL"
# Let the app itself create the item so it owns it (no per-read authorization).
security delete-generic-password -s be-nice.model-api-key -a default >/dev/null 2>&1 || true
printf '%s' "$key" | "$APP/Contents/MacOS/benice" --store-api-key
echo "configured: $BASE_URL  model=$MODEL  key=(from ~/.hermes/.env)"
