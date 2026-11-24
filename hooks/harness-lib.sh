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

# Files changed by commits made since <start> (the HEAD recorded at session start;
# "-" = no commit existed yet). Empty when HEAD has not moved, or when <start> is no
# longer in the object store (then only working-tree changes count, as before).
h_committed_files() {
  local root="$1" start="$2" head base
  head="$(git -C "${root}" rev-parse -q --verify HEAD 2>/dev/null)" || return 0
  [ -n "${head}" ] && [ "${head}" != "${start}" ] || return 0
  if [ "${start}" = "-" ]; then base="$(git -C "${root}" hash-object -t tree --stdin </dev/null 2>/dev/null)" || return 0
  else git -C "${root}" cat-file -e "${start}^{commit}" 2>/dev/null || return 0; base="${start}"; fi
  git -C "${root}" -c core.quotePath=false diff --name-only --no-renames "${base}" "${head}" 2>/dev/null
}
# Changed CODE files (tracked-modified + untracked, not ignored), one per line; with
# <start>, also the files changed by commits made since then (edit, commit, stop is
# still a change). Docs and the harness's own state are not code: editing them never
# needs verification. core.quotePath=false: non-ASCII names come out as real paths.
h_changed_files() {
  local root="$1" start="${2:-}"
  git -C "${root}" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
  { git -C "${root}" -c core.quotePath=false status --porcelain -uall 2>/dev/null | cut -c4- | sed -e 's/^.* -> //'
    [ -z "${start}" ] || h_committed_files "${root}" "${start}"
  } | sed -e 's/^"//' -e 's/"$//' | awk '!seen[$0]++' \
    | grep -Ev '(\.(md|mdx|txt|rst|adoc)$|^\.claude/harness/|(^|/)(LICENSE|CHANGELOG|NOTICE)[^/]*$)' | head -2000
  return 0
}
# Fingerprint of the code changes: names + git content hash for files up to 5 MB (one
# git process), names + size + mtime for larger ones, "gone" if missing. Content-based,
# so it is stable once nothing changes (also after the changes are committed).
h_dirty_hash() {
  local root="$1" start="${2:-}" lines hs
  lines="$(h_changed_files "${root}" "${start}" | while IFS= read -r f; do
      s="$(stat -c '%s.%Y' "${root}/${f}" 2>/dev/null || stat -f '%z.%m' "${root}/${f}" 2>/dev/null)"
      if [ -z "${s}" ]; then printf 'M\t%s gone\n' "${f}"
      elif [ -f "${root}/${f}" ] && [ "${s%%.*}" -le 5242880 ]; then printf 'H\t%s\n' "${f}"
      else printf 'M\t%s %s\n' "${f}" "${s}"; fi; done)"
  hs="$(printf '%s\n' "${lines}" | awk -F'\t' '$1=="H"{print $2}')"
  { printf '%s\n' "${lines}" | awk -F'\t' '$1=="M"{print $2}'
    [ -z "${hs}" ] || paste -d' ' <(printf '%s\n' "${hs}") <(printf '%s\n' "${hs}" | git -C "${root}" hash-object --no-filters --stdin-paths 2>/dev/null)
  } | h_hash
}
# h_last_change <root> [start] [time of the latest edit / may-write record]: newest
# mtime of the changed files. A changed file that no longer exists (deleted) has no
# mtime: it counts as changed at the third argument's time, so evidence from before
# the deletion does not cover it.
h_last_change() {
  local root="$1" start="${2:-}" gone="${3:-0}" f m max=0
  case "${gone}" in ''|*[!0-9]*) gone=0 ;; esac
  while IFS= read -r f; do
    m="$(h_mtime "${root}/${f}")"
    [ -z "${m}" ] && [ ! -e "${root}/${f}" ] && [ ! -L "${root}/${f}" ] && m="${gone}"
    case "${m}" in ''|*[!0-9]*) continue ;; esac
    [ "${m}" -gt "${max}" ] && max="${m}"
  done < <(h_changed_files "${root}" "${start}")
  printf '%s' "${max}"
}
# Outside git: content of the (non-doc) files the edit journal knows about, one
# "<path> <sha256|gone>" line each (first 200 files). Lets a fingerprint see writes
# that no tool event recorded, e.g. a verify recipe that rewrites app.py.
h_journal_content() {
  local root="$1" f p
  jq -r 'select(.k=="edit") | .f' 2>/dev/null | awk '!seen[$0]++' | head -200 | while IFS= read -r f; do
    p="${f//"${H_BSLASH}"//}"; case "${p}" in /*|[A-Za-z]:*) ;; *) p="${root%/}/${p}" ;; esac
    if [ -f "${p}" ]; then printf '%s %s\n' "${f}" "$(h_filehash "${p}" 2>/dev/null)"; else printf '%s gone\n' "${f}"; fi
  done
}

# Drop here-document bodies: they are data (file contents, scripts), not commands,
# and their words must never be read as command names or as targets.
h_strip_heredocs() {
  printf '%s\n' "$1" | awk 'hd != "" { if ($0 == hd) hd = ""; next }
    { print; if (match($0, /<<-?[ \t]*["\047]?[A-Za-z_][A-Za-z0-9_]*["\047]?/)) {
        t = substr($0, RSTART, RLENGTH); gsub(/<<-?[ \t]*|["\047]/, "", t); hd = t } }'
}
# One command segment per line (split on && || ; | &). awk, not sed: BSD sed
# writes a literal "n" for "\n" in a replacement.
h_segments() { h_strip_heredocs "$1" | awk '{ gsub(/&&|\|\||[;|&]/, "\n"); print }'; }
# Quote characters and a backslash, for stripping "ls", 'cat' and \ls down to the
# command name (as patterns; literal quotes inside ${...//} do not parse portably).
H_QUOTES="\"'"; H_BSLASH='\'

# The string arguments of `bash -c '…'` / `sh -lc "…"` / `bash --norc -c $'…'`, one per
# line: they are commands too. Literal single-line strings only; nested or escaped
# quotes are not parsed.
h_inline_scripts() {
  printf '%s\n' "$1" | awk '{ s = $0
    while (match(s, /(^|[^A-Za-z0-9_.-])(ba|z|da)?sh[ \t]+(--?[A-Za-z-]+[ \t]+)*-[A-Za-z]*c[ \t]*\$?["\047]/)) {
      q = substr(s, RSTART + RLENGTH - 1, 1); s = substr(s, RSTART + RLENGTH)
      e = index(s, q); if (e == 0) { print s; break }
      print substr(s, 1, e - 1); s = substr(s, e + 1) } }'
}

# Leading words of one command segment (passed as "$@") that only wrap the real
# command: VAR=value, env/sudo/nice/timeout/time/nohup/command/exec/npx/xargs … WITH
# their option operands (`nice -n 5`, `env -u FOO`, `sudo -u d`, `timeout -k 5 60`,
# `xargs -n 1`), numbers, and keywords that start a command ({ ! then do else). Sets
# H_PN = words to shift, H_XA = 1 when xargs was one of them, and H_ENVD = 1 when the
# segment is a bare `env` that prints the environment (`env -i` alone prints nothing
# inherited, so it is not; `( env )` is).
h_prefix_skip() {
  local w wrap="" envi=0
  H_PN=0; H_ENVD=0; H_XA=0
  while [ $# -gt 0 ]; do
    w="${1//[${H_QUOTES}]/}"; w="${w#"${H_BSLASH}"}"; w="${w#\(}"; w="${w%\)}"
    case "${w}" in
      -*) case "${wrap}:${w}" in
            env:-i|env:--ignore-environment|env:-) envi=1 ;;
            env:-u|env:-C|env:-S|sudo:-[ugCDhprtU]|doas:-u|nice:-n|timeout:-[ks]|time:-[fo]|exec:-a|stdbuf:-[ioe]|ionice:-[cnp]|npx:-p|npx:--package|xargs:-[nLPIdsaE])
              [ $# -ge 2 ] && { shift; H_PN=$((H_PN+1)); } ;;
          esac ;;
      [A-Za-z_]*=*|[0-9]*|''|'{'|'!'|then|do|else|if|elif|while|until) ;;
      *) case "${w##*/}" in
           env) wrap=env; H_ENVD=1 ;;
           timeout|gtimeout) wrap=timeout ;;
           npx|bunx|pnpx) wrap=npx ;;
           xargs) wrap=xargs; H_XA=1 ;;
           sudo|doas|nice|time|nohup|command|exec|stdbuf|ionice|setsid) wrap="${w##*/}" ;;
           *) break ;;
         esac ;;
    esac
    shift; H_PN=$((H_PN+1))
  done
  if [ $# -eq 0 ] && [ "${H_ENVD}" = 1 ] && [ "${envi}" = 0 ]; then H_ENVD=1; else H_ENVD=0; fi
}

