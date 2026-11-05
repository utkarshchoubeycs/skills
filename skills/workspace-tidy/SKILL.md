---
name: workspace-tidy
description: "Arranges and keeps tidy a folder that holds many git repos and worktrees. Use when the user asks to organise, clean up, audit or de-duplicate a multi-repo workspace, add a repo or worktree to one, find where a repo lives, or list stale worktrees. Rules: one folder per remote group, folder name = remote repo name, every worktree under one hidden dir, non-repo files under docs/. Never deletes without the user's explicit word."
license: MIT
compatibility: "bash 3.2+, git 2.31+; optional column(1), glab or gh for --mr"
---

# workspace-tidy

A workspace is one folder that holds many git repos. Over time it collects worktrees beside the
repos, clones of the same repo under different names, and loose files. This skill gives the
workspace one layout rule and one read-only audit, and it moves things into place on request.

## When not to use

- A single repo. Use a plain worktree skill such as superpowers `using-git-worktrees`, or the
  harness's own worktree tool (Claude Code `EnterWorktree`) when the user wants a scratch
  worktree for an agent.
- Worktrees that an agent harness manages itself (for example `.claude/worktrees/agent-*`).
  The audit labels them `harness`. Report them, never move or remove them.
- Git submodules. The audit lists them like any repo; moving them is out of scope.

## The layout

```
<workspace>/
  README.md            what lives where, one table
  CLAUDE.md            one line: worktrees go in .worktrees/<repo>/<branch-slug>
  workspace.conf       group mapping and dir names (see below)
  <group>/<repo>/      one folder per remote group, folder name = remote repo name
  docs/                diagrams, notes, reports, seeds: everything that is not a repo
  .worktrees/<repo>/<branch-slug>/   every worktree of every repo, nothing at root
```

Rules, in order of priority:

1. **Folder name = remote repo name.** `git remote get-url origin` decides, not the human.
   A repo with no origin cannot be placed; the audit reports it and the user decides.
2. **Group = remote group.** `gitlab.com/acme/platform/auth.git` lives at `platform/auth/`.
   `workspace.conf` maps a remote group to a different folder. Repos with no subgroup go
   to the folder named by `root-group`.
3. **Worktrees live in one hidden dir**, `.worktrees/<repo>/<branch-slug>/`, where `<repo>`
   is the main repo's folder name and the slug is the branch name with `/` replaced by `-`.
   One worktree stays on one branch for its whole life.
4. **Non-repo files go to `docs/`.** Root holds only `README.md`, `CLAUDE.md`,
   `workspace.conf`, and optionally `AGENTS.md` and `.gitignore`.
5. **The root may be a small git repo** that tracks only those files and `docs/`, and ignores
   every repo folder and `.worktrees/`. Optional.

Known limits, declare them in the workspace README when they apply: two repos with the same
name in different groups share a worktree folder name; branches `feat/x` and `feat-x` share a
slug. Resolve by hand with a suffix and note it. The audit scans 5 folder levels and skips
`node_modules`; deeper repos are listed as unscanned.

Why remote namespace and not architecture layers: layers live inside a service, not across
repos. A repo's layer changes; its remote group does not. The rule needs no judgement.

## workspace.conf

Plain `key value` lines, first two whitespace-separated fields only. Read with awk, never
sourced. Missing file means defaults: `worktrees .worktrees`, `docs docs`, `root-group root`.
Every value must be a relative path with no `..`; the audit refuses the file otherwise.

```
worktrees  .worktrees
docs       docs
root-group legacy
group  acme/platform      platform
group  acme/platform-v2   platform-v2
group  oldcorp            legacy
```

`group <remote-group> <folder>` matches the remote group exactly or as a prefix. The longest
matching prefix wins, and the remainder is kept: `acme/platform/foundation/sdk` lands at
`platform/foundation/sdk`. Set `WORKSPACE_CONF=<path>` to audit with a conf that is not in
place yet.

## Procedures

Every procedure starts by fixing the workspace root once: the folder the user names, else the
nearest ancestor of the current dir that holds `workspace.conf`, else the current dir. Say
which one you picked. Call it `$WS`. In the commands below, `.worktrees` and `docs` stand for
the values in `workspace.conf`.

The audit script is in the `scripts/` folder beside this file. In Claude Code that is
`${CLAUDE_SKILL_DIR}/scripts/audit.sh`; other harnesses: resolve the path of this SKILL.md.

### Audit (read-only, always first)

```
bash "${CLAUDE_SKILL_DIR}/scripts/audit.sh" "$WS"         # no network
bash "${CLAUDE_SKILL_DIR}/scripts/audit.sh" "$WS" --mr    # also count open MRs/PRs via glab or gh
```

