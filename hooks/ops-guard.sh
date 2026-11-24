#!/usr/bin/env bash
# ops-guard.sh — PreToolUse hook for Bash, Read and the edit tools. Turns a short list of
# high-consequence actions into an explicit operator decision ("ask"):
#   * deploying, publishing or releasing; applying or destroying infrastructure
#   * force-pushing, or pushing straight to main/master
#   * destructive database commands (DROP / TRUNCATE / migrate reset)
#   * reading credential files (.env, private keys, cloud credentials) or dumping the environment
#   * re-trusting a verify recipe that was already trusted, trusting another
#     project's recipe, un-trusting one, or turning the harness off — by CLI or by
#     writing ~/.claude/harness/off|trust (any letter case) or the gate's own
#     ~/.claude/harness/state/ with an edit tool (the agent must not be able to
#     weaken its own exam)
# In an unattended session an "ask" cannot be answered, so the action does not run.
#
# This is a tripwire against an agent doing something consequential unasked. It is
# NOT a sandbox: it matches the leading words of each command segment and can be
# evaded by indirection (a wrapper script, eval, an MCP tool). Real isolation comes
# from credentials the agent does not hold. Fails open on any internal error.
# Master switch: HARNESS_ALLOW_OPS=1 in the hook's environment.
. "$(dirname "${BASH_SOURCE[0]}")/harness-lib.sh" 2>/dev/null || exit 0
h_off && exit 0
[ "${HARNESS_ALLOW_OPS:-}" = "1" ] && exit 0
raw="$(cat)" || exit 0
# Fast path (no jq, no fork): for the edit tools only paths under …/harness/ matter, so
# a payload that never mentions "harness" (any letter case) has nothing to ask about.
re='"tool_name"[[:space:]]*:[[:space:]]*"(Write|Edit|MultiEdit|NotebookEdit)"'
if [[ ${raw} =~ ${re} ]]; then
  shopt -s nocasematch; [[ ${raw} == *harness* ]] || exit 0; shopt -u nocasematch
fi
h_read_payload <<<"${raw}" 2>/dev/null || exit 0

ask() {
  # Own evidence that the guard fired (the transcript of an unattended run may not show it).
  mkdir -p "${H_STATE}" 2>/dev/null; printf '%s ask %s\n' "$(date +%s)" "$1" >>"${H_STATE}/ops.log" 2>/dev/null
  jq -cn --arg r "harness ops-guard: $1 This needs your explicit go-ahead." \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"ask",permissionDecisionReason:$r}}'
  exit 0
}
SECRET_RE='(^|/)(\.env(\.[A-Za-z0-9_-]+)?|id_(rsa|dsa|ecdsa|ed25519)|[^/]*\.pem|[^/]*\.p12|\.netrc|\.npmrc|\.pypirc|credentials(\.json)?|secrets?\.(json|ya?ml|toml)|service-account[^/]*\.json)$'
SAFE_ENV_RE='\.env\.(example|sample|template|dist|defaults)$'
# Windows paths (C:\Users\a\.env) are matched in forward-slash form.
is_secret_path() { local p="${1//"${H_BSLASH}"//}"; printf '%s' "$p" | grep -Eq "${SECRET_RE}" && ! printf '%s' "$p" | grep -Eq "${SAFE_ENV_RE}"; }

if [ "${H_TOOL}" = "Read" ]; then
  f="$(h_get '.tool_input.file_path')"; f="${f//"${H_BSLASH}"//}"
  is_secret_path "${f}" && ask "reading ${f##*/} would put credentials into the conversation."
  exit 0
fi
# The off switch and the trust list are files: writing them with an edit tool is the
# same act as `harness off` / `harness trust-verify`.
case "${H_TOOL}" in Write|Edit|MultiEdit|NotebookEdit)
  f="$(h_get '.tool_input.file_path // .tool_input.notebook_path')"; f="${f//"${H_BSLASH}"//}"
  # Lower-cased: NTFS and APFS are case-insensitive by default (…/harness/OFF is the off switch).
  lf="$(printf '%s' "${f}" | tr '[:upper:]' '[:lower:]')"
  case "${lf}" in
    */harness/off|*/harness/trust) ask "this edits the harness's own safety settings (${f##*/})." ;;
    */harness/state/*) ask "this writes the harness's own session state (${f##*/}), which decides what counts as verified." ;;
  esac
  exit 0 ;;