# Is this command worth counting as "the change was exercised"? Listing, reading,
# moving files and plain git bookkeeping are not. Anything that runs code is.
h_is_evidence() {
  local cmd="$1" seg w ev=1
  set -f
  while IFS= read -r seg; do
    # shellcheck disable=SC2086
    set -- ${seg}
    h_prefix_skip "$@"; shift "${H_PN}"
    [ $# -gt 0 ] || continue
    w="${1//[${H_QUOTES}]/}"; w="${w#"${H_BSLASH}"}"; w="${w#\(}"; w="${w%\)}"; w="${w##*/}"
    case "${w}" in
      # Words that close or open a compound command run nothing by themselves.
      fi|done|esac|for|case|select|'}'|')'|ls|cat|head|tail|grep|rg|find|echo|printf|pwd|cd|wc|sed|awk|mkdir|cp|mv|rm|rmdir|touch|chmod|chown|true|false|which|file|stat|jq|sort|uniq|tree|diff|cut|tr|tee|ln|basename|dirname|date|sleep|export|set|unset|test|'['|'[['|read|kill|pkill|ps|du|df|xargs|less|more) ;;
      git) case "${2:-}" in bisect) ev=0 ;; esac ;;
      '#'*|'') ;;
      *) ev=0 ;;
    esac
  done <<<"$(h_segments "${cmd}")"
  set +f
  return "${ev}"
}

