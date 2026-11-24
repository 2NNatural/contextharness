#!/usr/bin/env bash
# stop-gate.sh — Stop hook. Verification-first, enforced rather than requested.
#
# When the agent tries to end its turn and CODE has changed since the last
# successful verification, the gate does one of two things:
#   recipe mode  the project has a TRUSTED .claude/harness/verify.sh -> run it
#                (bounded by a timeout). Pass = done. Fail = the turn is blocked
#                and the failing output is handed back to the agent.
#   weak mode    no trusted recipe -> block once if nothing that runs code was
#                executed after the last change ("you edited X and ran nothing").
#
# What it deliberately does NOT do:
#   * It never blocks when nothing changed, when only docs changed, in plan
#     mode, or when the agent's last message is a question to the operator.
#   * It never loops: at most HARNESS_GATE_MAX_BLOCKS (default 2) blocks per
#     operator request. After that it lets go and tells the operator, in plain
#     words, that the work is UNVERIFIED.
#   * It is not proof of correctness. Weak mode only catches "edited and declared
#     done without running anything"; recipe mode is as good as the recipe.
#
# Contract: exit 0 = allow. Block = JSON {"decision":"block","reason":...} on
# stdout, exit 0. Fail-open on any internal error.
. "$(dirname "${BASH_SOURCE[0]}")/harness-lib.sh" 2>/dev/null || exit 0

MAX_BLOCKS="${HARNESS_GATE_MAX_BLOCKS:-2}"
VERIFY_TIMEOUT="${HARNESS_VERIFY_TIMEOUT:-180}"

h_off && exit 0
h_read_payload 2>/dev/null || exit 0
[ "${H_MODE}" = "plan" ] && exit 0
[ -n "${H_AGENT}" ] && exit 0                      # subagents report to the orchestrator; gate the orchestrator
mkdir -p "${H_STATE}" 2>/dev/null || exit 0
J="${H_STATE}/journal.jsonl"
root="$(h_root)"

# Did this session change anything at all? (A repo that was already dirty when the
# session began is the operator's business, not ours.)
[ -s "${J}" ] || exit 0
did="$(jq -rs '[.[]|select(.k=="edit" or (.k=="exec" and .ev))]|length' "${J}" 2>/dev/null)"
[ "${did:-0}" -gt 0 ] || exit 0

if git -C "${root}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  cur="$(h_dirty_hash "${root}")"
  [ -n "$(h_changed_files "${root}")" ] || exit 0  # no code changes on disk
  last_change="$(h_last_change "${root}")"
else
  # Not a git repo: fall back to the journal's record of code edits.
  cur="$(jq -rs '[.[]|select(.k=="edit")|select(.f|test("\\.(md|mdx|txt|rst|adoc)$")|not)|[.t,.f]]|tostring' "${J}" 2>/dev/null | h_hash)"
  last_change="$(jq -rs '[.[]|select(.k=="edit")|select(.f|test("\\.(md|mdx|txt|rst|adoc)$")|not)|.t]|max // 0' "${J}" 2>/dev/null)"
  [ "${last_change:-0}" -gt 0 ] || exit 0
fi
[ "${cur}" = "$(cat "${H_STATE}/baseline" 2>/dev/null)" ] && exit 0
[ "${cur}" = "$(cat "${H_STATE}/verified" 2>/dev/null)" ] && exit 0

# A question to the operator is not a claim of completion.
last_msg="$(h_get '.last_assistant_message')"
case "$(printf '%s' "${last_msg}" | tail -c 240 | tr -d ' \n*_`')" in *\?) exit 0 ;; esac

blocks_file="${H_STATE}/blocks.${H_PROMPT}"
blocks="$(cat "${blocks_file}" 2>/dev/null)"; case "${blocks}" in ''|*[!0-9]*) blocks=0 ;; esac

