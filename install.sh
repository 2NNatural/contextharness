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
  if command -v claude >/dev/null 2>&1; then
    local runner=""
    if command -v timeout >/dev/null 2>&1; then runner="timeout 25"
    elif command -v gtimeout >/dev/null 2>&1; then runner="gtimeout 25"; fi
    if ${runner} claude -p --model claude-fable-5 --max-turns 1 'hi' >/dev/null 2>&1; then
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
while [ $# -gt 0 ]; do
  case "$1" in
    --top-model=*)
      TOP_MODEL="${1#--top-model=}"
      shift
      ;;
    --top-model)
      if [ $# -lt 2 ]; then
        echo "error: --top-model requires a value (fable or opus)" >&2
        exit 1
      fi
      TOP_MODEL="$2"
      shift 2
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

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
EOF
else
  cat <<EOF

Done. Next steps:
  1. Start (or restart) Claude Code.
  2. Run /agents — you should see scout, executor, architect, and oracle at user level.
  3. Set your orchestrator model once: /model claude-fable-5[1m]
     (or make it the default by adding  "model": "claude-fable-5[1m]"  to ~/.claude/settings.json)
  4. To update later: git pull && ./install.sh --top-model fable
EOF
fi
