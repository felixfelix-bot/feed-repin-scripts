#!/usr/bin/env bash
# release-entry-ui.sh — finish the entry_ui pre-release in ONE command.
#
# What it does, in order, refusing to proceed at every step it cannot verify:
#   1. verifies this gh account is the feed maintainer
#   2. waits for the feed re-vendor PR's checks to go GREEN, then merges it
#   3. proves the flip is really in the feed tree (portal pin + mode-aware 92)
#   4. runs feed-repin.sh: module pin PR -> merge -> tag -> release-publish
#   5. proves the PUBLISHED aarch64 artifact carries the mode-aware 92
#   6. prints the tester one-liner + what to expect on hardware
#
# Usage:
#   curl -fsSL -o /tmp/r.sh https://raw.githubusercontent.com/felixfelix-bot/feed-repin-scripts/main/scripts/release-entry-ui.sh && bash /tmp/r.sh
#   CHECK_ONLY=1 bash /tmp/r.sh     # verify everything, change nothing
#
# Never force-pushes, never rewrites history, never merges a red check.
set -euo pipefail

REPO=FreedomTechFeed/packages
REVENDOR_PR=51
PIN_SHA=cb4db7f0152f804a3250516c5ec7c05346dfddaa
PORTAL_SHA=752df98935d7a5106cc1388ff6bc96a50d41d696
TAG=v0.6.0-rc1-pre25
ARCH=aarch64_cortex-a53
REPIN_URL=https://raw.githubusercontent.com/felixfelix-bot/feed-repin-scripts/main/scripts/feed-repin.sh
WORK=$(mktemp -d "${TMPDIR:-/tmp}/tg-release.XXXXXX"); trap 'rm -rf "$WORK"' EXIT
CHECK_ONLY=${CHECK_ONLY:-0}
say() { printf '\n== %s\n' "$*"; }
die() { printf '\nFATAL: %s\n' "$*" >&2; exit 1; }

say "0. this account must be the feed maintainer"
gh auth status 2>&1 | grep -E 'Logged in|account ' | head -2
gh api "repos/$REPO" --jq .permissions | grep -q '"push":true' \
  || die "this gh account cannot push to $REPO. Run this as the feed maintainer (c03rad0r)."

say "1. the feed re-vendor PR (#$REVENDOR_PR) must be green — nothing merges on red"
gh pr view "$REVENDOR_PR" --repo "$REPO" \
  --json state,mergeable,mergeStateStatus,headRefName \
  --jq '"  state=\(.state)  mergeable=\(.mergeable)  \(.mergeStateStatus)  head=\(.headRefName)"'
STATE=$(gh pr view "$REVENDOR_PR" --repo "$REPO" --json state --jq .state)
if [ "$STATE" = OPEN ]; then
  DEADLINE=$(( $(date +%s) + 3600 ))
  while :; do
    read -r TOTAL PEND FAIL <<EOF
$(gh pr checks "$REVENDOR_PR" --repo "$REPO" --json bucket \
   --jq '"\(length) \([.[]|select(.bucket=="pending")]|length) \([.[]|select(.bucket=="fail" or .bucket=="cancel")]|length)"')
EOF
    echo "  checks: ${TOTAL:-0} total, ${PEND:-0} pending, ${FAIL:-0} failing"
    [ "${FAIL:-0}" -gt 0 ] && die "a check is FAILING on PR #$REVENDOR_PR. Inspect: gh pr checks $REVENDOR_PR --repo $REPO"
    [ "${PEND:-0}" -eq 0 ] && break
    [ "$(date +%s)" -lt "$DEADLINE" ] || die "checks did not finish within 60 min — re-run this command, it resumes safely"
    sleep 45
  done
  if [ "$CHECK_ONLY" = 1 ]; then
    echo "  CHECK_ONLY=1 — would merge PR #$REVENDOR_PR here."
  else
    say "2. merging the re-vendor PR (squash)"
    gh pr merge "$REVENDOR_PR" --repo "$REPO" --squash --delete-branch \
      --body "Merged by release-entry-ui.sh — re-vendors the captive-portal half at the entry_ui revision (portal #67)." \
      || die "merge failed — nothing else was changed"
  fi
