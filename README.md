# tag-on-merge-action

Composite GitHub Action that bumps a semver tag on PR merge. Zero dependencies — pure bash.

Replaces `anothrNick/github-tag-action` to eliminate third-party supply chain risk.

## Usage

```yaml
name: tag-on-merge
on:
  pull_request:
    types: [closed]
    branches: [main]

jobs:
  tag:
    if: github.event.pull_request.merged == true
    runs-on: ubuntu-latest
    permissions:
      contents: write
    steps:
      - uses: actions/checkout@v6
        with:
          ref: ${{ github.event.pull_request.merge_commit_sha }}
          fetch-depth: 0

      - uses: lbehounek/tag-on-merge-action@v1
        with:
          github-token: ${{ secrets.GITHUB_TOKEN }}
```

## Inputs

| Input | Default | Description |
|-------|---------|-------------|
| `github-token` | (required) | Token used to authenticate tag fetch/push (via a scoped auth header) |
| `tag-prefix` | `v` | Tag prefix (e.g., `v` → `v1.2.3`) |
| `default-bump` | `patch` | Default bump when no hint in PR title |
| `release-branches` | `main` | Comma-separated branches to tag |
| `initial-version` | `0.1.0` | Starting version if no tags exist |

## PR Title Hints

Override the default bump by including in PR title:
- `#major` → bump major (1.0.0 → 2.0.0)
- `#minor` → bump minor (1.0.0 → 1.1.0)
- `#patch` → bump patch (1.0.0 → 1.0.1)
- `#none` → skip tagging

## Outputs

| Output | Description |
|--------|-------------|
| `new-tag` | The tag that was created |
| `previous-tag` | The previous tag |
| `bump` | The bump level applied |

## Security

- **Grant minimal permissions.** Only `contents: write` is required to push tags
  (as in the usage example). Don't grant more.
- **Untrusted PR titles are handled safely.** The PR title is passed via the step
  `env:` block and read as a quoted shell variable — never interpolated inline
  into the script — so a title containing quotes, backticks, or `$( )` cannot
  inject commands (CWE-94).
- **Prefer `pull_request` over `pull_request_target`.** This action reads the
  attacker-controllable PR title; `pull_request_target` hands a write token to
  fork-triggered runs. The `pull_request` / `types: [closed]` trigger shown above
  is the safe pattern.
- **Token auth.** `github-token` authenticates fetch/push via a scoped auth
  header, so tagging works even if your `actions/checkout` used
  `persist-credentials: false`.
