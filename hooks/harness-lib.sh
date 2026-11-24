#!/usr/bin/env bash
# harness-lib.sh — shared helpers for the workflow hooks (journal, stop-gate,
# session-state, ops-guard). Sourced, never executed. Every hook FAILS OPEN:
# missing jq, empty stdin or an unparseable payload must never wedge a session.

H_DIR="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/harness"

# Kill switch: one file or one env var turns every workflow hook into a no-op.
h_off() { [ "${HARNESS_OFF:-}" = "1" ] || [ -e "${H_DIR}/off" ]; }

h_hash() { if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -c1-16; else shasum -a 256 | cut -c1-16; fi; }
h_filehash() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
h_mtime() { stat -c '%Y' "$1" 2>/dev/null || stat -f '%m' "$1" 2>/dev/null; }

# Reads the hook payload once and sets: H_SID H_CWD H_EVENT H_TOOL H_AGENT H_MODE H_PROMPT
h_read_payload() {
  command -v jq >/dev/null 2>&1 || return 1
  H_PAYLOAD="$(cat)" || return 1
  [ -n "${H_PAYLOAD}" ] || return 1
  local vars
  vars="$(printf '%s' "${H_PAYLOAD}" | jq -r '[
      (.session_id // "nosession"), (.cwd // ""), (.hook_event_name // ""), (.tool_name // ""),
      ((.agent_id // "") + (.agent_type // "")), (.permission_mode // ""), (.prompt_id // "noprompt")
    ] | map(gsub("[\u001f\n]"; " ")) | join("\u001f")' 2>/dev/null)" || return 1
  # Unit-separator, not tab: whitespace IFS characters collapse empty fields.
  IFS=$'\x1f' read -r H_SID H_CWD H_EVENT H_TOOL H_AGENT H_MODE H_PROMPT <<<"${vars}"
  H_SID="$(printf '%s' "${H_SID}" | tr -c 'A-Za-z0-9._-' '_')"
  H_PROMPT="$(printf '%s' "${H_PROMPT}" | tr -c 'A-Za-z0-9._-' '_')"
  [ -n "${H_CWD}" ] || H_CWD="${PWD}"
  H_STATE="${H_DIR}/state/${H_SID}"
  return 0
}
h_get() { printf '%s' "${H_PAYLOAD}" | jq -r "$1 // empty" 2>/dev/null; }

# Project root = git toplevel when there is one, else the session cwd.
h_root() { git -C "${H_CWD}" rev-parse --show-toplevel 2>/dev/null || printf '%s' "${H_CWD}"; }
# Stable identity shared by every worktree of a repository.
h_project_key() {
  local r c
  r="$(h_root)"
  c="$(cd "${r}" 2>/dev/null && git rev-parse --git-common-dir 2>/dev/null)" || c=""
  if [ -n "${c}" ]; then (cd "${r}" && cd "${c}" 2>/dev/null && pwd -P); else (cd "${r}" 2>/dev/null && pwd -P); fi
}

# Changed CODE files (tracked-modified + untracked, not ignored), one per line.
# Docs and the harness's own state are not code: editing them never needs verification.
h_changed_files() {
  local root="$1"
  git -C "${root}" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
  git -C "${root}" status --porcelain -uall 2>/dev/null | cut -c4- | sed -e 's/^.* -> //' -e 's/^"//' -e 's/"$//' \
    | grep -Ev '(\.(md|mdx|txt|rst|adoc)$|^\.claude/harness/|(^|/)(LICENSE|CHANGELOG|NOTICE)[^/]*$)' | head -2000
  return 0
}
# Fingerprint of the working tree's code changes (names + size + mtime).
h_dirty_hash() {
  local root="$1" f
  h_changed_files "${root}" | while IFS= read -r f; do
    printf '%s %s\n' "${f}" "$(stat -c '%s.%Y' "${root}/${f}" 2>/dev/null || stat -f '%z.%m' "${root}/${f}" 2>/dev/null || echo gone)"
  done | h_hash
}
h_last_change() {
  local root="$1" f m max=0
  while IFS= read -r f; do
    m="$(h_mtime "${root}/${f}")"; case "${m}" in ''|*[!0-9]*) continue ;; esac
    [ "${m}" -gt "${max}" ] && max="${m}"
  done < <(h_changed_files "${root}")
  printf '%s' "${max}"
}

# Is this command worth counting as "the change was exercised"? Listing, reading,
# moving files and plain git bookkeeping are not. Anything that runs code is.
h_is_evidence() {
  local cmd="$1" seg w ev=1
  set -f
  while IFS= read -r seg; do
    # shellcheck disable=SC2086
    set -- ${seg}
    while [ $# -gt 0 ]; do case "$1" in *=*|sudo|time|nohup|command|exec|timeout|[0-9]*) shift ;; *) break ;; esac; done
    [ $# -gt 0 ] || continue
    w="${1##*/}"
    case "${w}" in
      ls|cat|head|tail|grep|rg|find|echo|printf|pwd|cd|wc|sed|awk|mkdir|cp|mv|rm|rmdir|touch|chmod|chown|true|false|which|file|stat|jq|sort|uniq|tree|diff|cut|tr|tee|ln|basename|dirname|date|sleep|export|set|unset|test|'['|'[['|read|kill|pkill|ps|du|df|xargs|less|more) ;;
      git) case "${2:-}" in bisect) ev=0 ;; esac ;;
      '#'*|'') ;;
      *) ev=0 ;;
    esac
  done <<<"$(printf '%s' "${cmd}" | sed -E 's/(&&|\|\||[;|&])/\n/g')"
  set +f
  return "${ev}"
}

# Trusted verify recipe: <project>/.claude/harness/verify.sh whose content hash was
# registered (outside the project) by `harness trust-verify`. A recipe that arrives
# with a cloned repo, or that changed after it was trusted, is never auto-run.
h_trust_file() { printf '%s/trust' "${H_DIR}"; }
h_recipe_status() {   # echoes: none | trusted | untrusted | changed
  local root="$1" recipe key hash line
  recipe="${root}/.claude/harness/verify.sh"
  [ -f "${recipe}" ] || { echo none; return; }
  key="$(h_project_key)"; hash="$(h_filehash "${recipe}")"
  line="$(grep -F "	${key}" "$(h_trust_file)" 2>/dev/null | tail -1)"
  if [ -z "${line}" ]; then echo untrusted
  elif [ "${line%%	*}" = "${hash}" ]; then echo trusted
  else echo changed; fi
}
