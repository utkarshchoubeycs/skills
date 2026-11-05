#!/usr/bin/env bash
# workspace-tidy audit: read-only inventory of a multi-repo workspace.
# Usage: [WORKSPACE_CONF=path] audit.sh [ROOT] [--mr]
#   ROOT  workspace folder (default: current dir)
#   --mr  also ask gh/glab for open MRs/PRs per branch (network; those CLIs may write their own config)
# Needs: bash 3.2+, git 2.31+ (locked/prunable in worktree porcelain). Scans 5 levels deep, skips node_modules. Uses column(1) when present.
set -u
export GIT_OPTIONAL_LOCKS=0   # stops git status from refreshing the index; the script never writes otherwise

CHECK_MR=0; ROOT_ARG=.
for a in "$@"; do case "$a" in --mr) CHECK_MR=1 ;; -h|--help) sed -n '2,6p' "$0"; exit 0 ;; *) ROOT_ARG=$a ;; esac; done
ROOT=$(cd "$ROOT_ARG" 2>/dev/null && pwd -P) || { echo "no such dir: $ROOT_ARG" >&2; exit 1; }   # physical path: git prints physical paths
git version 2>/dev/null | awk '{split($3,v,"."); exit !(v[1]>2 || (v[1]==2 && v[2]>=31))}' \
  || { echo "needs git 2.31+ (locked/prunable worktree states); found: $(git version 2>&1)" >&2; exit 1; }
CONF=${WORKSPACE_CONF:-"$ROOT/workspace.conf"}   # env override lets you audit a conf before placing it
NOW=$(date +%s)
TAB=$(printf '\t')
MAXDEPTH=5

# ---- config: plain "key value" lines, read with awk, never sourced ----
conf() { [ -f "$CONF" ] && awk -v k="$1" '$1==k {print $2; exit}' "$CONF"; }
relpath_ok() { case "$1" in ""|/*|..|../*|*/..|*/../*) return 1 ;; esac; }   # non-empty, relative, no .. segment
WT_DIR=$(conf worktrees); WT_DIR=${WT_DIR:-.worktrees}
DOCS_DIR=$(conf docs);    DOCS_DIR=${DOCS_DIR:-docs}
ROOT_GROUP=$(conf root-group); ROOT_GROUP=${ROOT_GROUP:-root}
for kv in "worktrees=$WT_DIR" "docs=$DOCS_DIR" "root-group=$ROOT_GROUP"; do
  relpath_ok "${kv#*=}" || { echo "workspace.conf: ${kv%%=*} must be a relative path without ..: '${kv#*=}'" >&2; exit 1; }
done
[ -f "$CONF" ] && while IFS= read -r t; do
  relpath_ok "$t" || { echo "workspace.conf: group target must be a relative path without ..: '$t'" >&2; exit 1; }
done < <(awk '$1=="group" {print $3}' "$CONF")
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

# ---- per-checkout facts; every helper says "unknown" or "?" when git fails ----
default_branch() {
  local d="$1" b
  b=$(git -C "$d" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null) && { echo "${b#origin/}"; return; }
  for c in main master dev develop; do git -C "$d" show-ref --verify --quiet "refs/remotes/origin/$c" 2>/dev/null && { echo "$c"; return; }; done
  echo "?"
}
branch_of() { git -C "$1" symbolic-ref --short HEAD 2>/dev/null || { git -C "$1" rev-parse --verify -q HEAD >/dev/null 2>&1 && echo "DETACHED" || echo "unknown"; }; }
dirty_of()  { local o; o=$(git -C "$1" status --porcelain --untracked-files=normal 2>/dev/null) || { echo "unknown"; return; }; printf '%s' "$o" | grep -c . || true; }
age_days()  { local t; t=$(git -C "$1" log -1 --format=%ct 2>/dev/null) && [ -n "$t" ] && echo $(( (NOW - t) / 86400 )) || echo "unknown"; }
upstream_of() {  # pushed | ahead=N | never-pushed | detached | unknown. "pushed" needs a remote-tracking ref of the same branch name.
  local d="$1" b u n
  b=$(branch_of "$d")
  case "$b" in DETACHED) echo "detached"; return ;; unknown) echo "unknown"; return ;; esac
  u=$(git -C "$d" rev-parse --symbolic-full-name '@{upstream}' 2>/dev/null) || u=""
  case "$u" in refs/remotes/*/"$b") ;; *) u="refs/remotes/origin/$b" ;; esac   # a local or renamed upstream (-b x origin/main) is not proof of a push
  git -C "$d" show-ref --verify --quiet "$u" 2>/dev/null || { echo "never-pushed"; return; }
  n=$(git -C "$d" rev-list --count "$u..HEAD" 2>/dev/null) || { echo "unknown"; return; }
  [ "$n" = "0" ] && echo "pushed" || echo "ahead=$n"
}
local_refs() {  # "<branches>b <stashes>s <tags>t", evidence that a clone holds work beyond HEAD; "?" when git failed
  local d="$1" b s t
  if b=$(git -C "$d" for-each-ref --format=x refs/heads 2>/dev/null); then b=$(printf '%s' "$b" | grep -c . || true); else b="?"; fi
  if s=$(git -C "$d" stash list 2>/dev/null); then s=$(printf '%s' "$s" | grep -c . || true); else s="?"; fi
  if t=$(git -C "$d" for-each-ref --format=x refs/tags 2>/dev/null); then t=$(printf '%s' "$t" | grep -c . || true); else t="?"; fi
  echo "${b}b ${s}s ${t}t"
}
mr_of() {  # open MR/PR count for a branch; only with --mr; "unchecked" when no CLI or it fails; "-" otherwise
  [ "$CHECK_MR" = 1 ] || { echo "-"; return; }
  local d="$1" b="$2" host="$3" out
  case "$b" in DETACHED|unknown) echo "-"; return ;; esac
  case "$host" in
    gitlab*) command -v glab >/dev/null 2>&1 && out=$(cd "$d" && glab mr list --source-branch "$b" -F json 2>/dev/null) && { printf '%s' "$out" | grep -o '"iid"' | grep -c . || true; return; } ;;
    github*) command -v gh   >/dev/null 2>&1 && out=$(cd "$d" && gh pr list --head "$b" --state open --json number -q length 2>/dev/null) && { echo "$out"; return; } ;;
  esac
  echo "unchecked"
}

