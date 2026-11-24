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
case "${MAX_BLOCKS}" in ''|*[!0-9]*) MAX_BLOCKS=2 ;; esac
case "${VERIFY_TIMEOUT}" in ''|*[!0-9]*|0) VERIFY_TIMEOUT=180 ;; esac   # seconds, digits only ("5m" is not)

h_off && exit 0
h_read_payload 2>/dev/null || exit 0
[ "${H_MODE}" = "plan" ] && exit 0
[ -n "${H_AGENT}" ] && exit 0                      # subagents report to the orchestrator; gate the orchestrator
mkdir -p "${H_STATE}" 2>/dev/null || exit 0
J="${H_STATE}/journal.jsonl"
root="$(h_root)"

# Did this session change anything at all? (A repo that was already dirty when the
# session began is the operator's business, not ours.)
# A shell command that may have written files counts too (sed -i, >, cp ...), and so
# does an unreadable (torn) journal record: when unsure, let the git check decide.
[ -s "${J}" ] || exit 0
did="$(h_jlines <"${J}" | jq -rs '[.[]|select(.k=="edit" or .k=="corrupt" or (.k=="exec" and (.ev or .w)))]|length' 2>/dev/null)"
[ "${did:-0}" -gt 0 ] || exit 0

# Nothing to verify. But a trusted recipe that was modified or removed (it is excluded
# from the code-change check) must not pass unnoticed: say so once per request.
allow() {
  local nf="${H_STATE}/recipe-note.${H_PROMPT}"
  if [ ! -e "${nf}" ] && [ "$(h_recipe_status "${root}" "${r0}")" = changed ]; then
    : >"${nf}"
    jq -cn --arg m "Harness: the project verify recipe (.claude/harness/verify.sh) was modified or removed after it was trusted. It is not run until the operator reviews it and runs 'harness trust-verify' (or 'harness untrust-verify' if it was removed on purpose)." '{systemMessage:$m}'
  fi
  exit 0
}

r0="$(cat "${H_STATE}/recipe0" 2>/dev/null)"   # recipe present at session start (absent file: assume yes)
ingit=0; git -C "${root}" rev-parse --is-inside-work-tree >/dev/null 2>&1 && ingit=1
# HEAD at session start, if recorded — used only when this session ran a git command
# that creates commits (journal flag g). Otherwise a pull, a branch switch or the
# operator's own commit would count as this session's change.
start=""
[ "${ingit}" = 1 ] && h_jlines <"${J}" | jq -se 'any(.[]; .k=="exec" and .g==true)' >/dev/null 2>&1 \
  && start="$(head -n 1 "${H_STATE}/head" 2>/dev/null)"
# Outside git: the journal's code edits and unreadable records (a torn line may have
# swallowed an edit, so it counts as a change rather than failing open).
nj_filter='select(.k=="corrupt" or (.k=="edit" and (.f|test("\\.(md|mdx|txt|rst|adoc)$")|not)))'
# Fingerprint of the code changes. In git: working tree plus files changed by commits
# made since the session started. Outside git: the journal's code-edit records plus
# the current content of those files (so writes no tool event recorded still show).
fingerprint() {
  if [ "${ingit}" = 1 ]; then h_dirty_hash "${root}" "${start}"
  else { h_jlines <"${J}" | jq -c "${nj_filter}|[.t,.f,.k]" 2>/dev/null
         h_jlines <"${J}" | jq -c "${nj_filter}" 2>/dev/null | h_journal_content "${root}"; } | h_hash; fi
}
if [ "${ingit}" = 1 ]; then
  [ -n "$(h_changed_files "${root}" "${start}")" ] || allow  # no code changes on disk or in new commits
  # A deleted file has no mtime: it counts as changed at the latest edit / may-write record.
  lw="$(h_jlines <"${J}" | jq -rs '[.[]|select(.k=="edit" or (.k=="exec" and .w))|.t]|max // 0' 2>/dev/null)"
  last_change="$(h_last_change "${root}" "${start}" "${lw}")"
else
  last_change="$(h_jlines <"${J}" | jq -rs "[.[]|${nj_filter}|if .k==\"corrupt\" then 1 else .t end]|max // 0" 2>/dev/null)"
  [ "${last_change:-0}" -gt 0 ] || allow
fi
cur="$(fingerprint)"
[ "${cur}" = "$(cat "${H_STATE}/baseline" 2>/dev/null)" ] && allow
[ "${cur}" = "$(cat "${H_STATE}/verified" 2>/dev/null)" ] && allow

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

