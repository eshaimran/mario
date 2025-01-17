#' Turn a file that ends with a pipeline into JSON
#'
#' @param path The path to an R code file.
#' @importFrom rlang parse_exprs global_env
#' @importFrom purrr map safely
#' @export
file_to_json <- function(path) {
  con <- file(path, open = "r")
  on.exit(close(con))
  string_to_json(con)
}

#' Turn a pipeline call into JSON
#'
#' @param call A pipeline call, likely from either [parse_pipeline()]
#' or [rlang::parse_expr()].
#' @importFrom jsonlite toJSON
#' @export
pipeline_to_json <- function(call){
  ptbl <- pipeline_tbl(call)
  ptbl$BA <- c(NA, before_after_tbl_list(ptbl$DF))

  (pipeline_tbl_to_list(ptbl)[-1]) %>% toJSON(auto_unbox = TRUE, pretty = TRUE)
}

#' Turn a string of a pipeline into a JSON
#'
#' @param code A string of R code.
#' @importFrom rlang parse_exprs
#' @export
string_to_json <- function(code) {
  result <- safely(string_to_json_helper)(code)

  if(!is.null(result[["error"]])){
    list(list(
      type = "error",
      code_step = "NA",
      mapping = list(
        message = result[["error"]] %>% as.character()
      ),
      data_frame = "NA"
    )) %>% toJSON(auto_unbox = TRUE, pretty = TRUE)
  } else {
    result[["result"]]
  }
}

string_to_json_helper <- function(code) {
  exprs_ <- parse_exprs(code)
  map(exprs_[-length(exprs_)], eval, envir = global_env())
  pipeline_call <- exprs_[[length(exprs_)]]

  pipeline_to_json(pipeline_call)
}

# When you have the mario project open in RStudio, run this with
# mario:::create_jsons()
#' @importFrom purrr map2
create_jsons <- function(code_files = NULL, clobber = FALSE){
  dest_path <- file.path("inst", "test", "correct")
  if(clobber && is.null(code_files)){
    code_files <- list.files(file.path("inst", "test", "code"), full.names = TRUE)
  } else if(!is.null(code_files)) {
    code_files <- file.path("inst", "test", "code", code_files)
  } else {
    code_files <- list.files(file.path("inst", "test", "code"), full.names = TRUE) %>%
      basename() %>%
      tools::file_path_sans_ext()
    json_files <- list.files(file.path("inst", "test", "correct"), full.names = TRUE) %>%
      basename() %>%
      tools::file_path_sans_ext()
    code_files <- setdiff(code_files, json_files)
    stopifnot(length(code_files) > 0)
    code_files <- file.path("inst", "test", "code", code_files) %>%
      paste0(".R")
  }

  file.path(dest_path, basename(code_files)) %>%
    tools::file_path_sans_ext() %>%
    paste0(".json") %>%
    map2(code_files, ~writeLines(file_to_json(.y), .x))
  invisible()
}

#' @importFrom purrr walk2 safely
check_jsons <- function(){
  code_files <- list.files(file.path("inst", "test", "code"), full.names = TRUE)
  json_files <- file.path("inst", "test", "correct",
                          basename(code_files) %>%
                            tools::file_path_sans_ext() %>%
                            paste0(".json"))

  test_results = map2(code_files, json_files, safely(function(code, json){
    temp_file <- tempfile()
    file_to_json(code) %>% writeLines(temp_file)
    pass <- all.equal(readLines(temp_file), readLines(json))
    status <- ifelse(isTRUE(pass), "Passed", "FAILED")
    list(status = status)
  }))

  walk2(code_files, test_results, function(code, tr){
    test_name <- basename(code) %>% tools::file_path_sans_ext()

    if(!is.null(tr$error)){
      message("ERROR : ", test_name)
    } else {
      message(tr$result$status, ": ", test_name)
    }
  })
}


