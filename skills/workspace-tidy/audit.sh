#!/usr/bin/env bash
# workspace-tidy audit: read-only inventory of a multi-repo workspace.
# Usage: [WORKSPACE_CONF=path] audit.sh [ROOT] [--mr]
#   ROOT  workspace folder (default: current dir)
#   --mr  also ask gh/glab for an open MR/PR per branch (network)
set -u

CHECK_MR=0; ROOT_ARG=.
for a in "$@"; do case "$a" in --mr) CHECK_MR=1 ;; -h|--help) sed -n '2,5p' "$0"; exit 0 ;; *) ROOT_ARG=$a ;; esac; done
ROOT=$(cd "$ROOT_ARG" 2>/dev/null && pwd) || { echo "no such dir: $ROOT_ARG" >&2; exit 1; }
CONF=${WORKSPACE_CONF:-"$ROOT/workspace.conf"}   # env override lets you audit a conf before placing it

# ---- config (plain key value lines, never sourced) ----
conf() { [ -f "$CONF" ] && awk -v k="$1" '$1==k {print $2; exit}' "$CONF"; }
WT_DIR=$(conf worktrees); WT_DIR=${WT_DIR:-.worktrees}
DOCS_DIR=$(conf docs);    DOCS_DIR=${DOCS_DIR:-docs}
# "group <remote-group> <folder>" lines map a remote group to a local folder.
group_for() {  # $1 = remote group path (e.g. acme/platform/foundation)
  local g="$1" mapped
  if [ -f "$CONF" ]; then
    # exact or prefix match; a prefix keeps the remainder (acme/platform/foundation -> platform/foundation)
    mapped=$(awk -v g="$g" '$1=="group" && (g==$2 || index(g,$2"/")==1) {rest=substr(g,length($2)+1); print $3 rest; exit}' "$CONF")
    [ -n "$mapped" ] && { echo "$mapped"; return; }
  fi
  # default: drop the owner (first segment); repos with no subgroup go to root-group (default "root")
  local rest=${g#*/} rg; rg=$(conf root-group); rg=${rg:-root}
  [ "$rest" = "$g" ] && echo "$rg" || echo "$rest"
}

rel() { printf '%s\n' "${1#"$ROOT"/}"; }

# ---- remote url -> host group name ----
parse_remote() {  # prints: host group name
  local u="$1" path
  case "$u" in
    *://*) path=${u#*://}; path=${path#*@}; path=${path#*/}; host=${u#*://}; host=${host#*@}; host=${host%%/*} ;;
    *@*:*) host=${u#*@}; host=${host%%:*}; path=${u#*:} ;;
    *)     host="local"; path="$u" ;;
  esac
  path=${path%.git}; path=${path%/}
  local name=${path##*/} group=${path%/*}
  [ "$group" = "$path" ] && group=""
  printf '%s\t%s\t%s\n' "$host" "$group" "$name"
}

# ---- per-checkout facts ----
default_branch() {
  local d="$1" b
  b=$(git -C "$d" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null)
  [ -n "$b" ] && { echo "${b#origin/}"; return; }
  for c in main master dev develop; do
    git -C "$d" show-ref --verify --quiet "refs/remotes/origin/$c" && { echo "$c"; return; }
  done
  echo "?"
}
branch_of()  { git -C "$1" symbolic-ref --short HEAD 2>/dev/null || echo "DETACHED"; }
dirty_of()   { git -C "$1" status --porcelain 2>/dev/null | wc -l | tr -d ' '; }
age_days()   { local t; t=$(git -C "$1" log -1 --format=%ct 2>/dev/null); [ -n "$t" ] && echo $(( ($(date +%s) - t) / 86400 )) || echo "?"; }
upstream_of() {  # pushed | ahead=N | no-upstream | detached
  local d="$1"
  [ "$(branch_of "$d")" = "DETACHED" ] && { echo "detached"; return; }
  local ref='@{upstream}' b; b=$(branch_of "$d")
  if ! git -C "$d" rev-parse --abbrev-ref "$ref" >/dev/null 2>&1; then
    git -C "$d" show-ref --verify --quiet "refs/remotes/origin/$b" && ref="origin/$b" || { echo "never-pushed"; return; }
  fi
  local n; n=$(git -C "$d" rev-list --count "$ref..HEAD" 2>/dev/null)
  [ "${n:-0}" = "0" ] && echo "pushed" || echo "ahead=$n"
}
mr_of() {  # open MR/PR for the branch, only with --mr
  [ "$CHECK_MR" = 1 ] || { echo "unchecked"; return; }
  local d="$1" b="$2" host="$3" n
  [ "$b" = "DETACHED" ] && { echo "-"; return; }
  case "$host" in
    gitlab*) command -v glab >/dev/null && n=$(cd "$d" && glab mr list --source-branch "$b" --state opened -F json 2>/dev/null | grep -c '"iid"') ;;
    github*) command -v gh   >/dev/null && n=$(cd "$d" && gh pr list --head "$b" --state open --json number -q length 2>/dev/null) ;;
  esac
  echo "${n:-unchecked}"
}

