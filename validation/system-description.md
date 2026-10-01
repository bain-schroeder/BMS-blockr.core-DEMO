# System Description — `blockr.core`

This document describes the purpose and architecture of the R package `blockr.core` for computerized-system validation (CSV) review. It is hand-written, but every factual statement about behaviour carries an inline citation of the exact source lines it was derived from (see `validation/README.md` for how to read citations). Statements that could not be tied to source lines were left out. Citation integrity is machine-checked by `Rscript validation/tools/generate.R --check`.

## 1. Purpose

* `blockr.core` is "a framework for data manipulation and visualization using a web-based point and click user interface where analysis pipelines are decomposed into re-usable and parameterizable blocks" (`DESCRIPTION:L20-L21`).
* The board is extensible through S3 sub-classing, a plugin architecture and callback functions (`R/board-server.R:L1-L9`), and plugins are the core mechanism for customizing board UX (`R/board-plugins.R:L1-L9`).
* An analysis is assembled from **blocks** (pipeline steps), connected by **links**, optionally grouped into **stacks**, and held together in a **board** (`R/block-class.R:L1-L6`, `R/link-class.R:L1-L9`, `R/stack-class.R:L1-L9`, `R/board-class.R:L1-L11`).

## 2. Architecture overview

| Layer | Responsibility | Primary source |
|---|---|---|
| S3 object model | `block`, `blocks`, `link`, `links`, `stack`, `stacks`, `board` constructors and validators | `R/block-class.R`, `R/blocks-class.R`, `R/link-class.R`, `R/links-class.R`, `R/stack-class.R`, `R/stacks-class.R`, `R/board-class.R` |
| Block runtime (shiny modules) | `block_server()`, `expr_server()`, `block_eval()`, `block_ui()`, `expr_ui()`, `block_output()` | `R/block-server.R`, `R/block-eval.R`, `R/block-ui.R` |
| Board runtime | `board_server()`, board update protocol, board UI | `R/board-server.R`, `R/board-ui.R` |
| Plugins | Replaceable shiny modules for board UX (`R/plugin-*.R`) | `R/board-plugins.R`, `R/plugin-*.R` |
| Serialization | `blockr_ser()` / `blockr_deser()` | `R/utils-serdes.R` |
| Graph utilities | Topological sort and cycle detection for links | `R/utils-graph.R` |
| Block registry | Browsable directory of block constructors | `R/block-registry.R` |

The table above is a file map; the behavioural claims for each row are cited in the sections below.

## 3. S3 object model

### 3.1 Block (`block`)

* A block combines data input with user inputs to produce an output; it is implemented as a shiny module and is created from a server function, a UI function and a class vector (`R/block-class.R:L1-L6`).
* The constructor `new_block()` appends `"block"` to the supplied class vector (`R/block-class.R:L183-L183`), and stores the expression server, the expression UI and the data validator `dat_valid` as list components, with constructor, block name, `allow_empty_state`, `expr_type`, `external_ctrl` and `block_metadata` stored as attributes, before calling `validate_block()` (`R/block-class.R:L213-L230`).
* If no `ui` is supplied, `new_block()` substitutes a UI function returning an empty `tagList()` (`R/block-class.R:L173-L177`).
* The block name must resolve to a string; a function-valued `block_name` is called with the class vector (`R/block-class.R:L185-L189`).
* When no `block_metadata` is passed, metadata is looked up in the block registry by class; if no registry entry exists a `missing_block_metadata` warning is raised (`R/block-class.R:L191-L211`).
* The server function must return a `shiny::moduleServer()`, have an `id` argument and one further argument per data input; variadic blocks receive their inputs through a `...args` argument (`R/block-class.R:L28-L41`).
* The server function must return a list with components `expr` (a reactive quoted expression) and `state` (a named list whose names match constructor arguments) (`R/block-class.R:L43-L75`).
* The UI function must take a single argument `id` and namespace its inputs within that ID; block UI is limited to user inputs, while outputs are handled by `block_output()` and `block_ui()` (`R/block-class.R:L77-L89`).
* Virtual classes such as `transform_block` group blocks of similar behaviour and drive S3 dispatch of `block_output()` and `block_ui()` (`R/block-class.R:L91-L96`).
* `block_arity()` returns `NA_integer_` for variadic blocks (those whose expression inputs include `...args`) and otherwise the number of data inputs; for a board it returns the arity of every block, named by block ID (`R/block-class.R:L605-L620`).
* `external_ctrl_vars()` resolves `external_ctrl = TRUE` to all constructor inputs, `FALSE` to none and a character vector to a validated subset, and always adds `"block_name"` (`R/block-class.R:L716-L730`; documented in `R/block-class.R:L474-L483`).

