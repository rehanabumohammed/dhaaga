# ADR-0006 · CI stays in the repository even though it cannot run yet

**Status** Accepted · 26 Aug 2026 · decided by RayHaan

## Context
`.github/workflows/ci.yml` cannot currently execute: the repository has no
remote, the development environment cannot reach GitHub, and the workflow file
is a protected path for the file bridge to the Product Owner's machine.

An untested, non-running workflow is a liability in one specific way — it can be
mistaken for evidence.

## Decision
Keep CI in the repository, unmodified and unweakened. Do not remove, bypass or
disable it because it cannot run today. Alongside it:

1. document the limitation where a reader will meet it (`docs/ci.md`, README);
2. run every CI step locally and report the output with the work package;
3. never state that CI has passed unless a CI run has actually happened.

## Consequences
* The definition of "green" is version-controlled from P0, so the first push
  inherits a complete pipeline rather than needing one written under pressure.
* Reports distinguish *local validation* from *CI passed*. The distinction is
  load-bearing: the first is evidence gathered on a developer's machine, the
  second is a clean-room result.
* The first push may reveal defects in the workflow. That outcome gets reported
  like any other, not quietly fixed.
