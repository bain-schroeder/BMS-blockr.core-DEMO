#!/usr/bin/env Rscript
#
# Regenerates the derived validation documents from repository sources.
#
#   Rscript validation/tools/generate.R            # rewrite generated docs
#   Rscript validation/tools/generate.R --check    # fail on drift
#   Rscript validation/tools/generate.R --lock     # re-baseline citations.lock
#
# Inputs:  NAMESPACE, man/*.Rd, R/*.R, tests/testthat/test-*.R
# Outputs: validation/traceability-matrix.md, validation/test-scripts.md
# Checks:  every `path:Lx-Ly` citation in validation/system-description.md
#          resolves and its cited text matches validation/citations.lock.
#
# Only base R, tools and testthat (for argument matching) are required.

args <- commandArgs(trailingOnly = TRUE)
mode <- if ("--check" %in% args) "check" else if ("--lock" %in% args) "lock" else "write"

if (!file.exists("DESCRIPTION") || !dir.exists("validation")) {
  stop("Run from the package root: Rscript validation/tools/generate.R")
}

pkg <- unname(read.dcf("DESCRIPTION", fields = "Package")[1, 1])

`%||%` <- function(x, y) if (is.null(x) || !length(x)) y else x

cite <- function(file, l1, l2 = l1) sprintf("`%s:L%d-L%d`", file, l1, l2)

md_cell <- function(x) gsub("|", "\\|", gsub("\n", " ", x, fixed = TRUE), fixed = TRUE)

code_span <- function(x) {
  if (grepl("`", x, fixed = TRUE)) paste0("`` ", x, " ``") else paste0("`", x, "`")
}

squish <- function(x) trimws(gsub("[[:space:]]+", " ", x))

trunc_chr <- function(x, n = 160) {
  x <- squish(x)
  if (nchar(x) > n) paste0(substr(x, 1, n - 3), "...") else x
}

# ---------------------------------------------------------------------------
# NAMESPACE
# ---------------------------------------------------------------------------

ns_lines <- readLines("NAMESPACE")

ns_exports <- data.frame(
  symbol = sub("^export\\((.*)\\)$", "\\1", grep("^export\\(", ns_lines, value = TRUE)),
  line = grep("^export\\(", ns_lines),
  stringsAsFactors = FALSE
)
ns_exports$symbol <- gsub('^"|"$', "", ns_exports$symbol)

s3_idx <- grep("^S3method\\(", ns_lines)
s3_parts <- strsplit(sub("^S3method\\((.*)\\)$", "\\1", ns_lines[s3_idx]), ",")
ns_s3 <- data.frame(
  generic = gsub('"', "", trimws(vapply(s3_parts, `[`, "", 1L))),
  class = gsub('"', "", trimws(vapply(s3_parts, `[`, "", 2L))),
  line = s3_idx,
  stringsAsFactors = FALSE
)
ns_s3$method <- paste(ns_s3$generic, ns_s3$class, sep = ".")

# ---------------------------------------------------------------------------
# R/ top-level definitions
# ---------------------------------------------------------------------------

r_files <- sort(list.files("R", pattern = "\\.[Rr]$", full.names = TRUE))

defs <- do.call(rbind, lapply(r_files, function(f) {
  exprs <- parse(f, keep.source = TRUE)
  refs <- attr(exprs, "srcref")
  rows <- lapply(seq_along(exprs), function(i) {
    e <- exprs[[i]]
    if (is.call(e) && as.character(e[[1]]) %in% c("<-", "=") &&
        (is.symbol(e[[2]]) || is.character(e[[2]]))) {
      data.frame(
        symbol = as.character(e[[2]]),
        file = f,
        l1 = refs[[i]][1],
        l2 = refs[[i]][3],
        is_fun = is.call(e[[3]]) && identical(e[[3]][[1]], as.name("function")),
        stringsAsFactors = FALSE
      )
    }
  })
  do.call(rbind, rows)
}))
defs <- defs[!duplicated(defs$symbol), ]
rownames(defs) <- defs$symbol

def_cite <- function(sym) {
  if (sym %in% defs$symbol) {
    d <- defs[sym, ]
    cite(d$file, d$l1, d$l2)
  } else {
    "_definition not located as a top-level assignment in `R/`_"
  }
}

# Roxygen blocks: runs of `#'` lines, attributed to the topic they document.

rox_blocks <- do.call(rbind, lapply(r_files, function(f) {
  lns <- readLines(f)
  is_rox <- grepl("^\\s*#'", lns)
  rl <- rle(is_rox)
  ends <- cumsum(rl$lengths)
  starts <- ends - rl$lengths + 1L
  keep <- rl$values
  if (!any(keep)) return(NULL)
  rows <- lapply(which(keep), function(k) {
    s <- starts[k]
    e <- ends[k]
    txt <- sub("^\\s*#' ?", "", lns[s:e])
    nxt <- e + 1L
    while (nxt <= length(lns) && !nzchar(trimws(lns[nxt]))) nxt <- nxt + 1L
    target <- defs$symbol[defs$file == f & defs$l1 == nxt]
    target <- if (length(target)) target[1] else NA_character_
    rdname <- sub("^@rdname\\s+", "", grep("^@rdname\\s", txt, value = TRUE))
    nm <- sub("^@name\\s+", "", grep("^@name\\s", txt, value = TRUE))
    topic <- c(rdname, nm, target)[1]
    ret <- grep("^@return", txt)
    ret_l1 <- ret_l2 <- NA_integer_
    if (length(ret)) {
      tags <- grep("^@", txt)
      nxt_tag <- tags[tags > ret[1]]
      stop_at <- if (length(nxt_tag)) nxt_tag[1] - 1L else length(txt)
      while (stop_at > ret[1] && !nzchar(trimws(txt[stop_at]))) stop_at <- stop_at - 1L
      ret_l1 <- s + ret[1] - 1L
      ret_l2 <- s + stop_at - 1L
    }
    data.frame(file = f, l1 = s, l2 = e, topic = topic, target = target,
               ret_l1 = ret_l1, ret_l2 = ret_l2, stringsAsFactors = FALSE)
  })
  do.call(rbind, rows)
}))

