#!/bin/sh
# ============================================================
#  PeDItXOS-AiGate — self-contained gateway test-suite
#  Extracts the engine EMBEDDED in install.sh (source of truth),
#  runs it as CGI (env vars) against local mock upstreams.
#  Dev-only — never installed on the router.
#
#  Usage:  LUA=lua5.3 sh test/gateway-tests.sh
#  Needs:  lua5.3, curl, python3 (mock only)
# ============================================================
set -u
BASE=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
T=$(mktemp -d)
LUA=${LUA:-lua5.3}
command -v "$LUA" >/dev/null 2>&1 || { echo "lua not found — set LUA=/path/to/lua5.3"; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "python3 required for the mock"; exit 2; }
rm -rf /tmp/aigate-rr   # fresh round-robin state

# engine under test = the packaged file (source of truth)
G="$BASE/luci-app-aigate/root/usr/lib/aigate/gateway.lua"
[ -s "$G" ] || { echo "FAILED: engine not found at $G"; exit 2; }
"$LUA" -e "assert(loadfile('$G'))" || { echo "FAILED: embedded engine has a syntax error"; exit 2; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }
check() {
  if grep -q "$3" "$2" 2>/dev/null; then ok "$1"; else bad "$1 (missing: $3)"; fi
}

# ----- mock upstream (dialect-aware, echoes auth key + model) -----
cat > "$T/mock.py" <<'MOCKEOF'
#!/usr/bin/env python3
"""Mock AI upstream. argv: <mode> <port>
sse  -> honors body.stream (SSE per dialect); fail -> always 429."""
import json, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MODE, PORT = sys.argv[1], int(sys.argv[2])

class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def _json(self, code, obj):
        out = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers(); self.wfile.write(out)
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        try:
            body = json.loads(self.rfile.read(n) or b"{}")
        except Exception:
            body = {}
        if MODE == "fail":
            self._json(429, {"error": {"type": "rate_limit_error", "message": "mock 429"}})
            return
        key = self.headers.get("X-Api-Key") or ""
        authz = self.headers.get("Authorization") or ""
        if authz.startswith("Bearer "): key = authz[7:]
        model = body.get("model", "")
        stream = body.get("stream") is True
        if MODE == "empty":
            # 200 with zero usable content (9router's "HTTP 200 empty" case)
            if stream:
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Connection", "close")
                self.end_headers(); self.close_connection = True
                return
            self._json(200, {})
            return
        # thinking / reasoning translation guards
        if model == "think-test":
            if self.path.endswith("/chat/completions") and "reasoning_effort" not in body:
                self._json(400, {"error": {"message": "reasoning_effort not translated"}}); return
            if self.path.endswith("/messages") and "thinking" not in body:
                self._json(400, {"error": {"message": "thinking not translated"}}); return

        if self.path.endswith("/messages"):
            # anthropic dialect; enforce the one field anthropic requires
            if not isinstance(body.get("max_tokens"), int):
                self._json(400, {"error": {"message": "max_tokens required"}}); return
            if body.get("tools") and "input_schema" not in (body["tools"][0] or {}):
                self._json(400, {"error": {"message": "tools not anthropic-shaped"}}); return
            if stream:
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Connection", "close")
                self.end_headers(); self.close_connection = True
                events = ["event: message_start\ndata: " + json.dumps(
                    {"type": "message_start", "message": {
                        "id": "msg_1", "model": model,
                        "usage": {"input_tokens": 11}}}),
                    "event: content_block_start\ndata: " + json.dumps(
                    {"type": "content_block_start", "index": 0,
                     "content_block": {"type": "text", "text": ""}})]
                for tok in ["Hel", "lo ", "from ", "mock"]:
                    events.append("event: content_block_delta\ndata: " + json.dumps(
                        {"type": "content_block_delta", "index": 0,
                         "delta": {"type": "text_delta", "text": tok}}))
                events.append("event: message_delta\ndata: " + json.dumps(
                    {"type": "message_delta", "delta": {"stop_reason": "end_turn"},
                     "usage": {"output_tokens": 4}}))
                events.append("event: message_stop\ndata: {\"type\":\"message_stop\"}")
                events.append("")
                for e in events:
                    self.wfile.write((e + "\n").encode()); self.wfile.flush()
                    time.sleep(0.3)
                return
            self._json(200, {"id": "msg_1", "type": "message", "role": "assistant",
                             "model": model, "content": [
                                 {"type": "text", "text": "Hi back"}],
                             "stop_reason": "end_turn", "stop_sequence": None,
                             "usage": {"input_tokens": 11, "output_tokens": 3},
                             "received_key": key})

        if self.path.endswith("/embeddings"):
            self._json(200, {"object": "list", "model": model,
                              "data": [{"object": "embedding", "index": 0, "embedding": [0.1]}],
                              "received_key": key})
            return
        if self.path.endswith("/images/generations"):
            self._json(200, {"created": 1, "data": [{"url": "http://mock/img.png"}],
                              "model": model, "received_key": key})
            return
        # openai dialect
        if body.get("tools") and (body["tools"][0] or {}).get("type") != "function":
            self._json(400, {"error": {"message": "tools not openai-shaped"}}); return
        if stream:
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Connection", "close")
            self.end_headers(); self.close_connection = True
            chunks = [
                {"id": "c1", "model": model, "choices": [{"index": 0,
                 "delta": {"role": "assistant", "content": "Hel"}, "finish_reason": None}]},
                {"id": "c1", "model": model, "choices": [{"index": 0,
                 "delta": {"content": "lo"}, "finish_reason": None}]},
                {"id": "c1", "model": model, "choices": [{"index": 0,
                 "delta": {}, "finish_reason": "stop"}],
                 "usage": {"prompt_tokens": 10, "completion_tokens": 2}},
            ]
            for c in chunks:
                self.wfile.write(("data: " + json.dumps(c) + "\n\n").encode())
                self.wfile.flush(); time.sleep(0.3)
            self.wfile.write(b"data: [DONE]\n\n"); self.wfile.flush()
            return
        self._json(200, {"id": "c1", "object": "chat.completion", "model": model,
                          "choices": [{"index": 0, "message": {"role": "assistant",
                                       "content": "Yo back"}, "finish_reason": "stop"}],
                          "usage": {"prompt_tokens": 10, "completion_tokens": 2},
                          "received_key": key})

ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
MOCKEOF