### 3.2 Link (`link`, `links`)

* A link is a directed connection between two blocks, identified by `from` and `to`; the `input` attribute selects which data input of a polyadic receiving block is targeted (`R/link-class.R:L1-L9`).
* `links` containers manage unique IDs, disallow multiple links pointing to the same target (`to` + `input`), and reject cycles (`R/links-class.R:L1-L11`).
* `validate_links()` enforces, in order: inheritance from `links`, list-like behaviour, presence of fields `id`, `from`, `to`, `input`, per-link validity, unique IDs, no duplicated inputs per target block, and acyclicity, signalling classed errors `links_class_invalid`, `links_list_like_invalid`, `links_fields_invalid`, `links_names_unique_invalid`, `links_block_inputs_invalid` and `links_acyclic_invalid` (`R/links-class.R:L304-L364`).
* Tested by: concatenating a cycle-closing link raises `links_acyclic_invalid` (`tests/testthat/test-links-class.R:L19-L19`); duplicate target inputs raise `links_block_inputs_invalid` (`tests/testthat/test-links-class.R:L119-L132`).

### 3.3 Stack (`stack`, `stacks`)

* A stack groups related blocks and "has no functional implications"; its key attribute is `blocks`, a character vector of block IDs, plus an optional `name` (`R/stack-class.R:L1-L9`).
* `stacks` containers guarantee unique, non-empty IDs and disallow a block being a member of more than one stack (`R/stacks-class.R:L1-L5`), enforced by `validate_stacks()` with error classes `stacks_class_invalid`, `stacks_type_invalid`, `stacks_contains_invalid`, `stacks_names_invalid` and `stacks_blocks_invalid` (`R/stacks-class.R:L41-L88`), using a pairwise intersection check (`R/stacks-class.R:L90-L103`).
* Tested by: a block in two stacks raises `stacks_blocks_invalid` (`tests/testthat/test-stacks-class.R:L46-L51`).

### 3.4 Board (`board`)

* A board organizes a set of blocks, optionally connected via links and grouped into stacks; it can be extended via attributes and sub-classes, and S3 dispatch is used to customize UI (`R/board-class.R:L1-L11`).
* `new_board()` coerces its inputs with `as_blocks()`, `as_links()`, `as_stacks()` and `as_board_options()`, completes missing link inputs for unary and variadic blocks, and returns the result of `validate_board()` on an object of class `c(class, "board")` (`R/board-class.R:L38-L63`).

### 3.5 Directed-acyclic-graph semantics

* Block dependencies are represented as a DAG; `topo_sort()` returns a depth-first topological ordering and `is_acyclic()` checks for cycles (`R/utils-graph.R:L1-L6`).
* `topo_sort()` accepts a board (converted with `as.matrix()`) or a square 0/1 integer adjacency matrix with matching dimnames, returns `character()` for an empty graph, and signals a `graph_has_cycle` error when a cycle is found (`R/utils-graph.R:L30-L86`).
* `is_acyclic()` for matrices returns `FALSE` when `topo_sort()` signals `graph_has_cycle` and `TRUE` otherwise (`R/utils-graph.R:L111-L119`).
* Tested by: linear graph ordering (`tests/testthat/test-utils-graph.R:L4-L7`).

## 4. Shiny module generics

### 4.1 `block_server()` and `expr_server()`