else
  echo "  PR is $STATE — nothing to merge."
fi

say "3. prove the flip is in the feed tree (not just claimed)"
LOCK=$(gh api "repos/$REPO/contents/net/tollgate-wrt/vendor.lock.json" --jq .content | base64 -d)
echo "$LOCK" | grep -q "$PORTAL_SHA" \
  || die "vendor.lock.json does not pin portal_commit=$PORTAL_SHA — the vendored portal is NOT the entry_ui revision"
echo "  OK vendor.lock.json -> portal_commit $PORTAL_SHA"
gh api "repos/$REPO/contents/net/tollgate-wrt/files/uci-defaults/92-tollgate-admin-setup" --jq .content \
  | base64 -d > "$WORK/92"
grep -q "entry-ui-mapping" "$WORK/92" \
  || die "the vendored 92 does NOT write the D4 marker — the flip would ship INVISIBLY (module 99 would repair to luci)"
grep -q "entry_ui" "$WORK/92" || die "the vendored 92 has no entry_ui logic"
echo "  OK vendored 92 is mode-aware (entry_ui + D4 marker)"

say "4. pin the module and publish $TAG   <-- the tag/publish gate"
if [ "$CHECK_ONLY" = 1 ]; then
  echo "  CHECK_ONLY=1 — would now run feed-repin.sh ($REPIN_URL) to pin $PIN_SHA, tag $TAG and publish."
else
  curl -fsSL -o "$WORK/feed-repin.sh" "$REPIN_URL" || die "could not fetch feed-repin.sh"
  bash "$WORK/feed-repin.sh" "$PIN_SHA" || die "feed-repin.sh failed — read its output above; the release was NOT completed"
fi

if [ "$CHECK_ONLY" = 1 ]; then
  say "CHECK_ONLY done — every precondition above was verified; nothing was changed."
  exit 0
fi

say "5. prove the PUBLISHED artifact carries the flip (bytes, not a claim)"
gh release download "$TAG" --repo "$REPO" --pattern "*${ARCH}*.apk" --dir "$WORK" --clobber 2>/dev/null \
  || gh release download "$TAG" --repo "$REPO" --pattern "*${ARCH}*.ipk" --dir "$WORK" --clobber \
  || die "could not download a ${ARCH} artifact for $TAG"
ART=$(ls "$WORK" | grep -E "${ARCH}.*\.(apk|ipk)$" | head -1)
echo "  artifact: $ART"
mkdir -p "$WORK/x"; tar xzf "$WORK/$ART" -C "$WORK/x" 2>/dev/null || true
for inner in "$WORK"/x/data.tar.gz "$WORK"/x/*.tar.gz; do
  [ -f "$inner" ] && tar xzf "$inner" -C "$WORK/x" 2>/dev/null || true
done
PUB=$(find "$WORK/x" -name '92-tollgate-admin-setup' | head -1)
[ -n "$PUB" ] || die "the published artifact does not contain 92-tollgate-admin-setup at all"
grep -q "entry-ui-mapping" "$PUB" \
  || die "the PUBLISHED 92 is not mode-aware — the flip is NOT in the shipped bytes"
echo "  OK the PUBLISHED $ART ships the mode-aware 92 (entry_ui + D4 marker present)"

say "DONE — $TAG is published and verified"
echo "  release : https://github.com/$REPO/releases/tag/$TAG"
echo "  assets  : $(gh release view "$TAG" --repo "$REPO" --json assets --jq '.assets|length') files"
echo
echo "Tester install one-liner:"
echo "  bash <(curl -fsSL https://raw.githubusercontent.com/OpenTollGate/tollgate-installer/main/install-and-test.sh)"
echo
echo "What the manual test must show on the router (this is the flip):"
echo "  :8080 + :443  -> the BOARD  (config UI, /www/tollgate)"
echo "  :8090 + :8443 -> LuCI"
echo "  marker /etc/tollgate/entry-ui-mapping must exist and read: board"
echo "  and the board must show a working LuCI link (from ui_links, https only)"
