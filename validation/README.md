# Validation Documentation Package — `blockr.core`

This directory contains the computerized-system-validation (CSV) evidence set for the R package `blockr.core`. It is documentation only: no package source (`R/`), generated documentation (`man/`, `NAMESPACE`) or test (`tests/`) file is modified by it.

## Document set

| File | Kind | Content |
|---|---|---|
| `system-description.md` | Hand-written, citation-checked | Purpose and architecture: block/board/stack/link S3 object model, shiny module generics (`block_server()`, `block_eval()`, `block_output()`, ...), plugins (`R/plugin-*.R`), serialization (`R/utils-serdes.R`), input validation (`dat_valid`, `validate_data_inputs()`), regression evidence. |
| `traceability-matrix.md` | **Generated** | Requirements (`REQ-NNN`, one per `man/*.Rd` topic) → design elements (file, symbol, line range, `NAMESPACE` line) → test cases (`TC-NNN`: file, `test_that` name, line range). Includes the coverage summary and explicit FLAGGED lists of uncovered requirements, exported symbols without a directly linked test, undocumented exports, and unlinked test files/cases. |
| `test-scripts.md` | **Generated** | One human-executable script per linked test case: exact run command, setup/action code with citations, plain-language expected result per expectation, the expectation's source lines, and the package code under test. |
| `citations.lock` | **Generated** (by `--lock`) | MD5 of the exact lines behind every citation in the hand-written documents. |
| `tools/generate.R` | Tool | Deterministic generator and drift checker (base R + `tools` + `testthat`). |

## How to read a provenance citation

Every factual statement is followed by one or more inline citations:

| Form | Meaning |
|---|---|
| `R/<file>.R:L<start>-L<end>` | The statement was derived from lines `start`..`end` (inclusive, 1-based) of that source file at the documented revision. Lines starting with `#'` are roxygen documentation (the *specified* behaviour); other lines are implementation (the *actual* behaviour). |
| `man/<topic>.Rd:L<start>-L<end>` | Lines of the roxygen-generated help page; `man/<topic>.Rd` alone means the whole topic. |
| `tests/testthat/test-<stem>.R:L<start>-L<end>` | The lines of a `test_that()` block or a single `expect_*()` call that verify the statement. |
| `NAMESPACE:L<n>` | The `export()` / `S3method()` directive making a symbol part of the public contract. |
| `DESCRIPTION:L<start>-L<end>`, `.github/workflows/<file>:L<start>-L<end>` | Package metadata / CI configuration lines. |

Interpretation rules for reviewers:

1. A statement is only as strong as its citation: open the cited lines and confirm they say what the statement says. Citations are chosen to be the *smallest* range that supports the statement.
2. A statement with several citations is supported jointly (e.g. documentation plus implementation, or implementation plus test).
3. "Tested by" bullets in `system-description.md` point to the specific expectation that verifies the behaviour; full traceability is in `traceability-matrix.md`.
4. Nothing in these documents is sourced from memory or external description; behaviour that could not be pinned to lines was omitted. The only external reference is the reusable CI workflow in `BristolMyersSquibb/blockr.ci`, which is explicitly marked as external and is not lock-checked.

## How the generated documents are derived

`tools/generate.R` reads only repository files:

* **Requirements**: one per `man/*.Rd` topic; the statement is the topic's `\value` section (fallback `\description`), cited to its `man/` lines and to the roxygen `@return` lines in `R/`. Documented `\section{}`s are listed with their line ranges.
* **Design elements**: the topic's `\alias` entries that are defined in `R/` or exported in `NAMESPACE`, plus `S3method()` registrations whose generic belongs to the topic. Line ranges come from R's parser (`srcref`).
* **Test cases**: every top-level `test_that()` block, parsed with `utils::getParseData()`.
* **Links**: a test references a package symbol if it occurs as a call/name token (or as a string literal naming a package function, e.g. `get_s3_method("block_server", blk)`). A reference is a link only under the mechanical rules `file` (same file stem), `name` (symbol in the test description) or `subject` (outermost call in an expectation's first argument). Internal helpers produce *indirect* links attributed by file proximity and are reported separately. No link is ever added by hand; gaps are flagged instead of filled.
* **Test-script expected results** are rendered from the matched arguments of each `expect_*()` call (e.g. `expect_error(..., class = "x")` → "signals an error of class `x`").

## Regenerating after a code change (drift detection)

The story is: **code changes → re-run generation → docs and matrix update → reviewer diff**.

```sh
# from the package root, with the package's dependencies and testthat installed
Rscript validation/tools/generate.R --check   # 1. detect drift (exit status 1 on drift)
Rscript validation/tools/generate.R           # 2. regenerate traceability-matrix.md and test-scripts.md
git diff validation/                          # 3. review what changed (new REQs, moved line ranges, new FLAGs)
# 4. if --check reported changed citations in system-description.md: re-read the cited lines,
#    update the statement and/or line range by hand, then re-baseline:
Rscript validation/tools/generate.R --lock
Rscript validation/tools/generate.R --check   # 5. must now exit 0
```

What `--check` detects:

* **Generated-document drift**: `traceability-matrix.md` / `test-scripts.md` differ from a fresh generation (any change in `NAMESPACE`, `man/*.Rd`, `R/*.R` or `tests/testthat/test-*.R` that affects requirements, line ranges, links or expectations). Each generated file also records an MD5 *input fingerprint*; a different fingerprint after regeneration means inputs changed.
* **Citation drift** in `system-description.md` and this README: a cited file is missing, a cited range is out of bounds, a citation is new and not yet reviewed, or the cited lines' content differs from `citations.lock` (the statement must be re-reviewed). A pure line shift therefore also surfaces as a changed hash, forcing the reviewer to move the range.

`--check` can be added as a step to CI (e.g. after dependency installation, run `Rscript validation/tools/generate.R --check`) so that a pull request that changes behaviour without updating its validation evidence fails. This package does not add that step, because CI is centrally managed in `BristolMyersSquibb/blockr.ci`.

Executing the tests themselves (the objective evidence) is separate from generating the documents: run `devtools::test()` for the whole suite or the per-script commands in `test-scripts.md`.

## Regression evidence

* Existing CI: `.github/workflows/ci.yaml` runs on every pull request to `main` and on merge groups (`.github/workflows/ci.yaml:L1-L4`) and calls the reusable `BristolMyersSquibb/blockr.ci` workflow, which runs R CMD check and coverage over the testthat suite (`.github/workflows/ci.yaml:L8-L20`; details in `system-description.md` section 9). As a CI workflow already exists, no `validation-tests.yaml` was added.
* Local run: `devtools::test()` from the package root executes all 53 test files (169 `test_that()` blocks); a run is valid evidence when it reports `FAIL 0`. The result recorded for this package version is in the pull request that introduced this directory.

## Known limitations

* The `validation/` directory is not listed in `.Rbuildignore`, so it is included in built source tarballs; `R CMD check` reports `checking top-level files ... OK` with it present. Excluding it would require editing an existing file and was not done.
* Link rules are lexical. A test that exercises a symbol only through setup code (without satisfying `file`, `name` or `subject`) is reported as *Referenced in tests: Yes* in the FLAGGED exported-symbols table rather than as coverage.
* `tests/testthat/test-utils-serve.R` drives example apps through `shinytest2` and references no package symbol directly, so it is flagged as unlinked; these tests are skipped when `shinytest2`/Chrome is unavailable (`skip_on_cran()`, `skip_if()`).