esac
[ "${H_TOOL}" = "Bash" ] || exit 0
cmd="$(h_get '.tool_input.command')"; [ -n "${cmd}" ] || exit 0
# The strings of `bash -c '…'` / `sh -c "…"` are checked as commands too.
inl="$(h_inline_scripts "${cmd}")"; [ -z "${inl}" ] || cmd="${cmd}
${inl}"
ncmd="${cmd//"${H_BSLASH}"//}"

# Is `harness trust-verify` actually invoked (command word `harness`, after any wrapper
# such as timeout/nice/env -u/xargs, or `bash harness`)? A search or a commit message
# that only mentions trust-verify is not.
tvs=""; set -f
while IFS= read -r seg; do
  # shellcheck disable=SC2086
  set -- ${seg}; h_prefix_skip "$@"; shift "${H_PN}"
  w="${1:-}"; w="${w//[${H_QUOTES}()\{\}]/}"; w="${w##*/}"
  case "${w}" in bash|sh|zsh|dash|xargs) shift; w="${1:-}"; w="${w//[${H_QUOTES}()]/}"; w="${w##*/}" ;; esac
  b="${2:-}"; b="${b//[${H_QUOTES}()\{\}]/}"
  if [ "${w}" = harness ] && [ "${b}" = trust-verify ]; then w="${3:-}"; tvs="@${w//[${H_QUOTES}()\{\}]/}"; break; fi
done <<<"$(h_segments "${ncmd}")"
set +f
if [ -n "${tvs}" ]; then
  # Resolve WHICH project is being trusted: an argument or a cd (anywhere: subshell,
  # braces, bash -c) can point trust-verify at a different project than this session's.
  ckey="$(h_project_key)"; tkey="${ckey}"
  printf '%s\n' "${ncmd}" | grep -Eq "(^|[[:space:];&|({\`${H_QUOTES}])(cd|pushd)([[:space:]]|\$)" \
    && ask "this trusts a verify recipe after changing directory, so which project it applies to cannot be checked."
  tv="${tvs#@}"
  case "${tv}" in *'<'*|*'>'*) tv="" ;; esac   # a redirection, not a directory
  if [ -n "${tv}" ]; then
    case "${tv}" in *'$'*|*'`'*) ask "the recipe to trust is named indirectly (${tv})." ;; esac
    case "${tv}" in /*|[A-Za-z]:*) td="${tv}" ;; '~'|'~'/*) td="${HOME}${tv:1}" ;; *) td="${H_CWD%/}/${tv}" ;; esac
    oc="${H_CWD}"; H_CWD="${td}"; tkey="$(h_project_key)"; H_CWD="${oc}"
    { [ -n "${tkey}" ] && [ "${tkey}" = "${ckey}" ]; } || ask "this trusts the verify recipe of a different project (${tv}); only the operator may do that."
  fi
  grep -qF "	${tkey}	" "$(h_trust_file)" 2>/dev/null && ask "this project's verify recipe is already trusted; trusting a changed one alters what counts as 'verified'."
fi
# Lower-cased: on a case-insensitive file system ~/.claude/harness/OFF is the off switch.
lc="$(printf '%s' "${ncmd}" | tr '[:upper:]' '[:lower:]')"
case "${lc}" in */harness/trust*|*harness_allow_ops=*|*harness_off=*|*harness/off*)
  ask "this command changes the harness's own safety settings." ;; esac