release() {   # give up blocking, but never silently
  printf 'UNVERIFIED at %s: %s\n' "$(date '+%Y-%m-%d %H:%M')" "$1" >"${H_STATE}/verify.last"
  jq -cn --arg m "Harness: this work is UNVERIFIED — $1 Treat the result as untested until it has been checked." '{systemMessage:$m}'
  exit 0
}
block() {
  printf '%s' "$((blocks+1))" >"${blocks_file}"
  jq -cn --arg r "$1" '{decision:"block",reason:$r}'
  exit 0
}

status="$(h_recipe_status "${root}")"
if [ "${status}" = "trusted" ]; then
  out_file="${H_STATE}/verify.out"
  runner=""; command -v timeout >/dev/null 2>&1 && runner="timeout ${VERIFY_TIMEOUT}"
  command -v gtimeout >/dev/null 2>&1 && [ -z "${runner}" ] && runner="gtimeout ${VERIFY_TIMEOUT}"
  # shellcheck disable=SC2086
  ( cd "${root}" && ${runner} bash .claude/harness/verify.sh ) >"${out_file}" 2>&1 </dev/null
  rc=$?
  if [ "${rc}" -eq 0 ]; then
    h_dirty_hash "${root}" >"${H_STATE}/verified"
    printf 'PASSED at %s (project verify recipe)\n' "$(date '+%Y-%m-%d %H:%M')" >"${H_STATE}/verify.last"
    exit 0
  fi
  why="exit code ${rc}"; [ "${rc}" -eq 124 ] && why="timed out after ${VERIFY_TIMEOUT}s (not a pass)"
  printf 'FAILED at %s (%s)\n' "$(date '+%Y-%m-%d %H:%M')" "${why}" >"${H_STATE}/verify.last"
  [ "${blocks}" -ge "${MAX_BLOCKS}" ] && release "the project verify recipe still fails (${why}) after ${blocks} fix attempts."
  block "[harness stop-gate] The project's verification recipe FAILED (${why}), so this is not done.

Last lines of output:
$(tail -n 30 "${out_file}" | cut -c1-300)

Fix the cause and finish again. Do NOT edit .claude/harness/verify.sh to make it pass — a changed recipe loses its trust and the work is reported to the operator as unverified. If the failure is unrelated to your change or cannot be fixed, stop and tell the operator exactly that, with the output above."
fi

# Weak mode. Was anything that runs code executed successfully after the last change?
# "After" means both later in the journal than the last recorded edit (ordering is
# exact) and not older than the newest changed file (catches edits made via shell).
ran="$(jq -rs --argjson since "${last_change:-0}" '
    (to_entries | map(select(.value.k=="edit")) | (last // {key:-1}) | .key) as $i
    | [to_entries[] | select(.key > $i) | .value | select(.k=="exec" and .ev and .ok and .t >= $since)] | length' "${J}" 2>/dev/null)"
if [ "${ran:-0}" -gt 0 ]; then
  printf '%s' "${cur}" >"${H_STATE}/verified"
  printf 'EXERCISED at %s (commands were run after the last change; no project verify recipe)\n' "$(date '+%Y-%m-%d %H:%M')" >"${H_STATE}/verify.last"
  exit 0
fi
note=""
[ "${status}" = "changed" ] && note=" (The verify recipe was modified after it was trusted, so it was not run.)"
[ "${status}" = "untrusted" ] && note=" (A verify recipe exists but has not been trusted, so it was not run.)"
[ "${blocks}" -ge 1 ] && release "code was changed but nothing was run afterwards to check it.${note}"
block "[harness stop-gate] You changed code and ran nothing afterwards, so there is no evidence it works.${note}

Changed: $(h_changed_files "${root}" 2>/dev/null | head -8 | tr '\n' ' ')

Before finishing: exercise the change for real (run the tests, run the script on a representative input, hit the endpoint, load the page) and report what you observed. A build or type-check alone is not evidence of behaviour. If it genuinely cannot be run here, say so explicitly and label the work UNVERIFIED in your report."
