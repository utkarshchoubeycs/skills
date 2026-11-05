# workspace-tidy

One layout rule and one read-only audit for a folder full of git repos and worktrees.

| Before | After |
|---|---|
| 70+ folders at root, 8 hidden `.wt-*`, three clones of one service under three names, diagrams loose beside repos | 7 group folders, every worktree under `.worktrees/`, every note under `docs/`, one README that says where things are |

## The rule

```
<workspace>/
  README.md  CLAUDE.md  workspace.conf
  platform/      auth-service  billing  go-commons
  platform-v2/   auth-service-v2  go-commons-v2
  legacy/        clinical-workflow  old-scheduler
  docs/          diagrams/  notes/  security/
  .worktrees/    auth-service/feat-webhooks  go-commons-v2/fix-routes
```

1. Folder name = remote repo name.
2. Group folder = remote group (`gitlab.com/acme/platform/auth` lives at `platform/auth`).
3. Worktrees live only in `.worktrees/<repo>/<branch-slug>/`.
4. Everything that is not a repo lives in `docs/`.

Why not clean-architecture layers across repos: a repo's layer is a judgement call that changes.
Its remote group is a fact that does not.

## Install

```
npx skills add utkarshchoubeycs/skills --skill workspace-tidy
```

Or copy this folder to `~/.claude/skills/workspace-tidy/`. Claude Code picks it up on the next session. Then ask: "audit my workspace", "arrange this
workspace", "add a worktree for feat/x", "which worktrees are stale".

## Audit only, no agent

```
bash ~/.claude/skills/workspace-tidy/audit.sh ~/my-workspace
bash ~/.claude/skills/workspace-tidy/audit.sh ~/my-workspace --mr   # adds open MR/PR counts via glab or gh (untested)
```

Output: four sections.

| Section | Columns |
|---|---|
| repos | path, host, group, name, branch, default branch, dirty files, upstream state, days since last commit, open MRs, expected path |
| worktrees | main repo, path, branch, state (ok or dead), placement, dirty, upstream, age |
| drift | wrong folder name, wrong path, worktree outside `.worktrees/`, dead link, plain folder, loose file |
| cleanup candidates | dead worktree links; clean + pushed worktrees 14 days old; extra clones of a remote already present (dead copies); repos idle 90 days. Never dirty, unpushed or detached. Evidence only, it removes nothing |

The script is read-only. It runs on macOS bash 3.2 and any Linux bash. No network unless `--mr`.

## Per-workspace config

`workspace.conf` at the workspace root, plain `key value` lines, never sourced:

```
worktrees  .worktrees
docs       docs
root-group legacy
group  acme/platform     platform
group  acme/platform-v2  platform-v2
group  oldcorp           legacy
```

See `examples/workspace.conf`.

## What it will not do

Delete, prune, force, or remove a branch on its own. Every removal is one item the user names.

## Credits

Ideas borrowed from the virtual-workspace, git-wt and WalletConnect worktree skills:
a manifest at the root, worktrees outside the repo, `git worktree move` over `mv`,
and remote-branch deletion as a separate opt-in.

## Licence

MIT