# ---------------------------------------------------------------------------
# man/*.Rd
# ---------------------------------------------------------------------------

rd_text <- function(x) {
  if (is.character(x)) return(paste(x, collapse = ""))
  tag <- attr(x, "Rd_tag") %||% ""
  if (tag %in% c("COMMENT", "\\dontrun", "\\donttest", "\\examples", "\\usage")) {
    return("")
  }
  if (tag == "\\href" && length(x) >= 2) return(rd_text(x[[2]]))
  if (tag == "\\item" && length(x) == 2) {
    return(paste0(" ", rd_text(x[[1]]), ": ", rd_text(x[[2]])))
  }
  inner <- paste(vapply(x, rd_text, ""), collapse = "")
  switch(
    tag,
    "\\code" = , "\\verb" = , "\\env" = , "\\option" = paste0("`", inner, "`"),
    "\\item" = paste0(" * ", inner),
    "\\emph" = , "\\strong" = , "\\bold" = inner,
    inner
  )
}

rd_files <- sort(list.files("man", pattern = "\\.Rd$", full.names = TRUE))

rd <- lapply(rd_files, function(f) {
  x <- tools::parse_Rd(f)
  tags <- vapply(x, function(el) attr(el, "Rd_tag") %||% "", "")
  get <- function(tag) x[tags == tag]
  rng <- function(el) {
    s <- attr(el, "srcref")
    c(s[1], s[3])
  }
  value <- get("\\value")
  desc <- get("\\description")
  secs <- get("\\section")
  src_hdr <- grep("^% Please edit documentation in", readLines(f, n = 3), value = TRUE)
  srcs <- if (length(src_hdr)) {
    trimws(strsplit(sub("^% Please edit documentation in ", "", src_hdr), ",")[[1]])
  } else character()
  list(
    file = f,
    name = squish(rd_text(get("\\name")[[1]])),
    aliases = vapply(get("\\alias"), function(a) squish(rd_text(a)), ""),
    title = squish(rd_text(get("\\title")[[1]])),
    value = if (length(value)) squish(rd_text(value[[1]])) else NA_character_,
    value_rng = if (length(value)) rng(value[[1]]) else NULL,
    desc = if (length(desc)) squish(rd_text(desc[[1]])) else NA_character_,
    desc_rng = if (length(desc)) rng(desc[[1]]) else NULL,
    sections = lapply(secs, function(s) {
      list(title = squish(rd_text(s[[1]])), rng = rng(s))
    }),
    sources = srcs
  )
})
names(rd) <- vapply(rd, `[[`, "", "name")

alias_topic <- do.call(c, unname(lapply(rd, function(t) setNames(rep(t$name, length(t$aliases)), t$aliases))))

# ---------------------------------------------------------------------------
# Requirements: one per Rd topic, stated by its documented contract
# ---------------------------------------------------------------------------

topic_names <- names(rd)
req_ids <- setNames(sprintf("REQ-%03d", seq_along(topic_names)), topic_names)

# S3 methods registered in NAMESPACE whose generic belongs to a topic.
s3_topic <- setNames(alias_topic[ns_s3$generic], ns_s3$method)
s3_topic <- s3_topic[!is.na(s3_topic)]

design <- lapply(topic_names, function(tp) {
  t <- rd[[tp]]
  al <- t$aliases[t$aliases %in% defs$symbol | t$aliases %in% ns_exports$symbol]
  meth <- setdiff(names(s3_topic)[s3_topic == tp], al)
  syms <- unique(c(al, meth))
  if (!length(syms)) return(NULL)
  data.frame(
    symbol = syms,
    kind = ifelse(
      syms %in% ns_exports$symbol, "exported function",
      ifelse(syms %in% ns_s3$method, "registered S3 method", "documented, not exported")
    ),
    ns_line = vapply(syms, function(s) {
      i <- c(ns_exports$line[ns_exports$symbol == s], ns_s3$line[ns_s3$method == s])
      if (length(i)) i[1] else NA_integer_
    }, 1L),
    stringsAsFactors = FALSE
  )
})
names(design) <- topic_names

# Every symbol that can carry a direct trace link, mapped to its topic.
direct_topic <- c(alias_topic, s3_topic)
direct_topic <- direct_topic[!duplicated(names(direct_topic))]

# Internal (non-exported, undocumented) helpers are attributed to the topic of
# the nearest preceding documented definition in the same file. These links
# are reported as "indirect" so that reviewers can judge them separately.
internal_topic <- local({
  res <- character()
  for (f in unique(defs$file)) {
    d <- defs[defs$file == f, ]
    d <- d[order(d$l1), ]
    cur <- NA_character_
    for (i in seq_len(nrow(d))) {
      s <- d$symbol[i]
      if (s %in% names(direct_topic)) {
        cur <- direct_topic[[s]]
      } else if (!is.na(cur)) {
        res[s] <- cur
      }
    }
  }
  res
})

# ---------------------------------------------------------------------------
# tests/testthat
# ---------------------------------------------------------------------------

test_files <- sort(list.files("tests/testthat", pattern = "^test-.*\\.R$", full.names = TRUE))

testthat_fun <- function(nm) {
  if (exists(nm, envir = asNamespace("testthat"), inherits = FALSE)) {
    get(nm, envir = asNamespace("testthat"))
  }
}

call_head <- function(x) {
  if (!is.call(x)) return(NA_character_)
  h <- x[[1]]
  if (is.symbol(h)) return(as.character(h))
  if (is.call(h) && as.character(h[[1]]) %in% c("::", ":::")) return(as.character(h[[3]]))
  NA_character_
}

