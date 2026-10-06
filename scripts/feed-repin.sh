#!/usr/bin/env bash
# feed-repin.sh — repin FreedomTechFeed/packages' net/tollgate-wrt to a module commit,
# open + merge the repin PR, cut the release tag, and verify the published assets.
#
# Run as the feed maintainer (gh must be authenticated with push rights):
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/felixfelix-bot/packages/tooling/feed-repin/scripts/feed-repin.sh)
#   bash <(curl -fsSL <same-url>) <commit>   # repin to a specific module commit (short or full sha)
#   DRY=1  bash <(curl -fsSL <same-url>)     # print the plan + diff, change nothing
#   HOLD=1 bash <(curl -fsSL <same-url>)     # stop after the PR is merged (no tag / no publish)
#
# It touches exactly ONE feed file — net/tollgate-wrt/Makefile:
#   PKG_SOURCE_VERSION := the target commit SHA (the real pin)
#   PKG_HASH           := sha256 of https://codeload.github.com/<mod>/tar.gz/<sha>
#   PKG_SOURCE_TAG     := the repo-root VERSION file inside that tarball
#                         (test-pkg-tarball-parity.sh Gate B fails if these disagree)
#   PKG_VERSION        := <version-from-VERSION-file>_pre<NN+1>  (apk-legal: underscores)
# plus two comment blocks. No other feed-side file is touched.
#
# Safety: it validates the hash method against the CURRENT pin before touching
# anything (recomputes the shipped PKG_HASH and aborts if it does not reproduce),
# never force-pushes, never rewrites history, and aborts on any unexpected state.
set -euo pipefail

REPO=${REPO_OVERRIDE:-FreedomTechFeed/packages}
MOD=${MOD_OVERRIDE:-OpenTollGate/tollgate-module-basic-go}
MK=net/tollgate-wrt/Makefile
BRANCH_PREFIX=pr/tollgate-wrt
ARG_TARGET=${1:-}

say()  { printf '\n=== %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\nABORT: %s\n' "$*" >&2; exit 1; }

command -v gh >/dev/null   || die "gh is not installed"
command -v curl >/dev/null || die "curl is not installed"
command -v python3 >/dev/null || die "python3 is not installed"

say "preflight"
gh auth status -h github.com >/dev/null 2>&1 || die "gh is not authenticated against github.com"
WHO=$(gh api user --jq .login)
PERM=$(gh api "repos/$REPO" --jq '.permissions.push' 2>/dev/null || echo false)
info "gh account        : $WHO"
info "push to $REPO : $PERM"
[ "$PERM" = "true" ] || die "the active gh account ($WHO) cannot push to $REPO — run this as the feed maintainer"

# ---------------------------------------------------------------- resolve target
say "resolving the target commit"
if [ -n "$ARG_TARGET" ]; then
    TARGET=$(gh api "repos/$MOD/commits/$ARG_TARGET" --jq .sha) || die "no such commit in $MOD: $ARG_TARGET"
    case "$TARGET" in
      *[!0-9a-f]*|"") die "could not resolve '$ARG_TARGET' to a commit sha" ;;
    esac
else
    TARGET=$(gh api "repos/$MOD/commits/main" --jq .sha)