#' @importFrom purrr map2
before_after_tbl_list <- function(tbl_list) {
  stopifnot(length(tbl_list) > 1)
  map2(tbl_list[-length(tbl_list)], tbl_list[-1], ~ list(.x, .y))
}

#' @importFrom purrr pmap safely
pipeline_tbl_to_list <- function(ptbl) {
  pmap(ptbl, handle)
  #result <- pmap(ptbl, safely(handle))
}

handle <- function(Name_Strings, Verb_Strings, DF, Verbs,
                                    Names, Args, Values, BA){
  result <- handle_pipeline_tbl_row(Name_Strings, Verb_Strings, DF, Verbs,
                                    Names, Args, Values, BA)
  if(length(BA) > 1 && is.data.frame(BA[[1]]) && is.data.frame(BA[[2]])){
    result[["data_frame"]] <- list(
      lhs = list(col_names = I(colnames(BA[[1]])),
                 data = BA[[1]]),
      rhs = list(col_names = I(colnames(BA[[2]])),
                 data = BA[[2]])
      )
  }
  result[["code_step"]] <- Verb_Strings
  result[c("type", "code_step", "mapping", "data_frame")]
}

handle_pipeline_tbl_row <- function(Name_Strings, Verb_Strings, DF, Verbs,
                                    Names, Args, Values, BA){
  if("mario-error" %in% class(DF)) {
    handle_error(DF, BA)
  } else if(Name_Strings == "slice"){
    handle_slice(Name_Strings, Verb_Strings, DF, Verbs, Names, Args, Values, BA)
  } else if(Name_Strings == "arrange"){
    handle_arrange(Name_Strings, Verb_Strings, DF, Verbs, Names, Args, Values, BA)
  } else if(Name_Strings == "filter"){
    handle_filter(Name_Strings, Verb_Strings, DF, Verbs, Names, Args, Values, BA)
  } else if(Name_Strings == "select"){
    handle_select(Name_Strings, Verb_Strings, DF, Verbs, Names, Args, Values, BA)
  } else if(Name_Strings == "mutate"){
    handle_mutate(Name_Strings, Verb_Strings, DF, Verbs, Names, Args, Values, BA)
  } else if(Name_Strings == "rename"){
    handle_rename(Name_Strings, Verb_Strings, DF, Verbs, Names, Args, Values, BA)
  } else {
    handle_unknown(Name_Strings, Verb_Strings, DF, Verbs, Names, Args, Values, BA)
  }
}

# mt <- mtcars %>%
#   select(mpg, cyl, hp) %>%
#   group_by(cyl) %>%
#   slice(1:2) %>%
#   ungroup()
#
# mt %>%
#   slice(1:3) %>%
#   parse_pipeline() -> call
#
# mtcars %>%
#   slice(1:10) %>%
#   slice(5:10) %>%
#   slice(c(1, 3)) %>% parse_pipeline() -> call



#
# #Formaldehyde %>% mutate(3, Sum = carb + optden, Two = 2, DSum = Sum * 2) %>% parse_pipeline() -> call
# ptbl <- pipeline_tbl(call)
# ptbl$BA <- c(NA, mario:::before_after_tbl_list(ptbl$DF))
# map2(colnames(ptbl), ptbl %>% slice(3) %>% purrr::flatten(), ~assign(.x, .y, envir = globalenv()))


#' @importFrom dplyr slice
#' @importFrom purrr flatten
#' @importFrom rlang global_env
load_vars <- function(call, where = 2){
  ptbl <- mario::pipeline_tbl(call)
  ptbl$BA <- c(NA, before_after_tbl_list(ptbl$DF))
  map2(colnames(ptbl), ptbl %>% slice(where) %>% purrr::flatten(), ~assign(.x, .y, envir = global_env()))
}

handle_error <- function(DF, BA){
  result <- list(type = "error",
       mapping = list(message = DF[["message"]]))

  if(is.data.frame(BA[[1]])){
    result[["data_frame"]] <- list(
      lhs = list(col_names = I(colnames(BA[[1]])), data = BA[[1]]),
      rhs = list(data = "NA"))
  } else {
    result[["data_frame"]] <- list(
      lhs = list(data = "NA"),
      rhs = list(data = "NA"))
  }
  result
}

