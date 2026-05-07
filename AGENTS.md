# Memory for Codex

## Context7 Usage

**Always use Context7 MCP tools automatically** when I need:
- Code generation
- Setup or configuration steps
- Library/API documentation

This means you should proactively:
1. Use `resolve-library-id` to find the correct library ID
2. Use `get-library-docs` to fetch up-to-date documentation

Do this automatically without waiting for me to explicitly ask for documentation lookups.

## Package Management

**Always use Volta for Node.js package management**. When working with Node.js:
- Use `volta install node` to install/manage Node.js versions
- Use `volta install <package>` for global npm packages
- For project dependencies, use `npm install` (Volta automatically manages the Node.js and npm versions)