Four sections: repos, worktrees, drift, cleanup candidates. Read the drift list with the user
before any move. Any `unknown`, `broken` or `?` value means git failed there; treat that item
as untouchable until the user looks at it. With `--mr`, glab or gh may write their own config
files; the script itself never writes.

### Arrange an existing workspace

1. Run the audit and keep its output as the baseline (it goes into `docs/` at step 6). Build
   two tables for the user: **renames** (today → proposed, one row per repo and per worktree)
   and **deletes** (item → evidence). In worktree targets `<repo>` is the main repo's folder
   name **after** its rename. A `DETACHED` worktree has no slug: list it, ask. The user vetoes
   renames and names each delete. Nothing moves before that answer.
2. Precondition check, stop on any hit and ask: a destination path that already exists, or has
   an ancestor that is itself a repo; a repo or worktree with `dirty` not `0`; any `unknown`,
   `broken` or `?`; any worktree in state `missing`; a `locked` worktree. An untracked folder
   that is a registered worktree of that repo does not count as dirty. A pre-existing
   `prunable` link is a cleanup candidate, not a stop.
3. Create the group folders, `docs/`, and `mkdir -p "$WS/.worktrees/<repo>"` for every repo
   that gets a worktree (`git worktree move` does not create parents).
4. Move each main repo with `mv <old> <new>`. Worktrees nested inside it move with it; that
   is the one case where a worktree moves by `mv`. Then inside the moved repo run
   `git worktree repair <new-path-of-each-nested-worktree>`, then a bare
   `git worktree repair`. Verify with `git worktree list`: no **new** `prunable` lines.
5. Move each remaining worktree whose place is not `in` or `harness`:
   `git -C "$WS/<group>/<repo>" worktree move <old> "$WS/.worktrees/<repo>/<slug>"`, never `mv`.
6. Move loose files and plain folders into `docs/`. Hidden folders at root: report only.
   Never overwrite: if the target exists, stop and ask.
7. Write `README.md`, `CLAUDE.md`, `workspace.conf`. If any of them exists, keep its content
   and add to it. If the root is a git repo, check every group folder and `.worktrees/` with
   `git -C "$WS" check-ignore -q <path>` and add the misses to `.gitignore`. Run the audit
   again. Drift must be zero except items the user chose to keep.
8. Tell the user which tool configs held absolute paths (editor workspaces, agent project
   lists, shell bookmarks). The audit does not touch them.

### Add a repo

Clone to `$WS/<group-folder>/<remote-name>`, the path the audit's `expected` column would
give. Never pick a name by hand. If the path exists, stop and ask.

### Add a worktree

New branch, after `git -C "$WS/<group>/<repo>" fetch`:

```
git -C "$WS/<group>/<repo>" worktree add "$WS/.worktrees/<repo>/<slug>" -b <branch> origin/<default-branch>
```

Branch already exists (no `-b`, no start point):

```
git -C "$WS/<group>/<repo>" worktree add "$WS/.worktrees/<repo>/<slug>" <branch>
```

Use an absolute path, never `..`. If the destination exists, stop and ask. Verify with
`git worktree list`. If the workspace `CLAUDE.md` declares the worktree dir, use it without
asking. A branch created from `origin/<default>` is not pushed until the user pushes it; the
audit says `never-pushed` until a remote branch of the same name exists.

### Clean up

The audit lists candidates with evidence. Never list, and never touch: locked, dirty,
unpushed, detached, missing, harness, open-MR or `unknown` items. For each candidate the user
approves:

| Candidate | Command | Then |
|---|---|---|
| stale worktree | `git -C <main> worktree remove <path>` | offer `git -C <main> branch -d <branch>` as a second yes; if git refuses, stop, never `-D`. Offer `git -C <main> push origin --delete <branch>` as a third yes. |
| dead link (prunable) | show `git -C <main> worktree prune --dry-run`; the user approves the whole preview, since prune cannot take one path | `git -C <main> worktree prune`, then show `git -C <main> worktree list` |
| duplicate clone | run `git -C <clone> worktree list`: any line besides the clone itself → stop. Then show its local branches, stashes and tags (`refs` column) | `rm -r <path>` only after the user confirms those are disposable. Git objects are read-only files, so an interactive `rm -r` prompts per file; answer the prompts or run it non-interactively, never add `-f` by reflex |
| idle repo | none | report only; archiving is the user's call |

## Hard stops

- No delete, no branch removal, no `--force`, no prune without the user naming the item or
  approving the exact prune preview.
- Locked, dirty, unpushed, detached, missing, harness-managed or `unknown` items are never
  moved or removed.
- Worktrees move with `git worktree move`. The only exception is a worktree nested inside a
  main repo that moves as a whole, followed by `git worktree repair`.
- Never overwrite an existing path. Stop and ask.
- The audit script is read-only. Keep it that way.
- Workspace-specific facts (groups, names, standards) live in `workspace.conf` and the
  workspace `README.md`, never in this skill.