# ----- test config: providers + 9router-style accounts -----
cat > "$T/config.txt" <<'EOF'
aigate.main.port='20128'
aigate.main.api_key='testkey'
aigate.prov_fail.type='anthropic'
aigate.prov_fail.base_url='http://127.0.0.1:18081/v1'
aigate.ac_fail.provider='prov_fail'
aigate.ac_fail.api_key='k1'
aigate.ac_fail.tier='free'
aigate.prov_sse.type='anthropic'
aigate.prov_sse.base_url='http://127.0.0.1:18080/v1'
aigate.prov_sse.models='claude-sse,claude-b'
aigate.ac_sse.provider='prov_sse'
aigate.ac_sse.api_key='k2'
aigate.ac_sse.tier='subscription'
aigate.prov_oai.type='openai'
aigate.prov_oai.base_url='http://127.0.0.1:18080/v1'
aigate.prov_oai.models='gpt-x'
aigate.ac_oai.provider='prov_oai'
aigate.ac_oai.api_key='k3'
aigate.ac_oai.tier='free'
EOF
sed 's/^aigate.main.api_key=.*/aigate.main.api_key=/' "$T/config.txt" > "$T/config-noauth.txt"

cat > "$T/config-tier.txt" <<'EOF'
aigate.main.api_key=''
aigate.prov_tier.type='anthropic'
aigate.prov_tier.base_url='http://127.0.0.1:18080/v1'
aigate.ac_free.provider='prov_tier'
aigate.ac_free.api_key='k_free'
aigate.ac_free.tier='free'
aigate.ac_sub.provider='prov_tier'
aigate.ac_sub.api_key='k_sub'
aigate.ac_sub.tier='subscription'
EOF

cat > "$T/config-rr.txt" <<'EOF'
aigate.main.api_key=''
aigate.prov_rr.type='anthropic'
aigate.prov_rr.base_url='http://127.0.0.1:18080/v1'
aigate.ac_a.provider='prov_rr'
aigate.ac_a.api_key='k_a'
aigate.ac_a.tier='free'
aigate.ac_b.provider='prov_rr'
aigate.ac_b.api_key='k_b'
aigate.ac_b.tier='free'
EOF