#' @importFrom purrr pmap
#' @importFrom rlang parse_expr
#' @importFrom dplyr pull
handle_slice <- function(Name_Strings, Verb_Strings, DF, Verbs,
         Names, Args, Values, BA){
  result <- list(type = "slice")

  old_row_number_index <- paste0("BA[[1]] %>% mutate(row_number()) %>% ", Verb_Strings) %>%
    parse_expr() %>%
    eval() %>%
    pull("row_number()")

  #suppressMessages(tbl_diff <- tibble_diff(BA[[1]], BA[[2]]))
  result[["mapping"]] <- map2(old_row_number_index, seq_along(old_row_number_index),
                              ~ list(illustrate = "outline", select = "row",
                                     from = list(anchor = "lhs", index = .x),
                                     to = list(anchor = "rhs", index = .y)
                                )
                          )
  result
}

#' @importFrom purrr pmap map map_lgl
handle_arrange <- function(Name_Strings, Verb_Strings, DF, Verbs,
                           Names, Args, Values, BA){
  result <- handle_slice(Name_Strings, Verb_Strings, DF, Verbs, Names, Args, Values, BA)
  result[["type"]] <- "arrange"
  colnames_in_call <- map_lgl(colnames(DF), ~grepl(.x, Verb_Strings)) %>% which()
  result[["mapping"]] <- map(colnames_in_call,
       ~list(illustrate = "highlight", select = "column",
             anchor = "lhs", index = .x)) %>%
    c(result[["mapping"]])
  result
}

handle_filter <- function(Name_Strings, Verb_Strings, DF, Verbs,
                           Names, Args, Values, BA){
  result <- handle_arrange(Name_Strings, Verb_Strings, DF, Verbs, Names, Args, Values, BA)
  result[["type"]] <- "filter"
  result
}

#' @importFrom dplyr contains
#' @importFrom purrr discard
handle_select <- function(Name_Strings, Verb_Strings, DF, Verbs,
                          Names, Args, Values, BA){
  result <- list(type = "select")
  suppressMessages(tbl_diff <- tibble_diff(BA[[1]], BA[[2]]))
  result[["mapping"]] <- pmap(tbl_diff$Col_Names_Position %>% select(contains("Position")),
                              ~ list(illustrate = "outline",
                                     select = "column",
                                     from = list(anchor = "lhs", index = .x),
                                     to = list(anchor = "rhs", index = .y)
                                     )) %>%
    discard(~ is.na(.x$to$index))

  result
}

# For debugging
# Formaldehyde %>% mutate(Two = 2, Last = Two + carb + 100) %>% parse_pipeline() -> call
#
# Formaldehyde %>% mutate(Sum = carb + optden) %>% parse_pipeline() -> call
#
# Formaldehyde %>% mutate(Sum = carb + optden, DSum = Sum * 2,
#                         Two = 2, Col = sapply(1:6, function(x){x+1}),  3) %>% parse_pipeline() -> call

# Formaldehyde %>% mutate(3, Sum = carb + optden, Two = 2, DSum = Sum * 2) %>% parse_pipeline() -> call
# ptbl <- pipeline_tbl(call)
# ptbl$BA <- c(NA, mario:::before_after_tbl_list(ptbl$DF))
# map2(colnames(ptbl), ptbl %>% slice(2) %>% purrr::flatten(), ~assign(.x, .y, envir = globalenv()))