tests <- list()

for (f in test_files) {
  exprs <- parse(f, keep.source = TRUE)
  refs <- attr(exprs, "srcref")
  pd <- utils::getParseData(exprs, includeText = TRUE)
  lns <- readLines(f)
  for (i in seq_along(exprs)) {
    e <- exprs[[i]]
    if (!identical(call_head(e), "test_that")) next
    m <- match.call(testthat::test_that, e)
    l1 <- refs[[i]][1]
    l2 <- refs[[i]][3]
    tok <- pd[pd$line1 >= l1 & pd$line2 <= l2, ]
    strs <- tok$text[tok$token == "STR_CONST"]
    strs <- substr(strs, 2L, nchar(strs) - 1L)
    syms <- unique(c(tok$text[tok$token %in% c("SYMBOL_FUNCTION_CALL", "SYMBOL")],
                     strs[strs %in% defs$symbol[defs$is_fun]]))
    syms <- intersect(syms, defs$symbol)
    # Outermost expectation calls.
    ex_tok <- tok[tok$token == "SYMBOL_FUNCTION_CALL" & grepl("^expect_", tok$text), ]
    ex <- lapply(seq_len(nrow(ex_tok)), function(k) {
      sym_expr <- ex_tok$parent[k]
      call_id <- pd$parent[pd$id == sym_expr]
      row <- pd[pd$id == call_id, ]
      list(fn = ex_tok$text[k], l1 = row$line1, l2 = row$line2, c1 = row$col1,
           text = utils::getParseText(pd, call_id))
    })
    if (length(ex)) {
      ord <- order(vapply(ex, `[[`, 1L, "l1"), vapply(ex, `[[`, 1L, "c1"))
      ex <- ex[ord]
      keep <- logical(length(ex))
      last_end <- c(-1L, -1L)
      for (k in seq_along(ex)) {
        if (ex[[k]]$l1 > last_end[1] ||
            (ex[[k]]$l1 == last_end[1] && ex[[k]]$c1 > last_end[2])) {
          keep[k] <- TRUE
          end_row <- pd[pd$line1 == ex[[k]]$l1 & pd$col1 == ex[[k]]$c1 &
                          pd$token == "expr", ]
          last_end <- c(ex[[k]]$l2, max(end_row$col2, 0L))
        }
      }
      ex <- ex[keep]
    }
    for (k in seq_along(ex)) {
      cl <- tryCatch(str2lang(ex[[k]]$text), error = function(e) NULL)
      fn <- testthat_fun(ex[[k]]$fn)
      mc <- if (!is.null(cl) && is.function(fn)) {
        tryCatch(match.call(fn, cl), error = function(e) cl)
      } else cl
      ex[[k]]$call <- mc
      subj <- if (!is.null(mc) && length(mc) >= 2) mc[[2]] else NULL
      ex[[k]]$subject <- if (is.call(subj)) call_head(subj) else NA_character_
      etok <- tok[tok$line1 >= ex[[k]]$l1 & tok$line2 <= ex[[k]]$l2 &
                    tok$token %in% c("SYMBOL_FUNCTION_CALL", "SYMBOL"), ]
      ex[[k]]$syms <- intersect(unique(etok$text), defs$symbol)
    }
    # Top-level statements of the test body.
    body <- m$code
    stmts <- list()
    if (is.call(body) && identical(body[[1]], as.name("{"))) {
      sr <- attr(body, "srcref")
      for (j in seq_along(sr)[-1]) {
        stmts[[length(stmts) + 1]] <- list(l1 = sr[[j]][1], l2 = sr[[j]][3])
      }
    } else if (!is.null(body)) {
      stmts[[1]] <- list(l1 = l1, l2 = l2)
    }
    tests[[length(tests) + 1]] <- list(
      file = f, stem = sub("^test-(.*)\\.R$", "\\1", basename(f)),
      desc = as.character(m$desc), l1 = l1, l2 = l2, syms = syms,
      expectations = ex, stmts = stmts, lines = lns
    )
  }
}

tc_ids <- sprintf("TC-%03d", seq_along(tests))
for (k in seq_along(tests)) tests[[k]]$id <- tc_ids[k]

# ---------------------------------------------------------------------------
# Trace links
# ---------------------------------------------------------------------------
#
# A test references a package symbol when the symbol occurs as a call or name
# token inside the `test_that()` block. A reference becomes a trace link when
# at least one of the following holds:
#   file    the symbol is defined in R/<stem>.R and the test is test-<stem>.R
#   name    the symbol appears verbatim in the test_that() description
#   subject the symbol is the outermost call in the first argument of an
#           expectation (the object under test)

word_in <- function(sym, txt) {
  grepl(paste0("(^|[^A-Za-z0-9._])", gsub(".", "\\.", sym, fixed = TRUE),
               "($|[^A-Za-z0-9._])"), txt)
}

links <- do.call(rbind, lapply(tests, function(t) {
  subjects <- unique(stats::na.omit(vapply(t$expectations, `[[`, "", "subject")))
  rows <- lapply(t$syms, function(s) {
    basis <- c(
      file = sub("\\.R$", "", basename(defs[s, "file"])) == t$stem,
      name = word_in(s, t$desc),
      subject = s %in% subjects
    )
    if (!any(basis)) return(NULL)
    if (s %in% names(direct_topic)) {
      tp <- direct_topic[[s]]
      type <- "direct"
    } else if (s %in% names(internal_topic)) {
      tp <- internal_topic[[s]]
      type <- "indirect"
    } else {
      return(NULL)
    }
    data.frame(tc = t$id, symbol = s, topic = tp, type = type,
               basis = paste(names(basis)[basis], collapse = "+"),
               stringsAsFactors = FALSE)
  })
  do.call(rbind, rows)
}))

