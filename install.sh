#!/usr/bin/env bash
# Installs the model-routing harness at user level (~/.claude).
# Idempotent: safe to re-run after every `git pull`.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="${HOME}/.claude"
AGENTS_DIR="${CLAUDE_DIR}/agents"
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

cat <<'EOF'

Done. Next steps:
  1. Start (or restart) Claude Code.
  2. Run /agents — you should see scout, executor, architect, and oracle at user level.
  3. Set your orchestrator model once: /model claude-fable-5[1m]
     (or make it the default by adding  "model": "claude-fable-5[1m]"  to ~/.claude/settings.json)
  4. To update later: git pull && ./install.sh
EOF
