# ACL Engine TODO

## 1) Fix find expression grouping so -mindepth/-maxdepth apply correctly

- Problem: `find` invocations use `-type f -o -type d` without parentheses, so `-o` breaks precedence and may bypass depth constraints.
- Impact: Unexpected files/dirs included; performance and correctness issues.
- Acceptance Criteria:
  - All `find` commands group type tests with `\( -type f -o -type d \)`.
  - Depth constraints (`-mindepth`, `-maxdepth`) apply to both types.
  - Add a dry-run demonstrating correct counts on a sample tree.

## 2) Implement include/exclude filtering per rule

- Problem: `include`, `exclude`, `pattern_syntax`, `match_base`, `case_sensitive` are parsed but not applied.
- Impact: Rules ignore intended scoping; potential over-application of ACLs.
- Approach:
  - Add `path_matches_rule` that honors glob/regex, case sensitivity, and basename vs fullpath matching.
  - Apply it before acting on each enumerated path for files, directories, and default ACLs.
- Acceptance Criteria:
  - Paths are filtered exactly per schema semantics; unit dry-run examples verify behavior.

## 3) Support per-rule max_depth (schema) with CLI override

- Problem: Only a global `--max-depth` exists; schema defines per-rule `max_depth`.
- Impact: Over-traversal or under-traversal for mixed rulesets.
- Approach:
  - Cache `rule.max_depth` and pass into enumeration. CLI flag overrides if provided.
- Acceptance Criteria:
  - Rule-specific depth honored; CLI overrides when set.

## 4) Honor apply_order: shallow_to_deep | deep_to_shallow

- Problem: `apply_order` is parsed and logged but not used.
- Impact: Overwrite ordering can be incorrect vs schema intent.
- Approach:
  - Sort enumerated paths by depth according to `apply_order` for individual strategy; consider root order.
- Acceptance Criteria:
  - With `deep_to_shallow`, deeper paths are processed before ancestors; vice versa otherwise.

## 5) Guard recursive optimization (-R) to avoid type cross-application

- Problem: Using `setfacl -R` separately for file and directory specs applies to both types indiscriminately.
- Impact: Directory ACLs set on files or file ACLs set on directories.
- Approach:
  - Enable -R only when there are no include/exclude patterns and either only one type is targeted or file/dir specs are identical.
  - Otherwise enumerate and filter by type.
- Acceptance Criteria:
  - No cross-type ACL application; optimization used safely.

## 6) JSONL output mode: implement or remove

- Problem: `jsonl` is accepted but never emitted.
- Impact: Confusing interface; broken contract.
- Approach:
  - Either implement JSON Lines output or drop the option and docs.
- Acceptance Criteria:
  - `--output-format jsonl` yields valid JSONL; or option removed consistently.

## 7) Track skipped paths/rules and use RETURN_SKIPPED

- Problem: `total_skipped` and `RETURN_SKIPPED` exist but never used.
- Impact: Metrics incomplete; harder to audit behavior.
- Approach:
  - Increment `total_skipped` where applicable (no valid roots, filtered-out paths, etc.).
  - Use a controlled non-error return to indicate skips.
- Acceptance Criteria:
  - Summary reflects nonzero skipped when expected.

## 8) Remove or wire up dead code and caches

- Problem: `match_glob`, `match_regex` unused; `cache_json`, `cache_paths` unused.
- Impact: Maintenance overhead; confusion.
- Approach:
  - Use matchers for include/exclude (Task 2) or remove them.
  - Remove unused caches if not needed.
- Acceptance Criteria:
  - No dead code; linters/grep show all symbols referenced.

## 9) Default ACL recursion robustness

- Problem: `setfacl -R -d` may traverse files; behavior varies by platform.
- Impact: Errors or inconsistent results.
- Approach:
  - Prefer enumeration of directories for default ACLs unless safe conditions are proven.
- Acceptance Criteria:
  - No errors when roots contain files; results consistent.

## 10) Tests and docs for schema parity

- Problem: Hard to verify feature coverage.
- Approach:
  - Add dry-run examples and documentation demonstrating schema features (types, includes/excludes, pattern syntax, depth, order).
- Acceptance Criteria:
  - Documented scenarios run successfully with `--dry-run` and expected output counts.