cat > "$T/config-cat.txt" <<'EOF'
aigate.main.api_key=''
aigate.prov_cat.type='anthropic'
aigate.prov_cat.base_url='http://127.0.0.1:18080/v1'
aigate.prov_cat.models='gpt-x'
aigate.ac_cat.provider='prov_cat'
aigate.ac_cat.api_key='kc'
EOF

cat > "$T/config-fail.txt" <<'EOF'
aigate.main.api_key=''
aigate.prov_dead.type='anthropic'
aigate.prov_dead.base_url='http://127.0.0.1:18081/v1'
aigate.ac_dead.provider='prov_dead'
aigate.ac_dead.api_key='kd'
EOF

cat > "$T/config-dead.txt" <<'EOF'
aigate.main.api_key=''
aigate.prov_x.type='anthropic'
aigate.prov_x.base_url='http://127.0.0.1:18099/v1'
aigate.ac_x.provider='prov_x'
aigate.ac_x.api_key='kx'
EOF

cat > "$T/config-combo.txt" <<'EOF'
aigate.main.api_key=''
aigate.prov_c1.type='anthropic'
aigate.prov_c1.base_url='http://127.0.0.1:18081/v1'
aigate.acc_c1.provider='prov_c1'
aigate.acc_c1.api_key='kc1'
aigate.acc_c1.tier='free'
aigate.prov_c2.type='anthropic'
aigate.prov_c2.base_url='http://127.0.0.1:18080/v1'
aigate.prov_c2.models='claude-sse'
aigate.acc_c2.provider='prov_c2'
aigate.acc_c2.api_key='kc2'
aigate.acc_c2.tier='free'
aigate.smart.chain='claude-b,claude-sse'
EOF

cat > "$T/config-side.txt" <<'EOF'
aigate.main.api_key=''
aigate.prov_side.type='openai'
aigate.prov_side.base_url='http://127.0.0.1:18080/v1'
aigate.prov_side.embeddings='1'
aigate.prov_side.images='1'
aigate.acc_side.provider='prov_side'
aigate.acc_side.api_key='kside'
EOF

cat > "$T/config-empty.txt" <<'EOF'
aigate.main.api_key=''
aigate.prov_e1.type='anthropic'
aigate.prov_e1.base_url='http://127.0.0.1:18082/v1'
aigate.acc_e1.provider='prov_e1'
aigate.acc_e1.api_key='ke1'
aigate.prov_e2.type='anthropic'
aigate.prov_e2.base_url='http://127.0.0.1:18080/v1'
aigate.acc_e2.provider='prov_e2'
aigate.acc_e2.api_key='ke2'
aigate.acc_e2.models=''
aigate.prov_e2.models='claude-sse'
EOF

cat > "$T/config-think.txt" <<'EOF'
aigate.main.api_key=''
aigate.prov_th.type='openai'
aigate.prov_th.base_url='http://127.0.0.1:18080/v1'
aigate.acc_th.provider='prov_th'
aigate.acc_th.api_key='kth'
EOF

cat > "$T/config-quota.txt" <<'EOF'
aigate.main.api_key=''
aigate.prov_q.type='anthropic'
aigate.prov_q.base_url='http://127.0.0.1:18080/v1'
aigate.acc_q.provider='prov_q'
aigate.acc_q.api_key='kq'
aigate.acc_q.daily_limit='100'
EOF

python3 "$T/mock.py" sse 18080 & MOCK1=$!
python3 "$T/mock.py" fail 18081 & MOCK2=$!
python3 "$T/mock.py" empty 18082 & MOCK3=$!
trap 'kill $MOCK1 $MOCK2 ${MOCK3:-} 2>/dev/null; rm -rf "$T"' EXIT
sleep 0.5

run() { # run <outfile> <method> <uri> <body> [auth] [cfg]
  local out=$1 m=$2 uri=$3 body=${4:-} auth=${5:-} cfg=${6:-$T/config.txt}
  { printf '%s' "$body" | env AIGATE_CONFIG_FILE="$cfg" \
      REQUEST_METHOD="$m" REQUEST_URI="$uri" \
      CONTENT_LENGTH="${#body}" HTTP_AUTHORIZATION="$auth" \
      "$LUA" "$G"; } > "$out" 2>"$out.err"
}

