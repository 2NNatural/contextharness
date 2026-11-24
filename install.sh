#!/usr/bin/env bash
# Installs the model-routing harness at user level (~/.claude).
# Idempotent: safe to re-run after every `git pull`.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}"
AGENTS_DIR="${CLAUDE_DIR}/agents"
SKILLS_SRC="${REPO_DIR}/skills"
SKILLS_DIR="${CLAUDE_DIR}/skills"
CLAUDE_MD="${CLAUDE_DIR}/CLAUDE.md"
RULES_FILE="${REPO_DIR}/routing-rules.md"
HOOKS_SRC="${REPO_DIR}/hooks"
HOOKS_DIR="${CLAUDE_DIR}/hooks"
SETTINGS_FILE="${CLAUDE_DIR}/settings.json"
HOOK_NEEDLE='context-meter.sh'
GUARD_NEEDLE='destructive-guard.sh'
TEMPLATES_SRC="${REPO_DIR}/templates"
SCRIPTS_DIR="${CLAUDE_DIR}/scripts"
CODEX_REFRESH_SRC="${REPO_DIR}/scripts/codex-refresh.sh"
CODEX_TOGGLE="${CLAUDE_DIR}/codex-routing.on"
START_MARKER='<!-- model-harness:start -->'
END_MARKER='<!-- model-harness:end -->'

file_mode() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null
}

has_any_read_bit() {
  local mode perms owner group other
  mode="$(file_mode "$1")" || return 1
  perms="${mode: -3}"
  owner="${perms:0:1}"
  group="${perms:1:1}"
  other="${perms:2:1}"
  [ $((owner & 4)) -ne 0 ] || [ $((group & 4)) -ne 0 ] || [ $((other & 4)) -ne 0 ]
}

# Best-effort probe for the strongest available model tier.
# Echoes "fable" or "opus", or "" if inconclusive. NEVER fails the install.
# Drives the `claude` CLI in print mode to reuse Claude Code's own resolved
# auth (OAuth/keychain/apiKeyHelper) — no ANTHROPIC_API_KEY required.
probe_top_model() {
  # Test-only escape hatch. tests/run-tests.sh exports HARNESS_SKIP_PROBE=1 so the
  # suite never shells out to the real `claude` CLI (up to 25s per install run,
  # ~21 runs = >2min on Windows). Returns "" = inconclusive, which the caller
  # already handles. Never set this in normal use.
  if [ -n "${HARNESS_SKIP_PROBE:-}" ]; then printf ''; return 0; fi
  if command -v claude >/dev/null 2>&1; then
    local runner=""
    if command -v timeout >/dev/null 2>&1; then runner="timeout 25"
    elif command -v gtimeout >/dev/null 2>&1; then runner="gtimeout 25"; fi
    if ${runner} claude -p --model "${TOP_FABLE_ID}" --max-turns 1 'hi' >/dev/null 2>&1; then
      printf 'fable'; return 0
    fi
    printf 'opus'; return 0
  fi
  if [ -n "${ANTHROPIC_API_KEY:-}" ] && command -v curl >/dev/null 2>&1; then
    local code
    code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 \
      -H "x-api-key: ${ANTHROPIC_API_KEY}" \
      -H "anthropic-version: 2023-06-01" \
      -H "content-type: application/json" \
      -d '{"model":"'"${TOP_FABLE_ID}"'","max_tokens":1,"messages":[{"role":"user","content":"hi"}]}' \
      https://api.anthropic.com/v1/messages 2>/dev/null)" || { printf ''; return 0; }
    case "${code}" in
      200) printf 'fable'; return 0 ;;
      4*)  printf 'opus';  return 0 ;;
      *)   printf '';      return 0 ;;
    esac
  fi
  printf ''
}

# The top-model ID is single-sourced from agents/oracle.md so the tier probe and
# the post-install message can never drift from the pin (they did, in v1).
TOP_FABLE_PIN="$(sed -n 's/^model: //p' "${REPO_DIR}/agents/oracle.md" 2>/dev/null | head -1 || true)"
[ -n "${TOP_FABLE_PIN}" ] || TOP_FABLE_PIN="fable"
TOP_FABLE_ID="${TOP_FABLE_PIN%%\[*}"

