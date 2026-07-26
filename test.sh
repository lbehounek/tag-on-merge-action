#!/usr/bin/env bash
#
# Tests for action.yml. Pure bash + git, no dependencies — same constraint as
# the action itself.
#
# The script under test is EXTRACTED FROM action.yml at run time, never copied
# into this file. A copy would drift, and every bug this suite exists to catch
# was a silent one — a stale copy would keep passing while the real action
# broke. Extraction also proves the `run:` block is well-formed.
#
# Each case builds a throwaway git repo with a local bare "origin", so
# `git fetch` / `git push` / `git tag` all really run. That is what makes the
# SIGPIPE regression detectable at all: it only appears with enough real tags
# for git to still be writing when `head` closes the pipe.
#
#   ./test.sh            run everything
#   ./test.sh sigpipe    run cases whose name matches "sigpipe"

set -uo pipefail   # NOT -e: a failing assertion must report, not abort the run

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly ACTION="$ROOT/action.yml"
FILTER="${1:-}"
PASS=0; FAIL=0
RC=0            # last action exit status (see run_action)
ACTION_OUT=""   # file holding the last action's combined output
WORK="$(mktemp -d)"
# `find -delete` rather than a recursive rm: same result, but it cannot be
# pointed at anything outside the directory mktemp just handed us.
trap 'find "$WORK" -depth -delete 2>/dev/null || true' EXIT

# ── Extract the run: block from action.yml ───────────────────────────────────
# awk, not a YAML library: keeping this dependency-free is the point. The block
# is `run: |` followed by lines indented deeper than the key; we stop at the
# first line that is non-blank and indented no further.
extract_script() {
  awk '
    /^ *run: \|/ { key_indent = match($0, /[^ ]/) - 1; capture = 1; next }
    capture {
      if ($0 ~ /^[[:space:]]*$/) { print ""; next }
      line_indent = match($0, /[^ ]/) - 1
      if (line_indent <= key_indent) { capture = 0; next }
      if (body_indent == 0) body_indent = line_indent
      print substr($0, body_indent + 1)
    }
  ' "$ACTION"
}

