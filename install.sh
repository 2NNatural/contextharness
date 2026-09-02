#!/usr/bin/env bash
# Installs the model-routing harness at user level (~/.claude).
# Idempotent: safe to re-run after every `git pull`.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="${HOME}/.claude"
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
    if ${runner} claude -p --model claude-fable-5-1 --max-turns 1 'hi' >/dev/null 2>&1; then
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
      -d '{"model":"claude-fable-5","max_tokens":1,"messages":[{"role":"user","content":"hi"}]}' \
      https://api.anthropic.com/v1/messages 2>/dev/null)" || { printf ''; return 0; }
    case "${code}" in
      200) printf 'fable'; return 0 ;;
      4*)  printf 'opus';  return 0 ;;
      *)   printf '';      return 0 ;;
    esac
  fi
  printf ''
}

# --- Parse --top-model flag (supports --top-model VALUE and --top-model=VALUE) ---
TOP_MODEL=""
WITH_CONTEXT_HOOK=0
REMOVE_CONTEXT_HOOK=0
WITH_GUARD=0
REMOVE_GUARD=0
INIT_INVENTORY=0
OTHER_FLAGS=0
while [ $# -gt 0 ]; do
  case "$1" in
    --top-model=*)
      TOP_MODEL="${1#--top-model=}"
      OTHER_FLAGS=1
      shift
      ;;
    --top-model)
      if [ $# -lt 2 ]; then
        echo "error: --top-model requires a value (fable or opus)" >&2
        exit 1
      fi
      TOP_MODEL="$2"
      OTHER_FLAGS=1
      shift 2
      ;;
    --with-context-hook)  WITH_CONTEXT_HOOK=1;  OTHER_FLAGS=1; shift ;;
    --remove-context-hook) REMOVE_CONTEXT_HOOK=1; OTHER_FLAGS=1; shift ;;
    --with-destructive-guard)  WITH_GUARD=1;   OTHER_FLAGS=1; shift ;;
    --remove-destructive-guard) REMOVE_GUARD=1; OTHER_FLAGS=1; shift ;;
    --init-inventory)          INIT_INVENTORY=1; shift ;;
    *)
      echo "error: unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

# --- --init-inventory: the ONE mode that writes outside ~/.claude -------------
# Copies templates/INTERFACES.md into the CURRENT working directory's project.
# It writes exactly one file, to $PWD, never overwrites, and exits before the
# tier probe and before ANY ~/.claude work. Every other install.sh code path
# below this block writes only under ${HOME}/.claude.
if [ "${INIT_INVENTORY}" -eq 1 ]; then
  if [ "${OTHER_FLAGS}" -eq 1 ]; then
    echo "error: --init-inventory must be used alone (it writes to the current project, not ~/.claude)" >&2
    exit 1
  fi
  TEMPLATE="${TEMPLATES_SRC}/INTERFACES.md"
  [ -f "${TEMPLATE}" ] && [ -r "${TEMPLATE}" ] \
    || { echo "error: cannot read ${TEMPLATE}" >&2; exit 1; }
  DEST_DIR="$(pwd)"
  case "${DEST_DIR}" in
    "${HOME}"|"${HOME}/"|"${HOME}/.claude"|"${HOME}/.claude/"*)
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

# Validate flag value if provided
if [ -n "${TOP_MODEL}" ]; then
  case "${TOP_MODEL}" in
    fable|opus) ;;
    *)
      echo "error: --top-model must be 'fable' or 'opus', got: '${TOP_MODEL}'" >&2
      exit 1
      ;;
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

# Normalize the rules file's line endings before using it anywhere below.
# On Windows, git may check routing-rules.md out with CRLF while a
# previously-installed CLAUDE.md block was written with LF (or vice versa),
# which makes re-runs of the block-replace path non-idempotent byte-for-byte
# even though the content is identical modulo \r. Read through a stripped
# copy so every code path (fresh append and block replace) emits LF-only.
NORMALIZED_RULES_FILE="$(mktemp)"
trap 'rm -f "${NORMALIZED_RULES_FILE}"' EXIT
tr -d '\r' < "${RULES_FILE}" > "${NORMALIZED_RULES_FILE}"
RULES_FILE="${NORMALIZED_RULES_FILE}"

