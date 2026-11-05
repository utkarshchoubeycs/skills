#!/usr/bin/env bash
# workspace-tidy audit: read-only inventory of a multi-repo workspace.
# Usage: [WORKSPACE_CONF=path] audit.sh [ROOT] [--mr]
#   ROOT  workspace folder (default: current dir)
#   --mr  also ask gh/glab for open MRs/PRs per branch (network; those CLIs may write their own config)
# Needs: bash 3.2+, git 2.17+ (worktree porcelain). Uses column(1) when present.
set -u
export GIT_OPTIONAL_LOCKS=0   # stops git status from refreshing the index; the script never writes otherwise

CHECK_MR=0; ROOT_ARG=.
for a in "$@"; do case "$a" in --mr) CHECK_MR=1 ;; -h|--help) sed -n '2,6p' "$0"; exit 0 ;; *) ROOT_ARG=$a ;; esac; done
ROOT=$(cd "$ROOT_ARG" 2>/dev/null && pwd) || { echo "no such dir: $ROOT_ARG" >&2; exit 1; }
CONF=${WORKSPACE_CONF:-"$ROOT/workspace.conf"}   # env override lets you audit a conf before placing it
NOW=$(date +%s)
TAB=$(printf '\t')

# ---- config: plain "key value" lines, read with awk, never sourced ----
conf() { [ -f "$CONF" ] && awk -v k="$1" '$1==k {print $2; exit}' "$CONF"; }
WT_DIR=$(conf worktrees); WT_DIR=${WT_DIR:-.worktrees}
DOCS_DIR=$(conf docs);    DOCS_DIR=${DOCS_DIR:-docs}
ROOT_GROUP=$(conf root-group); ROOT_GROUP=${ROOT_GROUP:-root}
case "$WT_DIR$DOCS_DIR" in /*|*..*) echo "workspace.conf: worktrees and docs must be relative paths without .." >&2; exit 1 ;; esac
group_for() {  # $1 = remote group (acme/platform/foundation) -> local folder. Longest "group" prefix wins.
  local g="$1" mapped
  if [ -f "$CONF" ]; then
    mapped=$(awk -v g="$g" '$1=="group" && (g==$2 || index(g,$2"/")==1) && length($2)>best {best=length($2); out=$3 substr(g,length($2)+1)} END {print out}' "$CONF")
    [ -n "$mapped" ] && { echo "$mapped"; return; }
  fi
  local rest=${g#*/}
  [ "$rest" = "$g" ] && echo "$ROOT_GROUP" || echo "$rest"   # drop the owner; no subgroup -> root-group
}
rel() { printf '%s\n' "${1#"$ROOT"/}"; }
fmt() { if command -v column >/dev/null 2>&1; then column -t -s "$TAB"; else cat; fi; }

