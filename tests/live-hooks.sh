#!/usr/bin/env bash
# tests/live-hooks.sh — contract test against the REAL Claude Code on this machine.
#
# The unit suite (run-tests.sh) feeds the hooks synthetic payloads. This script
# answers the other question: does THIS Claude Code build actually call the hooks,
# honour a block, honour an "ask", and inject restored state? It runs a preflight and
# four tiny headless sessions on the cheapest model in a throwaway config directory
# and costs a few cents. Run it after installing and after Claude Code updates.
#
#   bash tests/live-hooks.sh            # uses haiku
#   LIVE_MODEL=sonnet bash tests/live-hooks.sh
#
# Auth: the throwaway config has no login of its own. Either export ANTHROPIC_API_KEY,
# or set LIVE_COPY_CREDENTIALS=1 to copy your Claude credentials file
# (<config>/.credentials.json; Linux/Windows — macOS keeps it in the Keychain) into
# the throwaway config, which is deleted on exit. Off by default.
# If the preflight cannot reach the model, the run ABORTS with exit 2: no hook
# contract was tested, and nothing counts as a pass.
set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REAL_CFG="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}"   # captured before HOME is redirected
command -v claude >/dev/null 2>&1 || { echo "SKIP: claude CLI not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not found"; exit 0; }
# h_run_bounded: timeout/gtimeout when present, else a shell watchdog (never unbounded).
. "${REPO}/hooks/harness-lib.sh" || { echo "FAIL: cannot load hooks/harness-lib.sh"; exit 1; }
PY="$(h_python)" || { echo "SKIP: no Python 3 (python3/python) on PATH"; exit 0; }
MODEL="${LIVE_MODEL:-haiku}"
ROOT="$(mktemp -d)"; H="${ROOT}/home"; CFG="${H}/.claude"; mkdir -p "${CFG}"
trap 'rm -rf "${ROOT:?}"' EXIT
trap 'exit 130' INT; trap 'exit 143' TERM HUP     # route signals through the EXIT cleanup
P=0; F=0
pass() { echo "PASS: $1"; P=$((P+1)); }
fail() { echo "FAIL: $1"; F=$((F+1)); }
HOME="${H}" CLAUDE_CONFIG_DIR="${CFG}" HARNESS_SKIP_PROBE=1 bash "${REPO}/install.sh" --top-model opus --recommended >/dev/null 2>&1 \
  || { echo "FAIL: install into sandbox failed"; exit 1; }
if [ "${LIVE_COPY_CREDENTIALS:-}" = 1 ]; then
  if [ -f "${REAL_CFG}/.credentials.json" ]; then
    cp "${REAL_CFG}/.credentials.json" "${CFG}/.credentials.json" && chmod 600 "${CFG}/.credentials.json" \
      && echo "NOTE: copied your Claude credentials file into the throwaway config (deleted on exit)."
  else
    echo "NOTE: LIVE_COPY_CREDENTIALS=1 but ${REAL_CFG}/.credentials.json does not exist (on macOS it is in the Keychain); export ANTHROPIC_API_KEY instead."
  fi
fi
proj() { local d="${ROOT}/$1"; mkdir -p "${d}"; ( cd "${d}" && git init -q && git config user.email l@l && git config user.name l && echo 'x = 1' > seed.py && git add -A && git commit -qm seed ); echo "${d}"; }
ask() {  # ask <dir> <prompt> [extra claude args...]  -> JSON result on stdout
  local d="$1" p="$2"; shift 2
  ( cd "${d}" && HOME="${H}" CLAUDE_CONFIG_DIR="${CFG}" h_run_bounded 300 claude -p "${p}" --model "${MODEL}" --output-format json \
      --permission-mode acceptEdits --allowedTools Read Edit Write Glob Grep "Bash(python3:*)" "Bash(python:*)" "Bash(bash:*)" "Bash(ls:*)" "$@" 2>/dev/null </dev/null )
}
# Did claude -p actually reach the model? An auth/API error still prints JSON, and a
# check like "DEPLOYED is absent" would otherwise pass on a session that never ran.
live_ok() { printf '%s' "$1" | jq -e '(.is_error != true) and ((.result // "") | test("Not logged in|Please run /login|Invalid API key|api_error|authentication_error|credit balance";"i") | not)' >/dev/null 2>&1; }
why() { local m; m="$(printf '%s' "$1" | jq -r '.result // empty' 2>/dev/null | head -c 200)"; printf '%s' "${m:-no output}"; }
state_of() { ls -d "${CFG}"/harness/state/"$1" 2>/dev/null; }

# 0. Preflight: a session that cannot reach the model tests nothing.
R0="$(ask "$(proj preflight)" 'Reply with just: ok')"
live_ok "${R0}" || { echo "LIVE TEST ABORTED (exit 2, not a pass): claude -p did not reach the model in the sandbox config: $(why "${R0}"). Export ANTHROPIC_API_KEY or set LIVE_COPY_CREDENTIALS=1. No hook contract was tested."; exit 2; }

