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

## Tests

```bash
bash test.sh            # everything
bash test.sh sigpipe    # only cases whose name matches
```

Pure bash + git, no dependencies — the same constraint as the action. Each case
builds a throwaway repo with a local bare `origin` and runs **the real script
extracted from `action.yml`**, never a copy: a copy would drift, and every bug
this suite exists to catch was a silent one, so a stale copy would keep passing
while the action broke.

Two cases are *static* rather than behavioural, and deliberately so. Both
SIGPIPE bugs below are race conditions; `echo "$title" | grep -q` in particular
can essentially never be made to lose the race in a test, because a short title
is written in one syscall. A rule that cannot be observed by running the code
has to be asserted on the code — so the suite greps the extracted script for
those idioms. The behavioural sigpipe case uses a calibrated 2000 tags
(measured: 400 never reproduces it, 2000 always does).

The suite is mutation-tested: reintroducing any of the three historical bugs
turns it red, and that was checked rather than assumed.

## Implementation notes

Two bash footguns this action deliberately avoids. Both were live bugs (fixed
2026-07-26) and both failed *silently*, so they are worth not reintroducing.

**Never `cmd | head -n 1` under `set -o pipefail`.** `head` closes the pipe after
the first line; with enough output upstream (a repo with hundreds of tags) the
producer takes SIGPIPE and exits 141, `pipefail` promotes that to the pipeline's
status, and `set -e` kills the step. Inside a command substitution it prints
nothing at all, so the log shows only `exit code 141`. Use
`git for-each-ref --count=1` — git selects the first match itself, no pipe.

**Never `echo "$x" | grep -q` under `set -o pipefail`.** Same SIGPIPE, worse
outcome: `grep -q` exits *the moment it matches*, so the race is most likely
exactly when the pattern IS present. The pipeline returns 141, the `if` reads
false, and `set -e` doesn't fire because it's a condition — so a `#minor` PR
silently ships as a patch. Use bash `[[ "$x" == *"pat"* ]]`.

Related (already fixed in v1): the PR title is passed via `env: PR_TITLE`, never
interpolated into the script body — `${{ }}` is textual substitution done before
bash parses the line, so a crafted title would inject shell (CWE-94).
