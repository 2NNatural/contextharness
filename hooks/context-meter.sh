#!/usr/bin/env bash
# context-meter.sh — Claude Code UserPromptSubmit hook.
# Reads real per-turn token usage from the session transcript and, ONLY when
# context crosses a 70/80/90% band, prints one short line that Claude Code adds
# to the model's context (e.g. "[context: ~72%]"). Below threshold: prints
# nothing (zero token cost). Pure local shell — no claude/API calls.
#
# Contract:
#   stdin  = JSON with .session_id and .transcript_path
#   stdout on exit 0 = added to the model's context for this turn
# The script ALWAYS exits 0 so it can never block or delay a prompt.

# --- config -----------------------------------------------------------------
# Usable context window (denominator). Default 1,000,000 for this harness's
# 1M-class models (fable 1M; opus-4.8/sonnet-5). On a 200k-capped plan, set
# CLAUDE_CONTEXT_WINDOW=200000 in your environment, or edit the default below.
DENOMINATOR="${CLAUDE_CONTEXT_WINDOW:-1000000}"
# Bands (ascending). A line is injected only when usage first reaches a new band.
BANDS="70 80 90"
# ----------------------------------------------------------------------------

{
  command -v jq >/dev/null 2>&1 || exit 0

  payload="$(cat)" || exit 0
  transcript="$(printf '%s' "$payload" | jq -r '.transcript_path // empty' 2>/dev/null)"
  session_id="$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null)"
  [ -n "$transcript" ] && [ -f "$transcript" ] || exit 0

  used="$(jq -rc '
      select(.type=="assistant" and (.isSidechain != true))
      | .message.usage
      | ((.input_tokens // 0) + (.cache_creation_input_tokens // 0)
         + (.cache_read_input_tokens // 0) + (.output_tokens // 0))
    ' "$transcript" 2>/dev/null | tail -1)"

  case "$used" in ''|*[!0-9]*) exit 0 ;; esac
  [ "$DENOMINATOR" -gt 0 ] 2>/dev/null || exit 0

  pct=$(( used * 100 / DENOMINATOR ))
  [ "$pct" -gt 99 ] && pct=99

  current=0
  for b in $BANDS; do [ "$pct" -ge "$b" ] && current="$b"; done

  state_dir="${TMPDIR:-/tmp}/claude-context-meter"
  mkdir -p "$state_dir" 2>/dev/null
  safe_id="$(printf '%s' "${session_id:-nosession}" | tr -c 'A-Za-z0-9._-' '_')"
  state_file="${state_dir}/${safe_id}.band"
  prev=0
  [ -f "$state_file" ] && prev="$(cat "$state_file" 2>/dev/null)"
  case "$prev" in ''|*[!0-9]*) prev=0 ;; esac

  if [ "$current" -gt "$prev" ]; then
    printf '%s' "$current" > "$state_file" 2>/dev/null
    printf '[context: ~%s%%]\n' "$pct"
  elif [ "$current" -lt "$prev" ]; then
    printf '%s' "$current" > "$state_file" 2>/dev/null
  fi
} 2>/dev/null

exit 0
