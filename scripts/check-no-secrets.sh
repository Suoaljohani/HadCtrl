#!/usr/bin/env bash
# Fails if anything that looks like a privileged key or signing material is
# tracked in the repository or bundled into a built app (spec §22, §36).
set -euo pipefail
target="${1:-.}"
pattern='service_role|sb_secret_[A-Za-z0-9]|-----BEGIN (RSA |EC )?PRIVATE KEY-----|SUPABASE_SERVICE_ROLE_KEY='
# The pattern itself and docs that name the forbidden strings are excluded.
hits=$(grep -RInE "$pattern" "$target" \
  --exclude-dir=.git --exclude-dir=docs --exclude-dir=.claude --exclude-dir=templates --exclude-dir=supabase \
  --exclude=check-no-secrets.sh --exclude=*.md --exclude=DependencyContainer.swift 2>/dev/null || true)
if [ -n "$hits" ]; then
  echo "Possible secret material found:" >&2
  echo "$hits" >&2
  exit 1
fi
for ext in p12 mobileprovision cer pem key; do
  if find "$target" -name "*.${ext}" -not -path '*/.git/*' | grep -q .; then
    echo "Signing/key file (*.${ext}) present under $target" >&2
    exit 1
  fi
done
echo "no secret material found under $target"
