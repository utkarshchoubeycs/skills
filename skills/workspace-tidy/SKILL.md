---
name: workspace-tidy
description: "Arrange and keep tidy a folder that holds many git repos and worktrees. Use when the user asks to organise, clean up, audit or de-duplicate a multi-repo workspace, add a repo or worktree to one, find where a repo lives, or list stale worktrees. Rules: one folder per remote group, folder name = remote repo name, every worktree under one hidden dir, non-repo files under docs/. Never deletes without the user's explicit word."
license: MIT
compatibility: "bash 3.2+, git 2.17+; optional column(1), glab or gh for --mr"
---

# workspace-tidy

A workspace is one folder that holds many git repos. Over time it collects worktrees beside the
repos, clones of the same repo under different names, and loose files. This skill gives the
workspace one layout rule and one read-only audit, and it moves things into place on request.

## When not to use

- A single repo. Use a plain worktree skill such as superpowers `using-git-worktrees`.
- Worktrees that an agent harness manages itself (for example `.claude/worktrees/agent-*`).
  Report them, never move or remove them.
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
slug. Resolve by hand with a suffix and note it.

Why remote namespace and not architecture layers: layers live inside a service, not across
repos. A repo's layer changes; its remote group does not. The rule needs no judgement.

## workspace.conf

Plain `key value` lines, first two whitespace-separated fields only. Read with awk, never
sourced. Missing file means defaults: `worktrees .worktrees`, `docs docs`, `root-group root`.

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
nearest ancestor of the current dir that holds `workspace.conf`, else ask. Call it `$WS`.
The script lives beside this file: `$SKILL_DIR/scripts/audit.sh`.

### Audit (read-only, always first)

```
bash "$SKILL_DIR/scripts/audit.sh" "$WS"         # no network
bash "$SKILL_DIR/scripts/audit.sh" "$WS" --mr    # also count open MRs/PRs via glab or gh
```

Four sections: repos, worktrees, drift, cleanup candidates. Read the drift list with the user
before any move. Any `unknown` value means git failed there; treat that item as untouchable
until the user looks at it. With `--mr`, glab or gh may write their own config files; the
script itself never writes.

### Arrange an existing workspace

1. Run the audit. Build two tables for the user: **renames** (today → proposed, one row per
   repo and per worktree) and **deletes** (item → evidence). The user vetoes renames and
   names each delete. Nothing moves before that answer.
2. Precondition check, stop on any hit: a destination path that already exists; a repo or
   worktree with `dirty` not `0`; any `unknown`; any worktree in state `missing`; a `locked`
   worktree. Show the hits and ask.
3. Create the group folders and `docs/`.
4. Move each main repo with `mv <old> <new>`. Worktrees nested inside it move with it; that
   is the one case where a worktree moves by `mv`. Then inside the moved repo run
   `git worktree repair <new-path-of-each-nested-worktree>`, then a bare
   `git worktree repair`. Verify with `git worktree list`: no `prunable` lines.
5. Move each remaining worktree with `git worktree move <old> "$WS/.worktrees/<repo>/<slug>"`,
   never `mv`.
6. Move loose files and plain folders into `docs/`. Never overwrite: if the target exists,
   stop and ask.
7. Write `README.md`, `CLAUDE.md`, `workspace.conf`. If any of them exists, keep its content
   and add to it. Run the audit again. Drift must be zero except items the user chose to keep.
8. Tell the user which tool configs held absolute paths (editor workspaces, agent project
   lists, shell bookmarks). The audit does not touch them.

### Add a repo

Clone to `$WS/<group-folder>/<remote-name>`, the path the audit's `expected` column would
give. Never pick a name by hand. If the path exists, stop and ask.

### Add a worktree

```
git -C "$WS/<group>/<repo>" worktree add "$WS/.worktrees/<repo>/<slug>" -b <branch> <start-point>
```

Use an absolute path, never `..`. `<start-point>` is `origin/<default-branch>` after a
`git fetch`, unless the user names one. If the branch already exists, drop `-b`. If the
destination exists, stop and ask. Verify with `git worktree list`. If the workspace `CLAUDE.md`
declares the worktree dir, use it without asking.

### Clean up

The audit lists candidates with evidence. Never list, and never touch: locked, dirty,
unpushed, detached, missing or `unknown` items. For each candidate the user approves:

| Candidate | Command | Then |
|---|---|---|
| stale worktree | `git worktree remove <path>` | offer `git branch -d <branch>` as a second yes; if git refuses, stop, never `-D`. Offer remote branch delete as a third yes. |
| dead link (prunable) | show `git worktree prune --dry-run` for that repo; the user approves the whole preview, since prune cannot take one path | `git worktree prune`, then show `git worktree list` |
| duplicate clone | show its local branches, stashes and tags first (`refs` column) | `rm -r <path>` only after the user confirms those are disposable |
| idle repo | none | report only; archiving is the user's call |

## Hard stops

- No delete, no branch removal, no `--force`, no prune without the user naming the item or
  approving the exact prune preview.
- Locked, dirty, unpushed, detached, missing or `unknown` items are never moved or removed.
- Worktrees move with `git worktree move`. The only exception is a worktree nested inside a
  main repo that moves as a whole, followed by `git worktree repair`.
- Never overwrite an existing path. Stop and ask.
- The audit script is read-only. Keep it that way.
- Workspace-specific facts (groups, names, standards) live in `workspace.conf` and the
  workspace `README.md`, never in this skill.