H_HOME="${CLAUDE_DIR}/harness"
BACKUP_ROOT="${H_HOME}/backups"
VERSION="$(cat "${REPO_DIR}/VERSION" 2>/dev/null || echo unknown)"
WORKFLOW_HOOKS="journal stop-gate session-state ops-guard"
ALL_HOOKS="context-meter destructive-guard ${WORKFLOW_HOOKS}"
CODEX_HOME_DIR="${CODEX_HOME:-${HOME}/.codex}"

usage() {
  cat <<USAGE
ContextHarness ${VERSION} installer

  ./install.sh                       install/update agents, skills, scripts and the core rules block
  ./install.sh --recommended         the above plus every safety and workflow hook (best for most people)
  ./install.sh --with-workflow-hooks   journal, stop-gate, session-state, ops-guard
  ./install.sh --with-context-hook | --with-destructive-guard
  ./install.sh --remove-workflow-hooks | --remove-context-hook | --remove-destructive-guard
  ./install.sh --with-codex-agents   also install the portable core into ${CODEX_HOME_DIR}/AGENTS.md
  ./install.sh --top-model fable|opus  override strongest-tier auto-detection
  ./install.sh --rollback            restore the state from before the last install
  ./install.sh --uninstall           remove everything this installer added (your own settings are kept)
  ./install.sh --init-inventory      create INTERFACES.md in the current project (use alone)
  ./install.sh --refresh-codex       update Codex CLI + restart its broker (use alone; toggle-gated)
USAGE
}

# --- Parse flags ---------------------------------------------------------------
TOP_MODEL=""
WITH_CONTEXT_HOOK=0; REMOVE_CONTEXT_HOOK=0
WITH_GUARD=0; REMOVE_GUARD=0
WITH_WORKFLOW=0; REMOVE_WORKFLOW=0
WITH_CODEX_AGENTS=0
ROLLBACK=0; UNINSTALL=0
INIT_INVENTORY=0; REFRESH_CODEX=0; OTHER_FLAGS=0
while [ $# -gt 0 ]; do
  case "$1" in
    --top-model=*) TOP_MODEL="${1#--top-model=}"; OTHER_FLAGS=1; shift ;;
    --top-model)
      if [ $# -lt 2 ]; then echo "error: --top-model requires a value (fable or opus)" >&2; exit 1; fi
      TOP_MODEL="$2"; OTHER_FLAGS=1; shift 2 ;;
    --recommended)             WITH_CONTEXT_HOOK=1; WITH_GUARD=1; WITH_WORKFLOW=1; OTHER_FLAGS=1; shift ;;
    --with-context-hook)       WITH_CONTEXT_HOOK=1;   OTHER_FLAGS=1; shift ;;
    --remove-context-hook)     REMOVE_CONTEXT_HOOK=1; OTHER_FLAGS=1; shift ;;
    --with-destructive-guard)  WITH_GUARD=1;   OTHER_FLAGS=1; shift ;;
    --remove-destructive-guard) REMOVE_GUARD=1; OTHER_FLAGS=1; shift ;;
    --with-workflow-hooks)     WITH_WORKFLOW=1;   OTHER_FLAGS=1; shift ;;
    --remove-workflow-hooks)   REMOVE_WORKFLOW=1; OTHER_FLAGS=1; shift ;;
    --with-codex-agents)       WITH_CODEX_AGENTS=1; OTHER_FLAGS=1; shift ;;
    --rollback)                ROLLBACK=1; shift ;;
    --uninstall)               UNINSTALL=1; shift ;;
    --init-inventory)          INIT_INVENTORY=1; shift ;;
    --refresh-codex)           REFRESH_CODEX=1; shift ;;
    -h|--help)                 usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; exit 1 ;;
  esac
done

