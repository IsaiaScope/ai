#!/bin/sh
if [ -f pnpm-lock.yaml ]; then
  pnpm exec commitlint --edit "$1"
elif [ -f bun.lockb ] || [ -f bun.lock ]; then
  bunx --no-install commitlint --edit "$1"
elif [ -f yarn.lock ]; then
  yarn commitlint --edit "$1"
else
  npx --no-install commitlint --edit "$1"
fi
