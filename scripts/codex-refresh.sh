#!/usr/bin/env bash
# Refreshes the Codex CLI + the Claude Code Codex plugin's resident broker.
#
# Why: the Codex plugin keeps a long-lived broker process
#   node <plugin cache>/openai-codex/codex/<ver>/scripts/app-server-broker.mjs serve ...
#     -> bash -c "codex app-server" -> codex(.exe)
# that pins the CLI version it was spawned with. After `npm install -g
# @openai/codex@latest` the plugin keeps talking to the OLD CLI until the
# broker is killed (the plugin respawns it on next use). Symptom: plugin calls
# fail with "model is not supported" / "requires a newer version" while
# `codex exec --model <id>` works directly.
#
# Steps (each logged on one line):
#   (a) codex not on PATH -> say so, exit 0
#   (b) compare `codex --version` to `npm view @openai/codex version`;
#       install the update only with --update
#   (c) ALWAYS kill stale broker processes (--dry-run lists only)
#   (d) --probe <id>[,<id>...]: one cheap `codex exec` per model ID
#
# Usage: codex-refresh.sh [--update] [--dry-run] [--probe <id>[,<id>...]]
# Env:   CODEX_REFRESH_EXCLUDE  ERE; matching command lines are never killed
#                               (default: pmbot\\bot)
# Idempotent and safe to run anytime. Never prints tokens or keys.
set -u

UPDATE=0
DRY_RUN=0
PROBE_IDS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --update)   UPDATE=1; shift ;;
    --dry-run)  DRY_RUN=1; shift ;;
    --probe=*)  PROBE_IDS="${1#--probe=}"; shift ;;
    --probe)
      if [ $# -lt 2 ] || [ -z "$2" ]; then
        echo "error: --probe requires a model ID list (comma-separated)" >&2
        exit 2
      fi
      PROBE_IDS="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *)
      echo "error: unknown argument: $1" >&2
      exit 2 ;;
  esac
done

BROKER_RE='app-server-broker|codex.*app-server'
# Default ERE `pmbot\\bot` matches the literal path fragment `pmbot\bot`.
EXCLUDE_RE="${CODEX_REFRESH_EXCLUDE:-pmbot\\\\bot}"

log() { printf 'codex-refresh: %s\n' "$*"; }

# Strip anything that looks like a credential before it reaches the terminal.
redact() {
  sed -E \
    -e 's/(sk-[A-Za-z0-9_-]{4})[A-Za-z0-9_-]+/\1[REDACTED]/g' \
    -e 's/([Bb]earer )[A-Za-z0-9._-]+/\1[REDACTED]/g' \
    -e 's/((access_token|refresh_token|id_token|api_key|OPENAI_API_KEY)"?[[:space:]]*[:=][[:space:]]*"?)[^",[:space:]]+/\1[REDACTED]/g'
}

# Run with a timeout when one is available.
with_timeout() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then timeout "${secs}" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then gtimeout "${secs}" "$@"
  else "$@"; fi
}

# --- (a) CLI present? -------------------------------------------------------
if ! command -v codex >/dev/null 2>&1; then
  log "codex CLI not installed"
  exit 0
fi

# --- (b) version check / optional update -------------------------------------
installed="$(with_timeout 30 codex --version 2>/dev/null | tr -d '\r' | grep -oE '[0-9]+(\.[0-9]+)+' | head -1)"
if ! command -v npm >/dev/null 2>&1; then
  log "version: installed ${installed:-unknown}; npm not found, skipping latest-version compare"
else
  latest="$(with_timeout 30 npm view @openai/codex version 2>/dev/null | tr -d '\r' | grep -oE '[0-9]+(\.[0-9]+)+' | head -1)"
  if [ -z "${latest}" ]; then
    log "version: installed ${installed:-unknown}; npm view failed (offline?), skipping latest-version compare"
  elif [ -z "${installed}" ]; then
    log "version: could not parse 'codex --version'; latest is ${latest}; skipping compare"
  elif [ "${installed}" = "${latest}" ] \
       || [ "$(printf '%s\n%s\n' "${installed}" "${latest}" | sort -V | tail -1)" = "${installed}" ]; then
    log "version: installed ${installed} is current (latest ${latest})"
  elif [ "${UPDATE}" -eq 1 ]; then
    log "version: installed ${installed} behind latest ${latest}; running npm install -g @openai/codex@latest"
    if with_timeout 600 npm install -g @openai/codex@latest >/dev/null 2>&1; then
      now="$(with_timeout 30 codex --version 2>/dev/null | tr -d '\r' | grep -oE '[0-9]+(\.[0-9]+)+' | head -1)"
      log "version: update done, codex now ${now:-unknown}"
    else
      log "version: npm install FAILED (re-run by hand: npm install -g @openai/codex@latest)"
    fi
  else
    log "version: installed ${installed} behind latest ${latest}; update with: npm install -g @openai/codex@latest (or re-run with --update)"
  fi