# ---- worktrees from a repo's own registry; states: ok | locked | missing | prunable | unknown (git failed) ----
WT_ROWS=()
scan_worktrees() {  # $1 main dir, $2 label, $3 host. Appends rows; sets W_COUNT = linked worktrees, or "?" when git failed
  local d="$1" main="$2" host="$3" mainname out line p br prun lock state want rest place up dirty age mr
  mainname=$(basename "$d"); W_COUNT=0
  out=$(git -C "$d" worktree list --porcelain 2>/dev/null) || { W_COUNT="?"; WT_ROWS+=("$(printf '%s\t?\t-\tunknown\t-\t-\t-\t-\t-' "$main")"); return; }
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
        W_COUNT=$((W_COUNT+1))
        if [ -n "$lock" ]; then state="locked"
        elif [ -n "$prun" ]; then state="prunable"
        elif [ ! -d "$p" ]; then state="missing"
        else state="ok"; fi
        want="$ROOT/$WT_DIR/$mainname/"
        case "$p" in
          */.claude/worktrees/*) place="harness" ;;   # managed by an agent harness: report only
          "$want"*) rest=${p#"$want"}; case "$rest" in */*|"") place="OUTSIDE-$WT_DIR" ;; *) place="in" ;; esac ;;
          "$ROOT/"*) place="OUTSIDE-$WT_DIR" ;;
          *) place="OUTSIDE-root" ;;
        esac
        if { [ "$state" = "ok" ] || [ "$state" = "locked" ]; } && [ -d "$p" ]; then
          up=$(upstream_of "$p"); dirty=$(dirty_of "$p"); age=$(age_days "$p"); mr=$(mr_of "$p" "$br" "$host")
        else up="-"; dirty="-"; age="-"; mr="-"; fi
        WT_ROWS+=("$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' "$main" "$(rel "$p")" "$br" "$state" "$place" "$dirty" "$up" "$age" "$mr")")
        p="" ;;
    esac
  done < <(printf '%s\n\n' "$out")
}