# --- --init-inventory: the ONE mode that writes outside ~/.claude -------------
# Copies templates/INTERFACES.md into the CURRENT working directory's project.
# It writes exactly one file, to $PWD, never overwrites, and exits before the
# tier probe and before ANY ~/.claude work.
if [ "${INIT_INVENTORY}" -eq 1 ]; then
  if [ "${OTHER_FLAGS}" -eq 1 ] || [ "${ROLLBACK}" -eq 1 ] || [ "${UNINSTALL}" -eq 1 ]; then
    echo "error: --init-inventory must be used alone (it writes to the current project, not ~/.claude)" >&2
    exit 1
  fi
  TEMPLATE="${TEMPLATES_SRC}/INTERFACES.md"
  [ -f "${TEMPLATE}" ] && [ -r "${TEMPLATE}" ] \
    || { echo "error: cannot read ${TEMPLATE}" >&2; exit 1; }
  DEST_DIR="$(pwd)"
  case "${DEST_DIR}" in
    "${HOME}"|"${HOME}/"|"${HOME}/.claude"|"${HOME}/.claude/"*|"${CLAUDE_DIR}"|"${CLAUDE_DIR}/"*)
      echo "error: refusing to create INTERFACES.md in ${DEST_DIR} — cd into a project directory first" >&2
      exit 1
      ;;
  esac
  DEST="${DEST_DIR}/INTERFACES.md"
  if [ -e "${DEST}" ]; then
    echo "INTERFACES.md already exists in ${DEST_DIR} — leaving it untouched."
    exit 0
  fi
  cp "${TEMPLATE}" "${DEST}"
  echo "created ${DEST}"
  echo "Fill in one row per cross-process/cross-service link, then keep the"
  echo "'last verified live' column current. /audit reads this file."
  exit 0
fi

# --- --refresh-codex: standalone Codex CLI + plugin-broker refresh -----------
if [ "${REFRESH_CODEX}" -eq 1 ]; then
  if [ "${OTHER_FLAGS}" -eq 1 ] || [ "${INIT_INVENTORY}" -eq 1 ] || [ "${ROLLBACK}" -eq 1 ] || [ "${UNINSTALL}" -eq 1 ]; then
    echo "error: --refresh-codex must be used alone" >&2
    exit 1
  fi
  if [ ! -e "${CODEX_TOGGLE}" ]; then
    echo "Codex routing is off (${CODEX_TOGGLE} absent) — skipping Codex refresh."
    exit 0
  fi
  [ -f "${CODEX_REFRESH_SRC}" ] \
    || { echo "error: ${CODEX_REFRESH_SRC} not found" >&2; exit 1; }
  bash "${CODEX_REFRESH_SRC}" --update
  exit $?
fi

# ============================ shared helpers ==================================

SETTINGS_BACKED_UP=0
backup_settings_once() {
  if [ "${SETTINGS_BACKED_UP}" -eq 0 ] && [ -f "${SETTINGS_FILE}" ]; then
    cp "${SETTINGS_FILE}" "${SETTINGS_FILE}.harness-bak.$(date +%Y%m%d%H%M%S)"
    SETTINGS_BACKED_UP=1
  fi
}

# hook_events <name> -> lines of "<Event>\t<matcher or ->\t<timeout or ->"
hook_events() {
  case "$1" in
    context-meter)     printf 'UserPromptSubmit\t-\t-\n' ;;
    destructive-guard) printf 'PreToolUse\tBash\t-\n' ;;
    ops-guard)         printf 'PreToolUse\tBash|Read\t-\n' ;;
    journal)           printf 'PostToolUse\tEdit|Write|MultiEdit|NotebookEdit|Bash\t-\nPostToolUseFailure\tBash\t-\n' ;;
    stop-gate)         printf 'Stop\t-\t300\n' ;;
    session-state)     printf 'SessionStart\t-\t-\n' ;;
  esac
}
hook_snippet() {  # manual instructions when the merge cannot be done safely
  local name="$1" ev matcher to
  echo "To enable the ${name//-/ } manually, add this to ${SETTINGS_FILE}:" >&2
  while IFS=$'\t' read -r ev matcher to; do
    if [ "${matcher}" = "-" ]; then
      echo "  \"hooks\": { \"${ev}\": [ { \"hooks\": [ { \"type\": \"command\", \"command\": \"${HOOKS_DIR}/${name}.sh\" } ] } ] }" >&2
    else
      echo "  \"hooks\": { \"${ev}\": [ { \"matcher\": \"${matcher}\", \"hooks\": [ { \"type\": \"command\", \"command\": \"${HOOKS_DIR}/${name}.sh\" } ] } ] }" >&2
    fi
  done < <(hook_events "${name}")
}
hook_label() {
  case "$1" in context-meter|destructive-guard) printf '%s' "$1" ;; *) printf '%s' "${1//-/ }" ;; esac
}

