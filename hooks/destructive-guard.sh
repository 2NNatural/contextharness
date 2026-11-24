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

# Credential-like file names. Keep IDENTICAL to hooks/ops-guard.sh (T42f checks).
SECRET_RE='(^|/)(\.env(\.[A-Za-z0-9_-]+)?|id_(rsa|dsa|ecdsa|ed25519)|[^/]*\.pem|[^/]*\.p12|\.netrc|\.npmrc|\.pypirc|credentials(\.json)?|secrets?\.(json|ya?ml|toml)|service-account[^/]*\.json)$'
SAFE_ENV_RE='\.env\.(example|sample|template|dist|defaults)$'

# True if deleting/moving this path loses nothing git cannot give back: it does
# not exist yet, it is a clean tracked file, or it is git-ignored (build output) —
# except ignored files named like credentials (.env, keys), which git cannot restore
# and nobody can regenerate. A wholly ignored directory is one `!! dir/` entry and
# is not looked inside.
# Untracked files and files with uncommitted changes are NOT restorable — that is
# exactly the accident this guard exists for.
is_restorable() {
  local p="$1" d st
  case "$p" in *..*) return 1 ;; esac
  [ -e "$p" ] || [ -L "$p" ] || { d="$(dirname "$p")"; [ -d "$d" ] && git -C "$d" rev-parse --is-inside-work-tree >/dev/null 2>&1; return $?; }
  d="$p"; [ -d "$d" ] || d="$(dirname "$p")"
  git -C "$d" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
  case "$(cd "$d" 2>/dev/null && pwd -P)/" in */.git/*) return 1 ;; esac
  st="$(git -C "$d" status --porcelain --ignored -- "$p" 2>/dev/null)" || return 1
  # git prints forward-slash paths on every platform; strip porcelain quoting.
  printf '%s\n' "$st" | sed -n 's/^!! //p' | sed -e 's/^"//' -e 's/"$//' | while IFS= read -r ig; do
    printf '%s' "$ig" | grep -Eq "$SECRET_RE" && ! printf '%s' "$ig" | grep -Eq "$SAFE_ENV_RE" && echo hit
  done | grep -q hit && return 1
  # A wholly ignored directory is one `!! dir/` entry: look inside it for credential-
  # named files. Bounded: depth 3 below the target, first 5000 files, and dependency /
  # VCS trees (node_modules, .venv, venv, .git) are pruned, so `rm -rf node_modules`
  # and `rm -rf build` stay fast.
  if [ -d "$p" ] && printf '%s\n' "$st" | grep -q '^!! .*/"\{0,1\}$'; then
    find "$p" -maxdepth 3 \( -name node_modules -o -name .venv -o -name venv -o -name .git \) -prune -o -type f -print 2>/dev/null \
      | head -n 5000 | grep -E "$SECRET_RE" | grep -Evq "$SAFE_ENV_RE" && return 1
  fi
  [ -z "$(printf '%s\n' "$st" | grep -v '^!!' | grep -v '^$')" ]
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

# Drop here-document bodies (file contents are data, not delete targets), then turn
# shell operators and newlines into an explicit separator token, so one command's
# arguments are never mistaken for the next command's targets.
# `cd "$(git rev-parse --show-toplevel)"` at the start of the command is a literal cd
# to the repository root (a common agent idiom); anywhere else, $(…) stays unknown.
scmd="$cmd"
top_re='^[[:space:]]*(cd|pushd)[[:space:]]+["'"'"']?[$][(]git rev-parse --show-toplevel[)]["'"'"']?([[:space:]]|$)'
if [[ $cmd =~ $top_re ]]; then
  top="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)"
  case "$top" in ''|*[[:space:]\&]*) ;; *) scmd="${cmd/\$(git rev-parse --show-toplevel)/$top}" ;; esac