referenced <- unique(unlist(lapply(tests, `[[`, "syms")))

topic_cov <- vapply(topic_names, function(tp) {
  l <- links[links$topic == tp, ]
  if (any(l$type == "direct")) "direct" else if (nrow(l)) "indirect only" else "none"
}, "")

# ---------------------------------------------------------------------------
# Rendering helpers
# ---------------------------------------------------------------------------

fingerprint <- local({
  inputs <- c("NAMESPACE", rd_files, r_files, test_files)
  sums <- unname(tools::md5sum(inputs))
  tmp <- tempfile()
  writeLines(paste(inputs, sums), tmp)
  unname(tools::md5sum(tmp))
})

header <- function(title) {
  c(
    paste("#", title),
    "",
    "<!-- GENERATED FILE: do not edit by hand. -->",
    "<!-- Regenerate with: Rscript validation/tools/generate.R -->",
    "",
    sprintf("> Generated by `validation/tools/generate.R` from `NAMESPACE`, `man/*.Rd`, `R/*.R` and `tests/testthat/test-*.R` of package `%s` (version %s).",
            pkg, read.dcf("DESCRIPTION", fields = "Version")[1, 1]),
    sprintf("> Input fingerprint (MD5 over all input files): `%s`. A different fingerprint means the inputs changed since generation.", fingerprint),
    ""
  )
}

tc_label <- function(t) sprintf("%s (%s › \"%s\")", t$id, basename(t$file), md_cell(t$desc))

tc_by_id <- setNames(tests, tc_ids)

rd_cite <- function(t, rng) sprintf("`%s:L%d-L%d`", t$file, rng[1], rng[2])

req_statement <- function(t) {
  if (!is.na(t$value)) {
    list(text = t$value, src = rd_cite(t, t$value_rng), field = "\\value")
  } else if (!is.na(t$desc)) {
    list(text = t$desc, src = rd_cite(t, t$desc_rng), field = "\\description")
  } else {
    list(text = t$title, src = sprintf("`%s`", t$file), field = "\\title")
  }
}

rox_return_cites <- function(tp) {
  b <- rox_blocks[!is.na(rox_blocks$topic) & rox_blocks$topic == tp &
                    !is.na(rox_blocks$ret_l1), ]
  if (!nrow(b)) return(character())
  sprintf("`%s:L%d-L%d`", b$file, b$ret_l1, b$ret_l2)
}

# ---------------------------------------------------------------------------
# traceability-matrix.md
# ---------------------------------------------------------------------------

