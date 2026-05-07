module.exports = {
  extends: ['@commitlint/config-conventional'],
  rules: {
    // scope required — use app/package name (e.g. italian, dashboard, db)
    'scope-empty': [2, 'never'],
    // disabled — allows emoji in subject (feat(italian): ✨ add route)
    'subject-case': [0],
    // scope-enum: ONLY add after auditing all existing scopes in git history:
    //   git log --oneline | sed -n 's/[^(]*(\([^)]*\)).*/\1/p' | sort -u
    // Enabling without auditing will block commits with historical scopes.
    // 'scope-enum': [2, 'always', [
    //   'dashboard', 'italian', 'marketing',       // apps
    //   'api-core', 'auth', 'billing', 'config', 'db', 'fiscal-it', 'types', 'ui', // packages
    //   'ci', 'deps', 'docs', 'repo',              // cross-cutting
    // ]],
  },
};

// Version-bump contract (post-commit-version-bump.sh):
//   feat(scope)!: or BREAKING CHANGE: in body → major
//   feat(scope):                               → minor
//   everything else                            → patch
// --amend uses --no-verify so commitlint never runs twice.