# ---- scan: main repos (.git dirs) and worktrees whose main repo is outside ROOT (.git files) ----
REPOS=(); EXTERNAL_WT=(); UNSCANNED=(); PLAIN=(); HIDDEN=(); LOOSE=()
while IFS= read -r g; do
  d=${g%/.git}; [ "$d" = "$ROOT" ] && continue
  r=${d#"$ROOT"/}; slashes=${r//[!\/]/}
  if [ $(( ${#slashes} + 1 )) -gt "$MAXDEPTH" ]; then [ -d "$g" ] && UNSCANNED+=("$d"); continue; fi
  if [ -d "$g" ]; then REPOS+=("$d")
  elif [ -f "$g" ]; then
    common=$(git -C "$d" rev-parse --git-common-dir 2>/dev/null) || continue
    case "$common" in /*) ;; *) common="$d/$common" ;; esac
    case "$(cd "$common" 2>/dev/null && pwd -P)" in "$ROOT"/*) ;; *) EXTERNAL_WT+=("$d") ;; esac
  fi
done < <(find "$ROOT" -mindepth 1 -maxdepth $((MAXDEPTH+3)) -name node_modules -prune -o -name .git -print 2>/dev/null | sort)
while IFS= read -r p; do
  [ "$p" = "$ROOT/$DOCS_DIR" ] && continue
  [ -n "$(find "$p" -maxdepth 4 -name .git -print -quit 2>/dev/null)" ] && continue
  case "$(basename "$p")" in .*) [ "$p" = "$ROOT/$WT_DIR" ] || [ "$p" = "$ROOT/.git" ] || [ "$p" = "$ROOT/.claude" ] || HIDDEN+=("$p") ;; *) PLAIN+=("$p") ;; esac
done < <(find "$ROOT" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
while IFS= read -r f; do
  case "$(basename "$f")" in README.md|CLAUDE.md|AGENTS.md|workspace.conf|.gitignore|.DS_Store|.git) continue ;; esac
  LOOSE+=("$f")
done < <(find "$ROOT" -mindepth 1 -maxdepth 1 -type f 2>/dev/null | sort)

# ---- one pass per repo: remote, its worktrees, then the row ----
# row fields: path host group name key branch default dirty upstream age mr expected refs
ROWS=()
if [ -e "$ROOT/.git" ]; then   # the root may itself be a small repo; list its worktrees under main "."
  url=$(git -C "$ROOT" remote get-url origin 2>/dev/null) || url=""; parse_remote "$url"; scan_worktrees "$ROOT" "." "$R_HOST"
fi
for d in ${REPOS[@]+"${REPOS[@]}"}; do
  # an unreadable .git makes git fall through to a parent repo; only trust it when the toplevel is this folder
  if [ "$(git -C "$d" rev-parse --show-toplevel 2>/dev/null)" != "$d" ]; then
    ROWS+=("$(printf '%s\tbroken\t.\tunknown\tbroken/./unknown\t-\t-\t-\t-\t-\t-\t-\t-' "$(rel "$d")")"); continue
  fi
  if url=$(git -C "$d" remote get-url origin 2>/dev/null); then parse_remote "$url"; else parse_remote ""; fi
  b=$(branch_of "$d")
  scan_worktrees "$d" "$(rel "$d")" "$R_HOST"
  case "$R_HOST" in unknown|broken|file) exp="-" ;; *) exp="$(group_for "$R_GROUP")/$R_NAME" ;; esac
  ROWS+=("$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
    "$(rel "$d")" "$R_HOST" "${R_GROUP:-.}" "$R_NAME" "$R_HOST/$R_GROUP/$R_NAME" "$b" "$(default_branch "$d")" \
    "$(dirty_of "$d")" "$(upstream_of "$d")" "$(age_days "$d")" "$(mr_of "$d" "$b" "$R_HOST")" \
    "$exp" "$(local_refs "$d") ${W_COUNT}w")")
done

echo "## repos (${#ROWS[@]})"
{ printf 'path\thost\tgroup\tname\tbranch\tdefault\tdirty\tupstream\tage_d\tmr\texpected\trefs\n'
  for r in ${ROWS[@]+"${ROWS[@]}"}; do printf '%s\n' "$r" | awk -F"$TAB" 'BEGIN{OFS="\t"} {print $1,$2,$3,$4,$6,$7,$8,$9,$10,$11,$12,$13}'; done; } | fmt
for d in ${EXTERNAL_WT[@]+"${EXTERNAL_WT[@]}"}; do echo "worktree of a repo outside this workspace: $(rel "$d")"; done

echo; echo "## worktrees (${#WT_ROWS[@]}, registered by the repos above)"
{ printf 'main\tworktree\tbranch\tstate\tplace\tdirty\tupstream\tage_d\tmr\n'; for r in ${WT_ROWS[@]+"${WT_ROWS[@]}"}; do printf '%s\n' "$r"; done; } | fmt

# ---- drift: everything that breaks the layout rule ----
echo; echo "## drift"
n=0
for r in ${ROWS[@]+"${ROWS[@]}"}; do
  IFS="$TAB" read -r path host group name key b def dirty up age mr exp refs < <(printf '%s\n' "$r")
  case "$host" in
    broken)  echo "git cannot read this repo, check by hand: $path"; n=$((n+1)); continue ;;
    unknown) echo "no origin remote, cannot place: $path"; n=$((n+1)); continue ;;
  esac
  [ "$(basename "$path")" != "$name" ] && { echo "folder name != remote name: $path (remote: $name)"; n=$((n+1)); }
  [ "$exp" != "-" ] && [ "$path" != "$exp" ] && { echo "not at expected path: $path -> $exp"; n=$((n+1)); }
done
DUPES=$(for r in ${ROWS[@]+"${ROWS[@]}"}; do printf '%s\n' "$r" | awk -F"$TAB" 'BEGIN{OFS="\t"} $2!="unknown" && $2!="broken" {print $5,$1}'; done \
  | awk -F"$TAB" '{paths[$1]=paths[$1] (paths[$1]?", ":"") $2; c[$1]++} END {for (k in c) if (c[k]>1) print k": "paths[k]}' | sort)
[ -n "$DUPES" ] && while IFS= read -r line; do echo "duplicate clones of $line"; n=$((n+1)); done < <(printf '%s\n' "$DUPES")
for r in ${WT_ROWS[@]+"${WT_ROWS[@]}"}; do
  IFS="$TAB" read -r main p br state place dirty up age mr < <(printf '%s\n' "$r")
  case "$state" in
    unknown)  echo "git worktree list failed, check by hand: $main"; n=$((n+1)) ;;
    prunable) echo "dead worktree link (git says prunable): $main -> $p"; n=$((n+1)) ;;
    missing)  echo "worktree folder missing, not marked prunable (unmounted? check before prune): $main -> $p"; n=$((n+1)) ;;
    *) case "$place" in in|harness) ;; *) echo "worktree outside $WT_DIR/<repo>/<slug>: $p ($main, $br)"; n=$((n+1)) ;; esac ;;
  esac
done
for p in ${UNSCANNED[@]+"${UNSCANNED[@]}"}; do echo "repo deeper than $MAXDEPTH levels, not scanned: $(rel "$p")"; n=$((n+1)); done
for p in ${PLAIN[@]+"${PLAIN[@]}"};   do echo "plain folder (no repo inside): $(rel "$p")"; n=$((n+1)); done
for p in ${HIDDEN[@]+"${HIDDEN[@]}"}; do echo "hidden folder at root (tool state? report only): $(rel "$p")"; n=$((n+1)); done
for f in ${LOOSE[@]+"${LOOSE[@]}"};   do echo "loose file at root: $(rel "$f")"; n=$((n+1)); done
echo "drift items: $n"

# ---- cleanup candidates: evidence only. Locked, dirty, unpushed, detached, harness, open-MR or unknown are never listed. ----
echo; echo "## cleanup candidates (evidence only, nothing is removed)"
for r in ${WT_ROWS[@]+"${WT_ROWS[@]}"}; do
  IFS="$TAB" read -r main p br state place dirty up age mr < <(printf '%s\n' "$r")
  [ "$place" = "harness" ] && continue
  case "$state" in
    prunable) echo "prune (dead link, git-confirmed): $main -> $p"; continue ;;
    ok) ;;
    *) continue ;;
  esac
  case "$mr" in 0|-) ;; *) continue ;; esac   # open MR, or MR check failed under --mr
  [ "$dirty" = "0" ] && [ "$up" = "pushed" ] && [ "$age" -ge 14 ] 2>/dev/null && echo "stale worktree, clean, pushed, last commit ${age}d ago: $p ($br)"
done
for r in ${ROWS[@]+"${ROWS[@]}"}; do
  IFS="$TAB" read -r path host group name key b def dirty up age mr exp refs < <(printf '%s\n' "$r")
  [ "$dirty" = "0" ] && [ "$up" = "pushed" ] || continue
  case "$refs" in *\?*) continue ;; esac                                   # a ref count failed: untouchable
  if [ "${refs##* }" = "0w" ] && printf '%s\n' "$DUPES" | awk -F': ' -v k="$key" '$1==k {f=1} END {exit !f}' && [ "$(basename "$path")" != "$name" ]; then
    echo "duplicate clone, review before removal (clean, HEAD pushed, no linked worktrees, holds $refs): $path"
  fi
  [ "$age" -ge 90 ] 2>/dev/null && echo "idle repo, ${age}d since last commit (archive candidate): $path"
done
echo "locked, dirty, unpushed, detached, harness-managed, open-MR or unknown items are never candidates. Removal needs the user's explicit word per item."
