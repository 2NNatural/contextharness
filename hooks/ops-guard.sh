#!/usr/bin/env bash
# ops-guard.sh — PreToolUse hook for Bash and Read. Turns a short list of
# high-consequence actions into an explicit operator decision ("ask"):
#   * deploying, publishing or releasing; applying or destroying infrastructure
#   * force-pushing, or pushing straight to main/master
#   * destructive database commands (DROP / TRUNCATE / migrate reset)
#   * reading credential files (.env, private keys, cloud credentials) or dumping the environment
#   * re-trusting a verify recipe that was already trusted (the agent must not be
#     able to weaken its own exam)
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
h_read_payload 2>/dev/null || exit 0

ask() {
  jq -cn --arg r "harness ops-guard: $1 This needs your explicit go-ahead." \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"ask",permissionDecisionReason:$r}}'
  exit 0
}
SECRET_RE='(^|/)(\.env(\.[A-Za-z0-9_-]+)?|id_(rsa|dsa|ecdsa|ed25519)|[^/]*\.pem|[^/]*\.p12|\.netrc|\.npmrc|\.pypirc|credentials(\.json)?|secrets?\.(json|ya?ml|toml)|service-account[^/]*\.json)$'
SAFE_ENV_RE='\.env\.(example|sample|template|dist|defaults)$'
is_secret_path() { printf '%s' "$1" | grep -Eq "${SECRET_RE}" && ! printf '%s' "$1" | grep -Eq "${SAFE_ENV_RE}"; }

if [ "${H_TOOL}" = "Read" ]; then
  f="$(h_get '.tool_input.file_path')"
  is_secret_path "${f}" && ask "reading ${f##*/} would put credentials into the conversation."
  exit 0
fi
[ "${H_TOOL}" = "Bash" ] || exit 0
cmd="$(h_get '.tool_input.command')"; [ -n "${cmd}" ] || exit 0

case "${cmd}" in
  *trust-verify*)
    if grep -qF "	$(h_project_key)" "$(h_trust_file)" 2>/dev/null; then
      ask "this project's verify recipe is already trusted; trusting a changed one alters what counts as 'verified'."
    fi ;;
esac
case "${cmd}" in */harness/trust*|*HARNESS_ALLOW_OPS=*|*HARNESS_OFF=*|*harness/off*)
  ask "this command changes the harness's own safety settings." ;; esac

set -f
while IFS= read -r seg; do
  # shellcheck disable=SC2086
  set -- ${seg}
  while [ $# -gt 0 ]; do case "$1" in *=*|sudo|time|nohup|command|exec|npx|bunx|pnpx) shift ;; *) break ;; esac; done
  [ $# -gt 0 ] || continue
  w="${1##*/}"; a="${2:-}"; b="${3:-}"; rest=" $* "
  case "$1" in ./*|/*|*.sh)
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
          br="$(git -C "${H_CWD}" branch --show-current 2>/dev/null)"
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
      case "${t##*/}" in *deploy*|*release*|*publish*|*prod*|*migrate*) ask "\`${t##*/}\` looks like a deploy/release/migration script." ;; esac ;;
  esac
done <<<"$(printf '%s' "${cmd}" | sed -E 's/(&&|\|\||[;|&])/\n/g')"
set +f
exit 0
