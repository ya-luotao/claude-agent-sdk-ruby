# TLA+ models

Two small [TLA+](https://lamport.azurewebsites.net/tla/tla.html) models of the SDK's most concurrency-sensitive designs, checked with TLC. They are design documentation that a machine checks, not a proof about the Ruby code: each one models the algorithm a source comment argues for, shows it holds over every interleaving within the model's bounds, and shows that the alternatives the comments warn against really do break.

```bash
formal/tla/run.sh                                   # every config, compared with its expected outcome
formal/tla/run.sh cli_installer/bug_order.cfg       # one config, with TLC's full counterexample trace
JAVA=/opt/homebrew/opt/openjdk/bin/java formal/tla/run.sh   # if the java on PATH is older than 11
```

`run.sh` downloads the pinned `tla2tools.jar` (v1.8.0, SHA-256 checked) into `formal/tla/.tools/` on first use and needs Java 11+. The whole run takes under a minute. Nothing here is shipped in the gem.

Each model has boolean switches. With all of them `TRUE` you get the shipped design, which must pass. Setting one to `FALSE` gives the alternative that a source comment rejects, and TLC must find a counterexample for it. The `reach_*` configs assert that something never happens (an upgrade, a crash leftover, an error outcome) and are expected to fail. They show that the model actually reaches the states the properties talk about, so a `pass` is not vacuous.

## `CLIInstaller.tla`: install, publish, sweep

Models `CLIInstaller.install` / `#publish` (`lib/claude_agent_sdk/cli_installer.rb`): several processes install into one `vendor/claude` at once. Every fallible step can raise, running its `ensure`, and any process can be killed at any point, which skips `ensure` but releases its flock. The `stable` dist-tag moves forward while they run.

| Config | Switch | Result | The comment it checks |
|---|---|---|---|
| `good`, `good_big` | all `TRUE` | pass (2 installers × 2 runs; 3 × 3) | |
| `bug_order` | `RECORD_BEFORE_RENAME = FALSE` | `NeverLoseWorkingInstall` violated: v1 installed; the v2 upgrade renames, then its metadata write fails and the cleanup deletes the binary, leaving the directory with none | `#publish`: "The reverse order — rename then record — … taking the previous working install with it" |
| `bug_resolve` | `RESOLVE_IN_LOCK = FALSE` | `NoDowngrade` violated: A reads tag 1, B installs 2, A takes the lock and installs 1 | `install`: "RESOLVED inside the lock … Semantics: last resolver wins" |
| `bug_sweep` | `SWEEP_IN_LOCK = FALSE` | `LiveDownloadsIntact` violated: one installer's sweep deletes another's in-flight download | `sweep_stale_temp_files`: "Safe because we hold the install lock" |

Properties: `ReadersSeeVerifiedBinary` (a lock-free reader never sees a partial or unverified binary), `NeverLoseWorkingInstall` (once an install has completed, a failed later one never leaves the directory without a binary), `NoDowngrade` (for dist-tag installs, published versions never go backwards; a concrete `install(version:)` is a legitimate downgrade and is not modelled), `LiveDownloadsIntact`, `StaleTempsSwept` (whoever holds the lock sees no temp files except its own, so disk use stays bounded after crashes).

**One reachable state is worth knowing.** `reach_mismatch` shows that the shipped design can leave `VERSION` naming v2 while the binary is still v1: this happens when a process crashes between the metadata write and the rename. That state is harmless only because `installed?` re-hashes the binary instead of trusting `VERSION`. `Metadata.read` has no other caller. Anything that starts reporting "the installed version" from `VERSION`, or drops the re-hash, reintroduces the inconsistency.

## `ControlProtocol.tla`: outbound control requests

Models the outbound half of the control protocol in `lib/claude_agent_sdk/query.rb`: `send_control_request` / `await_control_response`, the read loop's `handle_control_response`, and the EOF broadcast in `read_messages`' `ensure`. There are two senders: a reactor fiber (`Async::Condition`, which checks the result slot and parks with no suspension point between them) and a FiberBoundary worker thread (`ThreadWaiter`, where the read loop can run between the check and the park). The CLI may answer each request or never answer, and it eventually exits. The model checks liveness under weak fairness. Control-request timeouts are left out on purpose, because the 1200 s deadline would make every liveness property hold trivially. What the model asks is whether a caller ever *needs* the timeout.

| Config | Switch | Result | The comment it checks |
|---|---|---|---|
| `good` | all `TRUE` | pass | |
| `bug_write_first` | `REGISTER_BEFORE_WRITE = FALSE` | `DeliveredMeansAnswered` violated: the CLI answered, the response arrived before registration and was dropped as an unknown id, and the caller got "Control stream ended" | `send_control_request`: "Detecting after the write left a half-executed request … the eventual response dropped by the key? guard" |
| `bug_nonatomic` | `ATOMIC_REGISTRATION = FALSE` | `EverySenderFinishes` violated: a sender passed the stream-error check, EOF snapshotted the pending map before it registered, and it waits forever | `send_control_request`: "Register atomically with the terminal-state check so EOF cannot strand a sender that missed the final broadcast" |
| `bug_nocheck` | `CHECK_SLOT_FIRST = FALSE` | `EverySenderFinishes` violated: the fiber's write suspended after delivery, and the broadcast signal fired before it waited, so the signal was lost | `await_control_response`: "a signal arriving before the sender reaches wait would otherwise be dropped" |
| `bug_edge_thread` | `LEVEL_TRIGGERED = FALSE` | `EverySenderFinishes` violated: the thread checked the slot, the signal fired before it parked, and the signal was lost | `ThreadWaiter`: "closing the check-then-wait gap that an edge-triggered Condition would lose across threads" |

## What the models assume and leave out

- File contents are abstracted to "the version they are the bytes of", so a checksum match is equality. Platform detection is not modelled.
- The models assume that POSIX `rename` is atomic and that the kernel releases a dead process's flock. `ReadersSeeVerifiedBinary` holds by construction given those assumptions.
- Not modelled: control-request timeouts (see above); the inbound half (`handle_control_request`, the #119 process-exit path, cancellation during a response write, which the transport answers by poisoning itself so no partial frame is ever followed by another); `Metadata.write`'s own temp file; `TranscriptMirrorBatcher`.
- **The Ruby is not verified.** A model can drift from the code it describes. When you change one of the orderings the tables cite, update the model and `run.sh`'s expectations in the same change. Each counterexample trace can also be turned into an RSpec regression by stubbing `CLIInstaller::Http` / `Release` / `Metadata`, or with a scripted transport for `Query`, so that the step TLC found is exercised against the real code.
