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
P=0; F=0; S=0
pass() { echo "PASS: $1"; P=$((P+1)); }
fail() { echo "FAIL: $1"; F=$((F+1)); }
skip() { echo "SKIP: $1"; S=$((S+1)); }

# Detect symlink support directly rather than sniffing uname: Git Bash's
# `ln -s` silently copies instead of symlinking without elevated privileges
# or Developer Mode on Windows, which would otherwise make T10 a false fail.
symlinks_supported() {
  local probe_dir target link ok
  probe_dir="$(mktemp -d)"
  target="${probe_dir}/target"
  link="${probe_dir}/link"
  printf 'x' > "${target}"
  ln -s "${target}" "${link}" 2>/dev/null
  ok=1
  [ -L "${link}" ] && ok=0
  rm -rf "${probe_dir}"
  return "${ok}"
}

# Capability probe: is jq available for the settings.json merge tests?
jq_available() { command -v jq >/dev/null 2>&1; }

# Detect whether chmod 000 actually blocks reads for the current user.
# On NTFS (including via Git Bash/MSYS), chmod 000 does not enforce
# unreadability, which would otherwise make T14 a false fail.
chmod_000_enforced() {
  local probe_file ok
  probe_file="$(mktemp)"
  printf 'x' > "${probe_file}"
  chmod 000 "${probe_file}"
  ok=1
  cat "${probe_file}" >/dev/null 2>&1 || ok=0
  chmod 644 "${probe_file}"
  rm -f "${probe_file}"
  return "${ok}"
}

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
if symlinks_supported; then
  H="$SANDBOX/t10"; mkdir -p "$H/.claude" "$SANDBOX/dotfiles"
  printf 'dotfile content\n' > "$SANDBOX/dotfiles/CLAUDE.md"
  ln -s "$SANDBOX/dotfiles/CLAUDE.md" "$H/.claude/CLAUDE.md"
  run "$H"; run "$H"
  [ -L "$H/.claude/CLAUDE.md" ] && grep -q 'model-harness:start' "$SANDBOX/dotfiles/CLAUDE.md" \
    && grep -q 'dotfile content' "$SANDBOX/dotfiles/CLAUDE.md" \
    && pass "T10 symlink preserved, target updated" || fail "T10 symlink severed"
else
  skip "T10 (symlinks unsupported on this platform)"
fi

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
if chmod_000_enforced; then
  W3="$SANDBOX/repo3"; cp -R "$REPO" "$W3"; rm -rf "$W3/.git" "$W3/.claude"; chmod 000 "$W3/routing-rules.md"
  H="$SANDBOX/t14"; mkdir -p "$H"
  if HOME="$H" bash "$W3/install.sh" >/dev/null 2>"$SANDBOX/t14.err"; then fail "T14 should error"; else
    grep -q 'cannot read' "$SANDBOX/t14.err" && pass "T14 unreadable rules: upfront error" || fail "T14 wrong error"
  fi
  chmod 644 "$W3/routing-rules.md"
else
  skip "T14 (chmod 000 unreadable-file enforcement unsupported on this platform)"
fi

# T15: --top-model opus rewrites installed oracle.md; re-run with --top-model fable restores it
H="$SANDBOX/t15"; mkdir -p "$H"
HOME="$H" bash "$REPO/install.sh" --top-model opus >/dev/null 2>&1
installed_oracle="$H/.claude/agents/oracle.md"
if grep -qx 'model: opus' "$installed_oracle" \
   && ! grep -q 'claude-fable-5' "$installed_oracle" \
   && grep -qx 'model: claude-fable-5\[1m\]' "$REPO/agents/oracle.md"; then
  pass "T15a opus: installed oracle has model: opus, repo copy unchanged"
else
  fail "T15a opus: installed oracle model wrong or repo copy modified"
fi
# Now switch back to fable in the same HOME
HOME="$H" bash "$REPO/install.sh" --top-model fable >/dev/null 2>&1
if grep -qx 'model: claude-fable-5\[1m\]' "$installed_oracle"; then
  pass "T15b fable: re-run restores installed oracle to model: claude-fable-5[1m]"
else
  fail "T15b fable: installed oracle not restored"