status="$(h_recipe_status "${root}" "${r0}")"
# A recipe changed (or deleted) after it was trusted is neither run nor replaced by
# weak-mode evidence: otherwise editing the exam would silently downgrade it to "ran anything".
if [ "${status}" = "changed" ]; then
  [ "${blocks}" -ge 1 ] && release "the project verify recipe (.claude/harness/verify.sh) was modified or removed after it was trusted, so it was not run and nothing else counts as verification. Review the change and run 'harness trust-verify' yourself if it is intended (or 'harness untrust-verify' if the recipe was removed on purpose)."
  block "[harness stop-gate] .claude/harness/verify.sh was modified or removed after it was trusted, so it was NOT run and nothing you ran counts as verification. If YOU modified it this session, restore your earlier version. If you did not, do not touch it: stop and tell the operator the recipe changed and needs their review. Do not re-trust it yourself."
fi
if [ "${status}" = "trusted" ]; then
  out_file="${H_STATE}/verify.out"
  # Marker first: if the hook itself is killed mid-run, no stale PASSED survives.
  printf 'RUNNING since %s\n' "$(date '+%Y-%m-%d %H:%M')" >"${H_STATE}/verify.last"
  ( cd "${root}" && h_run_bounded "${VERIFY_TIMEOUT}" bash .claude/harness/verify.sh ) >"${out_file}" 2>&1 </dev/null
  rc=$?
  if [ "${rc}" -eq 0 ]; then
    # Record the PRE-run fingerprint: anything written while the recipe ran is
    # not certified by it, and makes the next stop run the recipe again.
    post="$(fingerprint)"
    printf '%s' "${cur}" >"${H_STATE}/verified"
    if [ "${post}" = "${cur}" ]; then printf 'PASSED at %s (project verify recipe)\n' "$(date '+%Y-%m-%d %H:%M')" >"${H_STATE}/verify.last"
    else printf 'PASSED at %s (project verify recipe) — but code files changed while it ran; it will run again at the next stop\n' "$(date '+%Y-%m-%d %H:%M')" >"${H_STATE}/verify.last"; fi
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
# "After" means both later in the journal than the last recorded edit or unreadable
# record (ordering is exact) and not older than the newest changed file (catches edits
# made via shell).
ran="$(h_jlines <"${J}" | jq -rs --argjson since "${last_change:-0}" '
    (to_entries | map(select(.value.k=="edit" or .value.k=="corrupt")) | (last // {key:-1}) | .key) as $i
    | [to_entries[] | select(.key > $i) | .value | select(.k=="exec" and .ev and .ok and .t >= $since)] | length' 2>/dev/null)"
if [ "${ran:-0}" -gt 0 ]; then
  printf '%s' "${cur}" >"${H_STATE}/verified"
  printf 'EXERCISED at %s (commands were run after the last change; no project verify recipe)\n' "$(date '+%Y-%m-%d %H:%M')" >"${H_STATE}/verify.last"
  exit 0
fi
note=""
[ "${status}" = "untrusted" ] && note=" (A verify recipe exists but has not been trusted, so it was not run.)"
# No edit-tool event on a code file: the change came from a shell command that may
# write files, or from outside this session. Say exactly that rather than "You changed code".
edits="$(h_jlines <"${J}" | jq -rs '[.[]|select(.k=="corrupt" or (.k=="edit" and (.f|test("\\.(md|mdx|txt|rst|adoc)$")|not)))]|length' 2>/dev/null)"
if [ "${edits:-0}" -gt 0 ]; then
  what="code was changed but nothing was run afterwards to check it."
  head_line="You changed code and ran nothing afterwards, so there is no evidence it works."
else
  what="code changed on disk during this session (no edit tool was used) and nothing was run afterwards to check it."
  head_line="Code files changed on disk since this session started and you ran nothing afterwards, so there is no evidence they work. No edit tool was used: the change came from a shell command that writes files, or from outside this session — if it is not yours, say so instead of verifying it."
fi
[ "${blocks}" -ge 1 ] && release "${what}${note}"
block "[harness stop-gate] ${head_line}${note}

Changed: $(h_changed_files "${root}" "${start}" 2>/dev/null | head -8 | tr '\n' ' ')

Before finishing: exercise the change for real (run the tests, run the script on a representative input, hit the endpoint, load the page) and report what you observed. A build or type-check alone is not evidence of behaviour. If it genuinely cannot be run here, say so explicitly and label the work UNVERIFIED in your report."