install_hook() {
  local name="$1" label src dst ev matcher to tmp changed=0 failed=0
  label="$(hook_label "${name}")"; src="${HOOKS_SRC}/${name}.sh"; dst="${HOOKS_DIR}/${name}.sh"
  if [ ! -f "${src}" ]; then echo "warning: ${src} not found; skipping hook install" >&2; return 0; fi
  mkdir -p "${HOOKS_DIR}"
  cp "${src}" "${dst}"; chmod +x "${dst}"
  [ -f "${HOOKS_SRC}/harness-lib.sh" ] && cp "${HOOKS_SRC}/harness-lib.sh" "${HOOKS_DIR}/harness-lib.sh"
  echo "installed hook: ${dst}"
  if ! command -v jq >/dev/null 2>&1; then
    echo "warning: jq not found — hook script copied but not registered" >&2
    hook_snippet "${name}"; return 0
  fi
  touch "${SETTINGS_FILE}"
  [ -s "${SETTINGS_FILE}" ] || printf '{}\n' > "${SETTINGS_FILE}"
  while IFS=$'\t' read -r ev matcher to; do
    if jq -e --arg c "${dst}" --arg e "${ev}" '[ .hooks[$e][]?.hooks[]?.command ] | any(. == $c)' "${SETTINGS_FILE}" >/dev/null 2>&1; then
      continue
    fi
    tmp="$(mktemp)"
    if jq --arg c "${dst}" --arg e "${ev}" --arg m "${matcher}" --arg t "${to}" '
          .hooks = (.hooks // {})
          | .hooks[$e] = (.hooks[$e] // [])
          | .hooks[$e] += [ ( (if $m == "-" then {} else {matcher: $m} end)
                + { hooks: [ ({type: "command", command: $c} + (if $t == "-" then {} else {timeout: ($t|tonumber)} end)) ] } ) ]
        ' "${SETTINGS_FILE}" > "${tmp}" 2>/dev/null && jq empty "${tmp}" 2>/dev/null; then
      backup_settings_once
      cat "${tmp}" > "${SETTINGS_FILE}"; changed=1
    else
      failed=1
    fi
    rm -f "${tmp:?}"
  done < <(hook_events "${name}")
  if [ "${failed}" -eq 1 ]; then
    echo "warning: could not safely merge ${SETTINGS_FILE}; left untouched" >&2
    hook_snippet "${name}"
  elif [ "${changed}" -eq 1 ]; then
    echo "registered ${label} hook in ${SETTINGS_FILE} (backup written)"
  else
    echo "${label} hook already registered in ${SETTINGS_FILE} (idempotent)"
  fi
}

unregister_hook() {   # removes registrations only; returns 1 if there was nothing to do
  local name="$1" tmp
  command -v jq >/dev/null 2>&1 && [ -f "${SETTINGS_FILE}" ] || return 1
  grep -q "${name}.sh" "${SETTINGS_FILE}" 2>/dev/null || return 1
  tmp="$(mktemp)"
  if jq --arg n "${name}.sh" '
        if (.hooks? | type) == "object" then
          .hooks |= with_entries(
            if (.value | type) == "array" then
              .value |= ( map(if (.hooks? | type) == "array"
                               then .hooks |= map(select(((.command // "") | contains($n)) | not)) else . end)
                          | map(select((.hooks? | type) != "array" or (.hooks | length) > 0)) )
            else . end)
        else . end
      ' "${SETTINGS_FILE}" > "${tmp}" 2>/dev/null && jq empty "${tmp}" 2>/dev/null; then
    backup_settings_once
    cat "${tmp}" > "${SETTINGS_FILE}"
    rm -f "${tmp:?}"; return 0
  fi
  rm -f "${tmp:?}"; return 1
}
remove_hook() {
  local name="$1" label
  label="$(hook_label "${name}")"
  if unregister_hook "${name}"; then
    echo "removed ${label} hook registration from ${SETTINGS_FILE}"
  fi
  rm -f "${HOOKS_DIR:?}/${name:?}.sh"
  echo "removed ${HOOKS_DIR}/${name}.sh"
}

# Insert-or-replace the marked block in a file, preserving everything outside it.
install_block() {
  local target="$1" rules="$2" what="$3" starts ends start_line end_line tmp
  mkdir -p "$(dirname "${target}")"
  touch "${target}"
  # Whole-line, fixed-string marker counts (grep -c exits 1 on zero matches; tolerate it).
  starts=$(grep -cxF "${START_MARKER}" "${target}" || true)
  ends=$(grep -cxF "${END_MARKER}" "${target}" || true)
  if [ "${starts}" -eq 0 ] && [ "${ends}" -eq 0 ]; then
    if [ -s "${target}" ]; then printf '\n' >> "${target}"; fi
    cat "${rules}" >> "${target}"
    echo "appended ${what} block to ${target}"
  elif [ "${starts}" -eq 1 ] && [ "${ends}" -eq 1 ]; then
    start_line=$(grep -nxF "${START_MARKER}" "${target}" | head -1 | cut -d: -f1)
    end_line=$(grep -nxF "${END_MARKER}" "${target}" | head -1 | cut -d: -f1)
    if [ "${start_line}" -ge "${end_line}" ]; then
      echo "error: harness markers are out of order in ${target}; fix the file by hand and re-run" >&2
      exit 1
    fi
    # Markers and filename go through the environment (awk -v would mangle
    # backslashes) and are matched as whole lines only.
    tmp="$(mktemp)"
    START="${START_MARKER}" END="${END_MARKER}" RULES="${rules}" awk '
      $0 == ENVIRON["START"] {
        skip = 1
        while ((r = (getline line < ENVIRON["RULES"])) > 0) print line
        if (r < 0) { print "error: cannot read rules file" > "/dev/stderr"; exit 1 }
        close(ENVIRON["RULES"]); next
      }
      $0 == ENVIRON["END"] && skip { skip = 0; next }
      !skip { print }
    ' "${target}" > "${tmp}"
    # Write through the existing inode (not mv): preserves permissions,
    # ownership, and symlinked files (dotfile-repo setups).
    cat "${tmp}" > "${target}"
    rm -f "${tmp:?}"
    echo "updated ${what} block in ${target}"
  else
    echo "error: expected exactly one harness block in ${target}, found ${starts} start / ${ends} end marker(s); refusing to edit — fix the file by hand and re-run" >&2
    exit 1
  fi
}
strip_block() {
  local target="$1" tmp
  [ -f "${target}" ] || return 0
  [ "$(grep -cxF "${START_MARKER}" "${target}" || true)" -eq 1 ] && [ "$(grep -cxF "${END_MARKER}" "${target}" || true)" -eq 1 ] || return 0
  tmp="$(mktemp)"
  START="${START_MARKER}" END="${END_MARKER}" awk '
    $0 == ENVIRON["START"] { skip = 1; next }
    $0 == ENVIRON["END"] && skip { skip = 0; next }
    !skip { print }' "${target}" > "${tmp}"
  cat "${tmp}" > "${target}"; rm -f "${tmp:?}"
  echo "removed harness block from ${target}"
}

# Everything this installer owns, relative to CLAUDE_DIR. Operator data (trust
# list, lesson ledger, session state, the Codex toggle) is deliberately NOT here.
managed_paths() {
  local f d
  for f in "${REPO_DIR}"/agents/*.md; do echo "agents/$(basename "$f")"; done
  for d in "${SKILLS_SRC}"/*/; do [ -d "$d" ] && echo "skills/$(basename "$d")"; done
  for f in ${ALL_HOOKS} harness-lib; do echo "hooks/${f}.sh"; done
  echo "scripts/codex-refresh.sh"; echo "scripts/harness"; echo "scripts/harness-lib.sh"
  echo "harness/VERSION"; echo "harness/codex-tiers"
  echo "CLAUDE.md"; echo "settings.json"
}
snapshot() {   # tar of the managed paths that currently exist; keeps the last 5
  local ts dir list p old
  ts="$(date +%Y%m%d%H%M%S)"; dir="${BACKUP_ROOT}/${ts}"
  [ -d "${CLAUDE_DIR}" ] || mkdir -p "${CLAUDE_DIR}"
  mkdir -p "${dir}"; list="$(mktemp)"
  while IFS= read -r p; do [ -e "${CLAUDE_DIR}/${p}" ] && echo "${p}"; done < <(managed_paths) > "${list}"
  if [ -s "${list}" ]; then tar -C "${CLAUDE_DIR}" -cf "${dir}/files.tar" -T "${list}" 2>/dev/null || true; fi
  cp "${list}" "${dir}/manifest"; rm -f "${list:?}"
  cat "${H_HOME}/VERSION" > "${dir}/from-version" 2>/dev/null || true
  # shellcheck disable=SC2012
  ls -1d "${BACKUP_ROOT}"/*/ 2>/dev/null | sort | head -n -5 | while IFS= read -r old; do
    case "${old}" in "${BACKUP_ROOT}"/2*) rm -rf "${old:?}" ;; esac
  done
}
remove_managed() {
  local p name
  for name in ${ALL_HOOKS}; do unregister_hook "${name}" || true; done
  while IFS= read -r p; do
    case "${p}" in CLAUDE.md|settings.json|'') continue ;; esac
    rm -rf "${CLAUDE_DIR:?}/${p:?}"
  done < <(managed_paths)
  strip_block "${CLAUDE_MD}"
}

# ============================ uninstall / rollback ============================
if [ "${UNINSTALL}" -eq 1 ] || [ "${ROLLBACK}" -eq 1 ]; then
  if [ "${OTHER_FLAGS}" -eq 1 ] || { [ "${UNINSTALL}" -eq 1 ] && [ "${ROLLBACK}" -eq 1 ]; }; then
    echo "error: --rollback and --uninstall must be used alone" >&2; exit 1
  fi
  if [ "${ROLLBACK}" -eq 1 ]; then
    # shellcheck disable=SC2012
    latest="$(ls -1d "${BACKUP_ROOT}"/*/ 2>/dev/null | sort | tail -1)"
    [ -n "${latest}" ] || { echo "error: no backup to roll back to under ${BACKUP_ROOT}" >&2; exit 1; }
    remove_managed
    # settings.json and CLAUDE.md come back exactly as they were, if they existed.
    if [ -f "${latest}files.tar" ]; then tar -C "${CLAUDE_DIR}" -xf "${latest}files.tar"; fi
    was="$(cat "${latest}from-version" 2>/dev/null)"; [ -n "${was}" ] || was="none (v1 or not installed)"
    case "${latest}" in "${BACKUP_ROOT}"/2*) rm -rf "${latest:?}" ;; esac
    echo "rolled back to the state before the last install (harness version then: ${was})."
    echo "Restart Claude Code for it to take effect."
    exit 0
  fi
  snapshot
  remove_managed
  echo "uninstalled. Your own CLAUDE.md content, settings, Codex toggle, trust list and lesson ledger were left in place."
  echo "A backup of what was removed is under ${BACKUP_ROOT} (./install.sh --rollback restores it)."
  exit 0
fi

# ================================ install =====================================

if [ -n "${TOP_MODEL}" ]; then
  case "${TOP_MODEL}" in
    fable|opus) ;;
    *) echo "error: --top-model must be 'fable' or 'opus', got: '${TOP_MODEL}'" >&2; exit 1 ;;
  esac
fi

# If no flag was given, ALWAYS auto-probe the tier first; only prompt (TTY) or
# default to fable (non-TTY) when the probe is inconclusive.
if [ -z "${TOP_MODEL}" ]; then
  probed="$(probe_top_model || true)"
  case "${probed}" in
    fable|opus)
      TOP_MODEL="${probed}"
      echo "auto-detected top model tier: ${TOP_MODEL}" >&2
      ;;
    *)
      if [ -t 0 ]; then
        while true; do
          printf "Strongest model on your plan? [fable/opus] (default: fable): "
          read -r answer
          case "${answer}" in
            ""|fable) TOP_MODEL="fable"; break ;;
            opus)     TOP_MODEL="opus";  break ;;
            *) echo "Invalid choice '${answer}'. Please enter 'fable' or 'opus'." >&2 ;;
          esac
        done
      else
        TOP_MODEL="fable"
        echo "tier probe inconclusive; defaulting to fable (override with --top-model)" >&2
      fi
      ;;
  esac