render_matrix <- function() {
  out <- header("Traceability Matrix")
  n_req <- length(topic_names)
  n_dir <- sum(topic_cov == "direct")
  n_ind <- sum(topic_cov == "indirect only")
  n_none <- sum(topic_cov == "none")

  out <- c(out,
    "## How to read this matrix",
    "",
    "* **Requirements** are derived one per documented topic (`man/<topic>.Rd`). The requirement statement is the topic's documented contract: the `\\value` section (or `\\description` where no `\\value` exists), quoted from the cited `man/*.Rd` lines and the roxygen `@return` lines in `R/` that generate them.",
    "* **Design elements** are the topic's aliases that are defined in `R/` or exported in `NAMESPACE`, plus S3 methods registered in `NAMESPACE` for generics of that topic. Each carries its definition line range and its `NAMESPACE` line.",
    "* **Test cases** are `test_that()` blocks in `tests/testthat/test-*.R` (IDs `TC-NNN`, shared with `test-scripts.md`). A test *references* a package symbol when the symbol occurs as a call or name token in the `test_that()` block, or as a string literal equal to the name of a package function (as in `get_s3_method(\"block_server\", blk)`). A test is linked to a requirement only if it references one of the requirement's symbols **and** one of these mechanical rules holds:",
    "  * `file`: the symbol is defined in `R/<stem>.R` and the test lives in `tests/testthat/test-<stem>.R`;",
    "  * `name`: the symbol name appears verbatim in the `test_that()` description;",
    "  * `subject`: the symbol is the outermost call in the first argument of an `expect_*()` call (the object under test).",
    "* **Link type** `direct` means the linked symbol is a design element of the requirement. `indirect` means the linked symbol is an internal (non-exported, undocumented) helper, attributed to the requirement of the nearest preceding documented definition in the same `R/` file. Indirect links are an inference from file layout and are reported separately; they are never counted as direct coverage.",
    "* No link is added by hand. Anything not satisfying the rules above is reported as a gap in the coverage summary.",
    "",
    "## Coverage summary",
    "",
    "| Metric | Count |",
    "|---|---|",
    sprintf("| Requirements (documented topics) | %d |", n_req),
    sprintf("| Requirements with direct test coverage | %d |", n_dir),
    sprintf("| Requirements with indirect-only coverage | %d |", n_ind),
    sprintf("| Requirements with no linked test | %d |", n_none),
    sprintf("| Exported symbols (`export()` in `NAMESPACE`) | %d |", nrow(ns_exports)),
    sprintf("| Registered S3 methods (`S3method()` in `NAMESPACE`) | %d |", nrow(ns_s3)),
    sprintf("| Test files | %d |", length(test_files)),
    sprintf("| Test cases (`test_that()` blocks) | %d |", length(tests)),
    sprintf("| Test cases linked to at least one requirement | %d |", length(unique(links$tc))),
    ""
  )

  # Requirements without coverage.
  out <- c(out, "### Requirements with no linked test (FLAGGED)", "")
  none <- topic_names[topic_cov == "none"]
  out <- c(out, if (length(none)) {
    c("| Requirement | Topic | Exported symbols |", "|---|---|---|",
      vapply(none, function(tp) {
        d <- design[[tp]]
        ex <- if (is.null(d)) character() else d$symbol[d$kind == "exported function"]
        sprintf("| %s | `man/%s.Rd` | %s |", req_ids[[tp]], tp,
                md_cell(paste(code_span_v(ex), collapse = ", ") %||% "none"))
      }, ""))
  } else "None.", "")

  ind <- topic_names[topic_cov == "indirect only"]
  out <- c(out, "### Requirements with indirect-only coverage (FLAGGED)", "",
    if (length(ind)) {
      c("| Requirement | Topic | Linked via internal helper(s) |", "|---|---|---|",
        vapply(ind, function(tp) {
          s <- unique(links$symbol[links$topic == tp])
          sprintf("| %s | `man/%s.Rd` | %s |", req_ids[[tp]], tp,
                  md_cell(paste(code_span_v(s), collapse = ", ")))
        }, ""))
    } else "None.", "")

  # Exported symbols without direct links.
  linked_direct <- unique(links$symbol[links$type == "direct"])
  exp_un <- ns_exports[!ns_exports$symbol %in% linked_direct, ]
  out <- c(out,
    "### Exported symbols with no directly linked test (FLAGGED)", "",
    "`Referenced in tests` = the symbol occurs somewhere in `tests/testthat/test-*.R` (for example as setup) without satisfying a link rule; `No` = it does not occur in any test file.",
    "",
    "| Symbol | NAMESPACE | Requirement | Referenced in tests |", "|---|---|---|---|",
    vapply(seq_len(nrow(exp_un)), function(i) {
      s <- exp_un$symbol[i]
      tp <- alias_topic[s]
      sprintf("| %s | `NAMESPACE:L%d` | %s | %s |", code_span(md_cell(s)), exp_un$line[i],
              if (is.na(tp)) "_undocumented_" else req_ids[[tp]],
              if (s %in% referenced) "Yes" else "No")
    }, ""),
    "")

  undoc <- ns_exports$symbol[!ns_exports$symbol %in% names(alias_topic)]
  out <- c(out, "### Exported symbols without a documentation topic (FLAGGED)", "",
    if (length(undoc)) paste0("* ", code_span_v(undoc)) else "None.", "")

  # Test files / cases without links.
  linked_tc <- unique(links$tc)
  files_un <- test_files[!vapply(test_files, function(f) {
    any(vapply(tests[vapply(tests, `[[`, "", "file") == f], `[[`, "", "id") %in% linked_tc)
  }, TRUE)]
  out <- c(out, "### Test files not linked to any requirement (FLAGGED)", "",
    if (length(files_un)) paste0("* `", files_un, "`") else "None.", "")
  tc_un <- tests[!tc_ids %in% linked_tc]
  out <- c(out, "### Test cases not linked to any requirement (FLAGGED)", "",
    if (length(tc_un)) {
      c("| Test case | Location | Package symbols referenced |", "|---|---|---|",
        vapply(tc_un, function(t) {
          sprintf("| %s | %s | %s |", tc_label(t), cite(t$file, t$l1, t$l2),
                  if (length(t$syms)) md_cell(paste(code_span_v(t$syms), collapse = ", ")) else "none")
        }, ""))
    } else "None.", "")

  # Overview table.
  out <- c(out, "## Requirement overview", "",
    "| Requirement | Topic | Title | Design elements | Linked tests (direct / indirect) | Coverage |",
    "|---|---|---|---|---|---|",
    vapply(topic_names, function(tp) {
      l <- links[links$topic == tp, ]
      sprintf("| [%s](#%s) | `man/%s.Rd` | %s | %d | %d / %d | %s |",
              req_ids[[tp]], tolower(req_ids[[tp]]), tp, md_cell(rd[[tp]]$title),
              if (is.null(design[[tp]])) 0L else nrow(design[[tp]]),
              length(unique(l$tc[l$type == "direct"])),
              length(setdiff(unique(l$tc[l$type == "indirect"]), l$tc[l$type == "direct"])),
              topic_cov[[tp]])
    }, ""),
    "")

  # Detail per requirement.
  out <- c(out, "## Requirement detail", "")
  for (tp in topic_names) {
    t <- rd[[tp]]
    st <- req_statement(t)
    out <- c(out,
      sprintf("### %s", req_ids[[tp]]), "",
      sprintf("**Topic:** %s — `man/%s.Rd` (roxygen source: %s)", md_cell(t$title), tp,
              paste(sprintf("`%s`", t$sources), collapse = ", ") %||% "n/a"),
      "",
      sprintf("**Requirement** (from `%s`, %s%s):", st$field, st$src,
              if (length(rc <- rox_return_cites(tp))) paste0("; roxygen ", paste(rc, collapse = ", ")) else ""),
      "",
      paste0("> ", st$text),
      "")
    if (length(t$sections)) {
      out <- c(out, "Documented behaviour sections: ",
               paste0("* ", vapply(t$sections, function(s) sprintf("%s — %s", md_cell(s$title), rd_cite(t, s$rng)), "")),
               "")
    }
    d <- design[[tp]]
    out <- c(out, "**Design elements**", "")
    out <- c(out, if (is.null(d)) "_No alias of this topic is defined in `R/` or exported._" else c(
      "| Symbol | Kind | Definition | NAMESPACE |", "|---|---|---|---|",
      vapply(seq_len(nrow(d)), function(i) {
        sprintf("| %s | %s | %s | %s |", code_span(md_cell(d$symbol[i])), d$kind[i],
                def_cite(d$symbol[i]),
                if (is.na(d$ns_line[i])) "not exported" else sprintf("`NAMESPACE:L%d`", d$ns_line[i]))
      }, "")), "")
    l <- links[links$topic == tp, ]
    out <- c(out, "**Test cases**", "")
    if (!nrow(l)) {
      out <- c(out, "**FLAG: no linked test case.**", "")
    } else {
      ids <- unique(l$tc)
      out <- c(out, "| Test case | Location | Link type | Via symbol (rule) |", "|---|---|---|---|",
        vapply(ids, function(id) {
          tt <- tc_by_id[[id]]
          li <- l[l$tc == id, ]
          via <- vapply(seq_len(nrow(li)), function(i) {
            v <- sprintf("%s (%s)", code_span(md_cell(li$symbol[i])), li$basis[i])
            if (li$type[i] == "indirect") paste(v, "at", def_cite(li$symbol[i])) else v
          }, "")
          sprintf("| %s | %s | %s | %s |", tc_label(tt), cite(tt$file, tt$l1, tt$l2),
                  if (any(li$type == "direct")) "direct" else "indirect",
                  paste(via, collapse = "; "))
        }, ""), "")
    }
  }

  # Test catalogue.
  out <- c(out, "## Test case catalogue", "",
    "| Test case | File | `test_that` name | Lines | Expectations | Requirements |",
    "|---|---|---|---|---|---|",
    vapply(tests, function(t) {
      r <- unique(links$topic[links$tc == t$id])
      sprintf("| %s | `%s` | %s | %s | %d | %s |", t$id, t$file, md_cell(t$desc),
              cite(t$file, t$l1, t$l2), length(t$expectations),
              if (length(r)) paste(req_ids[r], collapse = ", ") else "**unlinked**")
    }, ""), "")
  out
}