BODY='{"model":"claude-sse","stream":true,"max_tokens":100,"messages":[{"role":"user","content":"hi"}]}'

echo "== T1: health JSON (no dashboard page — LuCI is the dashboard) =="
run "$T/t1.out" GET "/"
check "T1 json" "$T/t1.out" '"app":"aigate"'
check "T1 providers" "$T/t1.out" '"providers":3'
check "T1 accounts" "$T/t1.out" '"accounts":3'
check "T1 auth on" "$T/t1.out" '"auth":"on"'

echo "== T2: auth required when key set =="
run "$T/t2.out" POST "/v1/messages" "$BODY"
check "T2 401" "$T/t2.out" "Status: 401"

echo "== T3: models list =="
run "$T/t3.out" GET "/v1/models" "" "Bearer testkey"
check "T3 json content-type" "$T/t3.out" "Content-Type: application/json"
check "T3 has claude-sse" "$T/t3.out" '"claude-sse"'
check "T3 has gpt-x" "$T/t3.out" '"gpt-x"'

echo "== T4: SSE streaming + tier fallback (subscription first, free after) =="
START=$(date +%s%3N 2>/dev/null || date +%s000)
{ printf '%s' "$BODY" | env AIGATE_CONFIG_FILE="$T/config.txt" \
    REQUEST_METHOD=POST REQUEST_URI=/v1/messages \
    CONTENT_LENGTH="${#BODY}" HTTP_AUTHORIZATION="Bearer testkey" \
    "$LUA" "$G"; } | while IFS= read -r l; do
      echo "$(($(date +%s%3N 2>/dev/null || date +%s000) - START)) $l"
    done > "$T/t4.out" 2>"$T/t4.err"
check "T4 got 200" "$T/t4.out" "200 OK"
check "T4 sse content-type" "$T/t4.out" "text/event-stream"
check "T4 events streamed" "$T/t4.out" "content_block_delta"
check "T4 message_stop" "$T/t4.out" "message_stop"
GAPS=$(awk '{t=$1; if (prev && t-prev>=200) g++; prev=t} END{print g+0}' "$T/t4.out")
if [ "$GAPS" -ge 3 ]; then ok "T4 progressive streaming ($GAPS gaps >=200ms)"; else bad "T4 progressive streaming (only $GAPS gaps)"; fi

echo "== T5: no auth on open config =="
run "$T/t5.out" GET "/v1/models" "" "" "$T/config-noauth.txt"
check "T5 200" "$T/t5.out" '"object":"list"'

echo "== T6: openai passthrough (non-stream JSON) =="
OB='{"model":"gpt-x","stream":false,"messages":[{"role":"user","content":"hi"}]}'
run "$T/t6.out" POST "/v1/chat/completions" "$OB" "Bearer testkey"
check "T6 200" "$T/t6.out" "Status: 200"
check "T6 body forwarded" "$T/t6.out" "Yo back"
check "T6 right key used" "$T/t6.out" '"received_key": "k3"'

echo "== T7: all accounts fail -> 502 =="
run "$T/t7.out" POST "/v1/messages" "$BODY" "" "$T/config-fail.txt"
check "T7 502" "$T/t7.out" "Status: 502"
check "T7 names account" "$T/t7.out" "prov_dead/ac_dead -> HTTP 429"

echo "== T8: 404 =="
run "$T/t8.out" GET "/v1/nope"
check "T8 404" "$T/t8.out" "Status: 404"

echo "== T9: dead upstream (curl fails) =="
run "$T/t9.out" POST "/v1/messages" "$BODY" "" "$T/config-dead.txt"
check "T9 502 curl-fail" "$T/t9.out" "curl-fail"

echo "== T15: GLOBAL tier order (subscription beats free, even if free listed first) =="
NB='{"model":"claude-sse","stream":false,"max_tokens":50,"messages":[{"role":"user","content":"x"}]}'
run "$T/t15.out" POST "/v1/messages" "$NB" "" "$T/config-tier.txt"
check "T15 200" "$T/t15.out" "Status: 200"
check "T15 subscription key used" "$T/t15.out" '"received_key": "k_sub"'

