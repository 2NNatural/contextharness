#!/usr/bin/env bash
# bench/run.sh — run the benchmark tasks under one harness version ("arm").
#
#   bench/run.sh --arm v1 --ref 34eb046 --flags "--with-context-hook --with-destructive-guard"
#   bench/run.sh --arm v2 --ref WORKTREE --flags "--recommended"
#   bench/run.sh --arm none                      # no harness at all (control)
#
# Options: --tasks a,b,c   --trials N (default 1)   --model sonnet   --out DIR
#          --jobs N (default 3)   --budget USD per run (default 4)
#
# Each run: a fresh copy of the task fixture in its own git repo, a fresh isolated
# Claude config dir with that arm's harness installed, one headless `claude -p`
# session given only the task prompt, then the task's hidden check.sh (which the
# agent never sees) decides pass/fail. Cost, tokens, turns and duration come from
# Claude Code's own JSON result. Nothing here touches your real ~/.claude.
#
# Honest limits: one headless session per task (no operator to answer questions),
# model output is not deterministic (use --trials), and the orchestrator model is
# whatever --model says for every arm so arms differ only in the harness.
set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARM=""; REF=""; FLAGS=""; TASKS=""; TRIALS=1; MODEL="sonnet"; OUT=""; JOBS=3; BUDGET=4
while [ $# -gt 0 ]; do
  case "$1" in
    --arm) ARM="$2"; shift 2 ;;      --ref) REF="$2"; shift 2 ;;
    --flags) FLAGS="$2"; shift 2 ;;  --tasks) TASKS="$2"; shift 2 ;;
    --trials) TRIALS="$2"; shift 2 ;; --model) MODEL="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;      --jobs) JOBS="$2"; shift 2 ;;
    --budget) BUDGET="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done
