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

Apply these principles during any coding task. They do not apply during planning, grilling, or brainstorming sessions.

1. **Think first** — State assumptions explicitly. If unclear, ask. Present tradeoffs, don't pick silently.
2. **Simplicity first** — Minimum code that solves the problem. No speculative features, no abstractions for single-use code, no error handling for impossible scenarios.
3. **Surgical changes** — Touch only what the request requires. Don't improve adjacent code, refactor unrelated things, or clean up pre-existing issues unless asked.
4. **Verifiable goals** — For multi-step tasks, state a brief plan with a check per step before writing a line.