# Blank quoted text (data: search patterns, messages, jq/awk programs); the first
# opened quote wins, so "it's" stays one string.
h_unquote() { awk '{ o = ""; q = ""; for (i = 1; i <= length($0); i++) { ch = substr($0, i, 1)
  if (q == "") { if (ch == "\047" || ch == "\"") { q = ch; o = o " " } else o = o ch } else if (ch == q) q = "" }
  print o }'; }
# Could this command have written files? Deliberately liberal: a false "yes" only
# lets the stop-gate's git check run. Quoted strings are data, except the strings of
# `bash -c '…'`, which are appended (unquoted) as commands.
h_may_write() {
  local c; c="$(h_strip_heredocs "$1")
$(h_inline_scripts "$1")"
  c="$(printf '%s\n' "${c}" | h_unquote | sed -E -e 's/[0-9]*>&[0-9-]+//g' -e 's#[0-9]*>>?[[:space:]]*/dev/(null|stdout|stderr|tty)##g' -e 's/git[[:space:]]+stash[[:space:]]+(list|show)//g')"
  case "${c}" in *'>'*) return 0 ;; esac
  # A writer anywhere at a word boundary (after `for … do`, `find -exec`, `(`, `env X=1`,
  # inside `bash -c '…'`), not only at the start of a segment.
  printf '%s\n' "${c}" | grep -Eq "(^|[[:space:];&|({!\`])(sudo[[:space:]]+)?(cp|mv|rm|rmdir|touch|tee|ln|patch|install|rsync|unzip|tar|dd|truncate|xargs|chmod|(sed|perl|awk|gawk)[[:space:]][^;&|]*(-[A-Za-z]*i|--in-place)|git[[:space:]]+(checkout|restore|apply|stash|reset|merge|pull|rebase|cherry-pick|am|revert|switch|mv|rm|clean))([.=[:space:]]|\$)"
}

# Journal reader that survives a torn or garbled line: it becomes {"k":"corrupt"}
# instead of making the whole slurp fail. Reads JSONL on stdin, one object per line.
h_jlines() { jq -cR 'select(length>0) | (try fromjson catch {k:"corrupt"})' 2>/dev/null; }

