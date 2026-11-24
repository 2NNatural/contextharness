#!/usr/bin/env bash
# journal.sh — PostToolUse (Edit|Write|MultiEdit|NotebookEdit|Bash) and
# PostToolUseFailure (Bash) hook. Appends one short JSON line per event to a
# per-session journal that the stop-gate and session-state hooks read. It also
# notices an agent stuck in a loop: the same command failing three times in a row
# with no edit in between gets one injected "change strategy" instruction.
# Never blocks, never prints anything else, always exits 0.
. "$(dirname "${BASH_SOURCE[0]}")/harness-lib.sh" 2>/dev/null || exit 0
{
  h_off && exit 0
  h_read_payload || exit 0
  mkdir -p "${H_STATE}" 2>/dev/null || exit 0
  J="${H_STATE}/journal.jsonl"
  now="$(date +%s)"
  case "${H_TOOL}" in
    Bash)
      cmd="$(h_get '.tool_input.command')"; [ -n "${cmd}" ] || exit 0
      ok=true; [ "${H_EVENT}" = "PostToolUseFailure" ] && ok=false
      ev=false; h_is_evidence "${cmd}" && ev=true
      jq -cn --argjson t "${now}" --arg a "${H_AGENT}" --arg c "${cmd:0:300}" --argjson ok "${ok}" --argjson ev "${ev}" \
        '{t:$t,k:"exec",ok:$ok,ev:$ev,a:$a,c:$c}' >>"${J}" 2>/dev/null
      if [ "${ok}" = false ]; then
        n="$(tail -n 60 "${J}" | jq -rs --arg a "${H_AGENT}" --arg c "${cmd:0:300}" '
              reduce .[] as $e (0;
                if $e.k=="edit" then 0
                elif $e.k=="exec" and $e.a==$a and $e.c==$c and ($e.ok|not) then .+1
                elif $e.k=="exec" and $e.a==$a and $e.c==$c then 0
                else . end)' 2>/dev/null)"
        if [ "${n:-0}" = 3 ]; then
          jq -cn '{hookSpecificOutput:{hookEventName:"PostToolUseFailure",additionalContext:
            "[harness] This exact command has now failed 3 times in a row with no code change in between. Repeating it will not help. Stop, state the actual error, form a different hypothesis, and change approach (read the failing code, reduce the case, or escalate to architect). If it is an environment problem outside your control, say so plainly instead of retrying."}}'
        fi
      fi
      ;;
    Edit|Write|MultiEdit|NotebookEdit)
      [ "${H_EVENT}" = "PostToolUse" ] || exit 0
      f="$(h_get '(.tool_input.file_path // .tool_input.notebook_path)')"
      jq -cn --argjson t "${now}" --arg a "${H_AGENT}" --arg f "${f:0:300}" '{t:$t,k:"edit",a:$a,f:$f}' >>"${J}" 2>/dev/null
      ;;
  esac
} 2>/dev/null
exit 0