fi

# Sanity checks. Also catches invocation via a symlink, where BASH_SOURCE
# resolves to the link's directory instead of the repo.
[ -d "${REPO_DIR}/agents" ] || { echo "error: ${REPO_DIR}/agents not found — run install.sh from inside the repo (not via a symlink)" >&2; exit 1; }
[ -f "${RULES_FILE}" ] && [ -r "${RULES_FILE}" ] && has_any_read_bit "${RULES_FILE}" \
  || { echo "error: cannot read ${RULES_FILE}" >&2; exit 1; }

# Refuse to touch a malformed CLAUDE.md BEFORE changing anything else.
if [ -f "${CLAUDE_MD}" ]; then
  pre_s=$(grep -cxF "${START_MARKER}" "${CLAUDE_MD}" || true); pre_e=$(grep -cxF "${END_MARKER}" "${CLAUDE_MD}" || true)
  if ! { [ "${pre_s}" -eq 0 ] && [ "${pre_e}" -eq 0 ]; } && ! { [ "${pre_s}" -eq 1 ] && [ "${pre_e}" -eq 1 ]; }; then
    echo "error: expected exactly one harness block in ${CLAUDE_MD}, found ${pre_s} start / ${pre_e} end marker(s); refusing to edit — fix the file by hand and re-run" >&2
    exit 1
  fi
