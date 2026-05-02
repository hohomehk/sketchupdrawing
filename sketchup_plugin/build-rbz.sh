#!/usr/bin/env bash
# build-rbz.sh — inject secrets + build .rbz from clean source.
#
# Why: source on GitHub keeps placeholders so the public repo never carries
# CF / Gemini credentials (would otherwise trip secret-scanning + leak to anyone
# who clones). Real values only land in the shipped artifact.
#
# Reads $CF_AIG_TOKEN from env or `--env-file <path>` (only one secret needed
# now — Gemini API key is BYOK on the gateway side, never bundled). Writes:
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

echo "→ building .rbz from $SRC"
echo "  CF_AIG_TOKEN length: ${#CF_AIG_TOKEN}"

mkdir -p "$OUT_DIR"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# Inject — use python so we don't have to escape sed special chars.
python3 - "$SRC" "$TMP_DIR/su_gpt_render.rb" "$CF_AIG_TOKEN" <<'PY'
import sys
src, dst, tok = sys.argv[1:4]
content = open(src).read()
needle = "__INJECT_CF_AIG_TOKEN__"
if needle not in content:
    print(f"WARN: placeholder not found: {needle}", file=sys.stderr)
content = content.replace(needle, tok)
if needle in content:
    print(f"FATAL: placeholder still in output: {needle}", file=sys.stderr)
    sys.exit(1)
# Also fail if a stray AIza-key placeholder leaked back in.
if "__INJECT_GEMINI_API_KEY__" in content:
    print("FATAL: GEMINI_API_KEY placeholder reappeared — source should be BYOK only", file=sys.stderr)
    sys.exit(1)
open(dst, "w").write(content)
PY

# Copy injected file to release dir so the auto-update flow can fetch it.
cp "$TMP_DIR/su_gpt_render.rb" "$OUT_RB"

BRAND_LOGO="$REPO_ROOT/sketchup_plugin/su_gpt_render/brand_logo.png"

# Build .rbz with the injected source + brand assets (logo etc).
python3 - "$LOADER" "$TMP_DIR/su_gpt_render.rb" "$OUT_RBZ" "$BRAND_LOGO" <<'PY'
import sys, os, zipfile
loader_src, plugin_src, out, brand_logo = sys.argv[1:5]
with zipfile.ZipFile(out, "w", compression=zipfile.ZIP_DEFLATED) as zf:
    zf.write(loader_src, "su_gpt_render_loader.rb")
    zf.write(plugin_src, "su_gpt_render/su_gpt_render.rb")
    if os.path.exists(brand_logo):
        zf.write(brand_logo, "su_gpt_render/brand_logo.png")
print(f"wrote {out}: {os.path.getsize(out)} bytes")
PY

echo
echo "✓ output:"
ls -la "$OUT_RBZ" "$OUT_RB"
