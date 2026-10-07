#!/usr/bin/env bash
# finish-pre25.sh — merge the pre25 pin PR and TAG it, without waiting on the
# pre-merge multi-arch test build (which is the thing that wedged: the a53 job
# built the package fine, then hung 2h in "Register QEMU", a Docker Hub pull).
#
# The tag is what triggers release-publish.yml — the lane that actually builds,
# tests and publishes every arch + SHA256SUMS + offline bundles.
#
# This script does NOT trust CI for the pin: it re-derives the hash itself.
#
# Usage:
#   curl -fsSL -o /tmp/f.sh https://raw.githubusercontent.com/felixfelix-bot/feed-repin-scripts/main/scripts/finish-pre25.sh && bash /tmp/f.sh
#   CHECK_ONLY=1 bash /tmp/f.sh      # verify everything, merge nothing
set -euo pipefail

REPO=FreedomTechFeed/packages
PR=52
BR=pr/tollgate-wrt-0.6.0-rc1-pre25
TAG=v0.6.0-rc1-pre25
SHA_EXPECT=cb4db7f0152f804a3250516c5ec7c05346dfddaa
HASH_EXPECT=1ad7890ad0e09fbb844b4789c0fc767dc76d2cf1727827a0eb5f7b665aa53421
ARCH=aarch64_cortex-a53
WORK=$(mktemp -d "${TMPDIR:-/tmp}/tg-finish.XXXXXX"); trap 'rm -rf "$WORK"' EXIT
CHECK_ONLY=${CHECK_ONLY:-0}
say(){ printf '\n== %s\n' "$*"; }
die(){ printf '\nFATAL: %s\n' "$*" >&2; exit 1; }

say "0. maintainer check"
gh auth status 2>&1 | grep -E 'Logged in|account ' | head -2
gh api "repos/$REPO" --jq .permissions | grep -q '"push":true' || die "no push rights on $REPO"

say "1. the pin PR (#$PR) — a FAILING check is a stop, a pending build is not"
gh pr view "$PR" --repo "$REPO" --json state,mergeable,mergeStateStatus,headRefName \
  --jq '"  state=\(.state)  mergeable=\(.mergeable)  \(.mergeStateStatus)  head=\(.headRefName)"'
STATE=$(gh pr view "$PR" --repo "$REPO" --json state --jq .state)
[ "$STATE" = OPEN ] || say "  PR is already $STATE — will tag the merge commit if it is on master"
gh pr view "$PR" --repo "$REPO" --json statusCheckRollup \
  --jq '[.statusCheckRollup[]?] | "  checks: \(length) total, \([.[]|select(.conclusion=="FAILURE" or .conclusion=="CANCELLED" or .conclusion=="TIMED_OUT")]|length) failing, \([.[]|select(.status!="COMPLETED")]|length) unfinished"'
FAILN=$(gh pr view "$PR" --repo "$REPO" --json statusCheckRollup \
  --jq '[.statusCheckRollup[]?|select(.conclusion=="FAILURE" or .conclusion=="CANCELLED" or .conclusion=="TIMED_OUT")]|length')
[ "$FAILN" = 0 ] || die "$FAILN check(s) FAILED on PR #$PR — inspect before tagging: gh pr checks $PR --repo $REPO"
UNFIN=$(gh pr view "$PR" --repo "$REPO" --json statusCheckRollup \
  --jq '[.statusCheckRollup[]?|select(.status!="COMPLETED")]|length')
if [ "$UNFIN" != 0 ]; then
  echo "  NOTE: $UNFIN check(s) still unfinished — these are pre-merge test builds;"
  echo "        they do not gate the release (release-publish rebuilds every arch on the tag)."
  echo "        Unfinished: $(gh pr view "$PR" --repo "$REPO" --json statusCheckRollup --jq '[.statusCheckRollup[]?|select(.status!="COMPLETED")|.name]|join(", ")')"
fi

say "2. verify the pin MYSELF (do not trust a wedged CI)"
MKGREP=$(gh api "repos/$REPO/contents/net/tollgate-wrt/Makefile?ref=$BR" --jq .content | base64 -d) || die "cannot read the branch Makefile"
SHA=$(printf '%s\n' "$MKGREP" | grep -m1 '^PKG_SOURCE_VERSION:=' | cut -d= -f2-)
HASH=$(printf '%s\n' "$MKGREP" | grep -m1 '^PKG_HASH:=' | cut -d= -f2-)
VTAG=$(printf '%s\n' "$MKGREP" | grep -m1 '^PKG_SOURCE_TAG:=' | cut -d= -f2-)
PV=$(printf '%s\n' "$MKGREP" | grep -m1 '^PKG_VERSION:=' | cut -d= -f2-)
for pair in "PKG_SOURCE_VERSION:$SHA" "PKG_HASH:$HASH" "PKG_SOURCE_TAG:$VTAG" "PKG_VERSION:$PV"; do
  [ -n "${pair#*:}" ] || die "${pair%%:*} is empty in the branch Makefile"