# ---- scan ----
REPOS=(); PLAIN=(); LOOSE=()
while IFS= read -r g; do REPOS+=("${g%/.git}"); done < <(find "$ROOT" -mindepth 2 -maxdepth 4 -type d -name .git -not -path "*/node_modules/*" 2>/dev/null | sort)
while IFS= read -r p; do
  [ "$p" = "$ROOT/$DOCS_DIR" ] && continue
  [ -n "$(find "$p" -maxdepth 3 -name .git -print -quit 2>/dev/null)" ] && continue
  PLAIN+=("$p")
done < <(find "$ROOT" -mindepth 1 -maxdepth 1 -type d -not -name '.*' 2>/dev/null | sort)
while IFS= read -r f; do
  case "$(basename "$f")" in README.md|CLAUDE.md|AGENTS.md|workspace.conf|repos.conf|.gitignore|.DS_Store) continue ;; esac
  LOOSE+=("$f")
done < <(find "$ROOT" -mindepth 1 -maxdepth 1 -type f 2>/dev/null | sort)

echo "## repos (${#REPOS[@]})"
{
  printf 'path\thost\tgroup\tname\tbranch\tdefault\tdirty\tupstream\tage_d\tmr\texpected\n'
  for d in ${REPOS[@]+"${REPOS[@]}"}; do
    url=$(git -C "$d" remote get-url origin 2>/dev/null || echo "none")
    IFS=$'\t' read -r host group name <<<"$(parse_remote "$url")"
    b=$(branch_of "$d")
    exp="$(group_for "$group")/$name"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$(rel "$d")" "$host" "${group:-.}" "$name" "$b" "$(default_branch "$d")" \
      "$(dirty_of "$d")" "$(upstream_of "$d")" "$(age_days "$d")" "$(mr_of "$d" "$b" "$host")" "$exp"
  done
} | column -t -s $'\t'

echo; echo "## worktrees (registered by the repos above)"
WT_ROWS=()
for d in ${REPOS[@]+"${REPOS[@]}"}; do
  main=$(rel "$d")
  while IFS= read -r line; do
    case "$line" in
      "worktree "*) p=${line#worktree }; br=""; prun="" ;;
      "branch "*)   br=${line#branch refs/heads/} ;;
      detached)     br="DETACHED" ;;
      prunable*)    prun="dead" ;;
      "")
        [ -z "${p:-}" ] && continue
        [ "$p" = "$d" ] && { p=""; continue; }
        if [ ! -d "$p" ]; then state="dead"
        elif [ -n "$prun" ]; then state="dead"
        else state="ok"; fi
        case "$p" in "$ROOT/$WT_DIR/"*) place="in" ;; "$ROOT/"*) place="OUTSIDE-$WT_DIR" ;; *) place="OUTSIDE-root" ;; esac
        if [ "$state" = "ok" ]; then up=$(upstream_of "$p"); dirty=$(dirty_of "$p"); age=$(age_days "$p")
        else up="-"; dirty="-"; age="-"; fi
        WT_ROWS+=("$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' "$main" "$(rel "$p")" "$br" "$state" "$place" "$dirty" "$up" "$age")")
        p="" ;;
    esac
  done < <(git -C "$d" worktree list --porcelain 2>/dev/null; echo)
