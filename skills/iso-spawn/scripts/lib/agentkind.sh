#!/usr/bin/env bash
# agentkind.sh — the facts that differ by Agent kind (codex | claude): transcript layout,
# full-permission flag, tab label. One home so callers ask instead of re-branching on type.
# Pure constants + normalize; bash 3.2-safe (no associative arrays). Assumes pipefail.

# Normalize a raw type/agent string to the canonical kind.
agentkind_normalize() { case "$1" in claude*) echo claude;; *) echo codex;; esac; }

# Root dir holding this kind's native JSONL transcripts (env-overridable for tests).
agentkind_root() { # $1=kind
  case "$(agentkind_normalize "$1")" in
    claude) printf '%s' "${ISO_CLAUDE_PROJ:-$HOME/.claude/projects}";;
    *)      printf '%s' "${ISO_CODEX_SESS:-$HOME/.codex/sessions}";;
  esac
}

# Glob matching this kind's transcript files within its (sub)dir.
agentkind_glob() { # $1=kind
  case "$(agentkind_normalize "$1")" in
    claude) printf '%s' '*.jsonl';;
    *)      printf '%s' 'rollout-*.jsonl';;
  esac
}

# "1" when this kind keys its transcript dir by a cwd slug (claude, flat dir); "" otherwise
# (codex, date-nested dir searched recursively).
agentkind_slug_needed() { # $1=kind
  case "$(agentkind_normalize "$1")" in claude) printf '%s' 1;; *) printf '%s' '';; esac
}

# herdr tab label / sidecar agent label for this kind.
agentkind_label() { # $1=kind
  case "$(agentkind_normalize "$1")" in claude) printf '%s' 'claude-code';; *) printf '%s' 'codex';; esac
}

# argv fragment enabling full permissions for this kind. Single token (caller word-splits safely).
agentkind_perm_argv() { # $1=kind
  case "$(agentkind_normalize "$1")" in
    claude) printf '%s' '--dangerously-skip-permissions';;
    *)      printf '%s' '--dangerously-bypass-approvals-and-sandbox';;
  esac
}