# "pid ppid" for every process, from one snapshot (no pkill/pgrep: Git Bash ships
# neither). `ps -A -o pid= -o ppid=` on Linux/macOS/BSD; MSYS/Cygwin ps has no -o, so
# its `ps -al` (numeric PID PPID first, no user-name column to shift) is next; `ps -ef`
# (UID PID PPID) is the last resort.
h_pidtable() {
  local t
  t="$(ps -A -o pid= -o ppid= 2>/dev/null)"
  [ -n "${t}" ] || t="$(ps -al 2>/dev/null | awk 'NR == 1 { ok = ($1 == "PID" && $2 == "PPID"); next } ok { print $1, $2 }')"
  [ -n "${t}" ] || t="$(ps -ef 2>/dev/null | awk 'NR > 1 { print $2, $3 }')"
  printf '%s\n' "${t}"
}
# Every descendant of a process.
h_descendants() { h_pidtable | awk -v r="$1" 'NF >= 2 { pp[$1] = $2 } END { n = 1; q[1] = r; for (i = 1; i <= n; i++) for (c in pp) if (pp[c] == q[i]) { q[++n] = c; print c } }'; }
# h_run_bounded <secs> cmd...  -> rc of cmd, or 124 on timeout (GNU timeout semantics).
# Uses timeout/gtimeout when present (with `-k 5`: KILL five seconds after TERM, when
# that timeout supports it — probed once per process); otherwise a shell watchdog that
# stops the command and its process tree (TERM, then KILL two seconds later).
# HARNESS_FORCE_WATCHDOG=1 forces the watchdog (tests).
h_run_bounded() {
  local secs="$1" t t0 rc; shift
  if [ -z "${HARNESS_FORCE_WATCHDOG:-}" ]; then
    for t in timeout gtimeout; do
      command -v "${t}" >/dev/null 2>&1 || continue
      if [ -z "${H_TO_K:-}" ]; then if "${t}" -k 1 1 true >/dev/null 2>&1; then H_TO_K=yes; else H_TO_K=no; fi; fi
      if [ "${H_TO_K}" = no ]; then "${t}" "${secs}" "$@"; return $?; fi
      t0="$(date +%s)"; "${t}" -k 5 "${secs}" "$@"; rc=$?
      # 137 = the KILL stage fired (TERM was ignored): still a timeout, not a crash.
      [ "${rc}" -eq 137 ] && [ $(( $(date +%s) - t0 )) -ge "${secs}" ] && rc=124
      return "${rc}"
    done
  fi
  # The mark must be writable or a timeout is misreported as a crash: TMPDIR, else /tmp,
  # else the harness's own directory.
  local mark pid wd; mark="$(mktemp 2>/dev/null || mktemp /tmp/h_wd.XXXXXX 2>/dev/null)" || mark="${H_DIR}/h_wd.$$"; rm -f "${mark}"
  "$@" <&0 &        # explicit <&0: async jobs otherwise get /dev/null stdin
  pid=$!
  ( sp=""; trap 'kill "${sp:-}" 2>/dev/null; exit 0' TERM
    sleep "${secs}" & sp=$!; wait "${sp}"
    # The mark (holding the tree's pids) says "timed out" before anything is signalled.
    tree="$(h_descendants "${pid}")"; printf '%s\n' ${tree} >"${mark}.t"; mv -f "${mark}.t" "${mark}"
    # shellcheck disable=SC2086
    kill -TERM ${tree} "${pid}" 2>/dev/null
    # KILL two seconds later, unless every process of the tree is already gone.
    for i in 1 2; do
      sleep 1 & sp=$!; wait "${sp}"; alive=""
      for p in ${tree} "${pid}"; do kill -0 "${p}" 2>/dev/null && alive=1; done
      [ -n "${alive}" ] || exit 0
    done
    # shellcheck disable=SC2086
    kill -KILL ${tree} "${pid}" 2>/dev/null ) </dev/null >/dev/null 2>&1 &
  wd=$!; wait "${pid}"; rc=$?
  if [ -e "${mark}" ]; then
    # Timed out. If a descendant outlived the TERM, let the watchdog finish its KILL
    # stage (it must not be cancelled just because the top process exited).
    local p alive=""
    for p in $(cat "${mark}" 2>/dev/null); do kill -0 "${p}" 2>/dev/null && alive=1; done
    [ -n "${alive}" ] || kill -TERM "${wd}" 2>/dev/null
    wait "${wd}" 2>/dev/null; rm -f "${mark}"; return 124
  fi
  kill -TERM "${wd}" 2>/dev/null; wait "${wd}" 2>/dev/null; return "${rc}"
}

# A real Python 3 interpreter name (python3, else python). The version check also
# rejects the Windows Store "python3" stub.
h_python() { local p; for p in python3 python; do command -v "$p" >/dev/null 2>&1 && "$p" -c 'import sys; sys.exit(0 if sys.version_info[0]>=3 else 1)' >/dev/null 2>&1 && { printf '%s' "$p"; return 0; }; done; return 1; }

# Trusted verify recipe: <project>/.claude/harness/verify.sh whose content hash was
# registered (outside the project) by `harness trust-verify`. A recipe that arrives
# with a cloned repo, or that changed after it was trusted, is never auto-run. A
# trusted recipe that was DELETED during the session is "changed" too (deleting the
# exam must not drop the project to weak mode); `harness untrust-verify` is the
# operator's way out. A recipe that was already absent when the session started (a
# branch that never had it) is "none".
h_trust_file() { printf '%s/trust' "${H_DIR}"; }
h_recipe_status() {   # h_recipe_status <root> [recipe present at session start: 1|0; default 1]
  # echoes: none | trusted | untrusted | changed
  local root="$1" recipe key hash line
  recipe="${root}/.claude/harness/verify.sh"
  if [ ! -f "${recipe}" ]; then
    key="$(h_project_key)"
    if [ "${2:-1}" != 0 ] && [ -n "${key}" ] && grep -qF "	${key}	" "$(h_trust_file)" 2>/dev/null; then echo changed; else echo none; fi
    return
  fi
  key="$(h_project_key)"; hash="$(h_filehash "${recipe}")"
  line="$(grep -F "	${key}	" "$(h_trust_file)" 2>/dev/null | tail -1)"
  if [ -z "${line}" ]; then echo untrusted
  elif [ "${line%%	*}" = "${hash}" ]; then echo trusted
  else echo changed; fi
}
