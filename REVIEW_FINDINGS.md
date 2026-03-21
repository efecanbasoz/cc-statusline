# Security & Code Quality Review Findings

**Date**: 2026-03-21
**Reviewers**: Codex CLI (GPT-5.4, read-only sandbox) + Claude Opus 4.6 manual analysis
**Scope**: Full codebase (slim/statusline.sh, full/statusline.sh, install.sh, ~1,085 LOC)

---

## Summary

| Severity | Count | Actionable |
|----------|-------|-----------|
| CRITICAL | 1 | 1 |
| HIGH | 3 | 3 |
| MEDIUM | 9 | 7 |
| LOW | 2 | 1 |
| **Total** | **15** | **12** |

---

## Fix Phases

### Phase A: Critical + High Security
- SEC-001: Sanitize arithmetic inputs (regex validation before `$((...))`)
- SEC-002: Move cache to per-user directory, set umask 077
- SEC-003: Hash SESSION_ID for cache file names
- QA-001: Create cache dir before first use (speed cache race)

### Phase B: Medium Security + Quality
- SEC-004: Pass OAuth token via header file instead of argv
- SEC-005: Sanitize display strings for terminal escape injection
- QA-004: Add `set -u -o pipefail` to statusline scripts
- QA-010: Remove dead code (unused MAG color, slim Python extra output lines)

### Phase C: Code Quality
- QA-003: Centralize magic numbers as named constants
- QA-005: Narrow Python exception handling to JSONDecodeError
- QA-006: Probe for timeout/gtimeout before use
- QA-009: Only delete statusLine config if it matches our payload

### Deferred (performance optimization, not fixing now)
- QA-002: Batch jq calls (significant refactor, deferred)
- QA-007: Optimize git status --porcelain (acceptable for now)
- QA-008: Reorder installer operations (low risk, deferred)
- SEC-006: Transcript path confinement (low severity, trusted source)
