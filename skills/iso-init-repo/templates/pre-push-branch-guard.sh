# >>> iso-init-repo branch guard >>>
# Refuses direct pushes to dev, test and prod.
#
# Why this exists: branch protection is paywalled. A private repo on GitHub Free
# returns 403 from the protection API, so nothing server-side refuses these
# pushes — and a push straight to prod fires no workflow at all, because
# ci-branch-gate.yml is `on: pull_request` and a push is not a pull request.
#
# Why a blanket refusal is correct: nothing in the sanctioned flow needs to push
# here. Features land as `gh pr merge --rebase`, promotions as
# `gh pr merge --merge` — GitHub is the only writer to all three branches. A
# fast-forward landing would need an exception; the merge-based cascade does
# not, so the rule has no hole to argue about.
#
# What it covers: a direct push made from this working copy. That is the real
# failure mode for a solo repo — twenty years of muscle memory typing
# `git push origin dev`.
#
# What it does not cover, and cannot: a merge or file edit made in the GitHub
# web UI, a push from another clone or another machine, or anything done in a
# clone where `git config core.hooksPath .githooks` was never run. Those routes
# do not pass through this file. Only server-side protection sees all of them.
#
# Everything between these markers is managed by /iso-init-repo. Re-running the
# skill replaces this block in place. Delete the block once the repo is public
# or on a paid plan and step 4b has run — at that point GitHub refuses these
# pushes itself, and two copies of one rule is somewhere for them to disagree.

while read -r _ _ guard_remote_ref _; do
    guard_branch="${guard_remote_ref#refs/heads/}"
    case "$guard_branch" in
        dev|test|prod)
            printf 'pre-push: refusing direct push to %s.\n' "$guard_branch" >&2
            case "$guard_branch" in
                prod) printf 'pre-push:   prod takes PRs from test.\n' >&2 ;;
                test) printf 'pre-push:   test takes PRs from dev.\n' >&2 ;;
                dev)  printf 'pre-push:   dev takes PRs from any branch.\n' >&2 ;;
            esac
            printf 'pre-push:   commit on a branch, then /iso-push.\n' >&2
            rc=1
            ;;
    esac
done
# <<< iso-init-repo branch guard <<<
