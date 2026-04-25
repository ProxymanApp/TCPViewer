# v0.3.5 Large File Loading v1

## Summary
Define the first large-file loading behavior so TCP Viewer can open meaningful captures without freezing the app while deeper performance work remains future-phased.

## What To Build
- Describe incremental loading, responsive selection, and cancellation expectations for large traces.
- Define loading states and user-visible progress signals.
- Identify minimum acceptable behavior before dedicated v0.9 performance work.

## Requirements
- Opening a large file must not block the main thread.
- Users must be able to inspect early packets before the full file is processed when feasible.
- The design must support later indexing and lazy byte loading without redoing the document model.

## Dependencies
- v0.2.4 offline file pipeline.
- v0.2.5 packet ingest model.

## Tests
- Unit tests: cover loading-state transitions and cancellation logic.
- Integration tests: cover incremental loading and responsiveness with large fixture captures.
- UI tests: out of scope.

## Out Of Scope
- Final indexing strategy.
- Graph/stat aggregation performance tuning.