* A block is represented by nested shiny modules; the top-level module is created by the `block_server()` generic and the default `block` method normally suffices; `expr_server()` and `block_eval()` are further customization points (`R/block-server.R:L1-L11`).
* `block_server()` dispatches on `x` (`R/block-server.R:L42-L44`); both `block_server()` and `expr_server()` return a `shiny::moduleServer()` (`R/block-server.R:L36-L39`).
* A block is ready for evaluation when input data satisfying `validate_data_inputs()` is available and state values are non-empty (unless relaxed via `allow_empty_state`); conditions raised during validation and evaluation are caught and surfaced (`R/block-server.R:L20-L24`).
* The default method `block_server.block()` (`R/block-server.R:L52-L241`):
  * initializes `data_valid` to `TRUE` when the block has no data validator and to `NULL` otherwise (`R/block-server.R:L63-L66`);
  * tracks conditions per phase `data`, `state`, `eval`, `render` and `block` (`R/block-server.R:L68-L74`);
  * starts the expression module via `expr_server()` and checks its return value (`R/block-server.R:L80-L83`);
  * registers the validation and state-check observers (`R/block-server.R:L104-L105`);
  * calls the `ctrl_block` plugin with the externally controllable variables and an `eval` reactive, defaulting to `TRUE` when no plugin is supplied (`R/block-server.R:L181-L192`);
  * calls the `edit_block` plugin (`R/block-server.R:L198-L204`);
  * returns a list with `result`, `expr`, `state` and `conditions` (`R/block-server.R:L230-L238`).
* Every externally controllable variable must inherit from `reactiveVal`, otherwise an `unsupported_external_ctrl_variable` error is raised (`R/block-server.R:L168-L179`).

### 4.2 `block_eval()`

* `block_eval()` evaluates an interpolated block expression in the context of the block's data inputs (`R/block-server.R:L36-L39`); the generic is defined in `R/block-eval.R:L5-L7` and documented under the `block_server` topic (`R/block-eval.R:L1-L4`).
* The default method evaluates `expr` in `env` with `eval()` (`R/block-eval.R:L10-L12`).
* `eval_env()` builds the evaluation environment from the data list, with `baseenv()` as parent unless option `attach_default_packages` is `TRUE`, in which case the parent chain exposes the exports of the default R packages (`R/block-eval.R:L16-L40`), as locked environments (`R/block-eval.R:L42-L54`).
* Tested by: the default parent is `baseenv()` and `utils::head` is not visible (`tests/testthat/test-eval-env.R:L1-L5`).

### 4.3 `block_ui()`, `expr_ui()` and `block_output()`

* `expr_ui()` renders the block-type-specific user inputs (calling the `ui` passed to `new_block()`), while `block_ui()` renders output UI shared via the class hierarchy; `block_output()` produces the output that `block_ui()` displays (`R/block-ui.R:L1-L15`).
* The result of `block_output()` is assigned to `output$result`, so `block_ui()` must refer to it as `NS(id, "result")` (`R/block-ui.R:L17-L20`).
* `block_output()` must return the result of a shiny render function and `block_ui()` shiny UI (`R/block-ui.R:L26-L32`).
* The default `block` methods of `block_ui()` and `block_output()` return `NULL` (`R/block-ui.R:L39-L42`, `R/block-ui.R:L73-L76`).
* `expr_ui.block()` aborts with `superfluous_expr_ui_args` when called with extra arguments (`R/block-ui.R:L50-L58`) and calls the block's expression UI with the namespaced ID `NS(id, "expr")` (`R/block-ui.R:L62-L62`).

### 4.4 `board_server()`

* `board_server()` returns a `shiny::moduleServer()` with all logic to manipulate board components via UI and is extensible via S3, plugins and callbacks (`R/board-server.R:L1-L9`, `R/board-server.R:L25-L31`).
* The default method validates callbacks and board options before starting the module (`R/board-server.R:L42-L62`).
* Active block conditions are exposed as a reactive data frame `board$conditions` with columns `block`, `phase`, `severity`, `message` and `id` (`R/board-server.R:L11-L19`), built from each block's `server$conditions` reactive (`R/board-server.R:L82-L86`).
* All board state changes flow through a single `board_update` reactive; an initial core observer validates and augments the payload, a final one applies it, and the highest and lowest reactive priorities are reserved for core (`R/board-server.R:L682-L691`).
* `validate_board_update()` checks payload structure and cross-references and returns the payload invisibly (`R/board-server.R:L781-L788`); a non-list payload is rejected with `board_update_type_invalid` (`R/board-server.R:L795-L800`).
* The default `apply_board_update.board()` returns the board unchanged (`R/board-server.R:L1254-L1257`).
* Every update cycle records `board$last_update` with fields `seq`, `ok`, `phase` and `message` (`R/board-server.R:L728-L738`).

