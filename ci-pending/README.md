# Pending GitHub Actions workflows

`ci.yml` and `release.yml` belong in `.github/workflows/`. They are here because the
GitHub token used to push this repo has no `workflow` scope, and GitHub refuses pushes
that change workflow files without it.

To turn them on:

1. Give the token the `workflow` scope (or create a new token with `repo` and `workflow`).
2. Run:
   ```bash
   mkdir -p .github && git mv ci-pending .github/workflows && git rm -q .github/workflows/README.md
   git commit -m "Turn on CI and release workflows" && git push
   ```