fi

# T16: no flag, stdin not a TTY -> defaults to fable silently
# Strip ANTHROPIC_API_KEY and claude CLI from PATH so probe is deterministically inconclusive.
H="$SANDBOX/t16"; mkdir -p "$H"
env -u ANTHROPIC_API_KEY HOME="$H" PATH="/usr/bin:/bin" bash "$REPO/install.sh" </dev/null >/dev/null 2>&1
if grep -qx 'model: claude-fable-5\[1m\]' "$H/.claude/agents/oracle.md"; then
  pass "T16 non-TTY default: installed oracle retains model: claude-fable-5[1m]"
else
  fail "T16 non-TTY default: installed oracle wrong"
fi

# T17: --top-model with invalid value -> exits non-zero, prints error, installs nothing
H="$SANDBOX/t17"; mkdir -p "$H"
if HOME="$H" bash "$REPO/install.sh" --top-model gpt5 >/dev/null 2>"$SANDBOX/t17.err"; then
  fail "T17 should exit non-zero for invalid --top-model"
else
  if grep -qiE 'fable|opus' "$SANDBOX/t17.err"; then
    pass "T17 invalid --top-model: exits non-zero, error mentions valid values"
  else
    fail "T17 invalid --top-model: exited non-zero but error doesn't mention valid values: $(cat "$SANDBOX/t17.err")"
  fi
fi

# T18: skill file installs into the sandbox HOME
H="$SANDBOX/t18"; mkdir -p "$H"; run "$H"
if [ -f "$H/.claude/skills/routing-refresh/SKILL.md" ] \
   && grep -q 'name: routing-refresh' "$H/.claude/skills/routing-refresh/SKILL.md"; then
  pass "T18 routing-refresh skill installed to HOME"
else
  fail "T18 skill not installed"
fi

# T19: skills copy is idempotent (second run byte-identical)
cp "$H/.claude/skills/routing-refresh/SKILL.md" "$SANDBOX/t19.before"; run "$H"
cmp -s "$SANDBOX/t19.before" "$H/.claude/skills/routing-refresh/SKILL.md" \
  && pass "T19 skill install idempotent" || fail "T19 skill changed on re-run"

# T20: tier probe falls back to fable when no API access (non-TTY, no key, no claude CLI)
H="$SANDBOX/t20"; mkdir -p "$H"
env -u ANTHROPIC_API_KEY HOME="$H" PATH="/usr/bin:/bin" \
  bash "$REPO/install.sh" </dev/null >/dev/null 2>&1
if grep -qx 'model: claude-fable-5\[1m\]' "$H/.claude/agents/oracle.md"; then
  pass "T20 no-API probe falls back to fable"
else
  fail "T20 probe fallback wrong: $(grep '^model:' "$H/.claude/agents/oracle.md")"
fi

# T21: install.sh neither creates the Codex toggle nor clobbers an existing one
H="$SANDBOX/t21"; mkdir -p "$H"; run "$H"
[ ! -e "$H/.claude/codex-routing.on" ] && pass "T21a fresh install leaves Codex toggle OFF (absent)" || fail "T21a toggle created"
touch "$H/.claude/codex-routing.on"; run "$H"
[ -e "$H/.claude/codex-routing.on" ] && pass "T21b re-run preserves Codex toggle" || fail "T21b toggle clobbered"

# T22 default install does NOT create the hook or touch settings.json
H="$SANDBOX/t22"; mkdir -p "$H"; run "$H"
[ ! -e "$H/.claude/hooks/context-meter.sh" ] && [ ! -e "$H/.claude/settings.json" ] \
  && pass "T22 default install leaves hook + settings.json absent" || fail "T22 hook/settings created by default"

# T23 --with-context-hook installs the script executable
# (--top-model opus pinned throughout T23-T26 to skip the live tier probe,
#  which shells out to a real `claude` CLI if present and can mutate the
#  sandbox settings.json as an unrelated side effect — irrelevant here but
#  would make the settings-merge assertions below non-deterministic.)
H="$SANDBOX/t23"; mkdir -p "$H"
HOME="$H" bash "$REPO/install.sh" --top-model opus --with-context-hook >/dev/null 2>&1
[ -f "$H/.claude/hooks/context-meter.sh" ] && [ -x "$H/.claude/hooks/context-meter.sh" ] \
  && pass "T23 hook script installed + executable" || fail "T23 hook not installed"

