# Long-task UI lifecycle contract — 2026-07-17

This record covers the filesystem Workflow cards, App Uninstaller discovery/recycle, and
Duplicate final-content verification. It exists because these paths previously exposed either
an unbounded spinner or a late result owned by a superseded screen revision.

## Shared contract

1. A long task has an explicit owner: card/request identity plus scan session and revision.
   Progress and terminal results may update UI state only while that exact owner is current.
2. Progress is a bounded side channel carrying real absolute counters. Timers, guessed totals,
   synthetic percentages, and per-file UI streams are not allowed.
3. Progress never determines success. Only the typed scan summary or deletion disposition may
   publish the terminal result.
4. A new request invalidates the previous owner before it starts. Late progress and completion
   from an old task cannot close a newer spinner or overwrite newer rows.
5. Cancellation is allowed only before the irreversible system submission boundary. Once
   `NSWorkspace.recycle` submission begins, the owner and durable ledger remain alive until a
   typed completed, pending, unknown, blocked, or failed result is available.
6. The submission boundary is recorded synchronously on the serial worker queue only after
   reservation, final verification, both claim-fence checks, and durable ledger claim have
   succeeded, immediately before the first actual `NSWorkspace.recycle` invocation. UI phase
   text may lag behind that record and must never be used as the sole cancellation authority.
   A queue wait, full rehash, or ledger claim is still pre-submit work.

## Implemented boundaries

- Workflow filesystem cards use `BulkScanner.summaryWithProgress`: summary-only allocation and
  completeness semantics plus throttled absolute byte/file progress, with one authoritative
  terminal progress sample before `finished`. No incremental node/cache stream is restored.
- DerivedData uses one allocation traversal for both cards and emits at most one update per 256
  regular files and 10 Hz, plus a terminal sample.
- App Uninstaller list refresh, candidate discovery, and recycle execution each own a separate
  revision. The recycle sheet mirrors typed TrashPipeline batch/diagnostic states and remains
  owned until the typed disposition arrives; dismissing the source view cannot orphan a submitted
  transaction. Public snapshot durations normalize NaN/non-positive values to an immediate
  boundary and preserve `+infinity` as intentionally unbounded, rather than letting NaN silently
  disable a requested budget.
- Duplicate final full-file verification exposes bounded item progress. Leaving the screen asks
  the verifier to cancel only while still pre-submit; after the synchronous submission marker,
  the transaction remains tracked until the typed recycle terminal arrives. Verification
  completion is not submission: only TrashPipeline's claim-adjacent marker may advance the
  execution boundary, and final success still comes only from the typed recycle disposition.

## Verification state

Focused regression test sources were added for owner/revision rejection, monotonic progress,
summary terminal progress, recycle phase reporting, submission/cancellation races, and Duplicate
departure behavior. Per the 2026-07-17 implementation-first instruction, no tests, builds, or App
launches were run in this landing pass. Current evidence is static C1 only; C2/C3 and the single
sustained C4 interaction run remain a separate verification phase.
