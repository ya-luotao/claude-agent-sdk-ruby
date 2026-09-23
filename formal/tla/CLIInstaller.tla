---------------------------- MODULE CLIInstaller ----------------------------
(***************************************************************************)
(* Model of ClaudeAgentSDK::CLIInstaller.install and #publish             *)
(* (lib/claude_agent_sdk/cli_installer.rb). Several installer processes   *)
(* run install() concurrently against one vendor/claude directory. Any     *)
(* step may fail                                                           *)
(* (raise -> `ensure` runs) and any process may die at any point (SIGKILL: *)
(* no `ensure`, but the kernel releases its flock).                        *)
(*                                                                         *)
(* Abstraction: file contents are represented by the version they are the  *)
(* bytes of, so "sha256(file) = recorded checksum" becomes equality.       *)
(*                                                                         *)
(* Three switches select the shipped design (all TRUE) or a historical /   *)
(* hypothetical bug:                                                       *)
(*   RECORD_BEFORE_RENAME  FALSE = old publish order (rename, then write   *)
(*                         VERSION; on metadata failure delete the binary) *)
(*   RESOLVE_IN_LOCK       FALSE = resolve the dist-tag before the flock   *)
(*   SWEEP_IN_LOCK         FALSE = sweep stale temp files before the flock *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS Installers,          \* e.g. {1, 2}
          MaxVersion,          \* the dist-tag moves through 1..MaxVersion
          MaxRuns,             \* how many times each installer may run install()
          RECORD_BEFORE_RENAME,
          RESOLVE_IN_LOCK,
          SWEEP_IN_LOCK

NONE     == 0
Versions == 1..MaxVersion
CORRUPT  == MaxVersion + 1     \* downloaded bytes whose checksum does not match
PARTIAL  == MaxVersion + 2     \* a download cut off mid-stream
Contents == Versions \cup {CORRUPT, PARTIAL}

VARIABLES
  pc,             \* per installer: where it is inside install()
  runs,           \* per installer: completed install() calls (also names its temp file)
  resolved,       \* per installer: the concrete version it is installing
  lock,           \* holder of the flock on .install.lock, 0 = free
  tag,            \* what the `stable` dist-tag currently resolves to (only moves forward)
  binary,         \* content of vendor/claude/claude (NONE = absent)
  vfile,          \* version + checksum recorded in VERSION (NONE = absent)
  tmps,           \* claude.download.<hex> files on disk
  published,      \* history: every version renamed into place, in order
  everInstalled   \* history: some install() has run to completion (binary AND VERSION in place)

vars == <<pc, runs, resolved, lock, tag, binary, vfile, tmps, published, everInstalled>>

TmpFile == [owner : Installers, run : Nat, content : Contents]

Init ==
  /\ pc       = [i \in Installers |-> "idle"]
  /\ runs     = [i \in Installers |-> 0]
  /\ resolved = [i \in Installers |-> NONE]
  /\ lock     = 0
  /\ tag      = 1
  /\ binary   = NONE
  /\ vfile    = NONE
  /\ tmps     = {}
  /\ published = <<>>
  /\ everInstalled = FALSE

\* The temp file belonging to installer i's current run (0 or 1 elements).
MyTmp(i) == {f \in tmps : f.owner = i /\ f.run = runs[i]}

\* install() is over for i -- returned, raised, or the process died. The
\* flock is released either by `ensure` or by the kernel.
Leave(i) ==
  /\ pc'       = [pc EXCEPT ![i] = "idle"]
  /\ runs'     = [runs EXCEPT ![i] = @ + 1]
  /\ resolved' = [resolved EXCEPT ![i] = NONE]
  /\ lock'     = IF lock = i THEN 0 ELSE lock

Goto(i, where) == pc' = [pc EXCEPT ![i] = where]

\* installed?: VERSION names this version AND the binary re-hashes to it.
Installed(v) == binary = v /\ vfile = v

-----------------------------------------------------------------------------
(* install(): validate (local, not modelled) -> [resolve] -> flock           *)

Begin(i) ==
  /\ pc[i] = "idle" /\ runs[i] < MaxRuns
  /\ Goto(i, "waitlock")
  /\ resolved' = IF RESOLVE_IN_LOCK THEN resolved ELSE [resolved EXCEPT ![i] = tag]
  /\ tmps'     = IF SWEEP_IN_LOCK THEN tmps ELSE {}
  /\ UNCHANGED <<runs, lock, tag, binary, vfile, published, everInstalled>>

\* with_install_lock + sweep_stale_temp_files
Acquire(i) ==
  /\ pc[i] = "waitlock" /\ lock = 0
  /\ lock' = i
  /\ tmps' = IF SWEEP_IN_LOCK THEN {} ELSE tmps
  /\ Goto(i, IF RESOLVE_IN_LOCK THEN "resolve" ELSE "check")
  /\ UNCHANGED <<runs, resolved, tag, binary, vfile, published, everInstalled>>

\* Release.resolve_version (a GET to the dist-tag endpoint)
Resolve(i) ==
  /\ pc[i] = "resolve"
  /\ resolved' = [resolved EXCEPT ![i] = tag]
  /\ Goto(i, "check")
  /\ UNCHANGED <<runs, lock, tag, binary, vfile, tmps, published, everInstalled>>

\* `next binary if installed?(...)` -- the offline idempotency shortcut
Check(i) ==
  /\ pc[i] = "check"
  /\ IF Installed(resolved[i])
       THEN Leave(i)
       ELSE /\ Goto(i, "download")
            /\ UNCHANGED <<runs, resolved, lock>>
  /\ UNCHANGED <<tag, binary, vfile, tmps, published, everInstalled>>

(* publish(): fetch_verified -> Metadata.write -> File.rename               *)

\* Http.download_to opens claude.download.<hex> with O_EXCL
StartDownload(i) ==
  /\ pc[i] = "download"
  /\ tmps' = tmps \cup {[owner |-> i, run |-> runs[i], content |-> PARTIAL]}
  /\ Goto(i, "downloading")
  /\ UNCHANGED <<runs, resolved, lock, tag, binary, vfile, published, everInstalled>>

\* The stream completes: the right bytes, or bytes that will fail the checksum.
\* (If the file was unlinked under us, the writes land in an orphaned inode.)
FinishDownload(i) ==
  /\ pc[i] = "downloading"
  /\ \E c \in {resolved[i], CORRUPT} :
       tmps' = {IF f.owner = i /\ f.run = runs[i] THEN [f EXCEPT !.content = c] ELSE f : f \in tmps}
  /\ Goto(i, "verify")
  /\ UNCHANGED <<runs, resolved, lock, tag, binary, vfile, published, everInstalled>>

\* Digest::SHA256.file(tmp) == entry[:checksum], then chmod 0755
Verify(i) ==
  /\ pc[i] = "verify"
  /\ \E f \in MyTmp(i) : f.content = resolved[i]
  /\ Goto(i, IF RECORD_BEFORE_RENAME THEN "record" ELSE "rename")
  /\ UNCHANGED <<runs, resolved, lock, tag, binary, vfile, tmps, published, everInstalled>>

\* Metadata.write: its own temp file + rename, so VERSION changes atomically
Record(i) ==
  /\ pc[i] \in {"record", "record_after"}
  /\ vfile' = resolved[i]
  /\ IF pc[i] = "record"
       THEN /\ Goto(i, "rename")
            /\ UNCHANGED <<runs, resolved, lock>>
       ELSE Leave(i)                              \* old order: this was the last step
  /\ everInstalled' = (everInstalled \/ pc[i] = "record_after")
  /\ UNCHANGED <<tag, binary, tmps, published>>

\* File.rename(tmp, binary): atomic replace
Rename(i) ==
  /\ pc[i] = "rename"
  /\ \E f \in MyTmp(i) :
       /\ binary'    = f.content
       /\ published' = Append(published, f.content)
  /\ tmps' = tmps \ MyTmp(i)
  /\ everInstalled' = (everInstalled \/ RECORD_BEFORE_RENAME)
  /\ IF RECORD_BEFORE_RENAME
       THEN Leave(i)
       ELSE /\ Goto(i, "record_after")
            /\ UNCHANGED <<runs, resolved, lock>>
  /\ UNCHANGED <<tag, vfile>>

\* Any fallible step raises (network error, checksum mismatch, ENOENT,
\* ENOSPC, EACCES, a failed rename, ...). `ensure FileUtils.rm_f(tmp)` runs.
\* The pre-fix code, on a metadata failure AFTER the rename, also deleted the
\* freshly renamed binary.
Fail(i) ==
  /\ pc[i] \in {"resolve", "check", "download", "downloading",
                "verify", "record", "rename", "record_after"}
  /\ tmps'   = tmps \ MyTmp(i)
  /\ binary' = IF pc[i] = "record_after" THEN NONE ELSE binary
  /\ Leave(i)
  /\ UNCHANGED <<tag, vfile, published, everInstalled>>

\* SIGKILL / OOM / power loss: no `ensure`, the temp file stays behind.
Crash(i) ==
  /\ pc[i] # "idle"
  /\ Leave(i)
  /\ UNCHANGED <<tag, binary, vfile, tmps, published, everInstalled>>

\* A new release is promoted to `stable`.
AdvanceTag ==
  /\ tag < MaxVersion
  /\ tag' = tag + 1
  /\ UNCHANGED <<pc, runs, resolved, lock, binary, vfile, tmps, published, everInstalled>>

Next ==
  \/ AdvanceTag
  \/ \E i \in Installers :
       \/ Begin(i) \/ Acquire(i) \/ Resolve(i) \/ Check(i)
       \/ StartDownload(i) \/ FinishDownload(i) \/ Verify(i)
       \/ Record(i) \/ Rename(i) \/ Fail(i) \/ Crash(i)

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* Safety properties                                                        *)

TypeOK ==
  /\ lock \in Installers \cup {0}
  /\ tag \in Versions
  /\ binary \in Contents \cup {NONE}
  /\ vfile \in Versions \cup {NONE}
  /\ tmps \subseteq TmpFile

\* A lock-free reader (installed_path / find_cli / the spawned CLI) only ever
\* sees a complete, checksum-verified binary.
ReadersSeeVerifiedBinary == binary \in Versions \cup {NONE}

\* "An upgrade never destroys a working install": once one install() has
\* completed, a failed later one never leaves the directory without a binary.
NeverLoseWorkingInstall == everInstalled => binary # NONE

\* "Last resolver wins": for dist-tag installs, the published version never
\* goes backwards. (A concrete `install(version: '2.1.220')` over a newer
\* binary is a legitimate downgrade -- such installers are not modelled.)
NoDowngrade ==
  \A k \in 1..(Len(published) - 1) : published[k] <= published[k + 1]

\* The sweep never deletes the temp file of an install that is still running.
LiveDownloadsIntact ==
  \A i \in Installers :
    pc[i] \in {"downloading", "verify", "record", "rename"} => MyTmp(i) # {}

\* Disk usage is bounded: whoever holds the lock sees no temp files but
\* (at most) its own -- stale ones from dead installers have been swept.
StaleTempsSwept ==
  lock # 0 => \A f \in tmps : f.owner = lock /\ f.run = runs[lock]

-----------------------------------------------------------------------------
(* Reachability checks (EXPECTED to be violated -- proves the model is not  *)
(* vacuous: upgrades, crashes and the VERSION/binary mismatch all happen)   *)

NoUpgradeEverHappens == Len(published) < 2
NoCrashLeftovers     == \A f \in tmps : f.run = runs[f.owner]
NoRecordedButNotRenamed == ~(binary \in Versions /\ vfile \in Versions /\ vfile > binary)
=============================================================================