code_span_v <- function(x) vapply(x, code_span, "", USE.NAMES = FALSE)

# ---------------------------------------------------------------------------
# test-scripts.md
# ---------------------------------------------------------------------------

dep <- function(x) trunc_chr(paste(deparse(x, width.cutoff = 500L), collapse = " "), 120)

arg <- function(mc, nm, pos = NULL) {
  if (is.null(mc)) return(NULL)
  a <- as.list(mc)[-1]
  if (!is.null(a[[nm]])) return(a[[nm]])
  if (!is.null(pos) && length(a) >= pos && (is.null(names(a)) || !nzchar(names(a)[pos]))) {
    return(a[[pos]])
  }
  NULL
}

translate <- function(e, stem) {
  mc <- e$call
  fn <- e$fn
  obj <- arg(mc, "object", 1)
  o <- if (is.null(obj)) "the expression" else code_span(dep(obj))
  exp_v <- arg(mc, "expected", 2)
  ev <- if (is.null(exp_v)) "the expected value" else code_span(dep(exp_v))
  cls <- arg(mc, "class")
  rx <- arg(mc, "regexp")
  cond_detail <- paste0(
    if (!is.null(cls)) sprintf(" of class %s", code_span(dep(cls))) else "",
    if (!is.null(rx)) sprintf(" whose message matches %s", code_span(dep(rx))) else ""
  )
  switch(fn,
    expect_error = paste0("Evaluating ", o, " signals an error", cond_detail, "."),
    expect_warning = paste0("Evaluating ", o, " signals a warning", cond_detail, "."),
    expect_message = paste0("Evaluating ", o, " emits a message", cond_detail, "."),
    expect_condition = paste0("Evaluating ", o, " signals a condition", cond_detail, "."),
    expect_no_error = paste0("Evaluating ", o, " does not signal an error."),
    expect_no_warning = paste0("Evaluating ", o, " does not signal a warning."),
    expect_no_message = paste0("Evaluating ", o, " does not emit a message."),
    expect_no_condition = paste0("Evaluating ", o, " does not signal any condition."),
    expect_silent = paste0("Evaluating ", o, " produces no output, messages, warnings or errors."),
    expect_equal = paste0(o, " equals ", ev, " (within numeric tolerance)."),
    expect_identical = paste0(o, " is identical to ", ev, "."),
    expect_setequal = paste0(o, " has the same set of elements as ", ev, "."),
    expect_mapequal = paste0(o, " has the same names and values as ", ev, "."),
    expect_true = paste0(o, " is `TRUE`."),
    expect_false = paste0(o, " is `FALSE`."),
    expect_null = paste0(o, " is `NULL`."),
    expect_s3_class = paste0(o, " inherits from S3 class(es) ",
                             code_span(dep(arg(mc, "class", 2))), "."),
    expect_s4_class = paste0(o, " is an S4 object of class ",
                             code_span(dep(arg(mc, "class", 2))), "."),
    expect_type = paste0(o, " has base type ", code_span(dep(arg(mc, "type", 2))), "."),
    expect_length = paste0(o, " has length ", code_span(dep(arg(mc, "n", 2))), "."),
    expect_named = paste0(o, " is named",
                          if (is.null(exp_v)) "" else paste0(" ", ev), "."),
    expect_match = paste0(o, " matches the regular expression ",
                          code_span(dep(arg(mc, "regexp", 2))), "."),
    expect_no_match = paste0(o, " does not match the regular expression ",
                             code_span(dep(arg(mc, "regexp", 2))), "."),
    expect_output = paste0("Evaluating ", o, " prints output",
                           if (!is.null(arg(mc, "regexp", 2))) paste0(" matching ", code_span(dep(arg(mc, "regexp", 2)))) else "", "."),
    expect_contains = paste0(o, " contains all elements of ", ev, "."),
    expect_in = paste0("All elements of ", o, " are in ",
                       code_span(dep(arg(mc, "expected", 2))), "."),
    expect_gt = paste0(o, " is greater than ", ev, "."),
    expect_gte = paste0(o, " is greater than or equal to ", ev, "."),
    expect_lt = paste0(o, " is less than ", ev, "."),
    expect_lte = paste0(o, " is less than or equal to ", ev, "."),
    expect_invisible = paste0("Evaluating ", o, " returns its value invisibly."),
    expect_visible = paste0("Evaluating ", o, " returns its value visibly."),
    expect_vector = paste0(o, " is a vector matching the given prototype/size."),
    expect_snapshot = sprintf("The printed output of %s matches the approved snapshot in `tests/testthat/_snaps/%s.md`.",
                              code_span(dep(arg(mc, "x", 1))), stem),
    expect_snapshot_error = sprintf("The error message of %s matches the approved snapshot in `tests/testthat/_snaps/%s.md`.",
                                    code_span(dep(arg(mc, "x", 1))), stem),
    expect_snapshot_output = sprintf("The output of %s matches the approved snapshot in `tests/testthat/_snaps/%s.md`.",
                                     code_span(dep(arg(mc, "x", 1))), stem),
    expect_snapshot_value = sprintf("The value of %s matches the approved snapshot in `tests/testthat/_snaps/%s.md`.",
                                    code_span(dep(arg(mc, "x", 1))), stem),
    sprintf("The testthat expectation `%s()` succeeds for the code shown.", fn)
  )
}

