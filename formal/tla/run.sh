#!/usr/bin/env bash
# Model-checks every configuration and compares the outcome with the expected
# one: the shipped design must pass, each bug variant must fail on its named
# property, and each reach_* check must fail (proving the model is not vacuous).
# Exits non-zero on any mismatch.
#
# Needs Java 11+ (set JAVA=/path/to/java if the one on PATH is older).
# Downloads the pinned TLA+ tools jar into .tools/ on first run.
#
#   formal/tla/run.sh                     # everything
#   formal/tla/run.sh cli_installer/bug_order.cfg   # one config, full TLC output
set -euo pipefail
cd "$(dirname "$0")"

TLA_VERSION=1.8.0
TLA_SHA256=32d64fbbc464559fc7192341b27b885fa4eb6b92d1648d2b49fb9cdcb7aacf81
JAR=.tools/tla2tools-$TLA_VERSION.jar
JAVA=${JAVA:-java}

if [[ ! -f $JAR ]]; then
  mkdir -p .tools
  curl -fsSL -o "$JAR.tmp" \
    "https://github.com/tlaplus/tlaplus/releases/download/v$TLA_VERSION/tla2tools.jar"
  actual=$(shasum -a 256 "$JAR.tmp" | cut -d' ' -f1)
  if [[ $actual != "$TLA_SHA256" ]]; then
    rm -f "$JAR.tmp"
    echo "tla2tools.jar checksum mismatch: expected $TLA_SHA256, got $actual" >&2
    exit 1
  fi
  mv "$JAR.tmp" "$JAR"
fi

java_major=$("$JAVA" -version 2>&1 | sed -nE '1s/.*version "(1\.)?([0-9]+).*/\2/p')
if [[ -z $java_major || $java_major -lt 11 ]]; then
  echo "TLC needs Java 11+; '$JAVA' is ${java_major:-unknown}. Set JAVA=/path/to/java." >&2
  exit 1
fi

tlc() { # spec cfg
  "$JAVA" -XX:+UseParallelGC -cp "$JAR" tlc2.TLC -workers auto -deadlock \
    -noGenerateSpecTE -metadir .tools/states -config "$2" "$1" 2>&1
}

spec_for() {
  case $1 in
    cli_installer/*) echo CLIInstaller.tla ;;
    control_protocol/*) echo ControlProtocol.tla ;;
    *) echo "unknown config $1" >&2; exit 1 ;;
  esac
}

if [[ $# -gt 0 ]]; then
  for cfg in "$@"; do tlc "$(spec_for "$cfg")" "$cfg"; done
  exit 0
fi

# config => "pass", or the property TLC must report as violated
EXPECTED=(
  cli_installer/good.cfg                       pass
  cli_installer/good_big.cfg                   pass
  cli_installer/bug_order.cfg                  NeverLoseWorkingInstall
  cli_installer/bug_resolve.cfg                NoDowngrade
  cli_installer/bug_sweep.cfg                  LiveDownloadsIntact
  cli_installer/reach_upgrade.cfg              NoUpgradeEverHappens
  cli_installer/reach_crash.cfg                NoCrashLeftovers
  cli_installer/reach_mismatch_crash.cfg       NoMismatchLeftByCrash
  cli_installer/reach_mismatch_fail.cfg        NoMismatchLeftByFailedRename
  control_protocol/good.cfg                    pass
  control_protocol/bug_detect_after_write.cfg  NoHalfExecutedRequest
  control_protocol/bug_nonatomic.cfg           EverySenderFinishes
  control_protocol/bug_nocheck.cfg             EverySenderFinishes
  control_protocol/bug_edge_thread.cfg         EverySenderFinishes
  control_protocol/reach_resp.cfg              NobodyGetsAResponse
  control_protocol/reach_err.cfg               NobodyGetsAnError
)

failures=0
for ((k = 0; k < ${#EXPECTED[@]}; k += 2)); do
  cfg=${EXPECTED[k]} want=${EXPECTED[k + 1]}
  out=$(tlc "$(spec_for "$cfg")" "$cfg" || true)
  if grep -q 'No error has been found' <<<"$out"; then
    got=pass
  else
    got=$(sed -nE 's/.*(Invariant|Temporal property) ([A-Za-z]+) (is|was) violated.*/\2/p' <<<"$out" | head -1)
    got=${got:-error}
  fi
  if [[ $got == "$want" ]]; then
    printf 'ok    %-44s %s\n' "$cfg" "$got"
  else
    printf 'FAIL  %-44s expected %s, got %s\n' "$cfg" "$want" "$got"
    [[ $got == error ]] && grep -E 'Error|error' <<<"$out" | head -5 | sed 's/^/        /'
    failures=$((failures + 1))
  fi
done

exit $((failures > 0))