# ---- remote url -> R_HOST R_GROUP R_NAME (globals, so empty fields survive) ----
parse_remote() {
  local u="$1" path
  R_HOST=""; R_GROUP=""; R_NAME=""
  case "$u" in
    "") R_HOST="unknown"; R_NAME="unknown"; return ;;
    file://*) R_HOST="file"; path=${u#file://} ;;
    *://*) path=${u#*://}; R_HOST=${path%%/*}; R_HOST=${R_HOST#*@}; path=${path#*/} ;;
    /*|./*|../*) R_HOST="file"; path=$u ;;
    *:*) R_HOST=${u%%:*}; R_HOST=${R_HOST#*@}; path=${u#*:} ;;   # scp form, user optional
    *) R_HOST="unknown"; path=$u ;;
  esac
  path=${path%/}; path=${path%.git}; path=${path%/}; path=${path#/}
  R_NAME=${path##*/}; R_GROUP=${path%/*}
  [ "$R_GROUP" = "$path" ] && R_GROUP=""
  [ -z "$R_NAME" ] && R_NAME="unknown"
}

# ---- per-checkout facts; every helper says "unknown" when git fails ----
default_branch() {
  local d="$1" b
  b=$(git -C "$d" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null) && { echo "${b#origin/}"; return; }
  for c in main master dev develop; do git -C "$d" show-ref --verify --quiet "refs/remotes/origin/$c" 2>/dev/null && { echo "$c"; return; }; done
  echo "?"
}
branch_of() { git -C "$1" symbolic-ref --short HEAD 2>/dev/null || { git -C "$1" rev-parse --verify -q HEAD >/dev/null 2>&1 && echo "DETACHED" || echo "unknown"; }; }
dirty_of()  { local o; o=$(git -C "$1" status --porcelain --untracked-files=normal 2>/dev/null) || { echo "unknown"; return; }; printf '%s' "$o" | grep -c . || true; }
age_days()  { local t; t=$(git -C "$1" log -1 --format=%ct 2>/dev/null) && [ -n "$t" ] && echo $(( (NOW - t) / 86400 )) || echo "unknown"; }
upstream_of() {  # pushed | ahead=N | never-pushed | detached | unknown
  local d="$1" b ref n
  b=$(branch_of "$d")
  case "$b" in DETACHED) echo "detached"; return ;; unknown) echo "unknown"; return ;; esac
  if git -C "$d" rev-parse --abbrev-ref '@{upstream}' >/dev/null 2>&1; then ref='@{upstream}'
  elif git -C "$d" show-ref --verify --quiet "refs/remotes/origin/$b" 2>/dev/null; then ref="origin/$b"
  else echo "never-pushed"; return; fi
  n=$(git -C "$d" rev-list --count "$ref..HEAD" 2>/dev/null) || { echo "unknown"; return; }
  [ "$n" = "0" ] && echo "pushed" || echo "ahead=$n"
}
local_refs() {  # "<local branches>b <stashes>s <tags>t", evidence that a clone holds work beyond HEAD
  local d="$1" b s t
  if b=$(git -C "$d" for-each-ref --format=x refs/heads 2>/dev/null); then b=$(printf '%s' "$b" | grep -c . || true); else b="?"; fi
  if s=$(git -C "$d" stash list 2>/dev/null); then s=$(printf '%s' "$s" | grep -c . || true); else s="?"; fi
  if t=$(git -C "$d" for-each-ref --format=x refs/tags 2>/dev/null); then t=$(printf '%s' "$t" | grep -c . || true); else t="?"; fi
  echo "${b}b ${s}s ${t}t"
}
mr_of() {  # open MR/PR count for a branch; only with --mr; "unchecked" when no CLI or it fails
  [ "$CHECK_MR" = 1 ] || { echo "unchecked"; return; }
  local d="$1" b="$2" host="$3" out
  case "$b" in DETACHED|unknown) echo "-"; return ;; esac
  case "$host" in
    gitlab*) command -v glab >/dev/null 2>&1 && out=$(cd "$d" && glab mr list --source-branch "$b" -F json 2>/dev/null) && { printf '%s' "$out" | grep -o '"iid"' | grep -c .; return; } ;;
    github*) command -v gh   >/dev/null 2>&1 && out=$(cd "$d" && gh pr list --head "$b" --state open --json number -q length 2>/dev/null) && { echo "$out"; return; } ;;
  esac
  echo "unchecked"
}

# ---- scan: main repos (.git dirs) and worktrees whose main repo is outside ROOT (.git files) ----
REPOS=(); EXTERNAL_WT=(); PLAIN=(); HIDDEN=(); LOOSE=()
while IFS= read -r g; do
  d=${g%/.git}
  if [ -d "$g" ]; then REPOS+=("$d")
  elif [ -f "$g" ]; then
    common=$(git -C "$d" rev-parse --git-common-dir 2>/dev/null) || continue
    case "$common" in /*) ;; *) common="$d/$common" ;; esac
    case "$(cd "$common" 2>/dev/null && pwd)" in "$ROOT"/*) ;; *) EXTERNAL_WT+=("$d") ;; esac
  fi
done < <(find "$ROOT" -mindepth 2 -maxdepth 5 -name .git -not -path "*/node_modules/*" 2>/dev/null | sort)
while IFS= read -r p; do
  [ "$p" = "$ROOT/$DOCS_DIR" ] && continue
  [ -n "$(find "$p" -maxdepth 4 -name .git -print -quit 2>/dev/null)" ] && continue
  case "$(basename "$p")" in .*) [ "$p" = "$ROOT/$WT_DIR" ] || [ "$p" = "$ROOT/.git" ] || [ "$p" = "$ROOT/.claude" ] || HIDDEN+=("$p") ;; *) PLAIN+=("$p") ;; esac
done < <(find "$ROOT" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
while IFS= read -r f; do
  case "$(basename "$f")" in README.md|CLAUDE.md|AGENTS.md|workspace.conf|.gitignore|.DS_Store) continue ;; esac
  LOOSE+=("$f")
done < <(find "$ROOT" -mindepth 1 -maxdepth 1 -type f 2>/dev/null | sort)

# ---- one pass of facts per repo: path host group name key branch default dirty upstream age mr expected refs ----
ROWS=()
for d in ${REPOS[@]+"${REPOS[@]}"}; do
  url=$(git -C "$d" remote get-url origin 2>/dev/null) || url=""
  parse_remote "$url"
  b=$(branch_of "$d")
  ROWS+=("$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
    "$(rel "$d")" "$R_HOST" "${R_GROUP:-.}" "$R_NAME" "$R_HOST/$R_GROUP/$R_NAME" "$b" "$(default_branch "$d")" \
    "$(dirty_of "$d")" "$(upstream_of "$d")" "$(age_days "$d")" "$(mr_of "$d" "$b" "$R_HOST")" \
    "$(group_for "$R_GROUP")/$R_NAME" "$(local_refs "$d")")")
done

echo "## repos (${#ROWS[@]})"
{ printf 'path\thost\tgroup\tname\tbranch\tdefault\tdirty\tupstream\tage_d\tmr\texpected\trefs\n'
  for r in ${ROWS[@]+"${ROWS[@]}"}; do printf '%s\n' "$r" | awk -F"$TAB" 'BEGIN{OFS="\t"} {print $1,$2,$3,$4,$6,$7,$8,$9,$10,$11,$12,$13}'; done; } | fmt
for d in ${EXTERNAL_WT[@]+"${EXTERNAL_WT[@]}"}; do echo "worktree of a repo outside this workspace: $(rel "$d")"; done

# ---- worktrees from each repo's own registry; states: ok | locked | missing | prunable ----
echo; echo "## worktrees (registered by the repos above)"
WT_ROWS=()
for d in ${REPOS[@]+"${REPOS[@]}"}; do
  main=$(rel "$d"); mainname=$(basename "$d")
  p=""; br=""; prun=""; lock=""
  while IFS= read -r line; do
    case "$line" in
      "worktree "*) p=${line#worktree }; br=""; prun=""; lock="" ;;
      "branch "*)   br=${line#branch refs/heads/} ;;
      detached)     br="DETACHED" ;;
      prunable*)    prun="prunable" ;;
      locked*)      lock="locked" ;;
      "")
        [ -z "$p" ] && continue
        [ "$p" = "$d" ] && { p=""; continue; }
        if [ -n "$lock" ]; then state="locked"
        elif [ -n "$prun" ]; then state="prunable"
        elif [ ! -d "$p" ]; then state="missing"
        else state="ok"; fi
        want="$ROOT/$WT_DIR/$mainname/"
        case "$p" in
          "$want"*) rest=${p#"$want"}; case "$rest" in */*|"") place="OUTSIDE-$WT_DIR" ;; *) place="in" ;; esac ;;
          "$ROOT/"*) place="OUTSIDE-$WT_DIR" ;;
          *) place="OUTSIDE-root" ;;
        esac
        if [ "$state" = "ok" ] || [ "$state" = "locked" ] && [ -d "$p" ]; then up=$(upstream_of "$p"); dirty=$(dirty_of "$p"); age=$(age_days "$p")
        else up="-"; dirty="-"; age="-"; fi
        WT_ROWS+=("$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' "$main" "$(rel "$p")" "$br" "$state" "$place" "$dirty" "$up" "$age")")
        p="" ;;
    esac
  done < <(git -C "$d" worktree list --porcelain 2>/dev/null; echo)
