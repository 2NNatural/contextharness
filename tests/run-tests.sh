#!/usr/bin/env bash
# Regression suite for install.sh. Runs entirely in a sandbox HOME under mktemp;
# never touches the real ~/.claude. Exits 0 only if all tests pass.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
run() { HOME="$1" bash "$REPO/install.sh" >/dev/null 2>&1; }
file_mode() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null
}
P=0; F=0
pass() { echo "PASS: $1"; P=$((P+1)); }
fail() { echo "FAIL: $1"; F=$((F+1)); }

# T1 fresh install
H="$SANDBOX/t1"; mkdir -p "$H"; run "$H"
[ "$(ls "$H/.claude/agents" | sort | tr '\n' ' ')" = "architect.md executor.md oracle.md scout.md " ] && pass "T1 four agents installed" || fail "T1 agents"
[ "$(grep -cxF '<!-- model-harness:start -->' "$H/.claude/CLAUDE.md")" = 1 ] && pass "T1 exactly one block" || fail "T1 block count"

# T2 idempotency
cp "$H/.claude/CLAUDE.md" "$SANDBOX/before"; run "$H"
cmp -s "$SANDBOX/before" "$H/.claude/CLAUDE.md" && pass "T2 second run byte-identical" || fail "T2 not idempotent"

# T3/T4 user content above and below the block preserved through replace
H="$SANDBOX/t3"; mkdir -p "$H/.claude"
printf '# personal\nabove content\n' > "$H/.claude/CLAUDE.md"; run "$H"
printf '\n# trailing\nbelow content\n' >> "$H/.claude/CLAUDE.md"; run "$H"
grep -q 'above content' "$H/.claude/CLAUDE.md" && grep -q 'below content' "$H/.claude/CLAUDE.md" \
  && [ "$(grep -cxF '<!-- model-harness:start -->' "$H/.claude/CLAUDE.md")" = 1 ] \
  && pass "T3/T4 content above+below preserved through replace" || fail "T3/T4 content lost"

# T5 pre-existing file without trailing newline
H="$SANDBOX/t5"; mkdir -p "$H/.claude"; printf 'no newline' > "$H/.claude/CLAUDE.md"; run "$H"
grep -qx -- '<!-- model-harness:start -->' "$H/.claude/CLAUDE.md" && pass "T5 marker on its own line" || fail "T5 marker merged"

# T6 rules-file update flows through on re-run
W="$SANDBOX/repo"; cp -R "$REPO" "$W"; rm -rf "$W/.claude" "$W/.git"
H="$SANDBOX/t6"; mkdir -p "$H"; HOME="$H" bash "$W/install.sh" >/dev/null 2>&1
sed 's/# Model-Routing Harness/# Model-Routing Harness v2/' "$W/routing-rules.md" > "$W/routing-rules.md.new" \
  && mv "$W/routing-rules.md.new" "$W/routing-rules.md"
HOME="$H" bash "$W/install.sh" >/dev/null 2>&1
grep -q 'Harness v2' "$H/.claude/CLAUDE.md" && pass "T6 updated rules replace old block" || fail "T6 stale block"

# T7 orphan start marker -> refuse, file untouched
H="$SANDBOX/t7"; mkdir -p "$H/.claude"
printf 'above\n<!-- model-harness:start -->\nstale\nmust survive\n' > "$H/.claude/CLAUDE.md"
cp "$H/.claude/CLAUDE.md" "$SANDBOX/t7.orig"
if run "$H"; then fail "T7 should have refused (exited 0)"; else
  cmp -s "$SANDBOX/t7.orig" "$H/.claude/CLAUDE.md" && pass "T7 orphan start: refused, file untouched" || fail "T7 refused but file modified"
fi