echo "== T16: round-robin across same-tier accounts =="
run "$T/t16a.out" POST "/v1/messages" "$NB" "" "$T/config-rr.txt"
run "$T/t16b.out" POST "/v1/messages" "$NB" "" "$T/config-rr.txt"
K1=$(grep -o '"received_key": "[^"]*"' "$T/t16a.out" | head -1)
K2=$(grep -o '"received_key": "[^"]*"' "$T/t16b.out" | head -1)
if [ -n "$K1" ] && [ -n "$K2" ] && [ "$K1" != "$K2" ]; then
  ok "T16 round-robin alternates ($K1 then $K2)"
else
  bad "T16 round-robin (got $K1 / $K2)"
fi

echo "== T17: model catalog gate =="
CB='{"model":"claude-nope","stream":false,"max_tokens":50,"messages":[{"role":"user","content":"x"}]}'
run "$T/t17.out" POST "/v1/messages" "$CB" "" "$T/config-cat.txt"
check "T17 404 no account" "$T/t17.out" "no account serves model"

echo "== T18: combo = ordered model chain with full fallback =="
CBY='{"model":"smart","stream":false,"max_tokens":50,"messages":[{"role":"user","content":"x"}]}'
run "$T/t18.out" POST "/v1/messages" "$CBY" "" "$T/config-combo.txt"
check "T18 combo resolved" "$T/t18.out" "Status: 200"
check "T18 step2 used" "$T/t18.out" '"received_key": "kc2"'
run "$T/t18m.out" GET "/v1/models" "" "" "$T/config-combo.txt"
check "T18 combo in models" "$T/t18m.out" '"owned_by":"aigate-combo"'

echo "== T19: /v1/embeddings passthrough =="
EB='{"model":"embed-v1","input":"hello"}'
run "$T/t19.out" POST "/v1/embeddings" "$EB" "" "$T/config-side.txt"
check "T19 200" "$T/t19.out" "Status: 200"
check "T19 data" "$T/t19.out" '"object": "list"'
check "T19 key" "$T/t19.out" '"received_key": "kside"'

echo "== T20: /v1/images/generations passthrough =="
IB='{"model":"img-v1","prompt":"a cat"}'
run "$T/t20.out" POST "/v1/images/generations" "$IB" "" "$T/config-side.txt"
check "T20 200" "$T/t20.out" "Status: 200"
check "T20 data" "$T/t20.out" 'img.png'

echo "== T25: HTTP-200-with-empty-body falls through to next account =="
EB2='{"model":"claude-sse","stream":false,"max_tokens":50,"messages":[{"role":"user","content":"x"}]}'
run "$T/t25.out" POST "/v1/messages" "$EB2" "" "$T/config-empty.txt"
check "T25 got real content via fallback" "$T/t25.out" "Hi back"
if grep -q '"content":\s*"Hi back"' "$T/t25.out" || grep -q 'Hi back' "$T/t25.out"; then
  ok "T25 skipped empty provider (e1) and used e2"
else
  bad "T25 fallback content"
fi

echo "== T26: thinking (Anthropic) translated to reasoning_effort (OpenAI) =="
TB='{"model":"think-test","stream":false,"max_tokens":50,"thinking":{"type":"enabled","budget_tokens":8000},"messages":[{"role":"user","content":"x"}]}'
run "$T/t26.out" POST "/v1/messages" "$TB" "" "$T/config-think.txt"
check "T26 translated (upstream accepted)" "$T/t26.out" "Status: 200"
check "T26 body went through" "$T/t26.out" "Yo back"

echo "== T27: daily quota skips exhausted account =="
mkdir -p /tmp/aigate-quota
echo "999999" > "/tmp/aigate-quota/acc_q_$(date +%Y-%m-%d)"
QB='{"model":"claude-sse","stream":false,"max_tokens":50,"messages":[{"role":"user","content":"x"}]}'
run "$T/t27.out" POST "/v1/messages" "$QB" "" "$T/config-quota.txt"
check "T27 502 quota" "$T/t27.out" "quota_exceeded"
rm -f "/tmp/aigate-quota/acc_q_$(date +%Y-%m-%d)"

echo ""
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
