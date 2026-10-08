#!/usr/bin/env bash
# finish-pre26.sh — merge the pre26 pin PR and TAG it, without waiting on the
# pre-merge multi-arch test build (the one that wedged on pre25: the a53 job
# built the package fine, then hung 2h in "Register QEMU", a Docker Hub pull).
#
# The tag is what triggers release-publish.yml — the lane that actually builds,
# tests and publishes every arch + SHA256SUMS + offline bundles.
#
# This script does NOT trust CI for the pin: it re-derives the hash itself.
#
# Usage:
#   curl -fsSL -o /tmp/f.sh https://raw.githubusercontent.com/felixfelix-bot/feed-repin-scripts/main/scripts/finish-pre26.sh && bash /tmp/f.sh
#   CHECK_ONLY=1 bash /tmp/f.sh      # verify everything, merge nothing
set -euo pipefail

REPO=FreedomTechFeed/packages
MOD=OpenTollGate/tollgate-module-basic-go
BR=pr/tollgate-wrt-0.6.0-rc1-pre26          # resolved to a PR number below — never hardcoded
TAG=v0.6.0-rc1-pre26
SHA_EXPECT=4614ac274dca471bb7739488b242919e1b6958cc
HASH_EXPECT=7da4e88d0805c42f692ca0921632a404f569b56bac33eada97429deaaddbe446
VER_EXPECT=0.6.0_rc1_pre26
TAG_STRING_EXPECT=v0.6.0-rc1
ARCH=aarch64_cortex-a53
WORK=$(mktemp -d "${TMPDIR:-/tmp}/tg-finish.XXXXXX"); trap 'rm -rf "$WORK"' EXIT
CHECK_ONLY=${CHECK_ONLY:-0}
say(){ printf '\n== %s\n' "$*"; }
die(){ printf '\nFATAL: %s\n' "$*" >&2; exit 1; }

say "0. maintainer check"
gh auth status 2>&1 | grep -E 'Logged in|account ' | head -2
gh api "repos/$REPO" --jq .permissions | grep -q '"push":true' || die "no push rights on $REPO"

say "1. resolve the pre26 pin PR from its branch (no hardcoded number to go stale)"
PR=$(gh pr list --repo "$REPO" --head "$BR" --state all --json number,state \
      --jq '.[0].number // empty' 2>/dev/null || true)
[ -n "$PR" ] || die "no PR found for branch $BR — run feed-repin.sh first"
PRSTATE=$(gh pr view "$PR" --repo "$REPO" --json state --jq .state)
echo "  PR #$PR  state=$PRSTATE  head=$BR"
gh pr view "$PR" --repo "$REPO" --json mergeable,mergeStateStatus \
  --jq '"  mergeable=\(.mergeable)  \(.mergeStateStatus)"'
[ "$PRSTATE" = OPEN ] || say "  PR is already $PRSTATE — will tag the merge commit if it is on master"
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
gh api "repos/$REPO/contents/net/tollgate-wrt/Makefile?ref=$BR" --jq .content | base64 -d > "$WORK/Makefile.branch" \
  || die "cannot read the branch Makefile at $BR"
[ -s "$WORK/Makefile.branch" ] || die "the branch Makefile came back empty"
# NOTE (measured: exit 141 = SIGPIPE): NEVER pipe a producer into an
# early-exiting reader (grep -m1, head -1) under `set -o pipefail` — the reader
# closes the pipe, the producer dies of SIGPIPE, the pipeline returns 141 and
# `set -e` exits the script SILENTLY. awk reads to EOF and prints once instead.
mval() { awk -F':=' -v k="$1" '$1==k && !seen { print $2; seen=1 }' "$WORK/Makefile.branch"; }
SHA=$(mval PKG_SOURCE_VERSION); HASH=$(mval PKG_HASH); VTAG=$(mval PKG_SOURCE_TAG); PV=$(mval PKG_VERSION)
for pair in "PKG_SOURCE_VERSION:$SHA" "PKG_HASH:$HASH" "PKG_SOURCE_TAG:$VTAG" "PKG_VERSION:$PV"; do
  [ -n "${pair#*:}" ] || die "${pair%%:*} is empty in the branch Makefile"