# T24 settings.json merge: valid JSON, our command present, idempotent
if jq_available; then
  grep -q 'context-meter.sh' "$H/.claude/settings.json" \
    && jq empty "$H/.claude/settings.json" 2>/dev/null \
    && pass "T24a settings.json merged, valid, references hook" || fail "T24a merge/validity"
  cp "$H/.claude/settings.json" "$SANDBOX/t24.before"
  HOME="$H" bash "$REPO/install.sh" --top-model opus --with-context-hook >/dev/null 2>&1
  cmp -s "$SANDBOX/t24.before" "$H/.claude/settings.json" \
    && pass "T24b merge idempotent (second run byte-identical)" || fail "T24b not idempotent"
else
  skip "T24 (jq unavailable — settings merge path skipped)"
fi

# T25 merge preserves pre-existing user settings.json content (model + a user hook)
if jq_available; then
  H="$SANDBOX/t25"; mkdir -p "$H/.claude"
  printf '{"model":"opus","hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"/usr/bin/true"}]}]}}\n' \
    > "$H/.claude/settings.json"
  HOME="$H" bash "$REPO/install.sh" --top-model opus --with-context-hook >/dev/null 2>&1
  jq empty "$H/.claude/settings.json" 2>/dev/null \
    && [ "$(jq -r '.model' "$H/.claude/settings.json")" = "opus" ] \
    && grep -q '/usr/bin/true' "$H/.claude/settings.json" \
    && grep -q 'context-meter.sh' "$H/.claude/settings.json" \
    && pass "T25 existing settings + user hook preserved through merge" || fail "T25 user settings clobbered"
else
  skip "T25 (jq unavailable)"
fi

# T26 --remove-context-hook strips our entry, keeps user content, removes script
if jq_available; then
  HOME="$H" bash "$REPO/install.sh" --top-model opus --remove-context-hook >/dev/null 2>&1
  [ ! -e "$H/.claude/hooks/context-meter.sh" ] \
    && jq empty "$H/.claude/settings.json" 2>/dev/null \
    && ! grep -q 'context-meter.sh' "$H/.claude/settings.json" \
    && grep -q '/usr/bin/true' "$H/.claude/settings.json" \
    && [ "$(jq -r '.model' "$H/.claude/settings.json")" = "opus" ] \
    && pass "T26 remove: hook gone, user settings intact" || fail "T26 remove wrong"
else
  skip "T26 (jq unavailable)"
fi

# T27 hook logic: above-band prints [context: ~N%], below-band prints nothing
HOOK="$REPO/hooks/context-meter.sh"
if jq_available && [ -f "$HOOK" ]; then
  TJ="$SANDBOX/t27.jsonl"
  printf '%s\n' '{"type":"assistant","isSidechain":false,"message":{"model":"claude-fable-5","usage":{"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":900000,"output_tokens":0}}}' > "$TJ"
  out="$(printf '{"session_id":"t27a","transcript_path":"%s"}' "$TJ" \
         | TMPDIR="$SANDBOX/t27state_a" bash "$HOOK" 2>/dev/null)"
  echo "$out" | grep -qE '\[context: ~9[0-9]%\]' && pass "T27a fires above band" || fail "T27a no fire: '$out'"
  printf '%s\n' '{"type":"assistant","isSidechain":false,"message":{"model":"claude-fable-5","usage":{"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":100000,"output_tokens":0}}}' > "$TJ"
  out="$(printf '{"session_id":"t27b","transcript_path":"%s"}' "$TJ" \
         | TMPDIR="$SANDBOX/t27state_b" bash "$HOOK" 2>/dev/null)"
  [ -z "$out" ] && pass "T27b silent below band" || fail "T27b unexpected output: '$out'"
else
  skip "T27 (jq unavailable or hook missing)"
fi

echo ""
echo "=== RESULTS: $P passed, $F failed, $S skipped ==="
[ "$F" -eq 0 ]