fi

# --- (c) restart stale brokers ----------------------------------------------
# Enumerate processes as "PID<TAB>START<TAB>CMDLINE" into a variable FIRST and
# filter in bash afterwards: a filter running concurrently (in a pipe) would
# carry the match pattern in its own command line and could match itself.
USE_PS=0
command -v powershell >/dev/null 2>&1 && USE_PS=1

enumerate() {
  if [ "${USE_PS}" -eq 1 ]; then
    powershell -NoProfile -Command 'Get-CimInstance Win32_Process | Where-Object { $_.CommandLine } | ForEach-Object { $s = if ($_.CreationDate) { $_.CreationDate.ToString("s") } else { "?" }; "{0}`t{1}`t{2}" -f $_.ProcessId, $s, ($_.CommandLine -replace "[\r\n\t]", " ") }' 2>/dev/null | tr -d '\r'
  else
    local pid args start
    for pid in $(pgrep -f "${BROKER_RE}" 2>/dev/null); do
      args="$(ps -o args= -p "${pid}" 2>/dev/null)" || continue
      start="$(ps -o lstart= -p "${pid}" 2>/dev/null | sed 's/^ *//')"
      printf '%s\t%s\t%s\n' "${pid}" "${start:-?}" "${args}"
    done
  fi
}

kill_pid() {
  if [ "${USE_PS}" -eq 1 ]; then
    powershell -NoProfile -Command "Stop-Process -Id $1 -Force -ErrorAction SilentlyContinue" >/dev/null 2>&1
  else
    kill "$1" 2>/dev/null
  fi
}

if [ "${USE_PS}" -eq 0 ] && ! command -v pgrep >/dev/null 2>&1; then
  log "brokers: neither powershell nor pgrep available; cannot enumerate, skipping restart"
else
  all="$(enumerate)"
  found=0; excluded=0
  while IFS=$'\t' read -r pid start cmd; do
    [ -n "${pid}" ] || continue
    case "${pid}" in *[!0-9]*) continue ;; esac
    [ "${pid}" = "$$" ] && continue
    printf '%s\n' "${cmd}" | grep -qE -- "${BROKER_RE}" || continue
    if printf '%s\n' "${cmd}" | grep -qE -- "${EXCLUDE_RE}"; then
      excluded=$((excluded+1)); continue
    fi
    found=$((found+1))
    if [ "${DRY_RUN}" -eq 1 ]; then
      log "broker: PID ${pid} started ${start} (dry-run, not killed)"
    else
      kill_pid "${pid}"
      log "broker: PID ${pid} started ${start} killed"
    fi
  done <<< "${all}"
  if [ "${found}" -eq 0 ]; then
    log "brokers: none running (excluded ${excluded}); plugin spawns a fresh one on next use"
  elif [ "${DRY_RUN}" -eq 1 ]; then
    log "brokers: ${found} found, none killed (--dry-run; excluded ${excluded})"
  else
    log "brokers: ${found} killed (excluded ${excluded}); plugin respawns the broker on the current CLI on next use"
  fi
fi

# --- (d) model probes ---------------------------------------------------------
rc=0
if [ -n "${PROBE_IDS}" ]; then
  IFS=',' read -r -a ids <<< "${PROBE_IDS}"
  for id in "${ids[@]}"; do
    id="$(printf '%s' "${id}" | tr -d '[:space:]')"
    [ -n "${id}" ] || continue
    # `codex exec` has no --effort flag; reasoning effort is a config override.
    out="$(with_timeout 120 codex exec --model "${id}" --skip-git-repo-check \
             -c model_reasoning_effort=low "Reply with exactly: OK" </dev/null 2>&1)"
    code=$?
    if [ "${code}" -eq 0 ] && printf '%s\n' "${out}" | grep -qw 'OK'; then
      echo "ACCEPTED ${id}"
    else
      err="$(printf '%s\n' "${out}" | tr -d '\r' | grep -iE 'error|not supported|unsupported|requires|denied|invalid' | head -1)"
      [ -n "${err}" ] || err="$(printf '%s\n' "${out}" | tr -d '\r' | grep -v '^[[:space:]]*$' | head -1)"
      [ "${code}" -eq 124 ] && err="timed out after 120s"
      [ -n "${err}" ] || err="exit ${code}, no output"
      echo "REJECTED ${id}: $(printf '%s' "${err}" | redact)"
      rc=1
    fi
  done
fi
exit "${rc}"