fi

# Normalize the rules file's line endings (Windows checkouts may carry CRLF) so
# every code path emits LF-only and re-runs stay byte-identical.
NORMALIZED_RULES_FILE="$(mktemp)"
trap 'rm -f "${NORMALIZED_RULES_FILE:?}"' EXIT
tr -d '\r' < "${RULES_FILE}" > "${NORMALIZED_RULES_FILE}"
RULES_FILE="${NORMALIZED_RULES_FILE}"

# 0. Snapshot what is about to be replaced, so --rollback can undo this run.
snapshot

# 1. Agents (repo is source of truth — overwrite).
mkdir -p "${AGENTS_DIR}"
for f in "${REPO_DIR}"/agents/*.md; do
  cp "$f" "${AGENTS_DIR}/"
  echo "installed agent: ${AGENTS_DIR}/$(basename "$f")"
done

# 1b. Skills (repo is source of truth — overwrite the tree, including support files).
if [ -d "${SKILLS_SRC}" ]; then
  mkdir -p "${SKILLS_DIR}"
  for d in "${SKILLS_SRC}"/*/; do
    [ -d "$d" ] || continue
    name="$(basename "$d")"
    mkdir -p "${SKILLS_DIR}/${name}"
    cp -R "$d". "${SKILLS_DIR}/${name}/"
    echo "installed skill: ${SKILLS_DIR}/${name}"
  done