[ -n "${ARM}" ] || { sed -n '2,20p' "${BASH_SOURCE[0]}"; exit 1; }
command -v claude >/dev/null 2>&1 || { echo "claude CLI not found" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq not found" >&2; exit 1; }
[ -n "${OUT}" ] || OUT="${TMPDIR:-/tmp}/harness-bench"
# h_run_bounded: timeout/gtimeout when present, else a shell watchdog (never unbounded).
. "${REPO}/hooks/harness-lib.sh" || { echo "cannot load hooks/harness-lib.sh" >&2; exit 1; }
# The graders need Python 3; resolve python3 or python once (check.sh falls back itself).
PY="$(h_python)" || PY=""
ARMDIR="${OUT}/${ARM}"; AHOME="${ARMDIR}/home"; CFG="${AHOME}/.claude"
mkdir -p "${ARMDIR}/src" "${CFG}" "${ARMDIR}/runs"

# ---- install this arm's harness into its own config dir ----------------------
: > "${ARMDIR}/system-prompt.txt"
if [ "${ARM}" != "none" ]; then
  [ -n "${REF}" ] || { echo "--ref is required (a git ref, or WORKTREE)" >&2; exit 1; }
  if [ "${REF}" = "WORKTREE" ]; then
    ( cd "${REPO}" && git ls-files -co --exclude-standard | tar -cf - -T - ) | tar -xf - -C "${ARMDIR}/src"
  else
    git -C "${REPO}" archive "${REF}" | tar -xf - -C "${ARMDIR}/src"
  fi
  # shellcheck disable=SC2086
  HOME="${AHOME}" CLAUDE_CONFIG_DIR="${CFG}" HARNESS_SKIP_PROBE=1 bash "${ARMDIR}/src/install.sh" --top-model opus ${FLAGS} >"${ARMDIR}/install.log" 2>&1 \
    || { echo "install failed for arm ${ARM}; see ${ARMDIR}/install.log" >&2; exit 1; }
  # Headless cloud sessions may not load the user-level CLAUDE.md, so the rules
  # block is delivered explicitly — identically for every arm that has one.
  cp "${CFG}/CLAUDE.md" "${ARMDIR}/system-prompt.txt"
fi
printf '%s\n' "${REF:-none}" > "${ARMDIR}/ref"; printf '%s\n' "${FLAGS}" > "${ARMDIR}/flags"

[ -n "${TASKS}" ] || TASKS="$(cd "${REPO}/bench/tasks" && ls -d */ | tr -d '/' | tr '\n' ',')"

run_one() {
  local task="$1" trial="$2" tdir="${REPO}/bench/tasks/$1" rdir="${ARMDIR}/runs/$1-$2" w
  w="${rdir}/work"; mkdir -p "${w}"
  cp -R "${tdir}/fixture/." "${w}/"
  ( cd "${w}" && git init -q && git config user.email bench@example.invalid && git config user.name bench && git add -A && git commit -qm "fixture" ) >/dev/null 2>&1
  local start end; start="$(date +%s)"
  ( cd "${w}" && HOME="${AHOME}" CLAUDE_CONFIG_DIR="${CFG}" h_run_bounded 1800 claude -p "$(cat "${tdir}/prompt.txt")" \
      --model "${MODEL}" --output-format json --permission-mode acceptEdits \
      --allowedTools Bash Read Edit Write Glob Grep Agent Skill TodoWrite \
      --max-budget-usd "${BUDGET}" \
      ${SYS_ARGS:+--append-system-prompt "$(cat "${ARMDIR}/system-prompt.txt")"} \
      > "${rdir}/result.json" 2> "${rdir}/stderr.log" </dev/null )
  local rc=$?; end="$(date +%s)"
  jq -r '.result // ""' "${rdir}/result.json" > "${rdir}/result.txt" 2>/dev/null || : > "${rdir}/result.txt"
  RESULT_FILE="${rdir}/result.txt" bash "${tdir}/check.sh" "${w}" > "${rdir}/check.log" 2>&1
  local pass=$?; [ "${pass}" -eq 0 ] && pass=true || pass=false
  local caveat=false; grep -Eiq 'unverified|not verified|could not (be )?(verif|test|run)|did not (verify|test|run)|untested|not checked' "${rdir}/result.txt" && caveat=true
  local asked=false; tail -c 200 "${rdir}/result.txt" | tr -d ' \n*_`' | grep -q '?$' && asked=true
  local gate=0; gate="$(cat "${CFG}"/harness/state/*/blocks.* 2>/dev/null | wc -l | tr -d ' ')"
  jq -cn --arg arm "${ARM}" --arg task "${task}" --argjson trial "${trial}" --argjson pass "${pass}" --argjson rc "${rc}" \
     --argjson wall "$((end-start))" --argjson caveat "${caveat}" --argjson asked "${asked}" \
     --slurpfile r "${rdir}/result.json" --arg fail "$(grep -m1 '^FAIL\|Error\|assert' "${rdir}/check.log" | cut -c1-160)" '
     ($r[0] // {}) as $x
     | {arm:$arm, task:$task, trial:$trial, pass:$pass, exit:$rc, wall_s:$wall,
        cost_usd:($x.total_cost_usd // null), turns:($x.num_turns // null), api_ms:($x.duration_api_ms // null),
        tokens:([($x.modelUsage // {})[] | (.inputTokens + .outputTokens + .cacheReadInputTokens + .cacheCreationInputTokens)] | add // 0),
        output_tokens:([($x.modelUsage // {})[] | .outputTokens] | add // 0),
        models:(($x.modelUsage // {}) | keys), subagents:($x.subagent_stats.spawned // 0),
        denials:(($x.permission_denials // []) | length), is_error:($x.is_error // null),
        caveated:$caveat, ended_with_question:$asked,
        false_done:(($pass|not) and ($caveat|not) and ($asked|not)), check_failure:$fail}' \
     > "${rdir}/row.json"
  echo "[${ARM}] ${task} #${trial}: pass=${pass} cost=\$$(jq -r '.cost_usd // "?"' "${rdir}/row.json") turns=$(jq -r '.turns // "?"' "${rdir}/row.json") wall=$((end-start))s"
}
export -f run_one h_run_bounded h_descendants h_pidtable
export REPO ARM ARMDIR AHOME CFG MODEL BUDGET PY
[ -s "${ARMDIR}/system-prompt.txt" ] && export SYS_ARGS=1

jobs_list="$(mktemp)"
for t in $(printf '%s' "${TASKS}" | tr ',' ' '); do
  [ -d "${REPO}/bench/tasks/${t}" ] || { echo "no such task: ${t}" >&2; continue; }
  for i in $(seq 1 "${TRIALS}"); do echo "${t} ${i}"; done
done > "${jobs_list}"
# shellcheck disable=SC2016
xargs -P "${JOBS}" -L 1 bash -c 'run_one "$0" "$1"' < "${jobs_list}"
cat "${ARMDIR}"/runs/*/row.json 2>/dev/null | jq -s '.' > "${ARMDIR}/results.json"
echo "arm ${ARM}: $(jq '[.[]|select(.pass)]|length' "${ARMDIR}/results.json")/$(jq 'length' "${ARMDIR}/results.json") passed — ${ARMDIR}/results.json"