## 5. Plugins

* Plugins are the core mechanism for customizing board UX; every plugin inherits from `plugin` plus a specific sub-class, sets of plugins use the wrapper class `plugins`, and each plugin has a server, usually a UI, and an optional validator (`R/board-plugins.R:L1-L9`).
* `new_plugin()` builds a list with `server` and `ui`, stores the validator as an attribute, and validates the result (`R/board-plugins.R:L34-L44`).
* `validate_plugin()` requires inheritance from `plugin`, list-like behaviour, exactly the components `server` and `ui`, a function or `NULL` server and UI, and a function validator (`R/board-plugins.R:L124-L174`).
* The default plugin set for a board is `preserve_board`, `manage_blocks`, `manage_links`, `manage_stacks`, `notify_user`, `generate_code`, `edit_block` and `edit_stack`, optionally subset with `which` (`R/board-plugins.R:L318-L336`).
* Tested by: invalid plugins raise `plugin_inheritance_invalid` and `plugin_components_invalid` (`tests/testthat/test-board-plugins.R:L12-L15`, `tests/testthat/test-board-plugins.R:L24-L29`).

| Plugin (file) | Documented role | Constructor |
|---|---|---|
| `preserve_board` (`R/plugin-serdes.R`) | Save/restore of board state via serialization; server must return a reactive evaluating to `NULL` or a `board` (`R/plugin-serdes.R:L1-L18`) | `R/plugin-serdes.R:L21-L26` |
| `manage_blocks` (`R/plugin-blocks.R`) | Add/remove blocks; updates as `blocks` entry with `add`/`rm` (`R/plugin-blocks.R:L1-L12`) | `R/plugin-blocks.R:L22-L26` |
| `manage_links` (`R/plugin-links.R`) | Add/remove/modify links via `add`/`rm`/`mod` (`R/plugin-links.R:L1-L15`) | `R/plugin-links.R:L25-L27` |
| `manage_stacks` (`R/plugin-stacks.R`) | Add/remove/modify stacks via `add`/`rm`/`mod` (`R/plugin-stacks.R:L1-L15`) | `R/plugin-stacks.R:L25-L29` |
| `edit_block` (`R/plugin-block.R`) | Edit block title; remove and insert blocks (`R/plugin-block.R:L1-L9`) | `R/plugin-block.R:L19-L22` |
| `edit_stack` (`R/plugin-stack.R`) | Edit stack name; remove stack (`R/plugin-stack.R:L1-L8`) | `R/plugin-stack.R:L18-L20` |
| `generate_code` (`R/plugin-code.R`) | Expose reproducible code, default modal with copy-to-clipboard (`R/plugin-code.R:L1-L8`) | `R/plugin-code.R:L18-L22` |
| `notify_user` (`R/plugin-notification.R`) | Show block conditions as toasts, tracked per block (`R/plugin-notification.R:L1-L9`) | `R/plugin-notification.R:L20-L22` |
| `ctrl_block` (`R/plugin-control.R`) | External control of block inputs (`R/plugin-control.R:L1-L17`) | `R/plugin-control.R:L28-L30` |

* The `ctrl_block` server applies submitted values, evaluates the block expression, and on error reverts the values, notifies the user and closes the gate (`FALSE`); on success the gate is `TRUE` (`R/plugin-control.R:L53-L89`). Its validator accepts only `TRUE` or a reactive (`R/plugin-control.R:L120-L130`).
* The `preserve_board` validator requires a reactive return value whose value is a `board` or a list with a `board` element, and validates that board (`R/plugin-serdes.R:L193-L227`).
* `serialize_board.board()` collects block states and board option values and passes them to `blockr_ser()` (`R/plugin-serdes.R:L150-L166`); `restore_board.board()` deserializes with `blockr_deser()` (`R/plugin-serdes.R:L96-L106`).