done
echo "(${#WT_ROWS[@]})"
{ printf 'main\tworktree\tbranch\tstate\tplace\tdirty\tupstream\tage_d\n'; for r in ${WT_ROWS[@]+"${WT_ROWS[@]}"}; do printf '%s\n' "$r"; done; } | fmt

# ---- drift: everything that breaks the layout rule ----
echo; echo "## drift"
n=0
for r in ${ROWS[@]+"${ROWS[@]}"}; do
  IFS="$TAB" read -r path host group name key b def dirty up age mr exp refs <<EOF
$r
EOF
  [ "$host" = "unknown" ] && { echo "no origin remote, cannot place: $path"; n=$((n+1)); continue; }
  [ "$(basename "$path")" != "$name" ] && { echo "folder name != remote name: $path (remote: $name)"; n=$((n+1)); }
  [ "$path" != "$exp" ] && { echo "not at expected path: $path -> $exp"; n=$((n+1)); }
done
DUPES=$(for r in ${ROWS[@]+"${ROWS[@]}"}; do printf '%s\n' "$r" | awk -F"$TAB" 'BEGIN{OFS="\t"} $2!="unknown" {print $5,$1}'; done \
  | awk -F"$TAB" '{paths[$1]=paths[$1] (paths[$1]?", ":"") $2; c[$1]++} END {for (k in c) if (c[k]>1) print k": "paths[k]}' | sort)