show_code <- function(lns, l1, l2, max = 12L) {
  n <- l2 - l1 + 1L
  shown <- lns[l1:min(l2, l1 + max - 1L)]
  # De-indent for readability.
  ind <- min(nchar(sub("^(\\s*).*$", "\\1", shown[nzchar(trimws(shown))])), 0L, na.rm = TRUE)
  ind <- suppressWarnings(min(nchar(sub("^(\\s*).*$", "\\1", shown[nzchar(trimws(shown))]))))
  if (is.finite(ind) && ind > 0) shown <- substring(shown, ind + 1L)
  c("```r", shown, if (n > max) sprintf("# ... (%d more lines, see citation)", n - max), "```")
}

run_cmd <- function(t) {
  sprintf("testthat::test_file(\"%s\", desc = %s, package = \"%s\", load_package = \"source\")",
          t$file, deparse(t$desc), pkg)
}

code_under_test <- function(t, e) {
  l <- links[links$tc == t$id, ]
  s <- intersect(e$syms, l$symbol)
  if (!length(s)) s <- intersect(e$syms, c(names(direct_topic), names(internal_topic)))
  if (!length(s)) return("_no package symbol occurs in this expectation; see linked design elements above_")
  paste(vapply(s, function(x) sprintf("%s %s", code_span(x), def_cite(x)), ""), collapse = "; ")
}

render_scripts <- function() {
  out <- header("Test Scripts")
  out <- c(out,
    "## General setup (applies to every script)",
    "",
    "1. Obtain a checkout of the repository at the revision under validation and open an R session (R >= 4.1) with the working directory set to the repository root.",
    "2. Install the package dependencies, including `Suggests` (which contains `testthat`): `pak::local_install_deps(dependencies = TRUE)`.",
    "3. When running `testthat::test_file()` directly, first run `Sys.setenv(NOT_CRAN = \"true\")`; otherwise testthat treats the run as a CRAN run and skips `expect_snapshot()` expectations and tests guarded by `skip_on_cran()`. `devtools::test()` sets this automatically.",
    sprintf("4. The commands below load `%s` from source (`load_package = \"source\"`). testthat automatically sources the shared fixtures %s and %s before any test runs.",
            pkg, cite("tests/testthat/helpers.R", 1, length(readLines("tests/testthat/helpers.R"))),
            cite("tests/testthat/setup.R", 1, length(readLines("tests/testthat/setup.R")))),
    "5. To execute the complete suite in one step run `devtools::test()`; to execute every script in one file run `testthat::test_file(\"tests/testthat/test-<stem>.R\", package = \"blockr.core\", load_package = \"source\")`.",
    "6. A script **passes** when the reporter shows `FAIL 0` and `SKIP 0` for it, which means every listed expected result was observed (a skipped expectation is not evidence). Record the reporter output as objective evidence.",
    "",
    "Each script lists, in source order: the actions that set up state (code to run, with its line citation), the expected result in plain language, the exact expectation code with its line citation, and the citation of the package code whose behaviour the expectation verifies. Steps marked _compound_ wrap several expectations inside one action (for example `shiny::testServer()` or `withr::with_*()`); all nested expected results must hold.",
    "",
    "Only test cases linked to a requirement in `traceability-matrix.md` are scripted here; unlinked test cases are listed at the end and flagged in the matrix.",
    "")
  linked_tc <- unique(links$tc)
  for (t in tests[tc_ids %in% linked_tc]) {
    l <- links[links$tc == t$id, ]
    reqs <- unique(l$topic)
    out <- c(out,
      sprintf("## %s — %s", t$id, md_cell(t$desc)), "",
      sprintf("* **Source:** %s", cite(t$file, t$l1, t$l2)),
      sprintf("* **Traces to:** %s", paste(vapply(reqs, function(r) {
        sprintf("%s (`man/%s.Rd`, %s)", req_ids[[r]], r,
                if (any(l$type[l$topic == r] == "direct")) "direct" else "indirect")
      }, ""), collapse = ", ")),
      "* **Run this script:**", "",
      "  ```r", paste0("  ", run_cmd(t)), "  ```", "",
      sprintf("  or the whole file: `devtools::test(filter = \"^%s$\")`", t$stem), "")
    step <- 0L
    pending <- integer()
    flush_actions <- function() {
      if (!length(pending)) return(character())
      a1 <- min(pending)
      a2 <- max(pending)
      c(sprintf("**Action** (%s):", cite(t$file, a1, a2)), "", show_code(t$lines, a1, a2), "")
    }
    for (s in t$stmts) {
      inside <- Filter(function(e) e$l1 >= s$l1 && e$l2 <= s$l2, t$expectations)
      if (!length(inside)) {
        pending <- c(pending, s$l1, s$l2)
        next
      }
      single <- length(inside) == 1L && inside[[1]]$l1 == s$l1 && inside[[1]]$l2 == s$l2
      step <- step + 1L
      if (single) {
        e <- inside[[1]]
        out <- c(out, sprintf("### Step %d", step), "", flush_actions(),
          sprintf("**Expected result:** %s", translate(e, t$stem)), "",
          sprintf("**Expectation** (%s):", cite(t$file, e$l1, e$l2)), "",
          show_code(t$lines, e$l1, e$l2), "",
          sprintf("**Code under test:** %s", code_under_test(t, e)), "")
      } else {
        out <- c(out, sprintf("### Step %d (compound)", step), "", flush_actions(),
          sprintf("**Action** (%s): run the block below; the nested expected results must all hold.", cite(t$file, s$l1, s$l2)), "",
          show_code(t$lines, s$l1, s$l2, max = 20L), "")
        for (k in seq_along(inside)) {
          e <- inside[[k]]
          out <- c(out,
            sprintf("%d.%d. **Expected result:** %s  ", step, k, translate(e, t$stem)),
            sprintf("    Expectation: %s · Code under test: %s", cite(t$file, e$l1, e$l2), code_under_test(t, e)),
            "")
        }
      }
      pending <- integer()
    }
    if (!step) out <- c(out, "_This test contains no `expect_*()` call; it passes if its body runs without error._", "")
  }
  un <- tests[!tc_ids %in% linked_tc]
  out <- c(out, "## Unlinked test cases (not scripted)", "",
    "These test cases did not satisfy any link rule and are flagged in `traceability-matrix.md`. They still run as part of `devtools::test()`.", "",
    if (length(un)) vapply(un, function(t) sprintf("* %s — %s", tc_label(t), cite(t$file, t$l1, t$l2)), "") else "None.",
    "")
  out
}

