# Repository working agreements

## Git workflow

- Work on `main` by default. Do not create a branch or worktree unless the user explicitly requests one or a platform limitation makes it unavoidable.
- Before changing files, inspect the current branch, worktrees, status, and recent history. If the repository is not on `main`, explain why and establish how that branch will be integrated before continuing.
- A task is not complete while its work exists only on an unmerged branch. Any branch created for a task must be merged or otherwise integrated into the intended target and then deleted locally and remotely, unless the user explicitly asks to retain it.
- Never delete, replace, reset, or rewrite `main` in favor of another branch. Before any history-changing cleanup, verify commit ancestry and create a named, recoverable safety tag.
- Never remove a branch with unique commits until those commits are proven to exist on `main` or on an explicitly retained safety reference.
- Do not leave detached worktrees, forgotten stashes, unpushed commits, or phantom remote branches. At handoff, verify and report the branch, worktree, local/remote synchronization, and working-tree status.
- Remote pushes and remote branch deletions still require the user's authorization.