fi

# 1c. Helper scripts, the shared hook library (the `harness` CLI needs it even when
#     no hook is registered), the Codex tier table and the version marker.
mkdir -p "${SCRIPTS_DIR}" "${H_HOME}"
if [ -f "${CODEX_REFRESH_SRC}" ]; then
  cp "${CODEX_REFRESH_SRC}" "${SCRIPTS_DIR}/codex-refresh.sh"
  chmod +x "${SCRIPTS_DIR}/codex-refresh.sh"
  echo "installed script: ${SCRIPTS_DIR}/codex-refresh.sh"
fi
if [ -f "${REPO_DIR}/scripts/harness" ]; then
  cp "${REPO_DIR}/scripts/harness" "${SCRIPTS_DIR}/harness"; chmod +x "${SCRIPTS_DIR}/harness"
  cp "${HOOKS_SRC}/harness-lib.sh" "${SCRIPTS_DIR}/harness-lib.sh"
  echo "installed script: ${SCRIPTS_DIR}/harness"
fi
[ -f "${REPO_DIR}/config/codex-tiers" ] && cp "${REPO_DIR}/config/codex-tiers" "${H_HOME}/codex-tiers"
printf '%s\n' "${VERSION}" > "${H_HOME}/VERSION"

# 1d. Hooks. All opt-in: a plain install never touches settings.json.
if [ "${REMOVE_CONTEXT_HOOK}" -eq 1 ]; then remove_hook context-meter
elif [ "${WITH_CONTEXT_HOOK}" -eq 1 ]; then install_hook context-meter; fi
if [ "${REMOVE_GUARD}" -eq 1 ]; then remove_hook destructive-guard
elif [ "${WITH_GUARD}" -eq 1 ]; then install_hook destructive-guard; fi
if [ "${REMOVE_WORKFLOW}" -eq 1 ]; then for h in ${WORKFLOW_HOOKS}; do remove_hook "${h}"; done
elif [ "${WITH_WORKFLOW}" -eq 1 ]; then for h in ${WORKFLOW_HOOKS}; do install_hook "${h}"; done; fi
# Keep already-installed hook scripts current on a plain update.
for h in ${ALL_HOOKS} harness-lib; do
  if [ -f "${HOOKS_DIR}/${h}.sh" ] && [ -f "${HOOKS_SRC}/${h}.sh" ]; then
    cp "${HOOKS_SRC}/${h}.sh" "${HOOKS_DIR}/${h}.sh"; chmod +x "${HOOKS_DIR}/${h}.sh"
  fi
