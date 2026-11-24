#!/usr/bin/env bash
cd "$1" || exit 1
PORT=$((20000 + RANDOM % 20000)); export PORT
node server.js >/dev/null 2>&1 & SP=$!
trap 'kill $SP 2>/dev/null' EXIT
for i in $(seq 1 30); do curl -s --noproxy '*' "http://127.0.0.1:$PORT/health" >/dev/null && break; sleep 0.2; done
g() { curl -s --noproxy '*' -o /tmp/chk.$$ -w '%{http_code}' "http://127.0.0.1:$PORT$1"; }
fail() { echo "FAIL: $1"; exit 1; }
[ "$(g /orders/2)" = 200 ] || fail "GET /orders/2 status"
[ "$(jq -r '.customer' /tmp/chk.$$)" = bo ] || fail "order 2 body"
[ "$(g /orders/999)" = 404 ] || fail "missing order should be 404"
jq -e . /tmp/chk.$$ >/dev/null || fail "404 body not JSON"
c=$(g /orders/abc); { [ "$c" = 400 ] || [ "$c" = 404 ]; } || fail "nonsense id got $c"
jq -e . /tmp/chk.$$ >/dev/null || fail "bad-id body not JSON"
[ "$(g '/orders?customer=ana')" = 200 ] && [ "$(jq length /tmp/chk.$$)" = 2 ] || fail "customer filter"
[ "$(g '/orders?customer=ana&status=paid')" = 200 ] && [ "$(jq length /tmp/chk.$$)" = 1 ] || fail "combined filter"
[ "$(g '/orders?status=nope')" = 200 ] && [ "$(jq length /tmp/chk.$$)" = 0 ] || fail "empty filter result"
[ "$(g /orders)" = 200 ] && [ "$(jq length /tmp/chk.$$)" = 3 ] || fail "unfiltered list regressed"
[ "$(g /health)" = 200 ] || fail "health regressed"
rm -f /tmp/chk.$$
