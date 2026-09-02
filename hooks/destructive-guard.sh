#!/usr/bin/env bash
# destructive-guard.sh — Claude Code PreToolUse hook for the Bash tool.
#
# WHAT THIS IS: a tripwire against ACCIDENTS. Motivation: an executor subagent on
# a read-only task deleted an untracked file in the user's repo. This blocks a
# Bash call when a destructive verb (rm / rmdir / mv / shred / del / Remove-Item /
# git clean) appears in the command AND any target it can see resolves OUTSIDE a
# scratchpad/temp directory.
#
# WHAT THIS IS NOT: a security boundary. Shell command strings cannot be parsed
# reliably — subshells, eval, xargs, base64, variable expansion, aliases, and
# heredocs all defeat it trivially. Anything that WANTS to delete a file can.
# Do not rely on this against an adversary; rely on it against a slip.
#
# FAIL-OPEN by design: missing jq, empty stdin, or an unparseable payload => the
# call is allowed and the hook exits 0. A broken guard must never wedge a session
# (same posture as hooks/context-meter.sh, and as the shipped hookify plugin).
#
# CONTRACT (verified against the plugin-dev hook-development skill and the
# shipped hookify plugin; RE-VERIFY LIVE with `claude --debug` after install):
#   stdin : JSON — .tool_name, .tool_input.command, .cwd, .agent_id, .agent_type
#   allow : exit 0, no output
#   deny  : exit 2 (documented "blocking error"; stderr is fed back to Claude)
#           with a human message on stderr AND the PreToolUse deny object on
#           stdout: {"hookSpecificOutput":{"hookEventName":"PreToolUse",
#           "permissionDecision":"deny"},"systemMessage":...}
#           Both documented mechanisms fire, because the two shipped reference
#           implementations disagree about which stream to use. There is no
#           build behavior in which the command gets through.
#
# ESCAPE HATCHES (deliberate operator action):
#   1. HARNESS_ALLOW_DESTRUCTIVE=1 in the HOOK'S OWN environment — export it
#      before launching claude, or set it in settings.json "env". Master off
#      switch, honored unconditionally, works even if agent detection misfires.
#   2. Prefix the command itself:
#        HARNESS_ALLOW_DESTRUCTIVE=1 rm ~/.claude/codex-routing.on
#      Honored ONLY when the payload does not identify the caller as a subagent.
#      (A subagent could forge this. See "not a security boundary" above.)
#
# SCOPE KNOB: HARNESS_GUARD_SCOPE=all (default) | subagent
#   "all"      — enforce on every Bash call. Fail-safe: correct even if the
#                agent_id/agent_type payload fields are absent on your build.
#   "subagent" — enforce only when .agent_id/.agent_type is present. Much lower
#                friction on the main thread. Those fields shipped in Claude Code
#                2.1.69; VERIFY they populate on your build before relying on it,
#                because if they never populate this mode is a silent no-op.

set -u

SCRATCH_ROOTS="/tmp /var/folders ${TMPDIR:-} ${TMP:-} ${TEMP:-} ${HARNESS_SCRATCHPAD_DIR:-}"