[ -n "$DUPES" ] && while IFS= read -r line; do echo "duplicate clones of $line"; n=$((n+1)); done <<EOF
$DUPES
EOF
for r in ${WT_ROWS[@]+"${WT_ROWS[@]}"}; do
  IFS="$TAB" read -r main p br state place dirty up age <<EOF
$r
EOF
  case "$state" in
    prunable) echo "dead worktree link (git says prunable): $main -> $p"; n=$((n+1)) ;;
    missing)  echo "worktree folder missing, not marked prunable (unmounted? check before prune): $main -> $p"; n=$((n+1)) ;;
    *) [ "$place" != "in" ] && { echo "worktree outside $WT_DIR/<repo>/<slug>: $p ($main, $br)"; n=$((n+1)); } ;;
  esac
done
for p in ${PLAIN[@]+"${PLAIN[@]}"};   do echo "plain folder (no repo inside): $(rel "$p")"; n=$((n+1)); done
for p in ${HIDDEN[@]+"${HIDDEN[@]}"}; do echo "hidden folder at root (tool state?): $(rel "$p")"; n=$((n+1)); done
for f in ${LOOSE[@]+"${LOOSE[@]}"};   do echo "loose file at root: $(rel "$f")"; n=$((n+1)); done
echo "drift items: $n"

# ---- cleanup candidates: evidence only. Locked, dirty, unpushed, detached or unknown are never listed. ----
echo; echo "## cleanup candidates (evidence only, nothing is removed)"
for r in ${WT_ROWS[@]+"${WT_ROWS[@]}"}; do
  IFS="$TAB" read -r main p br state place dirty up age <<EOF
$r
EOF
  case "$state" in
    prunable) echo "prune (dead link, git-confirmed): $main -> $p"; continue ;;
    ok) ;;
    *) continue ;;
  esac
  [ "$dirty" = "0" ] && [ "$up" = "pushed" ] && [ "$age" -ge 14 ] 2>/dev/null && echo "stale worktree, clean, pushed, ${age}d old: $p ($br)"
done
for r in ${ROWS[@]+"${ROWS[@]}"}; do
  IFS="$TAB" read -r path host group name key b def dirty up age mr exp refs <<EOF
$r
EOF
  [ "$dirty" = "0" ] && [ "$up" = "pushed" ] || continue
  if printf '%s\n' "$DUPES" | awk -F': ' -v k="$key" '$1==k {f=1} END {exit !f}' && [ "$(basename "$path")" != "$name" ]; then
    echo "duplicate clone, review before removal (clean, HEAD pushed, holds $refs): $path"
  fi
  [ "$age" -ge 90 ] 2>/dev/null && echo "idle repo, ${age}d since last commit (archive candidate): $path"
done
echo "locked, dirty, unpushed, detached or unknown items are never candidates. Removal needs the user's explicit word per item."
