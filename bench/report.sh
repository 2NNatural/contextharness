#!/usr/bin/env bash
# bench/report.sh [OUT_DIR] — print a Markdown comparison of every arm found under
# OUT_DIR (default: $TMPDIR/harness-bench). Reads only results.json files that
# bench/run.sh produced; it reports what was measured and nothing else.
set -u
OUT="${1:-${TMPDIR:-/tmp}/harness-bench}"
files="$(ls "${OUT}"/*/results.json 2>/dev/null)"
[ -n "${files}" ] || { echo "no results under ${OUT}" >&2; exit 1; }
# shellcheck disable=SC2086
all="$(jq -s 'add' ${files})"

echo "## Summary by arm"
echo
echo "| Arm | Runs | Passed hidden check | Pass rate | False \"done\" (failed, no caveat) | Total cost | Cost per pass | Mean turns | Mean wall time | Total tokens | Subagents | Permission denials |"
echo "|---|---|---|---|---|---|---|---|---|---|---|---|"
printf '%s' "${all}" | jq -r '
  group_by(.arm)[] | . as $g
  | ([$g[]|select(.pass)]|length) as $p
  | ([$g[].cost_usd // 0]|add) as $c
  | "| \($g[0].arm) | \($g|length) | \($p) | \(($p*100/($g|length))|floor)% | \([$g[]|select(.false_done)]|length) | $\($c*100|round/100) | \(if $p>0 then "$\(($c/$p)*100|round/100)" else "n/a" end) | \(([$g[].turns // 0]|add)/($g|length)|floor) | \(([$g[].wall_s]|add)/($g|length)|floor)s | \([$g[].tokens]|add) | \([$g[].subagents]|add) | \([$g[].denials]|add) |"'
echo
echo "## Per task"
echo
arms="$(printf '%s' "${all}" | jq -r '[.[].arm]|unique|join(" ")')"
hdr="| Task |"; sep="|---|"
for a in ${arms}; do hdr="${hdr} ${a} |"; sep="${sep}---|"; done
echo "${hdr}"; echo "${sep}"
for t in $(printf '%s' "${all}" | jq -r '[.[].task]|unique|.[]'); do
  row="| ${t} |"
  for a in ${arms}; do
    cell="$(printf '%s' "${all}" | jq -r --arg a "${a}" --arg t "${t}" '
      [.[]|select(.arm==$a and .task==$t)] | if length==0 then "—" else
        "\([.[]|select(.pass)]|length)/\(length) pass, $\(([.[].cost_usd // 0]|add)/length*100|round/100), \(([.[].turns // 0]|add)/length|floor) turns" end')"
    row="${row} ${cell} |"
  done
  echo "${row}"
done
echo
echo "## Failures"
echo
printf '%s' "${all}" | jq -r '.[]|select(.pass|not)|"- \(.arm) / \(.task) #\(.trial): \(.check_failure // "check failed")\(if .false_done then "  — reported as done with no caveat" else "" end)"'