done
echo "(${#WT_ROWS[@]})"; { printf 'main\tworktree\tbranch\tstate\tplace\tdirty\tupstream\tage_d\n'; printf '%s\n' ${WT_ROWS[@]+"${WT_ROWS[@]}"}; } | column -t -s $'\t'

echo; echo "## drift"
n=0
for d in ${REPOS[@]+"${REPOS[@]}"}; do
  url=$(git -C "$d" remote get-url origin 2>/dev/null || echo none)
  IFS=$'\t' read -r host group name <<<"$(parse_remote "$url")"
  [ "$(basename "$d")" != "$name" ] && { echo "folder name != remote name: $(rel "$d") (remote: $name)"; n=$((n+1)); }
  [ "$(rel "$d")" != "$(group_for "$group")/$name" ] && { echo "not at expected path: $(rel "$d") -> $(group_for "$group")/$name"; n=$((n+1)); }
done
while IFS= read -r line; do echo "duplicate clone of $line"; n=$((n+1)); done < <(
  for d in ${REPOS[@]+"${REPOS[@]}"}; do
    url=$(git -C "$d" remote get-url origin 2>/dev/null || echo none)
    printf '%s\t%s\n' "$(parse_remote "$url" | awk -F'\t' '{print $1"/"$2"/"$3}')" "$(rel "$d")"
  done | sort | awk -F'\t' '{paths[$1]=paths[$1] (paths[$1]?", ":"") $2; c[$1]++} END {for (k in c) if (c[k]>1) print k": "paths[k]}' | sort)
for r in ${WT_ROWS[@]+"${WT_ROWS[@]}"}; do
  IFS=$'\t' read -r main p br state place dirty up age <<<"$r"
  [ "$state" = "dead" ] && { echo "dead worktree link: $main -> $p"; n=$((n+1)); }
  [ "$state" = "ok" ] && [ "$place" != "in" ] && { echo "worktree outside $WT_DIR/: $p ($main, $br)"; n=$((n+1)); }
done
for p in ${PLAIN[@]+"${PLAIN[@]}"}; do echo "plain folder (no .git): $(rel "$p")"; n=$((n+1)); done
for f in ${LOOSE[@]+"${LOOSE[@]}"}; do echo "loose file at root: $(rel "$f")"; n=$((n+1)); done
echo "drift items: $n"

echo; echo "## cleanup candidates (evidence only, nothing is removed)"
for r in ${WT_ROWS[@]+"${WT_ROWS[@]}"}; do
  IFS=$'\t' read -r main p br state place dirty up age <<<"$r"
  [ "$state" = "dead" ] && { echo "prune (dead link): $main -> $p"; continue; }
  [ "$dirty" != "0" ] && continue
  [ "$up" = "pushed" ] && [ "${age:-0}" -ge 14 ] 2>/dev/null && echo "stale, pushed, ${age}d old: $p ($br)"
done
# dead copies: extra clones of a remote that another folder already holds, when clean and pushed
for d in ${REPOS[@]+"${REPOS[@]}"}; do
  url=$(git -C "$d" remote get-url origin 2>/dev/null || echo none)
  key=$(parse_remote "$url" | awk -F'\t' '{print $1"/"$2"/"$3}')
  if [ "$(for e in ${REPOS[@]+"${REPOS[@]}"}; do u=$(git -C "$e" remote get-url origin 2>/dev/null || echo none); parse_remote "$u" | awk -F'\t' '{print $1"/"$2"/"$3}'; done | grep -cx "$key")" -gt 1 ] \
     && [ "$(basename "$d")" != "$(printf '%s' "$key" | awk -F/ '{print $NF}')" ] \
     && [ "$(dirty_of "$d")" = "0" ] && [ "$(upstream_of "$d")" = "pushed" ]; then
    echo "dead copy (extra clone, clean, pushed): $(rel "$d")"
  fi
  # idle repos: clean, pushed, no commit in 90 days. Evidence for archiving, not a delete.
  a=$(age_days "$d"); [ "$(dirty_of "$d")" = "0" ] && [ "$(upstream_of "$d")" = "pushed" ] && [ "${a:-0}" -ge 90 ] 2>/dev/null && echo "idle repo, ${a}d since last commit: $(rel "$d")"
done
echo "unpushed or dirty worktrees are never candidates. Deletes need the user's explicit word."