done
[ "$SHA" = "$SHA_EXPECT" ] || die "pin is $SHA, expected $SHA_EXPECT"
[ "$PV"  = "$VER_EXPECT" ] || die "PKG_VERSION is $PV, expected $VER_EXPECT"
[ "$VTAG" = "$TAG_STRING_EXPECT" ] || die "PKG_SOURCE_TAG is $VTAG, expected $TAG_STRING_EXPECT"
# The archive bytes depend on the REF STRING: a 12-char short sha returns a
# DIFFERENT tarball (1830357 B) than the full 40-char sha (1829976 B), because the
# root directory inside is named after the ref as requested. Always hash the FULL
# sha, exactly as PKG_SOURCE_URL interpolates it.
curl -fsSL --retry 3 -o "$WORK/src.tar.gz" "https://codeload.github.com/$MOD/tar.gz/$SHA" || die "tarball download failed"
GOT=$(sha256sum "$WORK/src.tar.gz" | cut -d' ' -f1)
[ -n "$GOT" ] || die "no hash computed"
[ "$GOT" = "$HASH" ] || die "Gate A: PKG_HASH $HASH != recomputed $GOT"
[ "$GOT" = "$HASH_EXPECT" ] || die "Gate A: recomputed hash is not the expected pre26 hash"
VER=$(tar xzOf "$WORK/src.tar.gz" --wildcards '*/VERSION' 2>/dev/null | awk 'NR==1{print;exit}' | tr -d '\n')
[ -n "$VER" ] || die "no VERSION inside the tarball"
[ "$VER" = "$VTAG" ] || die "Gate B: PKG_SOURCE_TAG '$VTAG' != tarball VERSION '$VER'"
N=$(tar xzOf "$WORK/src.tar.gz" --wildcards '*/packaging/files/etc/uci-defaults/99-tollgate-setup' 2>/dev/null | grep -c 'entry_ui')
[ "$N" -gt 0 ] || die "the pinned tarball has no entry_ui in 99 — wrong commit"
U=$(tar xzOf "$WORK/src.tar.gz" --wildcards '*/docs/rc-tester-guide.md' 2>/dev/null | grep -c '8090')
[ "$U" -gt 0 ] || die "the pinned tarball's rc-tester-guide has no :8090 — the #744 doc fix is not in this commit"
echo "  Gate A PASS (hash matches a fresh download)   Gate B PASS ($VER)"
echo "  the flip is inside the tarball: $N entry_ui refs in 99; rc-guide :8090 refs: $U"
gh api "repos/$REPO/git/refs/tags/$TAG" >/dev/null 2>&1 && die "tag $TAG already exists" || echo "  tag $TAG is free"

if [ "$CHECK_ONLY" = 1 ]; then say "CHECK_ONLY=1 — every precondition verified; nothing merged, nothing tagged."; exit 0; fi

say "3. merge the pin PR (squash)"
if [ "$PRSTATE" = OPEN ]; then
  gh pr merge "$PR" --repo "$REPO" --squash --delete-branch \
    --body "Merged by finish-pre26.sh — pre26 pin to the module main tip 4614ac2 (7 commits: #744 #745 #710 #717 #738 #739 #730). The pre-merge multi-arch test build was wedged in Register QEMU on the pre25 cut; the pin is verified independently (Gate A hash + Gate B tag) and release-publish rebuilds every arch on the tag." \
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
  S=$(gh run view "$RUN" --repo "$REPO" --json status,conclusion --jq '"\(.status) \(.conclusion)"' 2>/dev/null || echo "unknown ")
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

say "6. verify the PUBLISHED artifact carries the pre26 changes"
gh release view "$TAG" --repo "$REPO" --json assets --jq '"  assets: \(.assets|length)"'
gh release view "$TAG" --repo "$REPO" --json assets \
  --jq '"  apk: \([.assets[].name|select(endswith(".apk"))]|length)  ipk: \([.assets[].name|select(endswith(".ipk"))]|length)  offline bundles: \([.assets[].name|select(test("offline"))]|length)  manifest: \([.assets[].name|select(test("SHA256SUMS"))]|length)"'
gh release download "$TAG" --repo "$REPO" --pattern "*${ARCH}*.apk" --dir "$WORK" --clobber 2>/dev/null \
  || gh release download "$TAG" --repo "$REPO" --pattern "*${ARCH}*.ipk" --dir "$WORK" --clobber \
  || die "no $ARCH artifact on the release"
# find -print -quit instead of `find ... | head -1` (SIGPIPE under pipefail).
ART=$(find "$WORK" -maxdepth 1 -type f -name "*${ARCH}*.apk" -print -quit)
[ -n "$ART" ] || ART=$(find "$WORK" -maxdepth 1 -type f -name "*${ARCH}*.ipk" -print -quit)
[ -n "$ART" ] || die "downloaded artifact not found in $WORK"
ART=$(basename "$ART")
mkdir -p "$WORK/x"; tar xzf "$WORK/$ART" -C "$WORK/x" 2>/dev/null || true
for i in "$WORK"/x/data.tar.gz "$WORK"/x/*.tar.gz; do [ -f "$i" ] && tar xzf "$i" -C "$WORK/x" 2>/dev/null || true; done
PUB=$(find "$WORK/x" -name '92-tollgate-admin-setup' -print -quit)
[ -n "$PUB" ] || die "the published artifact does not contain 92-tollgate-admin-setup"
grep -q 'entry-ui-mapping' "$PUB" || die "the PUBLISHED 92 is NOT mode-aware — the flip is not in the shipped bytes"
echo "  OK $ART ships the mode-aware 92 (D4 marker present)"
# pre26-specific: #745's ui_links answer must be inside the shipped payload
UL=$(grep -ral 'ui_links' "$WORK/x" 2>/dev/null | wc -l | tr -d ' ')
[ "$UL" -gt 0 ] || die "the PUBLISHED artifact has no 'ui_links' anywhere — #745 is NOT in the shipped bytes"
echo "  OK $ART ships ui_links (#745 present in $UL file(s) of the payload)"

say "DONE — $TAG published and verified"
echo "  release: https://github.com/$REPO/releases/tag/$TAG"
echo "  module commit: $SHA"
echo "  package version: $VER_EXPECT   PKG_HASH: $HASH_EXPECT"
echo
echo "Tester install one-liner:"
echo "  bash <(curl -fsSL https://raw.githubusercontent.com/OpenTollGate/tollgate-installer/main/install-and-test.sh)"
echo
echo "Manual test must show:"
echo "  :8080 + :443  -> the BOARD (config UI)"
echo "  :8090 + :8443 -> LuCI   + a working LuCI link on the board"
echo "  /etc/tollgate/entry-ui-mapping must exist and read: board"