# 1. Install agents (repo is source of truth — overwrite).
mkdir -p "${AGENTS_DIR}"
for f in "${REPO_DIR}"/agents/*.md; do
  cp "$f" "${AGENTS_DIR}/"
  echo "installed agent: ${AGENTS_DIR}/$(basename "$f")"
done

# 1b. Install skills (repo is source of truth — overwrite the tree).
if [ -d "${SKILLS_SRC}" ]; then
  mkdir -p "${SKILLS_DIR}"
  for d in "${SKILLS_SRC}"/*/; do
    [ -d "$d" ] || continue
    name="$(basename "$d")"
    mkdir -p "${SKILLS_DIR}/${name}"
    cp "$d"*.md "${SKILLS_DIR}/${name}/"
    echo "installed skill: ${SKILLS_DIR}/${name}"
  done
fi

# 1c. Optional context-meter hook (opt-in; default install never touches settings.json).
CONTEXT_HOOK_SCRIPT="${HOOKS_DIR}/context-meter.sh"
HOOK_CMD="${CONTEXT_HOOK_SCRIPT}"

print_manual_hook_instructions() {
  cat >&2 <<EOF
To enable the context meter manually, add this to ${SETTINGS_FILE}:
  "hooks": { "UserPromptSubmit": [ { "hooks": [
    { "type": "command", "command": "${HOOK_CMD}" } ] } ] }
EOF
}

