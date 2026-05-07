# Global Instructions for Claude Code

## Skill Priority

When both Matt Pocock and Superpowers skills could apply, always prefer Matt Pocock's:

| Task | Use | Not |
|------|-----|-----|
| Planning / alignment | `grill-with-docs` or `grill-me` | `superpowers:brainstorming` |
| Test-driven work | `tdd` | `superpowers:test-driven-development` |
| Debugging | `diagnose` | `superpowers:systematic-debugging` |
| Writing a skill | `write-a-skill` | `superpowers:writing-skills` |

## When Implementing Code

Always apply the `karpathy-guidelines` skill when writing, reviewing, or refactoring code. Do not apply it during planning, grilling, or brainstorming sessions.