#' @importFrom purrr flatten discard
handle_mutate  <- function(Name_Strings, Verb_Strings, DF, Verbs,
                           Names, Args, Values, BA){
  result <- list(type = "mutate")
  before_columns <- colnames(BA[[1]])
  after_columns <- colnames(BA[[2]])
  values <- Values %>%
    as.character() %>%
    strsplit("[^\\w\\d\\._]+", perl = TRUE)
  mutated_columns <- Args %>% as.character()

  # The goal is to map from the sources of data to the new columns
  # There are three sources of data:
  # - from existing columns: mutate(Sum = carb + optden)
  # - from columns created inline in the mutate: mutate(Double = card * 2, Triple = Double * 1.5)
  # - from "raw" values: mutate(Two = 2)

  from_old_columns <- map2(Args, values, function(arg, value){
    list(from = which(before_columns %in% value), to = which(arg == after_columns))
  }) %>%
    discard(~ length(.x$from) < 1) %>%
    map(function(z){
      map2(z$from, rep(z$to, length(z$from)), function(from, to){
        if(from > length(before_columns)){
          from_anchor <- "rhs"
        } else {
          from_anchor <- "lhs"
        }

        list(illustrate = "outline",
             select = "column",
             from = list(anchor = from_anchor, index = from),
             to = list(anchor = "rhs", index = to))
      })
    }) %>%
    flatten()

  from_inline_columns <- intersect(unlist(values), Args) %>%
    discard(~ any(.x == before_columns)) %>%
    map(function(z){
      list(from = which(after_columns == z),
        to = which(Args[map_lgl(values, ~ z %in% .x)] == after_columns))
    }) %>%
    map(function(x){
      if(x$from > length(before_columns)){
        from_anchor <- "rhs"
      } else {
        from_anchor <- "lhs"
      }

      list(illustrate = "outline",
           select = "column",
           from = list(anchor = from_anchor, index = x$from),
           to = list(anchor = "rhs", index = x$to))
    })

  new_col_index <- setdiff(seq_along(after_columns), seq_along(before_columns))#which(after_columns %in% Args)
  from_values_columns <- map_lgl(values, ~ all(!(.x %in% after_columns))) %>%
    which() %>%
    map(function(x){
      list(illustrate = "outline",
           select = "column",
           from = list(anchor = "arg", index = x),
           to = list(anchor = "rhs", index = new_col_index[x]))
    })

  simple_mapping <- c(from_old_columns, from_inline_columns, from_values_columns)

  # from_mapping <- list()
  # to_mapping <- list()
  #
  # for (i in seq_along(simple_mapping)) {
  #   from <- simple_mapping[[i]][["from"]] %>% as.character()
  #   to <- simple_mapping[[i]][["to"]] %>% as.character()
  #
  #   if (is.null(from_mapping[[from]])) {
  #     from_mapping[[from]] <- to
  #   } else {
  #     from_mapping[[from]] <- c(from_mapping[[from]], to)
  #   }
  #
  #   if (is.null(to_mapping[[to]])) {
  #     to_mapping[[to]] <- from
  #   } else {
  #     to_mapping[[to]] <- c(to_mapping[[to]], from)
  #   }
  # }
  #
  # from_mapping <- map2(names(from_mapping),
  #                      unname(from_mapping),
  #                      function(lhs, rhs){
  #                        lhs <- lhs %>% as.numeric()
  #                        rhs <- rhs %>% as.numeric()
  #                        list(illustrate = "outline", select = "column-lhs",
  #                             from = lhs, to = rhs)
  #                      })
  #
  # to_mapping <- map2(names(to_mapping),
  #                      unname(to_mapping),
  #                      function(rhs, lhs){
  #                        lhs <- lhs %>% as.numeric()
  #                        rhs <- rhs %>% as.numeric()
  #                        list(illustrate = "outline", select = "column-rhs",
  #                             from = lhs, to = rhs)
  #                      })

  # to_mapping_endpoints <- to_mapping %>% map_dbl(~ .x$to)
  # for (i in seq_along(from_values_columns)) {
  #   x <- from_values_columns[[i]]
  #   if(x$to %in% to_mapping_endpoints){
  #     index <- which(x$to == to_mapping_endpoints)
  #     to_mapping[[index]][["from_arg"]] <- x$from
  #   } else {
  #     to_mapping <- c(to_mapping, list(list(illustrate = "outline",
  #                                      select = "column-rhs",
  #                                      from_arg = x$from, to = x$to)))
  #   }
  # }
  #
  # result[["mapping"]] <- c(from_mapping, to_mapping)#, from_values_columns)

  to_col_index <- simple_mapping %>% map_dbl(~ .x$to$index)
  raw_cols <- setdiff(new_col_index, to_col_index) %>%
    map(function(x){
      list(illustrate = "outline",
           select = "column",
           from = list(anchor = "arg", index = x - length(before_columns)),
           to = list(anchor = "rhs", index = x))
    })

  result[["mapping"]] <- c(simple_mapping, raw_cols)
  result
}

