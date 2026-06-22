# Agent Rules

1. Performance is a top-level requirement. Any change must be designed and reviewed under the assumption that it may run during large scans, large lists, or full-disk workflows.
2. Do not fix correctness by reintroducing scan-time UI churn. During active scans, avoid rebuilding large SwiftUI/AppKit lists, sorting large collections, recomputing safety verdicts, querying stores, or materializing partial tree data on the main thread.
3. Prefer asynchronous/background work for all non-UI and non-main-thread-only tasks. Keep main-thread work limited to state publication and lightweight UI updates.
4. Preserve explicit scan-time/final-state boundaries. Partial scan snapshots may drive progress indicators, but heavy result views should consume frozen snapshots or final snapshots unless a measured design proves otherwise.
5. Do not add local hardcoded patches. Fix the shared data boundary or rendering contract so the same category of issue cannot recur in another scan/list surface.
6. Before landing changes that touch scanning, tree/list rendering, store fallback, deletion, or AI actions, verify both correctness and performance risk with focused tests or profiling evidence where practical.