done

# 1e. If top model is opus, rewrite the INSTALLED oracle.md only (repo copy untouched).
INSTALLED_ORACLE="${AGENTS_DIR}/oracle.md"
if [ "${TOP_MODEL}" = "opus" ]; then
  tmp_oracle="$(mktemp)"
  while IFS= read -r line; do
    case "${line}" in
      "model: "*) printf 'model: opus\n' ;;
      "description: "*)
        printf 'description: Maximum-capability reasoner in a fresh isolated context. Reserve for the hardest isolated jobs — bulk analysis too large to hold in the main thread (whole-codebase audits, huge log/diff digests, cross-cutting multi-system reasoning) or problems the architect explicitly could not crack. Expensive; use only when scout/architect are insufficient.\n'
        ;;
      *) printf '%s\n' "${line}" ;;
    esac
  done < "${INSTALLED_ORACLE}" > "${tmp_oracle}"
  cat "${tmp_oracle}" > "${INSTALLED_ORACLE}"
  rm -f "${tmp_oracle:?}"
  echo "patched installed oracle.md for top-model=opus"
fi

# 2. Core rules block in CLAUDE.md (everything outside the markers is preserved).
install_block "${CLAUDE_MD}" "${RULES_FILE}" "routing rules"

# 3. Optional: portable core for Codex CLI sessions.
if [ "${WITH_CODEX_AGENTS}" -eq 1 ]; then
  CODEX_BLOCK="$(mktemp)"; tr -d '\r' < "${REPO_DIR}/codex/AGENTS.block.md" > "${CODEX_BLOCK}"
  install_block "${CODEX_HOME_DIR}/AGENTS.md" "${CODEX_BLOCK}" "portable core"
  rm -f "${CODEX_BLOCK:?}"
fi

ORCH_MODEL="${TOP_FABLE_PIN}"; [ "${TOP_MODEL}" = "opus" ] && ORCH_MODEL="opus"
cat <<DONE

Done (ContextHarness ${VERSION}). Next steps:
  1. Start (or restart) Claude Code.
  2. Run /agents — you should see scout, executor, verifier, architect, and oracle at user level.
  3. Set your orchestrator model once: /model ${ORCH_MODEL}
     (or make it the default by adding  "model": "${ORCH_MODEL}"  to ${SETTINGS_FILE})
  4. To update later: git pull && ./install.sh --top-model ${TOP_MODEL}
  5. Recommended: ./install.sh --recommended   (verification gate, session recovery, safety guards, context meter)
  6. Check the install any time: ${SCRIPTS_DIR}/harness doctor
  7. Undo this install: ./install.sh --rollback
DONE

if [ -e "${CODEX_TOGGLE}" ]; then
  echo "Codex routing is ON: after any Codex CLI update run ./install.sh --refresh-codex (restarts the plugin's resident broker, which pins the old CLI)."
fi