## 6. Serialization (`R/utils-serdes.R`)

* Blocks are serialized by recording their constructor together with state values that re-create the object when passed to the constructor; `blockr_ser()` and `blockr_deser()` are generics producing nested lists of mostly strings without environments (`R/utils-serdes.R:L1-L12`).
* `blockr_deser()` forwards `...` to the dispatched per-class method (`R/utils-serdes.R:L14-L16`).
* For most objects `blockr_ser()` returns a list with `object` (class vector) and `payload`; `blockr_deser()` uses `object` to instantiate an empty object of that class and dispatch (`R/utils-serdes.R:L28-L32`).
* `blockr_ser.block()` uses the initial block state when no state is given, adds non-internal attributes to the payload and serializes the constructor (`R/utils-serdes.R:L42-L62`).
* `blockr_deser.list()` requires an `object` element, dispatches on it, and raises `block_deser_class_error` if the result's class differs (`R/utils-serdes.R:L259-L280`).
* Tested by: a dataset block survives a serialize/deserialize round trip (`tests/testthat/test-utils-serdes.R:L5-L9`); a class mismatch raises `block_deser_class_error` (`tests/testthat/test-utils-serdes.R:L113-L120`).

## 7. Input validation (`dat_valid` / `validate_data_inputs()`)

* `new_block()` accepts an optional data validator `dat_valid` taking the same arguments as the server function (excluding `id`); the block expression is not evaluated while it throws an error (`R/block-class.R:L98-L104`).
* Messages and warnings are caught and shown without interrupting evaluation; errors are caught and interrupt evaluation while validation fails (`R/block-class.R:L106-L109`).
* `validate_data_inputs()` returns `NULL` when no validator is set and otherwise the result of calling the validator with the data inputs (`R/block-class.R:L559-L566`; documented in `R/block-class.R:L459-L463` and `R/block-class.R:L508-L509`).
* At runtime the validator is only wired up for blocks that have one: on every data change the observer clears the result, resets `state_set`, and records whether `validate_data_inputs()` succeeded, capturing conditions under phase `"data"` (`R/block-server.R:L280-L305`).
* The state check returns `NULL` (not ready) while data is not valid, and otherwise checks non-emptiness of state values according to `allow_empty_state` (`R/block-server.R:L307-L336`).
* Examples of validators in shipped blocks: the merge block requires two data frames (`R/transform-merge.R:L88-L90`); the scatter block requires a data frame or matrix (`R/plot-scatter.R:L76-L78`).

## 8. Block registry

* The registry associates block constructors with metadata and a unique ID (by default derived from the first class) to provide a browsable directory (`R/block-registry.R:L3-L12`).
* Exported constructors are preferred because constructors are tracked for serialization (`R/block-registry.R:L14-L24`).
* Registration is via `register_block()`/`register_blocks()`, removal via `unregister_blocks()`, listing via `list_blocks()`/`available_blocks()`, and creation by ID via `create_block()` (`R/block-registry.R:L26-L32`).

## 9. Regression evidence

* The repository contains a CI workflow `.github/workflows/ci.yaml` that triggers on pull requests to `main` and on merge groups (`.github/workflows/ci.yaml:L1-L4`) and delegates to the reusable workflow `BristolMyersSquibb/blockr.ci/.github/workflows/ci.yaml@main`, plus a reverse-dependency job (`.github/workflows/ci.yaml:L8-L29`). Because CI already exists, no additional validation workflow was added.
* The reusable workflow is maintained outside this repository. Its PR jobs include an R CMD check (`smoke`, via `r-lib/actions/check-r-package@v2`, which runs the testthat suite) and a `coverage` job (`covr::package_coverage()`), per its header comment ("The other four jobs run the suite or build the site") and job definitions at `https://github.com/BristolMyersSquibb/blockr.ci/blob/main/.github/workflows/ci.yaml` (lines 57-62, 321-366, 421-496 at time of writing). External lines are not lock-checked by `generate.R`.
* The current local test baseline and the CI status of the validation PR are recorded in the PR description; re-run `devtools::test()` to reproduce.
