# Global Instructions for Claude Code

## Skill Priority

When both Matt Pocock and Superpowers skills could apply, always prefer Matt Pocock's:

| Task | Use | Not |
|------|-----|-----|
| Planning / alignment | `grill-with-docs` or `grill-me` | `superpowers:brainstorming` |
| Writing a PRD / plan | `to-prd` | `superpowers:writing-plans` |
| Test-driven work | `tdd` | `superpowers:test-driven-development` |
| Debugging | `diagnose` | `superpowers:systematic-debugging` |
| Writing a skill | `write-a-skill` | `superpowers:writing-skills` |

## When Implementing Code

Always apply the `karpathy-guidelines` skill when writing, reviewing, or refactoring code. Do not apply it during planning, grilling, or brainstorming sessions.

## Pushing

Every push in a repository under `/iso-init-repo` governance goes through
`/iso-push`, adapting the invocation to the situation. Never fall back to a raw
`git push`: the development, test and production branches are PR-only, so a
direct push is either rejected or lands work that skipped CI and the branch
gate. The skill also owns the `<branch>:refs/heads/<branch>` refspec that stops
an upstream of `origin/dev` from landing a feature branch on the wrong branch,
and the rebase and force-push gating.

When the situation does not fit the documented flow, change the invocation —
not the tool.
