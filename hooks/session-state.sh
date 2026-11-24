#!/usr/bin/env bash
# session-state.sh — SessionStart hook. Makes interruptions survivable without the
# operator carrying context between sessions:
#   startup        record a baseline + a git checkpoint (an undo point that does not
#                  touch the working tree); if unfinished task state exists, say so
#                  in ONE line (the content is not loaded unless it is needed).
#   resume/compact re-inject the task state (STATE.md, capped) plus what the journal
#                  knows for certain: files edited, last verification result.
# stdout is added to the model's context. Always exits 0.
. "$(dirname "${BASH_SOURCE[0]}")/harness-lib.sh" 2>/dev/null || exit 0
{
  h_off && exit 0
  h_read_payload || exit 0
  mkdir -p "${H_STATE}" 2>/dev/null || exit 0
  src="$(h_get '.source')"
  root="$(h_root)"
  state_md="${root}/.claude/harness/STATE.md"

  if [ ! -f "${H_STATE}/baseline" ]; then
    h_dirty_hash "${root}" >"${H_STATE}/baseline" 2>/dev/null
    if git -C "${root}" rev-parse HEAD >/dev/null 2>&1; then
      cp_sha="$(git -C "${root}" stash create 2>/dev/null)"
      [ -n "${cp_sha}" ] || cp_sha="$(git -C "${root}" rev-parse HEAD 2>/dev/null)"
      if [ -n "${cp_sha}" ]; then
        git -C "${root}" update-ref "refs/harness/checkpoints/${H_SID}" "${cp_sha}" 2>/dev/null
        printf '%s\n' "${cp_sha}" >"${H_STATE}/checkpoint"
      fi
    fi
    # Old session state is disposable; keep the directory from growing forever.
    find "${H_DIR}/state" -mindepth 1 -maxdepth 1 -type d -mtime +30 -exec rm -rf {} + 2>/dev/null
  fi

  fresh=0
  if [ -s "${state_md}" ]; then
    m="$(h_mtime "${state_md}")"; now="$(date +%s)"
    case "${m}" in ''|*[!0-9]*) m=0 ;; esac
    [ $(( now - m )) -lt 604800 ] && fresh=1
  fi

  case "${src}" in
    resume|compact)
      echo "[harness] Session ${src}: restoring task state. Trust this over memory of the earlier conversation."
      if [ "${fresh}" -eq 1 ]; then
        echo "--- .claude/harness/STATE.md ---"; head -c 2000 "${state_md}"; echo; echo "---"
      fi
      J="${H_STATE}/journal.jsonl"
      if [ -s "${J}" ]; then
        files="$(jq -rs '[.[]|select(.k=="edit")|.f]|unique|.[-20:]|join(", ")' "${J}" 2>/dev/null)"
        [ -n "${files}" ] && echo "Files edited this session: ${files}"
      fi
      [ -s "${H_STATE}/verify.last" ] && echo "Last verification: $(head -c 300 "${H_STATE}/verify.last")"
      ;;
    *)
      if [ "${fresh}" -eq 1 ]; then
        echo "[harness] Unfinished task state exists at .claude/harness/STATE.md (updated $(date -d "@${m}" '+%Y-%m-%d' 2>/dev/null || date -r "${m}" '+%Y-%m-%d' 2>/dev/null)). Read it only if this request continues that work."
      fi
      ;;
  esac
} 2>/dev/null
exit 0