# T8 duplicate blocks -> refuse, file untouched
H="$SANDBOX/t8"; mkdir -p "$H"; run "$H"
cat "$REPO/routing-rules.md" >> "$H/.claude/CLAUDE.md"
cp "$H/.claude/CLAUDE.md" "$SANDBOX/t8.orig"
if run "$H"; then fail "T8 should refuse on 2 blocks"; else
  cmp -s "$SANDBOX/t8.orig" "$H/.claude/CLAUDE.md" && pass "T8 duplicate blocks: refused, untouched" || fail "T8 modified"
fi

# T9 out-of-order markers -> refuse
H="$SANDBOX/t9"; mkdir -p "$H/.claude"
printf '<!-- model-harness:end -->\nmiddle\n<!-- model-harness:start -->\ntail\n' > "$H/.claude/CLAUDE.md"
if run "$H"; then fail "T9 should refuse out-of-order markers"; else pass "T9 out-of-order markers: refused"; fi

# T10 symlinked CLAUDE.md preserved (dotfile-repo setups)
H="$SANDBOX/t10"; mkdir -p "$H/.claude" "$SANDBOX/dotfiles"
printf 'dotfile content\n' > "$SANDBOX/dotfiles/CLAUDE.md"
ln -s "$SANDBOX/dotfiles/CLAUDE.md" "$H/.claude/CLAUDE.md"
run "$H"; run "$H"
[ -L "$H/.claude/CLAUDE.md" ] && grep -q 'model-harness:start' "$SANDBOX/dotfiles/CLAUDE.md" \
  && grep -q 'dotfile content' "$SANDBOX/dotfiles/CLAUDE.md" \
  && pass "T10 symlink preserved, target updated" || fail "T10 symlink severed"

# T11 permissions preserved through replace
H="$SANDBOX/t11"; mkdir -p "$H"; run "$H"; chmod 644 "$H/.claude/CLAUDE.md"; run "$H"
perms=$(file_mode "$H/.claude/CLAUDE.md")
[ "$perms" = "644" ] && pass "T11 perms preserved (644)" || fail "T11 perms changed: $perms"

# T12 marker mentioned in prose (substring) does NOT trigger replace
H="$SANDBOX/t12"; mkdir -p "$H/.claude"
printf 'docs: the block sits between `<!-- model-harness:start -->` markers\n' > "$H/.claude/CLAUDE.md"
run "$H"
grep -q 'docs: the block' "$H/.claude/CLAUDE.md" \
  && [ "$(grep -cxF '<!-- model-harness:start -->' "$H/.claude/CLAUDE.md")" = 1 ] \
  && pass "T12 prose mention ignored; real block appended" || fail "T12 substring false-positive"

# T13 missing agents/ -> clear upfront error
W2="$SANDBOX/repo2"; mkdir -p "$W2"; cp "$REPO/install.sh" "$REPO/routing-rules.md" "$W2/"
H="$SANDBOX/t13"; mkdir -p "$H"
if HOME="$H" bash "$W2/install.sh" >/dev/null 2>"$SANDBOX/t13.err"; then fail "T13 should error"; else
  grep -q 'agents not found' "$SANDBOX/t13.err" && pass "T13 missing agents/: clear error" || fail "T13 wrong error: $(cat "$SANDBOX/t13.err")"
fi

# T14 unreadable rules file -> upfront error, CLAUDE.md untouched
W3="$SANDBOX/repo3"; cp -R "$REPO" "$W3"; rm -rf "$W3/.git" "$W3/.claude"; chmod 000 "$W3/routing-rules.md"
H="$SANDBOX/t14"; mkdir -p "$H"
if HOME="$H" bash "$W3/install.sh" >/dev/null 2>"$SANDBOX/t14.err"; then fail "T14 should error"; else
  grep -q 'cannot read' "$SANDBOX/t14.err" && pass "T14 unreadable rules: upfront error" || fail "T14 wrong error"
fi
chmod 644 "$W3/routing-rules.md"

echo ""
echo "=== RESULTS: $P passed, $F failed ==="
[ "$F" -eq 0 ]