# ── Assertions ───────────────────────────────────────────────────────────────
ok()   { PASS=$((PASS+1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n       %s\n' "$1" "$2"; }
is()   { [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected '$3', got '$2'"; }
isnt() { [ "$2" != "$3" ] && ok "$1" || bad "$1" "expected anything but '$3'"; }

# ── Fixture: a repo with a bare origin, seeded with $* as tags ───────────────
# Returns the repo path on stdout.
make_repo() {
  local d; d="$(mktemp -d "$WORK/repo.XXXXXX")"
  git init -q --bare "$d/origin.git"
  git init -q "$d/work"
  (
    cd "$d/work"
    git config user.email t@example.com
    git config user.name  Test
    git config commit.gpgsign false
    git remote add origin "$d/origin.git"
    echo x > f && git add f && git commit -qm "initial"
    git push -q origin HEAD:refs/heads/main
    # Batch through update-ref: the sigpipe case needs thousands of tags, and
    # one `git tag` process each would dominate the suite's runtime.
    if [ $# -gt 0 ]; then
      for t in "$@"; do printf 'create refs/tags/%s %s\n' "$t" "$(git rev-parse HEAD)"; done \
        | git update-ref --stdin
      git push -q origin --tags
    fi
  ) >/dev/null 2>&1
  echo "$d"
}

# Run the real action script inside a fixture, with env supplied by the caller
# as a command prefix (PR_TITLE=... run_action "$r").
#
# Output goes to a FILE and the exit status to the global RC — deliberately not
# `out="$(run_action ...)"`. Command substitution runs the function in a
# SUBSHELL, so an RC assigned inside it never reaches the caller: assertions on
# $RC then silently read a stale value from an earlier test and pass no matter
# what. That exact false pass was caught by mutation-testing this suite.
run_action() {
  local repo="$1"; shift
  local script="$WORK/script.sh"
  extract_script > "$script"
  OUTPUT_FILE="$(mktemp "$WORK/ghout.XXXXXX")"
  ACTION_OUT="$(mktemp "$WORK/stdout.XXXXXX")"
  (cd "$repo/work" && env \
    TAG_PREFIX="${TAG_PREFIX:-v}" \
    DEFAULT_BUMP="${DEFAULT_BUMP:-patch}" \
    RELEASE_BRANCHES="${RELEASE_BRANCHES:-main}" \
    INITIAL_VERSION="${INITIAL_VERSION:-0.1.0}" \
    GITHUB_BASE_REF="${GITHUB_BASE_REF:-main}" \
    GITHUB_OUTPUT="$OUTPUT_FILE" \
    PR_TITLE="${PR_TITLE:-}" \
    GITHUB_TOKEN="${GITHUB_TOKEN:-}" \
    bash "$script") > "$ACTION_OUT" 2>&1
  RC=$?
}

# Combined output of the most recent run_action.
action_output() { cat "$ACTION_OUT"; }

# The tag that ended up on the remote (empty if none), highest version first.
pushed_tag() {
  git -C "$1/origin.git" for-each-ref --sort=-v:refname --count=1 \
      --format='%(refname:short)' 'refs/tags/*'
}

want() { [ -z "$FILTER" ] || [[ "$1" == *"$FILTER"* ]]; }

# ── Cases ────────────────────────────────────────────────────────────────────
echo "action.yml script"

if want "syntax"; then
  extract_script > "$WORK/syntax.sh"
  [ -s "$WORK/syntax.sh" ] && ok "syntax: run block extracts non-empty" \
                           || bad "syntax: run block extracts non-empty" "extraction produced nothing"
  msg="$(bash -n "$WORK/syntax.sh" 2>&1)"
  is "syntax: extracted body is valid bash" "$?" "0"
  [ -z "$msg" ] || bad "syntax: bash -n clean" "$msg"
fi

if want "lint"; then
  # STATIC guards for the two SIGPIPE idioms.
  #
  # These are not belt-and-braces — for one of them a behavioural test is
  # impossible. `echo "$title" | grep -q` only takes SIGPIPE if `echo` is still
  # writing when `grep -q` exits on a match, and a PR title is written in a
  # single syscall, so it essentially never loses the race in a test. It lost it
  # in production only because the pipeline's exit status is 141 *whenever* the
  # race is lost, and the consequence is silent: the `elif` reads false, `set -e`
  # does not fire (it is a condition), and a `#minor` PR ships as a patch.
  #
  # A rule that cannot be observed by running the code has to be asserted on the
  # code. Confirmed by mutation-testing: reintroducing either idiom leaves every
  # behavioural case green, and only these two fail.
  # Comment lines are stripped first: the action documents these very idioms in
  # order to warn against them, and linting the prose would fail on the warning.
  body="$WORK/lint.sh"; extract_script | sed '/^[[:space:]]*#/d' > "$body"

  if grep -nE '\|[[:space:]]*head\b' "$body" >/dev/null; then
    bad "lint: no pipe into head" "$(grep -nE '\|[[:space:]]*head\b' "$body")
       under set -o pipefail head closes the pipe and the producer takes SIGPIPE (141);
       use git for-each-ref --count=1 instead"
  else
    ok "lint: no pipe into head (SIGPIPE, exit 141)"
  fi

  if grep -nE '\|[[:space:]]*grep[[:space:]]+-[a-z]*q' "$body" >/dev/null; then
    bad "lint: no pipe into grep -q" "$(grep -nE '\|[[:space:]]*grep[[:space:]]+-[a-z]*q' "$body")
       grep -q exits on match, so the producer can take SIGPIPE and the condition
       reads FALSE exactly when the pattern WAS present; use bash [[ == *pat* ]]"
  else
    ok "lint: no pipe into grep -q (silent wrong bump)"
  fi
fi

if want "first-tag"; then
  r="$(make_repo)"
  PR_TITLE="first release" run_action "$r"
  is "first-tag: no tags yet uses INITIAL_VERSION" "$(pushed_tag "$r")" "v0.1.0"
fi

if want "patch"; then
  r="$(make_repo v1.2.3)"
  PR_TITLE="fix: a thing" run_action "$r"
  is "patch: default bump is patch" "$(pushed_tag "$r")" "v1.2.4"
fi

if want "minor"; then
  r="$(make_repo v1.2.3)"
  PR_TITLE="feat: a thing #minor" run_action "$r"
  is "minor: #minor bumps minor and zeroes patch" "$(pushed_tag "$r")" "v1.3.0"
fi

if want "major"; then
  # Case-insensitivity is load-bearing: it replaced `grep -i`, and losing it
  # would silently demote a major release to a patch.
  r="$(make_repo v1.2.3)"
  PR_TITLE="feat!: rewrite #MAJOR" run_action "$r"
  is "major: #MAJOR matches case-insensitively" "$(pushed_tag "$r")" "v2.0.0"
fi

if want "none"; then
  r="$(make_repo v1.2.3)"
  PR_TITLE="chore: docs #none" run_action "$r"
  out="$(action_output)"
  is "none: #none creates no tag" "$(pushed_tag "$r")" "v1.2.3"
  is "none: exits cleanly"        "$RC" "0"
  case "$out" in *"Skipping tag"*) ok "none: says why";; *) bad "none: says why" "$out";; esac
fi

if want "branch"; then
  r="$(make_repo v1.2.3)"
  GITHUB_BASE_REF=develop PR_TITLE="fix: x" run_action "$r"
  is "branch: non-release branch creates no tag" "$(pushed_tag "$r")" "v1.2.3"
  is "branch: exits cleanly"                     "$RC" "0"
fi

if want "sigpipe"; then
  # REGRESSION (exit 141). `git tag --list ... | head -n 1` under `pipefail`
  # takes SIGPIPE once there is enough output: head closes the pipe after line
  # one while git is still writing. It produced NO output (command
  # substitution), so the only symptom was "exit code 141".
  #
  # The count is calibrated, not arbitrary. Measured on the reference machine:
  # 400 tags never reproduced it (0/5 runs), 2000 always did (5/5). Below that
  # git finishes writing before head closes the pipe and the bug hides — a
  # smaller fixture would make this test a decoration. The consumer repo that
  # hit it in production had ~508, so real-world onset sits between.
  tags=(); for i in $(seq 1 2000); do tags+=("v1.0.$i"); done
  r="$(make_repo "${tags[@]}")"
  PR_TITLE="fix: with many tags" run_action "$r"
  isnt "sigpipe: does not die with SIGPIPE (141)" "$RC" "141"
  is   "sigpipe: exits cleanly"                   "$RC" "0"
  is   "sigpipe: picks the true latest of 2000"   "$(pushed_tag "$r")" "v1.0.2001"
fi

if want "prefix"; then
  # A non-default prefix must not confuse the version parse.
  r="$(make_repo release-2.0.0)"
  TAG_PREFIX=release- PR_TITLE="fix: x" run_action "$r"
  is "prefix: honours a custom tag-prefix" "$(pushed_tag "$r")" "release-2.0.1"
fi

if want "retry"; then
  # The computed tag already exists remotely (a concurrent merge won the race):
  # the loop must fetch, recompute and land on the next free version.
  r="$(make_repo v1.2.3)"
  (cd "$r/work" && git tag v1.2.4 && git push -q origin v1.2.4 && git tag -d v1.2.4) >/dev/null 2>&1
  PR_TITLE="fix: racing" run_action "$r"
  is "retry: skips a tag taken by a concurrent run" "$(pushed_tag "$r")" "v1.2.5"
  is "retry: exits cleanly"                         "$RC" "0"
fi

if want "injection"; then
  # The PR title arrives via env (CWE-94). If it were interpolated into the
  # script body, this title would execute. The canary file must not appear.
  r="$(make_repo v1.2.3)"
  canary="$WORK/pwned.$$"
  PR_TITLE="evil\"; touch $canary; #" run_action "$r"
  [ -e "$canary" ] && bad "injection: title is data, not code" "canary $canary was created" \
                   || ok  "injection: title is data, not code"
  is "injection: still tags normally" "$(pushed_tag "$r")" "v1.2.4"
fi

if want "auth"; then
  # REGRESSION (exit 128 / HTTP 400). `http.<host>.extraheader` is
  # MULTI-VALUED and actions/checkout already persists one, so adding a second
  # made git send two AUTHORIZATION headers and GitHub answered 400.
  # actions/checkout (v5+) supplies its credential through an includeIf-included
  # config FILE, not the local config. That distinction is the whole bug: a
  # local `git config <key> <value>` REPLACES a local value, but only ADDS to an
  # included one — so the naive fixture (setting it locally) cannot reproduce
  # the duplication, and would let the bug back in. Model the real mechanism.
  r="$(make_repo v1.2.3)"
  (
    cd "$r/work"
    printf '[http "https://github.com/"]\n\textraheader = AUTHORIZATION: basic FROM_CHECKOUT\n' > creds.config
    git config --local "includeIf.gitdir:$r/work/.git.path" "$r/work/creds.config"
  )
  GITHUB_TOKEN=secret PR_TITLE="fix: x" run_action "$r"
  n="$(cd "$r/work" && git config --get-all "http.https://github.com/.extraheader" | wc -l)"
  is "auth: does not duplicate an existing credential" "$n" "1"
  is "auth: leaves the existing credential intact" \
     "$(cd "$r/work" && git config --get "http.https://github.com/.extraheader")" \
     "AUTHORIZATION: basic FROM_CHECKOUT"

  # …but still installs one when there is none — that is what the
  # github-token input exists for (persist-credentials: false setups).
  r2="$(make_repo v1.2.3)"
  GITHUB_TOKEN=secret PR_TITLE="fix: x" run_action "$r2"
  n2="$(cd "$r2/work" && git config --get-all "http.https://github.com/.extraheader" 2>/dev/null | wc -l)"
  is "auth: installs a credential when none exists" "$n2" "1"
fi

if want "outputs"; then
  r="$(make_repo v1.2.3)"
  PR_TITLE="feat: x #minor" run_action "$r"
  is "outputs: new_tag"      "$(grep '^new_tag='      "$OUTPUT_FILE" | cut -d= -f2)" "v1.3.0"
  is "outputs: previous_tag" "$(grep '^previous_tag=' "$OUTPUT_FILE" | cut -d= -f2)" "v1.2.3"
  is "outputs: bump"         "$(grep '^bump='         "$OUTPUT_FILE" | cut -d= -f2)" "minor"
fi

# ── Result ───────────────────────────────────────────────────────────────────
echo
if [ "$FAIL" -eq 0 ]; then
  printf '\033[32m%d passed\033[0m\n' "$PASS"
else
  printf '\033[31m%d failed\033[0m, %d passed\n' "$FAIL" "$PASS"
fi
[ "$FAIL" -eq 0 ]