fi
scan="$(printf '%s\n' "$scmd" \
        | awk 'hd != "" { if ($0 == hd) hd = ""; next }
               { print; if (match($0, /<<-?[ \t]*["\047]?[A-Za-z_][A-Za-z0-9_]*["\047]?/)) {
                   t = substr($0, RSTART, RLENGTH); gsub(/<<-?[ \t]*|["\047]/, "", t); hd = t } }' \
        | tr '\n\t' '; ' \
        | sed -e 's/2>&1/ /g' -e 's/&&/ @@SEP@@ /g' -e 's/||/ @@SEP@@ /g' -e 's/[;|()]/ @@SEP@@ /g')"

# Only tokens AFTER the destructive verb, up to the next separator, are treated as
# targets — this keeps `grep -rn "rm" src/`-style commands from flagging their own
# leading words, and keeps a later `cat > file` out of an earlier delete's targets.
#
# `cd`/`pushd` to a literal directory is followed: relative targets are checked
# against EVERY directory the command may be in at that point (a `(cd x && ...)`
# subshell cannot be told apart once parentheses are separators). A `cd` whose
# target cannot be read literally ($VAR, `cd -`, backticks) makes every later
# relative target unprovable.
NL='
'
expand_assigns() {  # expand_assigns <token> -> token with literal $S / ${S} assignments substituted
  local t="$1" kv k v
  for kv in $assigns; do
    k="${kv%%=*}"; v="${kv#*=}"
    case "$t" in
      "\$${k}")       t="${v}" ;;
      "\$${k}/"*)     t="${v}/${t#*/}" ;;
      "\${${k}}")     t="${v}" ;;
      "\${${k}}/"*)   t="${v}/${t#*/}" ;;
    esac
  done
  printf '%s' "$t"
}
armed=0; seen_git=0; candidates=0; seg_candidates=0; bare=0; outside=""; assigns=""
cwds="$cwd"; cwd_unknown=0; segstart=1; pending_cd=0; cdpath=0
for tok in $scan; do
  tok="${tok%\"}"; tok="${tok#\"}"; tok="${tok%\'}"; tok="${tok#\'}"
  [ -n "$tok" ] || continue
  if [ "$tok" = "@@SEP@@" ]; then
    # A bare `cd` goes home.
    [ "$pending_cd" -eq 1 ] && { cwds="${cwds}${NL}${HOME}"; pending_cd=0; }
    # A destructive verb with nothing inspectable after it (`xargs rm -f`) is unprovable.
    [ "$armed" -eq 1 ] && [ "$seg_candidates" -eq 0 ] && bare=1
    armed=0; seen_git=0; segstart=1; continue
  fi
  # A non-empty CDPATH (as a prefix, an assignment or an export) can send every later
  # relative `cd` anywhere, so the taint is never reset within the command.
  case "$tok" in CDPATH=|CDPATH=[\"\']|CDPATH=[\"\'][\"\']) ;; CDPATH=*) cdpath=1 ;; esac
  if [ "$pending_cd" -eq 1 ]; then
    case "$tok" in
      -) cwd_unknown=1; pending_cd=0; continue ;;
      -*) continue ;;
    esac
    tok="$(expand_assigns "$tok")"
    case "$tok" in
      *'$'*|*'`'*) cwd_unknown=1 ;;
      '~')            cwds="${cwds}${NL}${HOME}" ;;
      '~'/*)          cwds="${cwds}${NL}${HOME}/${tok#\~/}" ;;
      /*|[A-Za-z]:*)  cwds="${cwds}${NL}${tok}" ;;
      *)              if [ "$cdpath" -eq 1 ]; then cwd_unknown=1
                      else last="${cwds##*"${NL}"}"; cwds="${cwds}${NL}${last%/}/${tok}"; fi ;;
    esac
    pending_cd=0; continue
  fi
  if [ "$armed" -eq 0 ]; then
    if [ "$segstart" -eq 1 ]; then
      # `cd` is still the command after VAR=value prefixes and after keywords that
      # start a command (`{ cd x; …}`, `then cd x`, `do cd x`, `! cd x`).
      case "$tok" in
        cd|pushd) segstart=0; pending_cd=1; continue ;;
        '{'|'!'|then|do|else|if|elif|while|until) continue ;;
        [A-Za-z_]*=*)
          case "$tok" in [A-Za-z_]*=/*) case "$tok" in *'$'*|*'`'*) ;; *) assigns="${assigns} ${tok}" ;; esac ;; esac
          continue ;;
      esac
      segstart=0
    fi
    case "$tok" in
      # Remember literal path assignments (S=/tmp/x) so `rm $S/file` can be resolved.
      [A-Za-z_]*=/*) case "$tok" in *'$'*|*'`'*) ;; *) assigns="${assigns} ${tok}" ;; esac ;;
      rm|rmdir|mv|shred|del|Remove-Item|*/rm|*/rmdir|*/mv|*/shred) armed=1; seg_candidates=0 ;;
      git) seen_git=1 ;;
      clean) [ "$seen_git" -eq 1 ] && { armed=1; seg_candidates=0; } ;;
    esac
    continue
  fi
  case "$tok" in
    -*) continue ;;
    '&'|'>'|'<'|'>>'|'2>') continue ;;
    /dev/null|/dev/stdout|/dev/stderr|/dev/tty) continue ;;
  esac
  candidates=$((candidates+1)); seg_candidates=$((seg_candidates+1))
  tok="$(expand_assigns "$tok")"
  # Anything we cannot expand ($VAR, $(...), backticks) cannot be proved safe.
  case "$tok" in *'$'*|*'`'*) outside="${outside} ${tok}"; continue ;; esac
  tok="${tok%/\*}"; tok="${tok%\*}"
  case "$tok" in
    '~')   abs="$HOME" ;;
    '~'/*) abs="${HOME}/${tok#\~/}" ;;
    /*)    abs="$tok" ;;
    *)
      # Relative: must be safe from every directory the command may be in.
      [ "$cwd_unknown" -eq 1 ] && { outside="${outside} ${tok}"; continue; }
      while IFS= read -r c; do
        abs="${c%/}/${tok}"
        is_scratch "$abs" || is_restorable "$abs" || { outside="${outside} ${tok}"; break; }
      done <<EOF
${cwds}
EOF
      continue ;;
  esac
  is_scratch "$abs" || is_restorable "$abs" || outside="${outside} ${tok}"
done

# candidates==0 means we found a destructive verb but no target we can inspect
# (bare `git clean -fd`, `xargs rm -f`). Cannot prove safety => block.
[ "$armed" -eq 1 ] && [ "$seg_candidates" -eq 0 ] && bare=1
if [ "$candidates" -eq 0 ] || [ "$bare" -eq 1 ] || [ -n "$outside" ]; then
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