# 1. journal + stop-gate (weak mode): an edit with nothing run must be blocked once.
D="$(proj gate)"
R="$(ask "${D}" 'Use the Write tool to create calc.py containing exactly: def add(a, b): return a + b   — Do not run any command yourself unless something tells you to. Then finish.')"
if ! live_ok "${R}"; then fail "journal/stop-gate: claude -p errored — result unattributable ($(why "${R}"))"
else
  SID="$(printf '%s' "${R}" | jq -r '.session_id // empty')"; S="$(state_of "${SID}")"
  [ -n "${S}" ] && [ -s "${S}/journal.jsonl" ] && jq -e 'select(.k=="edit")' "${S}/journal.jsonl" >/dev/null 2>&1 \
    && pass "journal hook fired on a real Write (PostToolUse contract holds)" || fail "journal hook did not record the edit"
  ls "${S}"/blocks.* >/dev/null 2>&1 \
    && pass "stop-gate blocked a real 'done' after an unverified edit (Stop block contract holds)" || fail "stop-gate never blocked"
  if jq -e 'select(.k=="exec" and .ev and .ok)' "${S}/journal.jsonl" >/dev/null 2>&1; then
    pass "after the block the agent actually ran the code ($(cat "${S}/verify.last" 2>/dev/null | cut -c1-40))"
  elif grep -q UNVERIFIED "${S}/verify.last" 2>/dev/null; then
    pass "agent did not verify; gate released and recorded UNVERIFIED (bounded, no loop)"
  else fail "after the block: neither verification nor an UNVERIFIED record"; fi
  [ -s "${S}/baseline" ] && git -C "${D}" rev-parse -q --verify "refs/harness/checkpoints/${SID}" >/dev/null \
    && pass "session-state hook fired at startup (baseline + git checkpoint)" || fail "session-state did not run at startup"
fi

# 2. stop-gate recipe mode: a trusted failing recipe must hold the turn open.
D="$(proj recipe)"; mkdir -p "${D}/.claude/harness"
printf '#!/usr/bin/env bash\n%s -c "import calc; assert calc.add(2, 3) == 5, calc.add(2, 3)"\n' "${PY}" > "${D}/.claude/harness/verify.sh"
( cd "${D}" && CLAUDE_CONFIG_DIR="${CFG}" bash "${CFG}/scripts/harness" trust-verify >/dev/null )
R="$(ask "${D}" 'Use the Write tool to create calc.py containing exactly: def add(a, b): return a - b   — then finish. Do not review the code first.')"
SID="$(printf '%s' "${R}" | jq -r '.session_id // empty')"; S="$(state_of "${SID}")"
if ! live_ok "${R}"; then fail "recipe mode: claude -p errored — result unattributable ($(why "${R}"))"
elif ( cd "${D}" && bash .claude/harness/verify.sh >/dev/null 2>&1 ) && grep -q PASSED "${S}/verify.last" 2>/dev/null; then
  pass "recipe mode: the planted bug was caught by the gate and fixed before the session could end"
elif ls "${S}"/blocks.* >/dev/null 2>&1; then
  pass "recipe mode: gate blocked on the failing recipe (agent did not fix it; recorded: $(cut -c1-30 "${S}/verify.last" 2>/dev/null))"
else fail "recipe mode: failing trusted recipe did not block"; fi

# 3. ops-guard: a deploy script must not run unattended — and the guard must be the reason.
D="$(proj ops)"; printf '#!/usr/bin/env bash\ntouch DEPLOYED\n' > "${D}/deploy.sh"; chmod +x "${D}/deploy.sh"
R="$(ask "${D}" 'Run this exact command and report its output: bash ./deploy.sh')"
SID="$(printf '%s' "${R}" | jq -r '.session_id // empty')"; S="$(state_of "${SID}")"
if [ -e "${D}/DEPLOYED" ]; then fail "ops-guard: deploy.sh RAN in an unattended session"
elif ! live_ok "${R}"; then fail "ops-guard: claude -p errored — result unattributable ($(why "${R}"))"
elif [ -n "${S}" ] && grep -q deploy "${S}/ops.log" 2>/dev/null; then
  pass "ops-guard fired (ops.log) and deploy.sh did not run (PreToolUse ask contract holds)"
else fail "ops-guard: INCONCLUSIVE — deploy.sh did not run but ops-guard never fired (the model may not have attempted it)"; fi

# 4. session-state restore on resume.
D="$(proj resume)"; mkdir -p "${D}/.claude/harness"; printf '# Goal\nThe project codeword is HELIOTROPE-42.\n' > "${D}/.claude/harness/STATE.md"
R="$(ask "${D}" 'Reply with just: ready')"; SID="$(printf '%s' "${R}" | jq -r '.session_id // empty')"
R2="$(ask "${D}" 'According to the restored harness task state, what is the project codeword? Answer from context only; do not read any files.' --resume "${SID}")"
if ! live_ok "${R}" || ! live_ok "${R2}"; then fail "session-state resume: claude -p errored — result unattributable ($(why "${R2}"))"
else
  printf '%s' "${R2}" | jq -r '.result // ""' | grep -q 'HELIOTROPE-42' \
    && pass "session-state: STATE.md was re-injected on resume (SessionStart context contract holds)" || fail "session-state: restored state not visible after resume"
fi

echo "=== LIVE RESULTS: ${P} passed, ${F} failed (model ${MODEL}) ==="
[ "${F}" -eq 0 ]
