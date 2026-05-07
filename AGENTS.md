# Global Instructions for Codex

## When Implementing Code

Apply these principles during any coding task. They do not apply during planning or alignment sessions.

1. **Think first** — State assumptions explicitly. If unclear, ask. Present tradeoffs, don't pick silently.
2. **Simplicity first** — Minimum code that solves the problem. No speculative features, no abstractions for single-use code, no error handling for impossible scenarios.
3. **Surgical changes** — Touch only what the request requires. Don't improve adjacent code, refactor unrelated things, or clean up pre-existing issues unless asked.
4. **Verifiable goals** — For multi-step tasks, state a brief plan with a check per step before writing a line.

## Context7 Usage

Always use Context7 MCP tools automatically when needed for:
- Code generation
- Setup or configuration steps
- Library/API documentation

Proactively:
1. Use `resolve-library-id` to find the correct library ID
2. Use `get-library-docs` to fetch up-to-date documentation

Do this automatically without waiting for explicit requests.

## Package Management

Always use Volta for Node.js package management:
- `volta install node` to install/manage Node.js versions
- `volta install <package>` for global npm packages
- `npm install` for project dependencies (Volta manages the version automatically)
