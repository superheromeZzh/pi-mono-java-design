#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
cd "$script_dir"

PUPPETEER_SKIP_CHROMIUM_DOWNLOAD=true \
SUPPRESS_NO_CONFIG_WARNING=true \
npx --yes @asyncapi/cli@6.0.2 generate fromTemplate \
  chat-ws-v2.asyncapi.yaml \
  @asyncapi/html-template@3.5.6 \
  --output chat-ws-v2-docs \
  --param singleFile=true \
  --param 'config={"show":{"info":false,"messages":false,"messageExamples":true},"expand":{"messageExamples":true},"sidebar":{"showOperations":"byDefault"}}' \
  --force-write

perl -pi -e 's/[ \t]+$//' chat-ws-v2-docs/index.html
