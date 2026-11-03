#!/usr/bin/env bash
# Re-applies deliberate breakages to a scratch copy and asserts the test suite FAILS for each.
# Usage: scripts/mutation-check.sh   (needs swift + python3; leaves the working tree untouched)
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
status=0
mutate() { # name file from to
  local dir; dir="$(mktemp -d)"
  cp -R "$ROOT/Package.swift" "$ROOT/Sources" "$ROOT/Tests" "$dir/"
  if ! python3 - "$dir/$2" "$3" "$4" <<'PY'
import sys
p, f, t = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p).read()
if f not in s:
    sys.exit(f"pattern not found in {p}")
open(p, "w").write(s.replace(f, t, 1))
PY
  then
    echo "STALE:    $1  (pattern no longer in the source — update the mutation)"; status=1
  elif ! (cd "$dir" && swift build --build-tests >/dev/null 2>&1); then
    echo "BROKEN:   $1  (mutation does not compile — fix the mutation, it proves nothing)"; status=1
  elif (cd "$dir" && swift test >/dev/null 2>&1); then
    echo "SURVIVED: $1  (tests still pass with the breakage — coverage gap)"; status=1
  else
    echo "caught:   $1"
  fi
  rm -rf "$dir"
}
mutate "ledger dedupe removed"      Sources/ThreadSession/ThreadSession.swift "if spec.hasSideEffects, let cached" "if false, let cached"
mutate "post-await epoch guard removed" Sources/ThreadSession/ThreadSession.swift "guard epoch == myEpoch else { throw ThreadSessionError.cancelledByReset }

            transcript.append(response.message)" "transcript.append(response.message)"
mutate "digest check reduced to count" Sources/ThreadSession/Planning.swift "local == anchor.syncedDigest" "local == local"
mutate "rollback on failure removed" Sources/ThreadSession/ThreadSession.swift "                transcript.truncate(to: startCount)
" ""
mutate "keep-warm post-await guard removed" Sources/ThreadSession/ThreadSession.swift "guard epoch == myEpoch, anchor == current else { return .skip(.cancelledByReset) }" ""
mutate "keep-warm ack not mirrored" Sources/ThreadSession/ThreadSession.swift "for message in ack.appended { transcript.append(message) }" ""
mutate "tool post-await epoch guard removed" Sources/ThreadSession/ThreadSession.swift "guard epoch == myEpoch else { throw ThreadSessionError.cancelledByReset }
                    executed" "executed"
mutate "ping allowed during a turn" Sources/ThreadSession/ThreadSession.swift "if inFlight { return .skip(.turnInFlight) }" ""
mutate "dropThread allowed in flight" Sources/ThreadSession/ThreadSession.swift "guard !inFlight else { return false }
        anchor = nil" "anchor = nil"
mutate "retry budget per turn, not per request" Sources/ThreadSession/ThreadSession.swift "            retriedRejection = false
" ""
mutate "reset keeps the ledger" Sources/ThreadSession/ThreadSession.swift "        ledger.removeAll()
        consecutivePings = 0" "        consecutivePings = 0"
mutate "send catch-path epoch guard removed" Sources/ThreadSession/ThreadSession.swift "                guard epoch == myEpoch else { throw ThreadSessionError.cancelledByReset }
                let transportError" "                let transportError"
mutate "rehydrating sticks after a failed turn" Sources/ThreadSession/ThreadSession.swift "            inFlight = false
            rehydrating = false" "            inFlight = false"
mutate "anchor kept after a rollback" Sources/ThreadSession/ThreadSession.swift "                    anchor = nil
                    rolledBack = true" "                    rolledBack = true"
mutate "ping allowed on a rewritten prefix" Sources/ThreadSession/ThreadSession.swift "guard transcript.digest(ofPrefix: current.syncedCount) == current.syncedDigest else { return .skip(.prefixDiverged) }" ""
exit $status