done
[ "$SHA" = "$SHA_EXPECT" ] || die "pin is $SHA, expected $SHA_EXPECT"
[ "$PV"  = "0.6.0_rc1_pre25" ] || die "PKG_VERSION is $PV, expected 0.6.0_rc1_pre25"
curl -fsSL --retry 3 -o "$WORK/src.tar.gz" "https://codeload.github.com/OpenTollGate/tollgate-module-basic-go/tar.gz/$SHA" || die "tarball download failed"
GOT=$(sha256sum "$WORK/src.tar.gz" | cut -d' ' -f1)
[ -n "$GOT" ] || die "no hash computed"
[ "$GOT" = "$HASH" ] || die "Gate A: PKG_HASH $HASH != recomputed $GOT"
[ "$GOT" = "$HASH_EXPECT" ] || die "Gate A: recomputed hash is not the expected pre25 hash"
VER=$(tar xzOf "$WORK/src.tar.gz" --wildcards '*/VERSION' 2>/dev/null | head -1 | tr -d '\n')
[ -n "$VER" ] || die "no VERSION inside the tarball"
[ "$VER" = "$VTAG" ] || die "Gate B: PKG_SOURCE_TAG '$VTAG' != tarball VERSION '$VER'"
N=$(tar xzOf "$WORK/src.tar.gz" --wildcards '*/packaging/files/etc/uci-defaults/99-tollgate-setup' 2>/dev/null | grep -c 'entry_ui')
[ "$N" -gt 0 ] || die "the pinned tarball has no entry_ui in 99 — wrong commit"
echo "  Gate A PASS (hash matches a fresh download)   Gate B PASS ($VER)"
echo "  the flip is inside the tarball: $N entry_ui refs in 99"
gh api "repos/$REPO/git/refs/tags/$TAG" >/dev/null 2>&1 && die "tag $TAG already exists" || echo "  tag $TAG is free"

if [ "$CHECK_ONLY" = 1 ]; then say "CHECK_ONLY=1 — every precondition verified; nothing merged, nothing tagged."; exit 0; fi

say "3. merge the pin PR (squash)"
if [ "$STATE" = OPEN ]; then
  gh pr merge "$PR" --repo "$REPO" --squash --delete-branch \
    --body "Merged by finish-pre25.sh — pre25 pin. The pre-merge multi-arch test build was wedged in Register QEMU; the pin is verified independently (Gate A hash + Gate B tag) and release-publish rebuilds every arch on the tag." \
    || die "merge failed — nothing was tagged"
fi
MERGE_SHA=$(gh pr view "$PR" --repo "$REPO" --json mergeCommit --jq .mergeCommit.oid)
[ -n "$MERGE_SHA" ] || die "no merge commit sha"
echo "  merge commit: $MERGE_SHA"

say "4. TAG $TAG at the merge commit (server-side; this is the publish trigger)"
gh api --method POST "repos/$REPO/git/refs" -f ref="refs/tags/$TAG" -f sha="$MERGE_SHA" \
  --jq '"  created \(.ref) -> \(.object.sha[0:10])"' || die "tag creation failed"
gh api "repos/$REPO/git/refs/tags/$TAG" --jq '"  verified: \(.ref) -> \(.object.sha[0:10])"'

say "5. waiting for release-publish.yml on $TAG (bound: 100 min)"
DEADLINE=$(( $(date +%s) + 6000 ))
RUN=""
while [ -z "$RUN" ]; do
  RUN=$(gh run list --repo "$REPO" --workflow release-publish.yml --limit 20 \
        --json databaseId,headBranch,status --jq "[.[]|select(.headBranch==\"$TAG\")][0].databaseId" 2>/dev/null || true)
  [ -n "$RUN" ] && [ "$RUN" != null ] && break
  [ "$(date +%s)" -lt "$DEADLINE" ] || die "no release-publish run appeared for $TAG — check https://github.com/$REPO/actions"
  sleep 20
done
echo "  run: https://github.com/$REPO/actions/runs/$RUN"
while :; do
  S=$(gh run view "$RUN" --repo "$REPO" --json status,conclusion --jq '"\(.status) \(.conclusion)"')
  echo "  $S"
  case "$S" in
    completed*) break;;
  esac
  [ "$(date +%s)" -lt "$DEADLINE" ] || die "release-publish did not finish within 100 min — run https://github.com/$REPO/actions/runs/$RUN"
  sleep 60
done
case "$S" in
  completed\ success) echo "  release-publish SUCCEEDED";;
  *) die "release-publish did not succeed ($S) — see https://github.com/$REPO/actions/runs/$RUN";;
esac

say "6. verify the PUBLISHED artifact carries the flip"
gh release view "$TAG" --repo "$REPO" --json assets --jq '"  assets: \(.assets|length)"'
gh release download "$TAG" --repo "$REPO" --pattern "*${ARCH}*.apk" --dir "$WORK" --clobber 2>/dev/null \
  || gh release download "$TAG" --repo "$REPO" --pattern "*${ARCH}*.ipk" --dir "$WORK" --clobber \
  || die "no $ARCH artifact on the release"
ART=$(ls "$WORK" | grep -E "${ARCH}.*\.(apk|ipk)$" | head -1)
mkdir -p "$WORK/x"; tar xzf "$WORK/$ART" -C "$WORK/x" 2>/dev/null || true
for i in "$WORK"/x/data.tar.gz "$WORK"/x/*.tar.gz; do [ -f "$i" ] && tar xzf "$i" -C "$WORK/x" 2>/dev/null || true; done
PUB=$(find "$WORK/x" -name '92-tollgate-admin-setup' | head -1)
[ -n "$PUB" ] || die "the published artifact does not contain 92-tollgate-admin-setup"
grep -q 'entry-ui-mapping' "$PUB" || die "the PUBLISHED 92 is NOT mode-aware — the flip is not in the shipped bytes"
echo "  OK $ART ships the mode-aware 92 (D4 marker present)"

say "DONE — $TAG published and verified"
echo "  release: https://github.com/$REPO/releases/tag/$TAG"
echo
echo "Tester install one-liner:"
echo "  bash <(curl -fsSL https://raw.githubusercontent.com/OpenTollGate/tollgate-installer/main/install-and-test.sh)"
echo
echo "Manual test must show (the flip):"
echo "  :8080 + :443  -> the BOARD (config UI)"
echo "  :8090 + :8443 -> LuCI   + a working LuCI link on the board"
echo "  /etc/tollgate/entry-ui-mapping must exist and read: board"
