#!/usr/bin/env bash
# End-to-end test for issue #19: a Full Disk Access grant must survive an app
# update.
#
# Run it by hand, from a terminal, on a Mac:
#
#     ./tests/e2e-fda.sh
#
# It is automated except for ONE manual step, which macOS does not allow to be
# scripted: granting Full Disk Access to the test app in System Settings.  The
# script tells you when.  It also needs your password once if the signing
# certificate does not exist yet (see `mac-app-util create-cert`).
#
# What it does:
#   1. builds mac-app-util and the test app in two versions ("v1", "v2")
#   2. creates the signing certificate if missing
#   3. sync-trampolines v1 -> signed copy; launches it; expects DENIED
#   4. you grant Full Disk Access to the signed copy; expects GRANTED
#   5. simulates an update: sync-trampolines v2 -> same location
#   6. launches it; expects GRANTED again, with no new grant
#
# Everything lives in a temp directory, and the TCC entry for the test app is
# reset at the start and at the end.

set -euo pipefail

cd "$(dirname "$0")/.."

IDENTITY="${MAC_APP_UTIL_SIGN_IDENTITY:-mac-app-util user signing}"
BUNDLE_ID="xyz.mac-app-util.test-app"

fail() { printf '\nFAIL: %s\n' "$*" >&2; exit 1; }
step() { printf '\n==> %s\n' "$*"; }
pass() { printf 'PASS: %s\n' "$*"; }

[[ "$(uname)" == Darwin ]] || fail "macOS only"
[[ -t 0 && -t 1 ]] || fail "run this from an interactive terminal"

work="$(mktemp -d)"
cleanup() {
  tccutil reset SystemPolicyAllFiles "$BUNDLE_ID" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

step "Building mac-app-util and the test apps"
mau="$(nix build .#default --no-link --print-out-paths)/bin/mac-app-util"
app1="$(nix build .#test-app --no-link --print-out-paths)/Applications"
app2="$(nix build .#test-app-v2 --no-link --print-out-paths)/Applications"
[[ -x "$mau" ]] || fail "mac-app-util not built"

step "Ensuring signing identity \"$IDENTITY\" exists"
"$mau" create-cert "$IDENTITY"
export MAC_APP_UTIL_SIGN_IDENTITY="$IDENTITY"

# sync-trampolines only acts when its source directory is a symlink, as in a
# real setup where it points into the Nix store.
src="$work/src"
dest="$work/dest"
signed="$dest/TestApp.app"

# Launch through LaunchServices (open), NOT directly: only then does macOS
# attribute the process to the app itself instead of this terminal, which may
# have Full Disk Access of its own.  The app writes its verdict to a file.
run_app() {
  local out="$work/out.txt"
  rm -f "$out"
  open -W -n "$signed" --args "$out"
  [[ -s "$out" ]] || fail "test app produced no output"
  cat "$out"
}

expect() { # expected-version expected-status
  local result
  result="$(run_app)"
  printf '    %s\n' "$result"
  [[ "$result" == "TestApp v$1: Full Disk Access $2" ]] \
    || fail "expected v$1 / $2"
}

step "Resetting any previous Full Disk Access grant for $BUNDLE_ID"
tccutil reset SystemPolicyAllFiles "$BUNDLE_ID" >/dev/null 2>&1 || true

step "Installing v1 as a signed copy"
ln -s "$app1" "$src"
"$mau" sync-trampolines "$src" "$dest"
[[ -d "$signed" ]] || fail "no signed copy at $signed"
codesign --verify --verbose "$signed"
req="$(codesign -dr- "$signed" 2>&1 | grep designated || true)"
printf '    %s\n' "$req"
[[ "$req" == *"certificate leaf"* && "$req" != *cdhash* ]] \
  || fail "designated requirement is not certificate-based"

step "v1 without Full Disk Access must be denied"
expect 1 DENIED
pass "v1 denied before the grant"

step "MANUAL STEP: grant Full Disk Access"
cat <<MSG

  In System Settings → Privacy & Security → Full Disk Access, add this app
  and switch it on:

      $signed

  (Finder and System Settings are being opened for you.  Click "+" and drag
  the revealed app in, or choose it from the file picker.)

MSG
open -R "$signed" || true
open "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles" || true
while true; do
  read -r -p "Press Enter once Full Disk Access is granted... " _
  result="$(run_app)"
  printf '    %s\n' "$result"
  [[ "$result" == "TestApp v1: Full Disk Access GRANTED" ]] && break
  echo "Still denied; try again."
done
pass "v1 granted"

step "Simulating an app update: replace v1 with v2 at the same location"
rm "$src"
ln -s "$app2" "$src"
"$mau" sync-trampolines "$src" "$dest"
codesign --verify --verbose "$signed"
req2="$(codesign -dr- "$signed" 2>&1 | grep designated || true)"
[[ "$req2" == "$req" ]] || fail "designated requirement changed: $req2"
pass "designated requirement unchanged"

step "v2 must still have Full Disk Access (no new grant)"
expect 2 GRANTED
pass "grant survived the update"

printf '\nALL PASSED: a Full Disk Access grant survives an update.\n'
