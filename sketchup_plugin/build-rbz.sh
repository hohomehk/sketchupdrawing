#!/usr/bin/env bash
# build-rbz.sh — inject secrets + build .rbz from clean source.
#
# Why: source on GitHub keeps placeholders so the public repo never carries
# CF / Gemini credentials (would otherwise trip secret-scanning + leak to anyone
# who clones). Real values only land in the shipped artifact.
#
# Reads secrets from $CF_AIG_TOKEN and $GEMINI_API_KEY in the env or from
# `--env-file <path>`. Writes:
#   - releases/su_gpt_render.rbz     (zip with secrets injected)
#   - releases/su_gpt_render.rb      (the injected ruby file alone — used as
#                                     auto-update rb_url target)
#   - releases/version.json          (kept untouched here, edit by hand)
#
# Usage:
#   ./sketchup_plugin/build-rbz.sh                       # uses live env
#   ./sketchup_plugin/build-rbz.sh --env-file ~/.openclaw/marketing/.env

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$REPO_ROOT/sketchup_plugin/su_gpt_render/su_gpt_render.rb"
LOADER="$REPO_ROOT/sketchup_plugin/su_gpt_render_loader.rb"
OUT_DIR="$REPO_ROOT/releases"
OUT_RBZ="$OUT_DIR/su_gpt_render.rbz"
OUT_RB="$OUT_DIR/su_gpt_render.rb"

ENV_FILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --env-file) ENV_FILE="$2"; shift 2 ;;
    *) echo "unknown arg: $1"; exit 1 ;;
  esac
done

if [[ -n "$ENV_FILE" ]]; then
  [[ -f "$ENV_FILE" ]] || { echo "env file not found: $ENV_FILE"; exit 1; }
  set -a
  # shellcheck source=/dev/null
  source "$ENV_FILE"
  set +a
fi

: "${CF_AIG_TOKEN:?CF_AIG_TOKEN must be set (live env or --env-file)}"
: "${GEMINI_API_KEY:?GEMINI_API_KEY must be set (live env or --env-file)}"

echo "→ building .rbz from $SRC"
echo "  CF_AIG_TOKEN  length: ${#CF_AIG_TOKEN}"
echo "  GEMINI_API_KEY length: ${#GEMINI_API_KEY}"

mkdir -p "$OUT_DIR"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# Inject — use python so we don't have to escape sed special chars.
python3 - "$SRC" "$TMP_DIR/su_gpt_render.rb" "$CF_AIG_TOKEN" "$GEMINI_API_KEY" <<'PY'
import sys
src, dst, tok, key = sys.argv[1:5]
content = open(src).read()
for needle, val in (("__INJECT_CF_AIG_TOKEN__", tok), ("__INJECT_GEMINI_API_KEY__", key)):
    if needle not in content:
        print(f"WARN: placeholder not found: {needle}", file=sys.stderr)
    content = content.replace(needle, val)
# Sanity: no placeholders should survive.
remaining = [m for m in ("__INJECT_CF_AIG_TOKEN__", "__INJECT_GEMINI_API_KEY__") if m in content]
if remaining:
    print(f"FATAL: placeholders still in output: {remaining}", file=sys.stderr)
    sys.exit(1)
open(dst, "w").write(content)
PY

# Copy injected file to release dir so the auto-update flow can fetch it.
cp "$TMP_DIR/su_gpt_render.rb" "$OUT_RB"

# Build .rbz with the injected source.
python3 - "$LOADER" "$TMP_DIR/su_gpt_render.rb" "$OUT_RBZ" <<'PY'
import sys, os, zipfile
loader_src, plugin_src, out = sys.argv[1:4]
with zipfile.ZipFile(out, "w", compression=zipfile.ZIP_DEFLATED) as zf:
    zf.write(loader_src, "su_gpt_render_loader.rb")
    zf.write(plugin_src, "su_gpt_render/su_gpt_render.rb")
print(f"wrote {out}: {os.path.getsize(out)} bytes")
PY

echo
echo "✓ output:"
ls -la "$OUT_RBZ" "$OUT_RB"