fi
[ ${#TARGET} -eq 40 ] || die "expected a 40-char sha, got '$TARGET'"
TARGET7=$(printf '%s' "$TARGET" | cut -c1-7)
TSHORT=$(gh api "repos/$MOD/commits/$TARGET" --jq '.commit.committer.date')
TSUBJ=$(gh api "repos/$MOD/commits/$TARGET" --jq '.commit.message|split("\n")[0]')
info "target    : $TARGET"
info "committed : $TSHORT"
info "subject   : $TSUBJ"

say "cloning $REPO"
WORK=$(mktemp -d /tmp/feed-repin.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
gh repo clone "$REPO" "$WORK/feed" -- --depth=1 --branch master --quiet
cd "$WORK/feed"

# ------------------------------------------------------------ read current state
say "current pin (from $MK)"
mkv() { sed -n "s/^$1:=//p" "$MK" | head -1; }
CUR_VER=$(mkv PKG_VERSION)
CUR_SHA=$(mkv PKG_SOURCE_VERSION)
CUR_TAG=$(mkv PKG_SOURCE_TAG)
CUR_HASH=$(mkv PKG_HASH)
CUR_URLTPL=$(grep -m1 '^PKG_SOURCE_URL:=' "$MK" | sed 's/^PKG_SOURCE_URL:=//')
for v in CUR_VER CUR_SHA CUR_TAG CUR_HASH CUR_URLTPL; do
    eval "val=\$$v"; [ -n "$val" ] || die "could not read $v from $MK"
done
info "PKG_VERSION       : $CUR_VER"
info "PKG_SOURCE_VERSION: $CUR_SHA"
info "PKG_SOURCE_TAG    : $CUR_TAG"
info "PKG_HASH          : $CUR_HASH"

[ "$CUR_SHA" != "$TARGET" ] || die "the feed is already pinned to $TARGET7 — nothing to do"

# ------------------------------------------------- validate the hash method (self-test)
say "self-test: recompute the SHIPPED PKG_HASH from the current pin"
url_for() { printf '%s' "$CUR_URLTPL" | sed "s/\$(PKG_SOURCE_VERSION)/$1/"; }
CUR_URL=$(url_for "$CUR_SHA")
info "url: $CUR_URL"
curl -fsSL --retry 3 -o "$WORK/cur.tar.gz" "$CUR_URL" || die "could not download the current pinned tarball"
GOT_CUR=$(sha256sum "$WORK/cur.tar.gz" | cut -d' ' -f1)
if [ "$GOT_CUR" != "$CUR_HASH" ]; then
    die "hash method does not reproduce the shipped PKG_HASH
      shipped : $CUR_HASH
      computed: $GOT_CUR
      the tarball bytes are not what the feed shipped — refusing to compute a new hash with an unvalidated method"
fi
info "OK — recomputed $GOT_CUR == shipped PKG_HASH (the method is validated)"

# --------------------------------------------------------------- the new pin values
say "fetching the target tarball"
NEW_URL=$(url_for "$TARGET")
curl -fsSL --retry 3 -o "$WORK/new.tar.gz" "$NEW_URL" || die "could not download the target tarball"
NEW_HASH=$(sha256sum "$WORK/new.tar.gz" | cut -d' ' -f1)
NEW_SIZE=$(wc -c < "$WORK/new.tar.gz" | tr -d ' ')
info "size: $NEW_SIZE bytes"
info "sha256: $NEW_HASH"

VERSION_FILE=$(tar -xzOf "$WORK/new.tar.gz" --wildcards '*/VERSION' 2>/dev/null | head -1 | tr -d '[:space:]' || true)
[ -n "$VERSION_FILE" ] || die "the target tarball has no repo-root VERSION file"
info "repo-root VERSION at the target: $VERSION_FILE"

CUR_NN=$(printf '%s' "$CUR_VER" | sed -n 's/.*_pre\([0-9][0-9]*\)$/\1/p')
[ -n "$CUR_NN" ] || die "cannot read the _pre<NN> counter out of PKG_VERSION=$CUR_VER"
NEXT_NN=$((CUR_NN + 1))
BASE_APK=$(printf '%s' "$VERSION_FILE" | sed 's/^v//; s/-/_/g')
NEW_VER="${BASE_APK}_pre${NEXT_NN}"
NEW_TAG="v${NEW_VER//_/-}"
NEW_BRANCH="$BRANCH_PREFIX-${NEW_TAG#v}"

if gh api "repos/$REPO/git/refs/tags/$NEW_TAG" >/dev/null 2>&1; then
    die "tag $NEW_TAG already exists in $REPO"
fi

say "delta: $CUR_SHA -> $TARGET"
DELTA_N=$(gh api "repos/$MOD/compare/$CUR_SHA...$TARGET" --jq '.total_commits')
gh api "repos/$MOD/compare/$CUR_SHA...$TARGET" --jq '.commits[].commit.message|split("\n")[0]' > "$WORK/delta.txt" || true
info "$DELTA_N commit(s)"
head -40 "$WORK/delta.txt" | sed 's/^/      /'
REFS=$(grep -oE '\(#[0-9]+\)' "$WORK/delta.txt" | tr -d '()' | sort -u | tr '\n' ' ' || true)

say "PLAN"
cat <<EOF
    module commit      : $TARGET  ($TARGET7)
    PKG_SOURCE_VERSION : $CUR_SHA -> $TARGET
    PKG_HASH           : $CUR_HASH
                       -> $NEW_HASH
    PKG_SOURCE_TAG     : $CUR_TAG -> $VERSION_FILE   (Gate B: must equal the tarball VERSION)
    PKG_VERSION        : $CUR_VER -> $NEW_VER
    release tag        : $NEW_TAG
    PR branch          : $NEW_BRANCH  (in $REPO, base master)
    files changed      : $MK only
EOF
if [ "$CUR_TAG" != "$VERSION_FILE" ]; then
    info "NOTE: the repo-root VERSION file moved, so PKG_SOURCE_TAG moves with it (first time across a VERSION change)."
fi

# ------------------------------------------------------------------------ the edit
say "editing $MK"
python3 - "$MK" <<'PY' "$CUR_VER" "$NEW_VER" "$CUR_SHA" "$TARGET" "$CUR_HASH" "$NEW_HASH" "$CUR_TAG" "$VERSION_FILE" "$TARGET7" "$DELTA_N" "$WORK/delta.txt" "$REFS" "$NEW_TAG" "$NEXT_NN"
import sys, pathlib
(mk, cur_ver, new_ver, cur_sha, target, cur_hash, new_hash,
 cur_tag, ver_file, t7, dn, dpath, refs, tag, nn) = sys.argv[1:]
p = pathlib.Path(mk)
s = p.read_text()

def one(old, new, what):
    global s
    n = s.count(old)
    if n != 1:
        sys.exit(f"expected exactly 1 occurrence of {what}, found {n}")
    s = s.replace(old, new, 1)

# 1. the three value lines (+ PKG_SOURCE_TAG when the VERSION file moved)
one(f"PKG_VERSION:={cur_ver}", f"PKG_VERSION:={new_ver}", "PKG_VERSION")
one(f"PKG_SOURCE_VERSION:={cur_sha}", f"PKG_SOURCE_VERSION:={target}", "PKG_SOURCE_VERSION")
one(f"PKG_HASH:={cur_hash}", f"PKG_HASH:={new_hash}", "PKG_HASH")
if cur_tag != ver_file:
    one(f"PKG_SOURCE_TAG:={cur_tag}", f"PKG_SOURCE_TAG:={ver_file}", "PKG_SOURCE_TAG")

# 2. a block documenting this repin, immediately above PKG_VERSION
delta = [l.strip() for l in pathlib.Path(dpath).read_text().splitlines() if l.strip()][:40]
body = "\n".join(f"#   {d}" for d in delta)
block = (
f"""# ---------------------------------------------------------------------------
# pre{nn} moves the pin and does nothing else -- the same shape as every repin before it:
# the module moved, so PKG_SOURCE_VERSION and PKG_HASH move with it (PKG_HASH is
# never recomputed without a pin move and never left stale across one), and no
# other feed-side file changes.
# The pin is now the merged module main tip {t7}, and the repo-root VERSION file
# inside that tarball is {ver_file}, so PKG_SOURCE_TAG moves with it
# ({cur_tag} -> {ver_file}) -- Gate B in test-pkg-tarball-parity.sh compares the two
# and fails the build if they disagree.
# Delta since {cur_sha[:7]} ({dn} commit(s)):
{body}
"""
)
one("PKG_VERSION:=" + new_ver, block + "PKG_VERSION:=" + new_ver, "insert point above PKG_VERSION")

# 3. one ordering line after the last existing ordering line
lines = s.split("\n")
idx = [i for i, l in enumerate(lines) if l.startswith("#     < ")]
if idx:
    chain = f"#     < {cur_ver} < {new_ver} < {ver_file.lstrip('v').replace('-', '_')}"
    lines.insert(idx[-1] + 1, chain)
    s = "\n".join(lines)
    print(f"   ordering comment: added '{chain}'", file=sys.stderr)
else:
    print("   WARNING: no '#     < ' ordering line found; skipped", file=sys.stderr)

p.write_text(s)
print("   edits applied", file=sys.stderr)
PY

say "diff"
git --no-pager diff --stat
git --no-pager diff -- "$MK" | sed -n '1,80p'

if [ "${DRY:-0}" = "1" ]; then
    say "DRY=1 — nothing pushed. The plan above is what a real run would do."
    exit 0
fi

# ------------------------------------------------------------------------- the PR
say "commit + push branch"
git config user.name  "$(git config --get user.name  || echo "$WHO")"
git config user.email "$(git config --get user.email || echo "$WHO@users.noreply.github.com")"
git checkout -q -b "$NEW_BRANCH"
git add "$MK"
git commit -q -m "build(pre${NEXT_NN}): move the module pin to ${TARGET7}, recompute PKG_HASH" \
    -m "Module delta since ${CUR_SHA:0:7}: ${DELTA_N} commit(s). References: ${REFS# }"
git push -q -u origin "$NEW_BRANCH"
PR_URL=$(gh pr create --repo "$REPO" --base master --head "$NEW_BRANCH" \
    --title "build(pre${NEXT_NN}): move the module pin to ${TARGET7}, recompute PKG_HASH" \
    --body "$(cat <<EOF
Repins \`net/tollgate-wrt\` to the merged module main tip \`$TARGET\`.

| field | from | to |
|---|---|---|
| PKG_SOURCE_VERSION | \`$CUR_SHA\` | \`$TARGET\` |
| PKG_HASH | \`$CUR_HASH\` | \`$NEW_HASH\` |
| PKG_SOURCE_TAG | \`$CUR_TAG\` | \`$VERSION_FILE\` |
| PKG_VERSION | \`$CUR_VER\` | \`$NEW_VER\` |

\`$MK\` is the only file touched.

Delta since \`${CUR_SHA:0:7}\` ($DELTA_N commit(s)):

\`\`\`
$(head -40 "$WORK/delta.txt")
\`\`\`

Hash method: recomputed the **shipped** \`PKG_HASH\` from the current pin first and
confirmed it reproduces byte-for-byte (\`$GOT_CUR\`), then computed the new one the
same way (\`curl -fsSL https://codeload.github.com/$MOD/tar.gz/<sha>\` → sha256).
\`PKG_SOURCE_TAG\` is read out of the repo-root VERSION file **inside the target
tarball**, which is exactly what Gate B compares.
EOF
)")
info "PR: $PR_URL"
PR_NUM=$(printf '%s' "$PR_URL" | sed 's#.*/##')

# Checks do NOT exist the instant a PR opens -- the run has to register, and a
# QUEUED run may not have produced a check-run yet. Poll the checks AND the
# workflow runs on the branch; never merge a repin whose checks did not pass.
say "waiting for the PR checks to register (bound: 5 min)"
CHK_TOTAL=0; RUN_N=0
for _ in $(seq 1 30); do
    CHK_TOTAL=$(gh pr checks "$PR_NUM" --repo "$REPO" --json bucket --jq 'length' 2>/dev/null || echo 0)
    case "$CHK_TOTAL" in ''|*[!0-9]*) CHK_TOTAL=0 ;; esac
    RUN_N=$(gh run list --repo "$REPO" --branch "$NEW_BRANCH" --limit 20 --json databaseId --jq 'length' 2>/dev/null || echo 0)
    case "$RUN_N" in ''|*[!0-9]*) RUN_N=0 ;; esac
    { [ "$CHK_TOTAL" -gt 0 ] || [ "$RUN_N" -gt 0 ]; } && break
    sleep 10
done
info "check-runs: $CHK_TOTAL   workflow runs on the branch: $RUN_N"

if [ "$CHK_TOTAL" -eq 0 ] && [ "$RUN_N" -eq 0 ]; then
    info "neither check-runs nor workflow runs appeared within 5 minutes"
    [ "${FORCE_MERGE:-0}" = "1" ] || die "refusing to merge an unverified repin — the PR is open at $PR_URL (FORCE_MERGE=1 to merge anyway, HOLD=1 to stop here)"
fi

if [ "$CHK_TOTAL" -gt 0 ]; then
    say "waiting for the PR checks to finish (bound: 40 min)"
    DEADLINE=$(( $(date +%s) + 2400 ))
    CHK_PENDING=0; CHK_FAIL=0
    while :; do
        S=$(gh pr checks "$PR_NUM" --repo "$REPO" --json bucket \
            --jq '"\\(length) \\([.[]|select(.bucket=="pending")]|length) \\([.[]|select(.bucket=="fail" or .bucket=="cancel")]|length)"' 2>/dev/null || echo "0 0 0")
        read -r CHK_TOTAL CHK_PENDING CHK_FAIL <<<"$S" || true
        case "$CHK_TOTAL$CHK_PENDING$CHK_FAIL" in *[!0-9]*|'') CHK_TOTAL=0; CHK_PENDING=0; CHK_FAIL=0 ;; esac
        [ "$CHK_TOTAL" -gt 0 ] && [ "$CHK_PENDING" -eq 0 ] && break
        if [ "$(date +%s)" -ge "$DEADLINE" ]; then CHK_FAIL=1; info "check watch timed out"; break; fi
        sleep 20
    done
    if [ "$CHK_FAIL" -gt 0 ] || [ "$CHK_TOTAL" -eq 0 ]; then
        info "checks did not all pass ($CHK_FAIL failing) — inspect $PR_URL"
        [ "${FORCE_MERGE:-0}" = "1" ] || die "refusing to merge a repin whose checks did not pass (FORCE_MERGE=1 to override, HOLD=1 to stop at the PR)"
    else
        info "all $CHK_TOTAL check(s) passed"
    fi
else
    say "no check-runs reported — watching the $RUN_N workflow run(s) on the branch (bound: 40 min)"
    DEADLINE=$(( $(date +%s) + 2400 ))
    while :; do
        PENDING=$(gh run list --repo "$REPO" --branch "$NEW_BRANCH" --limit 20 \
            --json status --jq '[.[]|select(.status!="completed")]|length' 2>/dev/null || echo 1)
        case "$PENDING" in ''|*[!0-9]*) PENDING=1 ;; esac
        if [ "$PENDING" -eq 0 ]; then
            BAD=$(gh run list --repo "$REPO" --branch "$NEW_BRANCH" --limit 20 \
                --json conclusion --jq '[.[]|select(.conclusion!="success" and .conclusion!="skipped" and .conclusion!="neutral")]|length' 2>/dev/null || echo 1)
            case "$BAD" in ''|*[!0-9]*) BAD=1 ;; esac
            if [ "$BAD" -eq 0 ]; then info "every run on the branch succeeded"; break; fi
            info "runs did not all succeed ($BAD) — inspect $PR_URL"
            [ "${FORCE_MERGE:-0}" = "1" ] || die "refusing to merge a repin whose runs did not succeed (FORCE_MERGE=1 to override, HOLD=1 to stop at the PR)"
            break
        fi
        [ "$(date +%s)" -lt "$DEADLINE" ] || die "run watch timed out — the PR is open at $PR_URL"
        sleep 20
    done
fi

say "merging the repin PR"
gh pr merge "$PR_NUM" --repo "$REPO" --squash --delete-branch --body "Merged by feed-repin.sh — repin only, no other feed-side file changes." \
    || die "merge failed (branch protection / required checks?) — the PR is open at $PR_URL"
MERGE_SHA=$(gh pr view "$PR_NUM" --repo "$REPO" --json mergeCommit --jq .mergeCommit.oid)
[ -n "$MERGE_SHA" ] && [ "$MERGE_SHA" != "null" ] || die "could not read the merge commit sha"
info "merged as $MERGE_SHA"

if [ "${HOLD:-0}" = "1" ]; then
    say "HOLD=1 — stopping before the tag. PR: $PR_URL (merge commit $MERGE_SHA)"
    exit 0
fi

# ---------------------------------------------------------------------- tag + publish
say "creating the release tag $NEW_TAG -> $MERGE_SHA (server-side, no local hooks involved)"
gh api "repos/$REPO/git/refs" -f "ref=refs/tags/$NEW_TAG" -f "sha=$MERGE_SHA" >/dev/null || die "could not create the tag"
info "tag created"

say "waiting for the release-publish workflow (bound: 45 min)"
RUN_ID=""
for _ in $(seq 1 90); do
    RUN_ID=$(gh run list --repo "$REPO" --workflow release-publish.yml --limit 15 \
        --json databaseId,headBranch,status --jq "[.[]|select(.headBranch==\"$NEW_TAG\")][0].databaseId" 2>/dev/null || true)
    [ -n "$RUN_ID" ] && [ "$RUN_ID" != "null" ] && break
    sleep 15
done
[ -n "$RUN_ID" ] && [ "$RUN_ID" != "null" ] || die "no release-publish run appeared for $NEW_TAG — check https://github.com/$REPO/actions"
info "run: https://github.com/$REPO/actions/runs/$RUN_ID"
timeout 2700 gh run watch "$RUN_ID" --repo "$REPO" --exit-status >/dev/null 2>&1 || true
RUN_CONC=$(gh run view "$RUN_ID" --repo "$REPO" --json status,conclusion --jq '"\(.status) \(.conclusion)"')
info "run: $RUN_CONC"

# -------------------------------------------------------------------------- verify
say "verifying the published release"
sleep 5
gh release view "$NEW_TAG" --repo "$REPO" --json url,tagName,assets \
    --jq '.url, "assets: \(.assets|length)", (.assets[].name)' > "$WORK/rel.txt" || die "no release found for $NEW_TAG"
cat "$WORK/rel.txt" | sed 's/^/    /'
grep -q 'SHA256SUMS'      "$WORK/rel.txt" || die "release has no SHA256SUMS asset"
grep -q 'aarch64'         "$WORK/rel.txt" || die "release has no aarch64 package asset"

say "PLAIN ANSWER"
cat <<EOF
    release      : $(head -1 "$WORK/rel.txt")
    tag          : $NEW_TAG
    module commit: $TARGET ($TARGET7)
    feed pin     : PKG_SOURCE_VERSION=$TARGET
    pkg version  : $NEW_VER   (PKG_SOURCE_TAG=$VERSION_FILE)
    PKG_HASH     : $NEW_HASH
    repin PR     : $PR_URL (merged as $MERGE_SHA)
    assets       : $(sed -n '2p' "$WORK/rel.txt")
EOF
say "done"
