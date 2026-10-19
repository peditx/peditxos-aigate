#!/bin/sh
# ============================================================
#  sync-providers.sh — regenerate the AiGate provider preset
#  list from9router's OWN registry (open-sse, vendored in
#  decolua/9router). Run by CI weekly, or by hand:
#      sh scripts/sync-providers.sh
#  Output: root/usr/share/aigate/providers.json  (pure data)
#  The LuCI panel reads that JSON at runtime — no JS edits
#  are needed when new providers appear upstream.
# ============================================================
set -eu
BASE=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUT="$BASE/luci-app-aigate/root/usr/share/aigate/providers.json"
REPO_URL="https://raw.githubusercontent.com/decolua/9router"   # branch master
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

command -v curl >/dev/null || { echo "curl required"; exit 1; }
command -v python3 >/dev/null || { echo "python3 required"; exit 1; }

echo "Fetching registry index..."
curl -sf --max-time 30 \
  "$REPO_URL/master/open-sse/providers/registry/index.js" -o "$WORK/index.js" || {
  echo "ERROR: cannot fetch registry index (upstream moved?)"; exit 1; }

# provider ids = the ./xxx.js imports
PROVS=$(grep -oE 'from "\./[a-z0-9-]+\.js"' "$WORK/index.js" \
  | sed 's|from "./||; s|\.js"||' | sort -u)
COUNT=$(echo "$PROVS" | wc -l)
echo "Registry lists $COUNT providers — fetching chat transports..."

for p in $PROVS; do
  curl -sf --max-time 10 -o "$WORK/$p.js" "$REPO_URL/master/open-sse/providers/registry/$p.js" \
    2>/dev/null || rm -f "$WORK/$p.js"
done

python3 - "$WORK" "$OUT" <<'PY'
import json, re, glob, sys, os, io
work, out = sys.argv[1], sys.argv[2]
data = {}
for fn in glob.glob(os.path.join(work, '*.js')):
    src = open(fn).read()
    pid = re.search(r'id:\s*"([^"]+)"', src)
    base = re.search(r'transport:\s*\{[^}]*?baseUrl:\s*"([^"]+)"', src, re.S)
    if not pid or not base:
        continue
    url = base.group(1)
    # our engine appends /chat/completions or /messages — strip full-path suffixes
    for suf in ('/chat/completions', '/messages'):
        if url.endswith(suf):
            url = url[:-len(suf)]
    fmt = 'anthropic' if re.search(r'format:\s*"claude"', src) else 'openai'
    kinds = re.search(r'serviceKinds:\s*\[([^\]]*)\]', src)
    kinds = kinds.group(1) if kinds else '"llm"'
    auth = re.search(r'authType:\s*"([^"]+)"', src)
    name = re.search(r'display:\s*\{[^}]*?name:\s*"([^"]+)"', src, re.S)
    data[pid.group(1)] = {
        'type': fmt,
        'url': url,
        'embeddings': "'embedding'" in kinds,
        'images': "'image'" in kinds,
        'tts': "'tts'" in kinds,
        'stt': "'stt'" in kinds,
        'search': "'search'" in kinds,
        'auth': auth.group(1) if auth else 'apikey',
        'display': name.group(1) if name else pid.group(1),
    }
# normalizations where9router's transport path is format-specific
if 'gemini' in data:
    data['gemini']['url'] = 'https://generativelanguage.googleapis.com/v1beta/openai'
if 'ollama' in data:
    data['ollama']['url'] = 'https://ollama.com/api/v1'
data['ollama-local'] = {'type': 'openai', 'url': 'http://<host>:11434/v1',
    'embeddings': False, 'images': False, 'tts': False, 'stt': False,
    'search': False, 'auth': 'none', 'display': 'Ollama (local)'}
data['custom'] = None
doc = {'_generated': 'from decolua/9router open-sse registry — do not edit, run scripts/sync-providers.sh',
       'providers': dict(sorted(data.items()))}
os.makedirs(os.path.dirname(out), exist_ok=True)
with open(out, 'w') as f:
    json.dump(doc, f, indent=1, ensure_ascii=False)
print('Wrote', out, 'with', len(data), 'entries')
PY