# ---------------------------------------------------------------------------
# Citation check for hand-written documents
# ---------------------------------------------------------------------------

lock_file <- "validation/citations.lock"
cited_docs <- c("validation/system-description.md", "validation/README.md")

extract_citations <- function(f) {
  if (!file.exists(f)) return(character())
  txt <- paste(readLines(f), collapse = "\n")
  unique(regmatches(txt, gregexpr("(R|tests/testthat|man|\\.github/workflows)/[A-Za-z0-9._/-]+:L[0-9]+-L[0-9]+|NAMESPACE:L[0-9]+(-L[0-9]+)?|DESCRIPTION:L[0-9]+-L[0-9]+", txt))[[1]])
}

resolve_citation <- function(x) {
  path <- sub(":L.*$", "", x)
  rng <- as.integer(strsplit(gsub("L", "", sub("^[^:]*:", "", x)), "-")[[1]])
  if (length(rng) == 1L) rng <- c(rng, rng)
  if (!file.exists(path)) return(list(ok = FALSE, msg = "file does not exist"))
  lns <- readLines(path)
  if (rng[1] < 1L || rng[2] > length(lns) || rng[1] > rng[2]) {
    return(list(ok = FALSE, msg = sprintf("range outside file (%d lines)", length(lns))))
  }
  h <- local({
    tmp <- tempfile()
    writeLines(lns[rng[1]:rng[2]], tmp)
    unname(tools::md5sum(tmp))
  })
  list(ok = TRUE, hash = h)
}

check_citations <- function() {
  cits <- unique(unlist(lapply(cited_docs, extract_citations)))
  lock <- if (file.exists(lock_file)) {
    l <- utils::read.table(lock_file, sep = "\t", header = TRUE, stringsAsFactors = FALSE)
    setNames(l$md5, l$citation)
  } else character()
  probs <- character()
  res <- lapply(cits, resolve_citation)
  for (i in seq_along(cits)) {
    r <- res[[i]]
    if (!r$ok) {
      probs <- c(probs, sprintf("%s: %s", cits[i], r$msg))
    } else if (mode != "lock" && !cits[i] %in% names(lock)) {
      probs <- c(probs, sprintf("%s: not in %s (review the statement, then run --lock)", cits[i], lock_file))
    } else if (mode != "lock" && !identical(lock[[cits[i]]], r$hash)) {
      probs <- c(probs, sprintf("%s: cited lines changed since last review", cits[i]))
    }
  }
  if (mode == "lock") {
    ok <- vapply(res, `[[`, TRUE, "ok")
    utils::write.table(
      data.frame(citation = cits[ok], md5 = vapply(res[ok], `[[`, "", "hash"))[order(cits[ok]), ],
      lock_file, sep = "\t", quote = FALSE, row.names = FALSE
    )
    message(sprintf("Wrote %d citation hashes to %s", sum(ok), lock_file))
  }
  list(n = length(cits), problems = probs)
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

generated <- list(
  "validation/traceability-matrix.md" = render_matrix(),
  "validation/test-scripts.md" = render_scripts()
)

drift <- character()
for (f in names(generated)) {
  new <- generated[[f]]
  if (mode == "check") {
    old <- if (file.exists(f)) readLines(f) else character()
    if (!identical(paste(old, collapse = "\n"), paste(new, collapse = "\n"))) drift <- c(drift, f)
  } else {
    writeLines(new, f)
    message("Wrote ", f)
  }
}

cc <- check_citations()
message(sprintf("Checked %d citations in hand-written documents.", cc$n))

message(sprintf(
  "Requirements: %d (direct %d, indirect-only %d, none %d); test cases: %d (linked %d).",
  length(topic_names), sum(topic_cov == "direct"), sum(topic_cov == "indirect only"),
  sum(topic_cov == "none"), length(tests), length(unique(links$tc))
))

if (length(drift)) message("DRIFT: generated documents are stale: ", paste(drift, collapse = ", "))
if (length(cc$problems)) message("CITATION PROBLEMS:\n  ", paste(cc$problems, collapse = "\n  "))
if (mode == "check" && (length(drift) || length(cc$problems))) quit(status = 1L)