#' @importFrom purrr map2_lgl
handle_rename  <- function(Name_Strings, Verb_Strings, DF, Verbs,
                           Names, Args, Values, BA){
  result <- list(type = "rename")
  before_columns <- colnames(BA[[1]])
  after_columns <- colnames(BA[[2]])
  changed <- map2_lgl(before_columns, after_columns, ~ .x != .y) %>% which()

  if(any(before_columns %in% Args)){
    no_op <- which(before_columns %in% Args)
    if(!(no_op %in% changed)){
      changed <- c(changed, no_op)
    }
  }

  result[["mapping"]] <- changed %>%
    sort() %>%
    map(~ list(illustrate = "outline", select = "column",
               from = list(anchor = "lhs", index = .x),
               to = list(anchor = "rhs", index = .x)))
  result
}

# df = mtcars %>%
#   group_by(cyl, gear)

#' @importFrom scales hue_pal
#' @importFrom dplyr group_indices group_vars left_join
decorate_groups <- function(df, where = "row"){
  group_id <- df %>% group_indices()
  color_hex_codes <- hue_pal()(max(group_id))
  color_tbl <- tibble(Color = color_hex_codes,
                      Group_Index = 1:length(color_hex_codes))
  row_tbl <- tibble(Row_Index = 1:nrow(df),
         Group_Index = group_id)
  left_join(row_tbl, color_tbl, by = "Group_Index") %>%
    pmap(~ list(illustrate = "highlight", select = where,
                index = ..1, group_id = ..2, color = ..3))
}

# handle_left_grouping <- function(result, df){
#   if(is_grouped_df(df)){
#     result[["mapping"]] <- decorate_groups(BA[[1]], "row-left")
    #   }
# }

# mtcars %>% group_by(cyl) %>% group_by(cyl, gear) %>% parse_pipeline() -> call

# Formaldehyde %>% group_by(carb > 0.5) %>% parse_pipeline() -> call
# ptbl <- pipeline_tbl(call)
# ptbl$BA <- c(NA, mario:::before_after_tbl_list(ptbl$DF))
# map2(colnames(ptbl), ptbl %>% slice(2) %>% purrr::flatten(), ~assign(.x, .y, envir = globalenv()))
#
# result %>% jsonlite::toJSON(pretty = TRUE, auto_unbox = TRUE)

handle_group_by <- function(Name_Strings, Verb_Strings, DF, Verbs,
                           Names, Args, Values, BA){


  result <- list(type = "group_by")
  if(is_grouped_df(BA[[1]])){
    result[["mapping"]] <- decorate_groups(BA[[1]], "row-left")
  }
  result[["mapping"]] <- decorate_groups(BA[[2]], "row-right") %>%
    c(result[["mapping"]])
  result[["mapping"]] <- which(colnames(BA[[2]]) %in% (group_vars(BA[[2]]))) %>%
    map(~ list(illustrate = "outline", select = "column",
              from = .x, to = .x)) %>%
  c(result[["mapping"]])
  result
}

handle_unknown <- function(Name_Strings, Verb_Strings, DF, Verbs,
                           Names, Args, Values, BA){
  list(type = "unknown",
       mapping = "NA",
       data_frame = "NA")
}
