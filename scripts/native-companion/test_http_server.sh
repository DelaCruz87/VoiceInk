#!/bin/zsh
# ENSO ad-hoc local override: synthetic harness for the approved VoiceInk Companion API v1.
# It assumes macOS swiftc/curl and the current transport sources; revalidate when toolchains,
# authentication, loopback policy, or request limits change upstream.

set -euo pipefail

repo_root=${0:A:h:h:h}
scratch=$(mktemp -d "${TMPDIR:-/tmp}/voiceink-companion-http.XXXXXX")
port=$((42000 + ($$ % 18000)))
harness="$scratch/companion-http-harness"
harness_pid=""

cleanup() {
    if [[ -n "$harness_pid" ]] && kill -0 "$harness_pid" 2>/dev/null; then
        kill "$harness_pid"
        wait "$harness_pid" 2>/dev/null || true
    fi
    rm -rf "$scratch"
}
trap cleanup EXIT INT TERM

xcrun swiftc \
    "$repo_root/VoiceInk/Infrastructure/SystemIntegration/Companion/CompanionModels.swift" \
    "$repo_root/VoiceInk/Infrastructure/SystemIntegration/Companion/CompanionHTTPServer.swift" \
    "$repo_root/scripts/native-companion/CompanionHTTPHarness.swift" \
    -o "$harness"

VOICEINK_COMPANION_PORT="$port" "$harness" >"$scratch/harness.log" 2>&1 &
harness_pid=$!

ready=0
for _ in {1..50}; do
    code=$(curl --silent --output "$scratch/ready.json" --write-out '%{http_code}' \
        --header 'Authorization: Bearer synthetic-token' \
        "http://127.0.0.1:$port/v1/probe" || true)
    if [[ "$code" == "200" ]]; then
        ready=1
        break
    fi
    sleep 0.1
done
[[ "$ready" == "1" ]]
grep -q '"status"[[:space:]]*:[[:space:]]*"ok"' "$scratch/ready.json"

unauthorized=$(curl --silent --output "$scratch/unauthorized.json" --write-out '%{http_code}' \
    "http://127.0.0.1:$port/v1/probe")
[[ "$unauthorized" == "401" ]]

invalid_host=$(curl --silent --output "$scratch/invalid-host.json" --write-out '%{http_code}' \
    --header 'Host: companion.invalid' \
    --header 'Authorization: Bearer synthetic-token' \
    "http://127.0.0.1:$port/v1/probe")
[[ "$invalid_host" == "400" ]]

unsupported_method=$(curl --silent --request PATCH --output "$scratch/method.json" --write-out '%{http_code}' \
    --header 'Authorization: Bearer synthetic-token' \
    "http://127.0.0.1:$port/v1/probe")
[[ "$unsupported_method" == "405" ]]

head -c 1048577 /dev/zero >"$scratch/oversized.bin"
oversized=$(curl --silent --request POST --data-binary "@$scratch/oversized.bin" \
    --output "$scratch/oversized.json" --write-out '%{http_code}' \
    --header 'Authorization: Bearer synthetic-token' \
    "http://127.0.0.1:$port/v1/probe")
[[ "$oversized" == "413" ]]

print 'PASS native companion HTTP transport: auth, loopback Host, method, and body limits'