# True if the absolute path lies under a known temp/scratch root.
# macOS: /private/tmp and /tmp are the same place; normalize both sides.
# Any path containing ".." is never treated as scratch (we do not resolve it).
is_scratch() {
  local p="$1" root
  case "$p" in *..*) return 1 ;; esac
  case "$p" in /private/*) p="${p#/private}" ;; esac
  for root in $SCRATCH_ROOTS; do
    [ -n "$root" ] || continue
    case "$root" in /private/*) root="${root#/private}" ;; esac
    root="${root%/}"
    [ -n "$root" ] || continue
    case "$p" in "$root"/*|"$root") return 0 ;; esac
  done
  return 1
}

command -v jq >/dev/null 2>&1 || exit 0
payload="$(cat)" || exit 0
[ -n "$payload" ] || exit 0

tool="$(printf '%s' "$payload" | jq -r '.tool_name // empty' 2>/dev/null)" || exit 0
[ "$tool" = "Bash" ] || exit 0

cmd="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null)"
[ -n "$cmd" ] || exit 0

cwd="$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null)"
[ -n "$cwd" ] || cwd="$PWD"

# Non-empty => this call came from a subagent (or a --agent session).
agent="$(printf '%s' "$payload" | jq -r '((.agent_id // "") + (.agent_type // "")) | tostring' 2>/dev/null)"

# Master off switch (hook's own environment).
[ "${HARNESS_ALLOW_DESTRUCTIVE:-}" = "1" ] && exit 0

# Scope.
if [ "${HARNESS_GUARD_SCOPE:-all}" = "subagent" ] && [ -z "$agent" ]; then exit 0; fi

# Destructive verb anywhere in the command, matched on word boundaries.
verb=""
for v in rm rmdir mv shred del Remove-Item; do
  if [[ "$cmd" =~ (^|[^[:alnum:]_-])${v}([[:space:]]|$) ]]; then verb="$v"; break; fi
done
if [ -z "$verb" ] && [[ "$cmd" =~ (^|[^[:alnum:]_-])git[[:space:]]+clean([[:space:]]|$) ]]; then
  verb="git clean"
fi
[ -n "$verb" ] || exit 0

# Inline escape hatch — operator only.
case " $cmd " in
  *" HARNESS_ALLOW_DESTRUCTIVE=1 "*) [ -z "$agent" ] && exit 0 ;;
esac

# Flatten shell operators so they are not mistaken for path tokens.
scan="$(printf '%s' "$cmd" | tr '\n\t' '  ' \
        | sed -e 's/&&/ /g' -e 's/||/ /g' -e 's/[;|()]/ /g' -e 's/2>&1/ /g')"

# Only tokens AFTER the destructive verb are treated as targets — this keeps
# `grep -rn "rm" src/`-style commands from flagging their own leading words.
armed=0; seen_git=0; candidates=0; outside=""
for tok in $scan; do
  tok="${tok%\"}"; tok="${tok#\"}"; tok="${tok%\'}"; tok="${tok#\'}"
  [ -n "$tok" ] || continue
  if [ "$armed" -eq 0 ]; then
    case "$tok" in
      rm|rmdir|mv|shred|del|Remove-Item|*/rm|*/rmdir|*/mv|*/shred) armed=1 ;;
      git) seen_git=1 ;;
      clean) [ "$seen_git" -eq 1 ] && armed=1 ;;
    esac
    continue
  fi
  case "$tok" in
    -*) continue ;;
    '&'|'>'|'<'|'>>'|'2>') continue ;;
    /dev/null|/dev/stdout|/dev/stderr|/dev/tty) continue ;;
  esac
  candidates=$((candidates+1))
  # Anything we cannot expand ($VAR, $(...), backticks) cannot be proved safe.
  case "$tok" in *'$'*|*'`'*) outside="${outside} ${tok}"; continue ;; esac
  tok="${tok%/\*}"; tok="${tok%\*}"
  case "$tok" in
    '~')   abs="$HOME" ;;
    '~'/*) abs="${HOME}/${tok#\~/}" ;;
    /*)    abs="$tok" ;;
    *)     abs="${cwd%/}/${tok}" ;;
  esac
  is_scratch "$abs" || outside="${outside} ${tok}"
done

# candidates==0 means we found a destructive verb but no target we can inspect
# (bare `git clean -fd`, `xargs rm -f`). Cannot prove safety => block.
if [ "$candidates" -eq 0 ] || [ -n "$outside" ]; then
  if [ -n "$outside" ]; then
    why="target(s) outside the scratchpad:${outside}"
  else
    why="no inspectable target (cannot prove the target is inside the scratchpad)"
  fi
  who="main thread"; [ -n "$agent" ] && who="subagent (${agent})"
  msg="harness destructive-guard blocked \`${verb}\` from the ${who}: ${why}."
  jq -cn --arg m "$msg" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny"},systemMessage:$m}'
  cat >&2 <<EOF
BLOCKED by the harness destructive-guard (PreToolUse hook).

  command : ${cmd}
  verb    : ${verb}
  caller  : ${who}
  reason  : ${why}

How to proceed legitimately:
  * Subagent on a scoped task: you may not delete/move files outside the paths
    named in your task. Put scratch output under the scratchpad directory
    instead, and report the blocked operation to your caller.
  * Operator, deliberate one-off: re-run the command with the prefix
        HARNESS_ALLOW_DESTRUCTIVE=1 ${cmd}
  * Operator, whole session: export HARNESS_ALLOW_DESTRUCTIVE=1 before starting
    Claude Code, or set it in ~/.claude/settings.json "env".
  * Remove the guard entirely: ./install.sh --remove-destructive-guard

This is a tripwire against accidents, not a security boundary — it matches
command text conservatively and will occasionally block a safe command.
EOF
  exit 2
fi

exit 0
