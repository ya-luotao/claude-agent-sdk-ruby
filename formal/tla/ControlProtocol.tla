--------------------------- MODULE ControlProtocol ---------------------------
(***************************************************************************)
(* Outbound half of the control protocol in lib/claude_agent_sdk/query.rb: *)
(* send_control_request / await_control_response, the read loop's          *)
(* handle_control_response, and the EOF broadcast in read_messages'       *)
(* ensure.                                                                 *)
(*                                                                         *)
(* Senders call a control method (interrupt, set_model, ...). Sender 1 is  *)
(* a reactor fiber (Async::Condition: edge-triggered, but checking the     *)
(* result slot and parking happen without a suspension point in between).  *)
(* Sender 2 runs on a FiberBoundary worker thread (ThreadWaiter): between  *)
(* its slot check and its park the read loop can run.                      *)
(*                                                                         *)
(* Timeouts are left out ON PURPOSE: with the 1200s deadline everything    *)
(* terminates trivially. The question is whether a sender ever NEEDS it.   *)
(*                                                                         *)
(* Switches (all TRUE = shipped design):                                   *)
(*   DETECT_MODE_BEFORE_WRITE  pick the waiter (Condition / ThreadWaiter)  *)
(*                          before writing; FALSE = the pre-420ee09 code,  *)
(*                          where Async::Task.current raised on a worker   *)
(*                          thread AFTER the request was written           *)
(*   ATOMIC_REGISTRATION    stream-error check + registration under one    *)
(*                          mutex, shared with the EOF snapshot            *)
(*   CHECK_SLOT_FIRST       `waiter.wait until slot.key?` (vs. a bare wait) *)
(*   LEVEL_TRIGGERED        ThreadWaiter pushes a token (vs. a plain       *)
(*                          edge-triggered condition on the thread path)   *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS DETECT_MODE_BEFORE_WRITE, ATOMIC_REGISTRATION,
          CHECK_SLOT_FIRST, LEVEL_TRIGGERED

Senders == {1, 2}
Kind(s) == IF s = 1 THEN "fiber" ELSE "thread"
Level(s) == Kind(s) = "thread" /\ LEVEL_TRIGGERED

NONE == "none"

VARIABLES
  spc,          \* sender program counter
  registered,   \* ids in @pending_control_responses
  slot,         \* @pending_control_results[id]: NONE | "resp" | "err"
  tokens,       \* ThreadWaiter queue length (level-triggered waiters)
  woken,        \* a pending wakeup for an edge-triggered waiter that was parked
  written,      \* requests the CLI has received
  answered,     \* requests the CLI has answered (response on stdout)
  unread,       \* answered but not yet consumed by the read loop
  delivered,    \* responses the read loop consumed (routed or dropped)
  cliGone,      \* the CLI closed stdout
  streamErr,    \* @control_stream_error is set
  snapshot,     \* EOF broadcast still to do (dup of the pending map)
  outcome       \* what the control method returned / raised

vars == <<spc, registered, slot, tokens, woken, written, answered, unread,
          delivered, cliGone, streamErr, snapshot, outcome>>

Init ==
  /\ spc = [s \in Senders |-> "idle"]
  /\ registered = {}
  /\ slot = [s \in Senders |-> NONE]
  /\ tokens = [s \in Senders |-> 0]
  /\ woken = [s \in Senders |-> FALSE]
  /\ written = {} /\ answered = {} /\ unread = {} /\ delivered = {}
  /\ cliGone = FALSE /\ streamErr = FALSE /\ snapshot = {}
  /\ outcome = [s \in Senders |-> NONE]

Goto(s, l) == spc' = [spc EXCEPT ![s] = l]

\* The method returns/raises; the `ensure` evicts both pending entries.
Finish(s, o) ==
  /\ Goto(s, "done")
  /\ outcome' = [outcome EXCEPT ![s] = o]
  /\ registered' = registered \ {s}

\* waiter.signal: a token for ThreadWaiter; an edge-triggered condition only
\* wakes a waiter that is parked right now -- otherwise the signal is lost.
Signal(s) ==
  IF Level(s)
    THEN /\ tokens' = [tokens EXCEPT ![s] = @ + 1] /\ UNCHANGED woken
    ELSE /\ woken' = IF spc[s] = "parked" THEN [woken EXCEPT ![s] = TRUE] ELSE woken
         /\ UNCHANGED tokens

-----------------------------------------------------------------------------
(* Sender                                                                   *)

\* @request_counter_mutex.synchronize { raise if @control_stream_error; register }
Start(s) ==
  /\ spc[s] = "idle"
  /\ IF streamErr
       THEN Finish(s, "err")
       ELSE IF ATOMIC_REGISTRATION
              THEN /\ registered' = registered \cup {s}
                   /\ Goto(s, "write") /\ UNCHANGED outcome
              ELSE /\ Goto(s, "register")
                   /\ UNCHANGED <<registered, outcome>>
  /\ UNCHANGED <<slot, tokens, woken, written, answered, unread, delivered,
                 cliGone, streamErr, snapshot>>

Register(s) ==
  /\ spc[s] = "register"
  /\ registered' = registered \cup {s}
  /\ Goto(s, "write")
  /\ UNCHANGED <<slot, tokens, woken, written, answered, unread, delivered,
                 cliGone, streamErr, snapshot, outcome>>

\* writeln(JSON.generate(request)) -- the bytes reach the CLI even if the
\* writer then suspends (custom transports, flush).
Write(s) ==
  /\ spc[s] = "write"
  /\ written' = written \cup {s}
  /\ Goto(s, IF ~DETECT_MODE_BEFORE_WRITE /\ Kind(s) = "thread" THEN "detect" ELSE "wait")
  /\ UNCHANGED <<registered, slot, tokens, woken, answered, unread, delivered,
                 cliGone, streamErr, snapshot, outcome>>

\* Pre-fix only: `Async::Task.current` after the write raises "No async task
\* available!" on a worker thread; the `ensure` evicts the pending entry, so
\* the CLI's eventual answer is dropped by the key? guard.
Detect(s) ==
  /\ spc[s] = "detect"
  /\ Finish(s, "raised")
  /\ UNCHANGED <<slot, tokens, woken, written, answered, unread, delivered,
                 cliGone, streamErr, snapshot>>

\* `until @pending_control_results.key?(id)` -- the check. A fiber parks in
\* the same step (no suspension point); a thread parks in a separate one.
Wait(s) ==
  /\ spc[s] = "wait"
  /\ IF CHECK_SLOT_FIRST /\ slot[s] # NONE
       THEN Finish(s, slot[s])
       ELSE /\ Goto(s, IF Kind(s) = "fiber" THEN "parked" ELSE "gap")
            /\ UNCHANGED <<registered, outcome>>
  /\ UNCHANGED <<slot, tokens, woken, written, answered, unread, delivered,
                 cliGone, streamErr, snapshot>>

Park(s) ==
  /\ spc[s] = "gap"
  /\ Goto(s, "parked")
  /\ UNCHANGED <<registered, slot, tokens, woken, written, answered, unread,
                 delivered, cliGone, streamErr, snapshot, outcome>>

\* waiter.wait returns (token popped / condition signalled)
Wake(s) ==
  /\ spc[s] = "parked"
  /\ IF Level(s) THEN tokens[s] > 0 ELSE woken[s]
  /\ tokens' = IF Level(s) THEN [tokens EXCEPT ![s] = @ - 1] ELSE tokens
  /\ woken'  = IF Level(s) THEN woken ELSE [woken EXCEPT ![s] = FALSE]
  /\ IF CHECK_SLOT_FIRST
       THEN /\ Goto(s, "wait") /\ UNCHANGED <<registered, outcome>>
       ELSE Finish(s, slot[s])
  /\ UNCHANGED <<slot, written, answered, unread, delivered, cliGone,
                 streamErr, snapshot>>

-----------------------------------------------------------------------------
(* CLI and read loop                                                        *)

CliAnswer(r) ==
  /\ r \in written \ answered
  /\ ~cliGone
  /\ answered' = answered \cup {r}
  /\ unread' = unread \cup {r}
  /\ UNCHANGED <<spc, registered, slot, tokens, woken, written, delivered,
                 cliGone, streamErr, snapshot, outcome>>

CliExit ==
  /\ ~cliGone
  /\ cliGone' = TRUE
  /\ UNCHANGED <<spc, registered, slot, tokens, woken, written, answered,
                 unread, delivered, streamErr, snapshot, outcome>>

\* handle_control_response: waiter = pending[id]; return unless waiter;
\* write the slot, THEN signal.
ReadResponse(r) ==
  /\ r \in unread
  /\ unread' = unread \ {r}
  /\ delivered' = delivered \cup {r}
  /\ IF r \in registered
       THEN /\ slot' = [slot EXCEPT ![r] = "resp"]
            /\ Signal(r)
       ELSE UNCHANGED <<slot, tokens, woken>>     \* unknown id: dropped
  /\ UNCHANGED <<spc, registered, written, answered, cliGone, streamErr,
                 snapshot, outcome>>

\* read_messages ensure, under @request_counter_mutex: publish the terminal
\* error and snapshot the pending map.
Eof ==
  /\ cliGone /\ unread = {} /\ ~streamErr
  /\ streamErr' = TRUE
  /\ snapshot' = registered
  /\ UNCHANGED <<spc, registered, slot, tokens, woken, written, answered,
                 unread, delivered, cliGone, outcome>>

\* @pending_control_results[id] ||= @control_stream_error; condition.signal
Broadcast(r) ==
  /\ r \in snapshot
  /\ snapshot' = snapshot \ {r}
  /\ slot' = IF slot[r] = NONE THEN [slot EXCEPT ![r] = "err"] ELSE slot
  /\ Signal(r)
  /\ UNCHANGED <<spc, registered, written, answered, unread, delivered,
                 cliGone, streamErr, outcome>>

SenderStep(s) == Start(s) \/ Register(s) \/ Write(s) \/ Detect(s) \/ Wait(s) \/ Park(s) \/ Wake(s)
ReaderStep == Eof \/ \E r \in Senders : ReadResponse(r) \/ Broadcast(r)

Next ==
  \/ \E s \in Senders : SenderStep(s)
  \/ \E r \in Senders : CliAnswer(r)
  \/ CliExit
  \/ ReaderStep

\* Every party keeps taking its enabled steps; the CLI may answer or not, but
\* it eventually exits (the process is not immortal).
Fairness ==
  /\ \A s \in Senders : WF_vars(SenderStep(s))
  /\ WF_vars(ReaderStep)
  /\ WF_vars(CliExit)

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
(* Properties                                                               *)

\* No control method hangs until its timeout: it returns or raises.
EverySenderFinishes == \A s \in Senders : <>(spc[s] = "done")

\* A response the read loop consumed is never replaced by "Control stream
\* ended": if the CLI answered in time, the caller gets the answer.
DeliveredMeansAnswered ==
  \A s \in Senders : (outcome[s] = "err") => (s \notin delivered)

\* No half-executed request: a control method that fails locally (rather
\* than with the CLI's answer or the stream's end) never reached the CLI.
NoHalfExecutedRequest ==
  \A s \in Senders : (outcome[s] = "raised") => (s \notin written)

\* Reachability (EXPECTED to be violated): both outcomes really occur.
NobodyGetsAResponse == \A s \in Senders : outcome[s] # "resp"
NobodyGetsAnError   == \A s \in Senders : outcome[s] # "err"
=============================================================================
