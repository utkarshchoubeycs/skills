# workspace-tidy

One layout rule and one read-only audit for a folder full of git repos and worktrees.

| Before | After |
|---|---|
| 70+ folders at root, 8 hidden `.wt-*`, three clones of one service under three names, diagrams loose beside repos | 7 group folders, every worktree under `.worktrees/`, every note under `docs/`, one README that says where things are |

## The rule

```
<workspace>/
  README.md  CLAUDE.md  workspace.conf
  platform/      auth-service  billing  shared-libs
  platform-v2/   auth-service-v2  shared-libs-v2
  legacy/        old-portal  old-scheduler
  docs/          diagrams/  notes/  security/
  .worktrees/    auth-service/feat-webhooks  shared-libs-v2/fix-routes
```

1. Folder name = remote repo name.
2. Group folder = remote group (`gitlab.com/acme/platform/auth` lives at `platform/auth`).
3. Worktrees live only in `.worktrees/<repo>/<branch-slug>/`.
4. Everything that is not a repo lives in `docs/`.

Why not clean-architecture layers across repos: a repo's layer is a judgement call that changes.
Its remote group is a fact that does not.

## Install

```
npx skills add utkarshchoubeycs/skills --skill workspace-tidy -g    # user-wide
npx skills add utkarshchoubeycs/skills --skill workspace-tidy       # this project only
```

Needs Node 22.20+. The installer asks which agent to install for; add `-a claude-code -y` to skip
the prompt.

Or copy this folder to `~/.claude/skills/workspace-tidy/`. Claude Code picks it up on the next
session. Then ask: "audit my workspace", "arrange this workspace", "add a worktree for feat/x",
"which worktrees are stale".

## Audit only, no agent

```
bash ~/.claude/skills/workspace-tidy/scripts/audit.sh ~/my-workspace
bash ~/.claude/skills/workspace-tidy/scripts/audit.sh ~/my-workspace --mr   # adds open MR/PR counts via glab or gh
```

Needs bash 3.2+ and git 2.31+ (it refuses older git: `locked` and `prunable` worktree states
need 2.31). Scans 5 folder levels, skips `node_modules`. Uses `column` for alignment when
present, plain tabs otherwise.

| Section | Columns |
|---|---|
| repos | path, host, group, name, branch, default branch, dirty files, upstream state, days since last commit, open MRs, expected path, refs (local branches, stashes, tags, linked worktrees) |
| worktrees | main repo, path, branch, state (ok, locked, missing, prunable, unknown), placement (in, harness, outside), dirty, upstream, age, open MRs, note (`default-branch`) |
| drift | unreadable repo, no origin, wrong folder name, wrong path, duplicate clones, worktree outside `.worktrees/<repo>/<slug>`, dead or missing link, unscanned deep repo, plain folder, hidden folder, loose file |
| cleanup candidates | git-confirmed dead links; clean + pushed worktrees whose last commit is 14 days old; duplicate clones with no linked worktrees, local refs listed; repos idle 90 days. Locked, dirty, unpushed, detached, harness-managed, open-MR or unknown items never appear. Evidence only, it removes nothing |

The script sets `GIT_OPTIONAL_LOCKS=0` and runs only read commands. `pushed` means a remote
branch of the same name exists and holds HEAD; a branch that only tracks `origin/main` reads
`never-pushed`. With `--mr`, glab or gh may write their own config on first use; in repos with
`core.fsmonitor` on, `git status` may start the monitor daemon. Any `unknown`, `broken` or `?`
value means git failed for that item.

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

Longest matching `group` prefix wins. See `examples/workspace.conf`.

## What it will not do

Delete, prune, force, or remove a branch on its own. Every removal is one item the user names,
or one exact prune preview the user approves.

## Credits

Ideas borrowed from the superpowers `using-git-worktrees`, git-wt and WalletConnect worktree
skills: a manifest at the root, worktrees outside the repo, `git worktree move` over `mv`,
lock awareness, and remote-branch deletion as a separate opt-in.

## Licence

MIT, see `LICENSE` in this folder.
