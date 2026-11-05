---
name: workspace-tidy
description: "Arrange and keep tidy a folder that holds many git repos and worktrees. Use when the user asks to organise, clean up, audit or de-duplicate a multi-repo workspace, add a repo or worktree to one, find where a repo lives, or list stale worktrees. Rules: one folder per remote group, folder name = remote repo name, every worktree under one hidden dir, non-repo files under docs/. Never deletes without the user's explicit word."
---

# workspace-tidy

A workspace is one folder that holds many git repos. Over time it collects worktrees beside the
repos, clones of the same repo under different names, and loose files. This skill gives the
workspace one layout rule and one read-only audit, and it moves things into place on request.

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
2. **Group = remote group.** `gitlab.com/acme/platform/auth.git` lives at `platform/auth/`.
   `workspace.conf` can map a remote group to a different folder, for example a sibling owner
   to `legacy/`. Repos with no subgroup go to the folder named by the `root-group` key.
3. **Worktrees live in one hidden dir**, `.worktrees/<repo>/<branch-slug>/`, where the slug is
   the branch name with `/` replaced by `-`. One worktree stays on one branch for its whole life.
4. **Non-repo files go to `docs/`.** Nothing loose at root except the four files above.
5. **The root may be a small git repo** that tracks only `README.md`, `CLAUDE.md`,
   `workspace.conf` and `docs/`, and ignores every repo folder and `.worktrees/`. This gives
   diagrams and notes a history. Optional.

Why remote namespace and not architecture layers: layers live inside a service, not across
repos. A repo's layer changes; its remote group does not. The rule needs no judgement.

## workspace.conf

Plain `key value` lines. The audit reads it with awk and never sources it.

```
worktrees  .worktrees
docs       docs
root-group legacy
group  acme/platform      platform
group  acme/platform-v2   platform-v2
group  oldcorp            legacy
```

`group <remote-group> <folder>` matches the remote group exactly or as a prefix, so
`acme/platform/foundation/sdk` lands at `platform/foundation/sdk`.

## Procedures

### Audit (read-only, always first)

```
bash audit.sh <workspace>         # no network
bash audit.sh <workspace> --mr    # also count open MRs/PRs per branch via glab or gh
```

It prints four sections: repos, worktrees, drift, cleanup candidates. Read the drift list
with the user before any move. Counts to sanity-check: repos found vs folders the user expects,
dead worktree links, nested clones inside other repos.

### Arrange an existing workspace

1. Run the audit. Build two tables for the user: **renames** (today → proposed) and
   **deletes** (item → evidence). The user vetoes renames and names each delete. Nothing moves
   before that answer.
2. Create the group folders and `docs/`.
3. Move main repos with plain `mv`, then inside each moved repo run
   `git worktree repair <path-of-each-worktree-that-moved-with-it>` for worktrees nested
   inside the repo (both sides of their link went stale), then a bare `git worktree repair`
   for the rest. Every worktree must exist on disk when repair runs.
4. Move worktrees with `git worktree move <old> <new>`, never `mv`. Target is
   `.worktrees/<repo>/<branch-slug>/`.
5. Move loose files and plain folders into `docs/`.
6. Write `README.md`, `CLAUDE.md`, `workspace.conf`. Run the audit again. Drift must be zero
   except items the user chose to keep.
7. Tell the user which tool configs held absolute paths (editor workspaces, agent project
   lists, shell bookmarks). The audit does not touch them.

### Add a repo

Clone to the path the rule gives: `<group-folder>/<remote-name>`. Never pick a name by hand.

### Add a worktree

`git -C <repo> worktree add ../.worktrees/<repo>/<slug> -b <branch>` (adjust `..` to reach the
workspace root). If the workspace `CLAUDE.md` declares the dir, use it without asking.

### Clean up

The audit lists candidates with evidence: dead links, and worktrees that are clean, pushed,
and older than 14 days. Dirty, unpushed, detached or locked worktrees are never candidates.
For each candidate the user approves: `git worktree remove <path>`, then offer the local
branch delete as a separate yes, then offer the remote branch delete as a third yes.
Dead links: `git worktree prune` after showing `git worktree prune --dry-run`.

## Hard stops

- No delete, no branch removal, no `--force`, no prune without the user naming the item.
- Dirty or unpushed worktrees are never moved or removed without the user seeing the status.
- Worktrees move with `git worktree move`, never `mv`.
- The audit script is read-only. Keep it that way.
- Workspace-specific facts (groups, names, standards) live in `workspace.conf` and the
  workspace `README.md`, never in this skill.