set -f
while IFS= read -r seg; do
  # shellcheck disable=SC2086
  set -- ${seg}
  # Wrappers (env/sudo/nice/timeout/npx/xargs …) and their option operands; assignments.
  h_prefix_skip "$@"; shift "${H_PN}"
  # A bare `env` (with or without assignments/flags, but not `env -i`) prints the environment.
  [ $# -gt 0 ] || { [ "${H_ENVD}" = 1 ] && ask "dumping the whole environment would print secrets into the conversation."; continue; }
  q="${1//[${H_QUOTES}]/}"; q="${q#\(}"; q="${q%\)}"; w="${q##*/}"
  # Normalise global options away so the subcommand is $2: git -C dir / -c k=v,
  # kubectl -n ns / --context c, helm -n ns, docker -H host ...
  gdir="${H_CWD}"
  if [ "${w}" = git ]; then shift
    while [ $# -gt 0 ]; do case "$1" in
      -C) if [ $# -ge 2 ]; then case "$2" in /*|[A-Za-z]:*) gdir="$2" ;; *) gdir="${gdir%/}/$2" ;; esac; shift 2; else shift; fi ;;
      -c|--git-dir|--work-tree|--namespace|--exec-path|--config-env) if [ $# -ge 2 ]; then shift 2; else shift; fi ;;
      -*) shift ;; *) break ;; esac; done
    set -- git "$@"
  elif case "${w}" in kubectl|oc|helm|docker|podman) true ;; *) false ;; esac; then f1="$1"; shift
    while [ $# -gt 0 ]; do case "$1" in
      -n|--namespace|--context|--kubeconfig|--cluster|--user|-s|--server|--kube-context|-H|--host|--config|-c|-l|--log-level) if [ $# -ge 2 ]; then shift 2; else shift; fi ;;
      -*) shift ;; *) break ;; esac; done
    set -- "${f1}" "$@"
  fi
  a="${2:-}"; a="${a//[${H_QUOTES}]/}"; b="${3:-}"; b="${b//[${H_QUOTES}]/}"; rest=" $* "
  case "${q}" in ./*|/*|*.sh)
    case "${w}" in *deploy*|*release*|*publish*|*prod*|*migrate*) ask "\`${w}\` looks like a deploy/release/migration script." ;; esac ;;
  esac
  case "${w}" in
    terraform|tofu|pulumi)   case "${rest}" in *" apply "*|*" destroy "*|*" up "*|*" import "*) ask "\`${w} ${a}\` changes real infrastructure." ;; esac ;;
    kubectl|oc)              case "${a}" in apply|delete|rollout|scale|patch|replace|drain|create|set) ask "\`${w} ${a}\` changes a live cluster." ;; esac ;;
    helm)                    case "${a}" in install|upgrade|uninstall|rollback|delete) ask "\`helm ${a}\` changes a live cluster." ;; esac ;;
    vercel|netlify|flyctl|fly|firebase|wrangler|serverless|sls|railway|heroku|cdk|sam|eb|amplify|render|supabase)
                             case "${rest}" in *" deploy "*|*" --prod "*|*" publish "*|*" up "*|*" promote "*|*" release "*|*" db push "*|*" db reset "*) ask "\`${w} ${a}\` deploys to a live environment." ;; esac ;;
    gcloud|az)               case "${rest}" in *" deploy "*|*" delete "*|*" create "*) ask "\`${w}\` is changing cloud resources." ;; esac ;;
    aws)                     case "${rest}" in *" deploy "*|*" delete"*|*" rm "*|*" terminate-"*|*" create-"*|*" update-"*|*" put-"*|*" sync "*) ask "\`aws ${a} ${b}\` changes cloud resources." ;; esac ;;
    docker|podman)           [ "${a}" = "push" ] && ask "pushing a container image publishes it." ;;
    npm|pnpm|yarn|bun)
      [ "${a}" = "publish" ] && ask "publishing a package is public and hard to undo."
      case "${a}" in run|run-script) s="${b}" ;; *) s="${a}" ;; esac
      case "${s}" in *deploy*|*release*|*publish*|*prod*|*migrate*) [ "${a}" != "install" ] && [ "${a}" != "add" ] && ask "the \`${s}\` script looks like a deploy/release/migration." ;; esac ;;
    cargo|gem|twine|poetry|flit|hatch|pod|mvn|gradle|gradlew)
                             case "${rest}" in *" publish "*|*" push "*|*" upload "*|*" release "*|*" deploy "*) ask "\`${w}\` is publishing an artifact." ;; esac ;;
    gh)                      case "${a} ${b}" in "release create"|"pr merge"|"repo delete"|"workflow run"|"secret set") ask "\`gh ${a} ${b}\` acts on the shared repository." ;; esac ;;
    make|just|task)          case "${a}" in *deploy*|*release*|*publish*|*prod*|*migrate*) ask "the \`${a}\` target looks like a deploy/release/migration." ;; esac ;;
    git)
      if [ "${a}" = "push" ]; then
        case "${rest}" in *" --force "*|*" -f "*|*" --force-with-lease"*|*" --mirror "*|*" --delete "*) ask "this push rewrites or deletes remote history." ;; esac
        case "${rest}" in *" main "*|*":main "*|*" master "*|*":master "*) ask "this pushes directly to the main branch." ;; esac
        nonflag=0; for arg in "$@"; do case "${arg}" in -*) ;; *) nonflag=$((nonflag+1)) ;; esac; done
        if [ "${nonflag}" -le 3 ]; then   # git push [remote] with no explicit branch
          br="$(git -C "${gdir}" branch --show-current 2>/dev/null)"
          case "${br}" in main|master) ask "you are on ${br}; this pushes directly to the main branch." ;; esac
        fi
      fi ;;
    prisma|drizzle-kit|alembic|flyway|liquibase|knex|sequelize|rails|rake|django-admin|manage.py)
                             case "${rest}" in *" migrate reset"*|*" db push"*|*" migrate deploy"*|*" db:drop"*|*" db:reset"*|*" downgrade "*|*" flush "*|*" clean "*) ask "this is a destructive or production database migration." ;; esac ;;
    psql|mysql|sqlite3|mongosh|redis-cli|clickhouse-client|bq)
                             printf '%s' "${seg}" | grep -Eiq '(drop[[:space:]]+(table|database|schema)|truncate[[:space:]]|delete[[:space:]]+from[[:space:]]+[A-Za-z_."]+[[:space:]]*(;|"|'"'"'|$)|flushall|dropDatabase)' \
                               && ask "this database command destroys data." ;;
    printenv|env)            [ $# -eq 1 ] && ask "dumping the whole environment would print secrets into the conversation." ;;
    cat|less|more|head|tail|grep|rg|cp|scp|rsync|base64|xxd|strings|source|.|curl|wget|nc|awk|sed|bat|open)
      for arg in "$@"; do
        arg="${arg%\"}"; arg="${arg#\"}"; arg="${arg%\'}"; arg="${arg#\'}"; case "${arg}" in *@*) arg="${arg##*@}" ;; esac
        is_secret_path "${arg}" && ask "\`${w} ${arg##*/}\` would expose credentials."
      done ;;
    bash|sh|zsh)
      t="${a}"
      case "${t##*/}" in *deploy*|*release*|*publish*|*prod*|*migrate*) ask "\`${t##*/}\` looks like a deploy/release/migration script." ;; esac
      [ "${t##*/}" = harness ] && [ "${b}" = off ] && ask "turning the harness off disables its safety hooks."
      [ "${t##*/}" = harness ] && [ "${b}" = untrust-verify ] && ask "un-trusting the verify recipe changes what counts as 'verified'." ;;
    harness)                 [ "${a}" = off ] && ask "turning the harness off disables its safety hooks."
                             [ "${a}" = untrust-verify ] && ask "un-trusting the verify recipe changes what counts as 'verified'."
                             # `… | xargs harness`: the subcommand comes from input that cannot be read here.
                             [ -z "${a}" ] && [ "${H_XA}" = 1 ] && ask "the harness subcommand is supplied by xargs, so it cannot be checked." ;;
  esac
done <<<"$(h_segments "${cmd}")"
set +f
exit 0