if [ "${REMOVE_CONTEXT_HOOK:-0}" -eq 1 ]; then
  if command -v jq >/dev/null 2>&1 && [ -f "${SETTINGS_FILE}" ]; then
    tmp="$(mktemp)"
    if jq --arg n "${HOOK_NEEDLE}" '
          if (.hooks.UserPromptSubmit? | type) == "array" then
            .hooks.UserPromptSubmit |=
              (map(.hooks |= map(select(((.command // "") | contains($n)) | not)))
               | map(select((.hooks | length) > 0)))
          else . end
        ' "${SETTINGS_FILE}" > "${tmp}" 2>/dev/null && jq empty "${tmp}" 2>/dev/null; then
      cp "${SETTINGS_FILE}" "${SETTINGS_FILE}.harness-bak.$(date +%Y%m%d%H%M%S)"
      cat "${tmp}" > "${SETTINGS_FILE}"
      echo "removed context-meter hook registration from ${SETTINGS_FILE}"
    fi
    rm -f "${tmp}"
  fi
  rm -f "${CONTEXT_HOOK_SCRIPT}"
  echo "removed ${CONTEXT_HOOK_SCRIPT}"
elif [ "${WITH_CONTEXT_HOOK:-0}" -eq 1 ]; then
  if [ -f "${HOOKS_SRC}/context-meter.sh" ]; then
    mkdir -p "${HOOKS_DIR}"
    cp "${HOOKS_SRC}/context-meter.sh" "${CONTEXT_HOOK_SCRIPT}"
    chmod +x "${CONTEXT_HOOK_SCRIPT}"
    echo "installed hook: ${CONTEXT_HOOK_SCRIPT}"
    if command -v jq >/dev/null 2>&1; then
      touch "${SETTINGS_FILE}"
      [ -s "${SETTINGS_FILE}" ] || printf '{}\n' > "${SETTINGS_FILE}"
      if jq -e --arg c "${HOOK_CMD}" '
            [ .hooks.UserPromptSubmit[]?.hooks[]?.command ] | any(. == $c)
          ' "${SETTINGS_FILE}" >/dev/null 2>&1; then
        echo "context-meter hook already registered in ${SETTINGS_FILE} (idempotent)"
      else
        tmp="$(mktemp)"
        if jq --arg c "${HOOK_CMD}" '
              .hooks = (.hooks // {})
              | .hooks.UserPromptSubmit = (.hooks.UserPromptSubmit // [])
              | .hooks.UserPromptSubmit += [ { "hooks": [ { "type": "command", "command": $c } ] } ]
            ' "${SETTINGS_FILE}" > "${tmp}" 2>/dev/null && jq empty "${tmp}" 2>/dev/null; then
          cp "${SETTINGS_FILE}" "${SETTINGS_FILE}.harness-bak.$(date +%Y%m%d%H%M%S)"
          cat "${tmp}" > "${SETTINGS_FILE}"
          echo "registered context-meter hook in ${SETTINGS_FILE} (backup written)"
        else
          echo "warning: could not safely merge ${SETTINGS_FILE}; left untouched" >&2
          print_manual_hook_instructions
        fi
        rm -f "${tmp}"
      fi
    else
      echo "warning: jq not found — hook script copied but not registered" >&2
      print_manual_hook_instructions
    fi
  else
    echo "warning: ${HOOKS_SRC}/context-meter.sh not found; skipping hook install" >&2
  fi
fi

# 1d. Optional destructive-guard hook (opt-in; default install never touches settings.json).
GUARD_SCRIPT="${HOOKS_DIR}/destructive-guard.sh"
GUARD_CMD="${GUARD_SCRIPT}"

print_manual_guard_instructions() {
  cat >&2 <<EOF
To enable the destructive guard manually, add this to ${SETTINGS_FILE}:
  "hooks": { "PreToolUse": [ { "matcher": "Bash", "hooks": [
    { "type": "command", "command": "${GUARD_CMD}" } ] } ] }
EOF
}

if [ "${REMOVE_GUARD:-0}" -eq 1 ]; then
  if command -v jq >/dev/null 2>&1 && [ -f "${SETTINGS_FILE}" ]; then
    tmp="$(mktemp)"
    if jq --arg n "${GUARD_NEEDLE}" '
          if (.hooks.PreToolUse? | type) == "array" then
            .hooks.PreToolUse |=
              (map(.hooks |= map(select(((.command // "") | contains($n)) | not)))
               | map(select((.hooks | length) > 0)))
          else . end
        ' "${SETTINGS_FILE}" > "${tmp}" 2>/dev/null && jq empty "${tmp}" 2>/dev/null; then
      cp "${SETTINGS_FILE}" "${SETTINGS_FILE}.harness-bak.$(date +%Y%m%d%H%M%S)"
      cat "${tmp}" > "${SETTINGS_FILE}"
      echo "removed destructive-guard hook registration from ${SETTINGS_FILE}"
    fi
    rm -f "${tmp}"
  fi
  rm -f "${GUARD_SCRIPT}"
  echo "removed ${GUARD_SCRIPT}"
elif [ "${WITH_GUARD:-0}" -eq 1 ]; then
  if [ -f "${HOOKS_SRC}/destructive-guard.sh" ]; then
    mkdir -p "${HOOKS_DIR}"
    cp "${HOOKS_SRC}/destructive-guard.sh" "${GUARD_SCRIPT}"
    chmod +x "${GUARD_SCRIPT}"
    echo "installed hook: ${GUARD_SCRIPT}"
    if command -v jq >/dev/null 2>&1; then
      touch "${SETTINGS_FILE}"
      [ -s "${SETTINGS_FILE}" ] || printf '{}\n' > "${SETTINGS_FILE}"
      if jq -e --arg c "${GUARD_CMD}" '
            [ .hooks.PreToolUse[]?.hooks[]?.command ] | any(. == $c)
          ' "${SETTINGS_FILE}" >/dev/null 2>&1; then
        echo "destructive-guard hook already registered in ${SETTINGS_FILE} (idempotent)"
      else
        tmp="$(mktemp)"
        if jq --arg c "${GUARD_CMD}" '
              .hooks = (.hooks // {})
              | .hooks.PreToolUse = (.hooks.PreToolUse // [])
              | .hooks.PreToolUse += [ { "matcher": "Bash", "hooks": [ { "type": "command", "command": $c } ] } ]
            ' "${SETTINGS_FILE}" > "${tmp}" 2>/dev/null && jq empty "${tmp}" 2>/dev/null; then
          cp "${SETTINGS_FILE}" "${SETTINGS_FILE}.harness-bak.$(date +%Y%m%d%H%M%S)"
          cat "${tmp}" > "${SETTINGS_FILE}"
          echo "registered destructive-guard hook in ${SETTINGS_FILE} (backup written)"
        else
          echo "warning: could not safely merge ${SETTINGS_FILE}; left untouched" >&2
          print_manual_guard_instructions
        fi
        rm -f "${tmp}"
      fi
    else
      echo "warning: jq not found — hook script copied but not registered" >&2
      print_manual_guard_instructions
    fi
  else
    echo "warning: ${HOOKS_SRC}/destructive-guard.sh not found; skipping hook install" >&2
  fi
fi

# 1a. If top model is opus, rewrite the INSTALLED oracle.md only (repo copy untouched).
INSTALLED_ORACLE="${AGENTS_DIR}/oracle.md"
if [ "${TOP_MODEL}" = "opus" ]; then
  # Whole-line replacement of model: and description: lines
  tmp_oracle="$(mktemp)"
  while IFS= read -r line; do
    case "${line}" in
      "model: "*)
        printf 'model: opus\n'
        ;;
      "description: "*)
        printf 'description: Maximum-capability reasoner in a fresh isolated context. Reserve for the hardest isolated jobs — bulk analysis too large to hold in the main thread (whole-codebase audits, huge log/diff digests, cross-cutting multi-system reasoning) or problems the architect explicitly could not crack. Expensive; use only when scout/architect are insufficient.\n'
        ;;
      *)
        printf '%s\n' "${line}"
        ;;
    esac
  done < "${INSTALLED_ORACLE}" > "${tmp_oracle}"
  cat "${tmp_oracle}" > "${INSTALLED_ORACLE}"
  rm -f "${tmp_oracle}"
  echo "patched installed oracle.md for top-model=opus"
fi
# If top model is fable, the repo copy is already correct (model: claude-fable-5[1m]);
# cp already overwrote any previous opus patch — nothing more to do.

# 2. Insert-or-replace the marked routing block in ~/.claude/CLAUDE.md,
#    preserving everything outside the markers.
mkdir -p "${CLAUDE_DIR}"
touch "${CLAUDE_MD}"

# Whole-line, fixed-string marker counts (grep -c exits 1 on zero matches; tolerate it).
starts=$(grep -cxF "${START_MARKER}" "${CLAUDE_MD}" || true)
ends=$(grep -cxF "${END_MARKER}" "${CLAUDE_MD}" || true)

if [ "${starts}" -eq 0 ] && [ "${ends}" -eq 0 ]; then
  # Fresh append (with a separating blank line if the file is non-empty).
  if [ -s "${CLAUDE_MD}" ]; then
    printf '\n' >> "${CLAUDE_MD}"
  fi
  cat "${RULES_FILE}" >> "${CLAUDE_MD}"
  echo "appended routing rules block to ${CLAUDE_MD}"
elif [ "${starts}" -eq 1 ] && [ "${ends}" -eq 1 ]; then
  # Refuse to edit if the markers are out of order — the block is malformed.
  start_line=$(grep -nxF "${START_MARKER}" "${CLAUDE_MD}" | head -1 | cut -d: -f1)
  end_line=$(grep -nxF "${END_MARKER}" "${CLAUDE_MD}" | head -1 | cut -d: -f1)
  if [ "${start_line}" -ge "${end_line}" ]; then
    echo "error: harness markers are out of order in ${CLAUDE_MD}; fix the file by hand and re-run" >&2
    exit 1
  fi
  # Replace the block in place, keeping everything outside it. Markers and
  # filename are passed via the environment (awk -v would mangle backslashes),
  # and matched as whole lines only.
  tmp="$(mktemp)"
  START="${START_MARKER}" END="${END_MARKER}" RULES="${RULES_FILE}" awk '
    $0 == ENVIRON["START"] {
      skip = 1
      while ((r = (getline line < ENVIRON["RULES"])) > 0) print line
      if (r < 0) { print "error: cannot read rules file" > "/dev/stderr"; exit 1 }
      close(ENVIRON["RULES"]); next
    }
    $0 == ENVIRON["END"] && skip { skip = 0; next }
    !skip { print }
  ' "${CLAUDE_MD}" > "${tmp}"
  # Write through the existing inode (not mv): preserves permissions,
  # ownership, and symlinked CLAUDE.md files (dotfile-repo setups).
  cat "${tmp}" > "${CLAUDE_MD}"
  rm -f "${tmp}"
  echo "updated routing rules block in ${CLAUDE_MD}"
else
  echo "error: expected exactly one harness block in ${CLAUDE_MD}, found ${starts} start / ${ends} end marker(s); refusing to edit — fix the file by hand and re-run" >&2
  exit 1
fi

# Post-install message (uses expansion, so use double-quoted heredoc)
if [ "${TOP_MODEL}" = "opus" ]; then
  cat <<EOF

Done. Next steps:
  1. Start (or restart) Claude Code.
  2. Run /agents — you should see scout, executor, architect, and oracle at user level.
  3. Set your orchestrator model once: /model opus
     (or make it the default by adding  "model": "opus"  to ~/.claude/settings.json)
  4. To update later: git pull && ./install.sh --top-model opus
  5. Optional context meter: ./install.sh --with-context-hook
  6. Optional destructive guard: ./install.sh --with-destructive-guard
  7. Start an interface inventory in a project: cd <project> && <path-to-harness>/install.sh --init-inventory
EOF
else
  cat <<EOF

Done. Next steps:
  1. Start (or restart) Claude Code.
  2. Run /agents — you should see scout, executor, architect, and oracle at user level.
  3. Set your orchestrator model once: /model claude-fable-5[1m]
     (or make it the default by adding  "model": "claude-fable-5[1m]"  to ~/.claude/settings.json)
  4. To update later: git pull && ./install.sh --top-model fable
  5. Optional context meter: ./install.sh --with-context-hook
  6. Optional destructive guard: ./install.sh --with-destructive-guard
  7. Start an interface inventory in a project: cd <project> && <path-to-harness>/install.sh --init-inventory
EOF
fi
