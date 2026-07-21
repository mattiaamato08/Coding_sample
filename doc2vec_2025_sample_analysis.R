# ============================================================
# EUROPEAN PARLIAMENT SPEECHES — 2025 DOC2VEC SAMPLE ANALYSIS
# ============================================================
# Required inputs in the working directory:
#   - ep_2025_aligned.csv.gz
#   - ep_2025_embeddings.npy
#
# The CSV and embedding matrix must have the same row order.
# The script performs:
#   1. alignment checks;
#   2. nearest-neighbour cosine diagnostics;
#   3. local NPMI coherence;
#   4. cosine kNN graph construction;
#   5. Leiden community detection;
#   6. TF-IDF cluster interpretation;
#   7. selection of representative speeches.
# ============================================================

# ------------------------------------------------------------
# 0. Packages
# ------------------------------------------------------------

required_packages <- c(
  "data.table", "RcppCNPy", "RcppHNSW", "text2vec",
  "Matrix", "igraph", "writexl", "R.utils"
)

missing_packages <- required_packages[
  !vapply(required_packages, requireNamespace, logical(1), quietly = TRUE)
]

if (length(missing_packages) > 0L) {
  install.packages(missing_packages)
}

library(data.table)
library(RcppCNPy)
library(RcppHNSW)
library(text2vec)
library(Matrix)
library(igraph)
library(writexl)

# ------------------------------------------------------------
# 1. Configuration
# ------------------------------------------------------------

DATA_PATH <- "ep_2025_aligned.csv.gz"
EMBEDDINGS_PATH <- "ep_2025_embeddings_float64.npy"

OUTPUT_DIR <- "doc2vec_2025_outputs"
VALIDATION_DIR <- file.path(OUTPUT_DIR, "01_validation")
CLUSTER_DIR <- file.path(OUTPUT_DIR, "02_clustering")
INTERPRETATION_DIR <- file.path(OUTPUT_DIR, "03_interpretation")

dir.create(VALIDATION_DIR, recursive = TRUE, showWarnings = FALSE)
dir.create(CLUSTER_DIR, recursive = TRUE, showWarnings = FALSE)
dir.create(INTERPRETATION_DIR, recursive = TRUE, showWarnings = FALSE)

TEXT_COL <- "text_preprocessed_bigrams"
DISPLAY_TEXT_CANDIDATES <- c("translatedText", "text", TEXT_COL)
META_COLS <- c(
  "speaker", "date", "agenda", "party", "political_group",
  "period", "legislature", "speechnumber"
)

RANDOM_SEED <- 123L

# Validation settings
K_VALIDATION <- 20L
NPMI_SAMPLE_SIZE <- 2000L
TOP_WORDS_NPMI <- 15L
MIN_DOC_FREQUENCY <- 5L
MAX_DOC_PROPORTION <- 0.90

# Graph and Leiden settings
K_GRAPH <- 10L
LEIDEN_RESOLUTION <- 1.0
LEIDEN_ITERATIONS <- 2L

# Approximate nearest-neighbour settings
HNSW_M <- 16L
HNSW_EF_CONSTRUCTION <- 200L
HNSW_EF_SEARCH <- 200L

# Interpretation settings
TOP_WORDS_CLUSTER <- 20L
N_REPRESENTATIVE_DOCS <- 5L

set.seed(RANDOM_SEED)

# ------------------------------------------------------------
# 2. Helper functions
# ------------------------------------------------------------

log_message <- function(...) {
  message(sprintf("[%s] ", format(Sys.time(), "%H:%M:%S")), paste0(...))
}

load_numpy_matrix <- function(path, expected_rows) {
  x <- npyLoad(path, type = "numeric")

  if (!is.matrix(x)) {
    stop("The embeddings file is not a two-dimensional numeric matrix.")
  }

  if (nrow(x) == expected_rows) {
    return(x)
  }

  if (ncol(x) == expected_rows) {
    log_message("Transposing the embedding matrix after NumPy import.")
    return(t(x))
  }

  stop(
    "The embedding matrix cannot be aligned with the CSV.\n",
    "CSV rows: ", expected_rows, "\n",
    "Loaded embedding dimensions: ", paste(dim(x), collapse = " x ")
  )
}

row_normalise <- function(x) {
  norms <- sqrt(rowSums(x^2))
  norms[norms == 0] <- 1
  x / norms
}

remove_self_neighbours <- function(indices, distances, k) {
  n <- nrow(indices)
  clean_indices <- matrix(NA_integer_, nrow = n, ncol = k)
  clean_cosines <- matrix(NA_real_, nrow = n, ncol = k)

  for (i in seq_len(n)) {
    keep <- !is.na(indices[i, ]) & indices[i, ] != i
    idx_i <- indices[i, keep]
    dist_i <- distances[i, keep]
    n_take <- min(k, length(idx_i))

    if (n_take > 0L) {
      clean_indices[i, seq_len(n_take)] <- idx_i[seq_len(n_take)]
      clean_cosines[i, seq_len(n_take)] <- 1 - dist_i[seq_len(n_take)]
    }
  }

  list(indices = clean_indices, cosines = clean_cosines)
}

safe_quantile <- function(x, p) {
  unname(quantile(x, probs = p, na.rm = TRUE, names = FALSE))
}

clean_display_text <- function(x) {
  x <- as.character(x)
  x[is.na(x)] <- ""
  x <- gsub("[\r\n]+", " ", x)
  trimws(gsub("\\s+", " ", x))
}

build_metadata <- function(data, row_number, columns) {
  available_columns <- intersect(columns, names(data))

  values <- vapply(
    available_columns,
    function(column) {
      value <- as.character(data[[column]][row_number])
      if (is.na(value) || !nzchar(trimws(value))) return("")
      paste0(column, ": ", value)
    },
    character(1)
  )

  paste(values[nzchar(values)], collapse = " | ")
}

# ------------------------------------------------------------
# 3. Load inputs and verify alignment
# ------------------------------------------------------------

log_message("Loading the 2025 speech sample.")

speeches <- fread(DATA_PATH, encoding = "UTF-8", showProgress = TRUE)

if (!(TEXT_COL %in% names(speeches))) {
  stop("The CSV does not contain the required column: ", TEXT_COL)
}

if (nrow(speeches) < 3L) {
  stop("The sample contains too few speeches for the analysis.")
}

speeches[, (TEXT_COL) := fifelse(
  is.na(get(TEXT_COL)), "", as.character(get(TEXT_COL))
)]

display_text_col <- DISPLAY_TEXT_CANDIDATES[
  DISPLAY_TEXT_CANDIDATES %in% names(speeches)
][1]

if (is.na(display_text_col)) {
  stop("No suitable column is available for displaying speech text.")
}

log_message("Loading the aligned Doc2Vec embeddings.")

embeddings <- load_numpy_matrix(
  path = EMBEDDINGS_PATH,
  expected_rows = nrow(speeches)
)

storage.mode(embeddings) <- "double"

if (any(!is.finite(embeddings))) {
  stop("The embedding matrix contains NA, NaN or infinite values.")
}

if (nrow(embeddings) != nrow(speeches)) {
  stop("The CSV and embedding matrix have different row counts.")
}

if (!("sample_doc_index" %in% names(speeches))) {
  speeches[, sample_doc_index := .I - 1L]
}

log_message(
  "Alignment confirmed: ", format(nrow(speeches), big.mark = ","),
  " speeches and ", ncol(embeddings), "-dimensional embeddings."
)

# ------------------------------------------------------------
# 4. Cosine nearest-neighbour diagnostics
# ------------------------------------------------------------

log_message("Computing cosine nearest neighbours.")

k_max <- min(max(K_VALIDATION, K_GRAPH) + 1L, nrow(embeddings))

nearest_neighbours <- hnsw_knn(
  X = embeddings,
  k = k_max,
  distance = "cosine",
  M = HNSW_M,
  ef_construction = min(HNSW_EF_CONSTRUCTION, nrow(embeddings)),
  ef = min(max(HNSW_EF_SEARCH, k_max), nrow(embeddings)),
  verbose = TRUE,
  n_threads = 1,
  byrow = TRUE
)

validation_neighbours <- remove_self_neighbours(
  indices = nearest_neighbours$idx,
  distances = nearest_neighbours$dist,
  k = min(K_VALIDATION, nrow(embeddings) - 1L)
)

cosine_values <- as.vector(validation_neighbours$cosines)
cosine_values <- cosine_values[is.finite(cosine_values)]

cosine_summary <- data.table(
  statistic = c("mean", "median", "standard_deviation", "p05", "p25", "p75", "p95"),
  value = c(
    mean(cosine_values), median(cosine_values), sd(cosine_values),
    safe_quantile(cosine_values, 0.05),
    safe_quantile(cosine_values, 0.25),
    safe_quantile(cosine_values, 0.75),
    safe_quantile(cosine_values, 0.95)
  )
)

fwrite(
  cosine_summary,
  file.path(VALIDATION_DIR, "nearest_neighbour_cosine_summary.csv")
)

speech_cosine_summary <- data.table(
  sample_doc_index = speeches$sample_doc_index,
  mean_topk_cosine = rowMeans(validation_neighbours$cosines, na.rm = TRUE),
  median_topk_cosine = apply(validation_neighbours$cosines, 1L, median, na.rm = TRUE),
  minimum_topk_cosine = apply(validation_neighbours$cosines, 1L, min, na.rm = TRUE),
  maximum_topk_cosine = apply(validation_neighbours$cosines, 1L, max, na.rm = TRUE)
)

fwrite(
  speech_cosine_summary,
  file.path(VALIDATION_DIR, "nearest_neighbour_cosine_by_speech.csv")
)

# ------------------------------------------------------------
# 5. Sparse lexical matrices for NPMI and interpretation
# ------------------------------------------------------------

log_message("Building sparse lexical matrices.")

speech_texts <- speeches[[TEXT_COL]]

iterator_vocab <- itoken(
  speech_texts,
  tokenizer = word_tokenizer,
  progressbar = FALSE
)

vocabulary <- create_vocabulary(iterator_vocab, ngram = c(1L, 1L))

vocabulary <- prune_vocabulary(
  vocabulary,
  term_count_min = MIN_DOC_FREQUENCY,
  doc_proportion_max = MAX_DOC_PROPORTION
)

if (nrow(vocabulary) < 2L) {
  stop("The filtered vocabulary is too small. Reduce MIN_DOC_FREQUENCY.")
}

vectorizer <- vocab_vectorizer(vocabulary)

iterator_count <- itoken(
  speech_texts,
  tokenizer = word_tokenizer,
  progressbar = FALSE
)

document_term_count <- create_dtm(iterator_count, vectorizer)

document_term_binary <- document_term_count
document_term_binary@x[] <- 1

tfidf_transformer <- TfIdf$new(norm = "none", sublinear_tf = FALSE)
document_term_tfidf <- fit_transform(document_term_count, tfidf_transformer)

term_document_frequency <- Matrix::colSums(document_term_binary)
n_documents <- nrow(document_term_binary)

# ------------------------------------------------------------
# 6. Local NPMI coherence
# ------------------------------------------------------------

npmi_pair <- function(term_i, term_j) {
  frequency_i <- term_document_frequency[term_i]
  frequency_j <- term_document_frequency[term_j]

  if (frequency_i == 0 || frequency_j == 0) return(NA_real_)

  cooccurrence <- sum(
    document_term_binary[, term_i, drop = FALSE] *
      document_term_binary[, term_j, drop = FALSE]
  )

  if (cooccurrence == 0) return(-1)

  p_i <- frequency_i / n_documents
  p_j <- frequency_j / n_documents
  p_ij <- cooccurrence / n_documents

  pmi <- log(p_ij / (p_i * p_j))
  pmi / (-log(p_ij))
}

neighbourhood_npmi <- function(target_row, neighbour_rows, top_words) {
  neighbour_rows <- neighbour_rows[is.finite(neighbour_rows)]
  local_rows <- unique(c(target_row, neighbour_rows))

  local_tfidf <- Matrix::colSums(
    document_term_tfidf[local_rows, , drop = FALSE]
  )

  positive_terms <- which(local_tfidf > 0)
  if (length(positive_terms) < 2L) return(NA_real_)

  ranked_terms <- positive_terms[
    order(local_tfidf[positive_terms], decreasing = TRUE)
  ]

  top_term_ids <- head(ranked_terms, top_words)
  if (length(top_term_ids) < 2L) return(NA_real_)

  term_pairs <- combn(top_term_ids, 2L)
  pair_scores <- apply(
    term_pairs,
    2L,
    function(pair) npmi_pair(pair[1], pair[2])
  )

  if (all(is.na(pair_scores))) return(NA_real_)
  mean(pair_scores, na.rm = TRUE)
}

npmi_sample_size <- min(NPMI_SAMPLE_SIZE, nrow(speeches))
npmi_target_rows <- sort(sample(
  seq_len(nrow(speeches)),
  size = npmi_sample_size,
  replace = FALSE
))

log_message(
  "Computing local NPMI for ",
  format(npmi_sample_size, big.mark = ","),
  " sampled neighbourhoods. This passage can take 20 minutes, more or less"
)

npmi_scores <- vapply(
  npmi_target_rows,
  function(target_row) {
    neighbourhood_npmi(
      target_row = target_row,
      neighbour_rows = validation_neighbours$indices[target_row, ],
      top_words = TOP_WORDS_NPMI
    )
  },
  numeric(1)
)

npmi_summary <- data.table(
  statistic = c("mean", "median", "standard_deviation", "p25", "p75", "valid_neighbourhoods"),
  value = c(
    mean(npmi_scores, na.rm = TRUE),
    median(npmi_scores, na.rm = TRUE),
    sd(npmi_scores, na.rm = TRUE),
    safe_quantile(npmi_scores, 0.25),
    safe_quantile(npmi_scores, 0.75),
    sum(is.finite(npmi_scores))
  )
)

fwrite(npmi_summary, file.path(VALIDATION_DIR, "local_npmi_summary.csv"))

fwrite(
  data.table(
    sample_doc_index = speeches$sample_doc_index[npmi_target_rows],
    local_npmi = npmi_scores
  ),
  file.path(VALIDATION_DIR, "local_npmi_by_speech.csv")
)

# ------------------------------------------------------------
# 7. Weighted undirected kNN graph
# ------------------------------------------------------------

log_message("Building the weighted kNN graph.")

graph_k <- min(K_GRAPH, nrow(embeddings) - 1L)

graph_neighbours <- remove_self_neighbours(
  indices = nearest_neighbours$idx,
  distances = nearest_neighbours$dist,
  k = graph_k
)

edge_list <- vector("list", nrow(embeddings))

for (i in seq_len(nrow(embeddings))) {
  neighbours_i <- graph_neighbours$indices[i, ]
  similarities_i <- graph_neighbours$cosines[i, ]
  valid <- is.finite(neighbours_i) & is.finite(similarities_i)

  neighbours_i <- neighbours_i[valid]
  similarities_i <- similarities_i[valid]

  edge_list[[i]] <- data.table(
    from = pmin(i, neighbours_i),
    to = pmax(i, neighbours_i),
    weight = pmax(similarities_i, 0)
  )
}

edges <- rbindlist(edge_list, use.names = TRUE)
edges <- edges[from != to & weight > 0]
edges <- edges[, .(weight = max(weight)), by = .(from, to)]

vertices <- data.frame(name = as.character(seq_len(nrow(embeddings))))

graph <- graph_from_data_frame(
  d = data.frame(
    from = as.character(edges$from),
    to = as.character(edges$to),
    weight = edges$weight
  ),
  directed = FALSE,
  vertices = vertices
)

E(graph)$weight <- edges$weight

# ------------------------------------------------------------
# 8. Leiden community detection
# ------------------------------------------------------------

log_message("Running Leiden community detection.")
set.seed(RANDOM_SEED)

leiden_partition <- cluster_leiden(
  graph = graph,
  objective_function = "modularity",
  weights = E(graph)$weight,
  resolution = LEIDEN_RESOLUTION,
  n_iterations = LEIDEN_ITERATIONS
)

cluster_membership <- membership(leiden_partition)
cluster_labels <- as.integer(cluster_membership) - 1L

cluster_assignments <- data.table(
  sample_doc_index = speeches$sample_doc_index,
  cluster = cluster_labels
)

fwrite(cluster_assignments, file.path(CLUSTER_DIR, "cluster_assignments.csv"))

cluster_sizes <- cluster_assignments[
  , .(n_docs = .N), by = cluster
][order(-n_docs, cluster)]
cluster_sizes[, share := n_docs / sum(n_docs)]

clustering_summary <- data.table(
  n_documents = nrow(speeches),
  embedding_dimension = ncol(embeddings),
  k_graph = graph_k,
  n_edges = ecount(graph),
  leiden_resolution = LEIDEN_RESOLUTION,
  leiden_iterations = LEIDEN_ITERATIONS,
  n_clusters = nrow(cluster_sizes),
  largest_cluster_size = max(cluster_sizes$n_docs),
  largest_cluster_share = max(cluster_sizes$share),
  median_cluster_size = median(cluster_sizes$n_docs),
  mean_cluster_size = mean(cluster_sizes$n_docs),
  minimum_cluster_size = min(cluster_sizes$n_docs),
  modularity = modularity(
    graph,
    cluster_membership,
    weights = E(graph)$weight
  )
)

fwrite(cluster_sizes, file.path(CLUSTER_DIR, "cluster_sizes.csv"))
fwrite(clustering_summary, file.path(CLUSTER_DIR, "clustering_summary.csv"))
saveRDS(graph, file.path(CLUSTER_DIR, "knn_graph.rds"))

# ------------------------------------------------------------
# 9. Cluster interpretation
# ------------------------------------------------------------

log_message("Interpreting Leiden clusters.")

embeddings_normalised <- row_normalise(embeddings)
speeches[, cluster := cluster_labels]

cluster_ids <- sort(unique(cluster_labels))
cluster_summary_rows <- vector("list", length(cluster_ids))
representative_rows <- list()
representative_counter <- 1L
feature_names <- colnames(document_term_tfidf)

for (cluster_position in seq_along(cluster_ids)) {
  cluster_id <- cluster_ids[cluster_position]
  document_rows <- which(cluster_labels == cluster_id)

  log_message(
    "Cluster ", cluster_id, " (", cluster_position, "/", length(cluster_ids),
    "): ", format(length(document_rows), big.mark = ","), " speeches."
  )

  mean_tfidf <- Matrix::colMeans(
    document_term_tfidf[document_rows, , drop = FALSE]
  )

  positive_terms <- which(mean_tfidf > 0)
  ranked_terms <- positive_terms[
    order(mean_tfidf[positive_terms], decreasing = TRUE)
  ]
  selected_term_ids <- head(ranked_terms, TOP_WORDS_CLUSTER)
  selected_terms <- feature_names[selected_term_ids]

  cluster_vectors <- embeddings_normalised[document_rows, , drop = FALSE]
  centroid <- colMeans(cluster_vectors)
  centroid_norm <- sqrt(sum(centroid^2))
  if (centroid_norm > 0) centroid <- centroid / centroid_norm

  centroid_cosines <- as.vector(cluster_vectors %*% centroid)
  n_representatives <- min(N_REPRESENTATIVE_DOCS, length(document_rows))
  representative_local_rows <- head(
    order(centroid_cosines, decreasing = TRUE),
    n_representatives
  )
  representative_document_rows <- document_rows[representative_local_rows]

  cluster_summary_rows[[cluster_position]] <- data.table(
    cluster = cluster_id,
    n_docs = length(document_rows),
    share = length(document_rows) / nrow(speeches),
    top_tfidf_words = paste(selected_terms, collapse = ", ")
  )

  for (representative_rank in seq_along(representative_document_rows)) {
    source_row <- representative_document_rows[representative_rank]

    representative_rows[[representative_counter]] <- data.table(
      cluster = cluster_id,
      rank = representative_rank,
      sample_doc_index = speeches$sample_doc_index[source_row],
      original_doc_index = if ("original_doc_index" %in% names(speeches)) {
        speeches$original_doc_index[source_row]
      } else {
        NA_integer_
      },
      centroid_cosine = centroid_cosines[
        representative_local_rows[representative_rank]
      ],
      metadata = build_metadata(speeches, source_row, META_COLS),
      representative_text = clean_display_text(
        speeches[[display_text_col]][source_row]
      )
    )

    representative_counter <- representative_counter + 1L
  }
}

cluster_interpretation <- rbindlist(cluster_summary_rows, use.names = TRUE)
representative_speeches <- rbindlist(
  representative_rows,
  use.names = TRUE,
  fill = TRUE
)

setorder(cluster_interpretation, -n_docs, cluster)
setorder(representative_speeches, cluster, rank)

fwrite(
  cluster_interpretation,
  file.path(INTERPRETATION_DIR, "cluster_interpretation.csv"),
  bom = TRUE
)

fwrite(
  representative_speeches,
  file.path(INTERPRETATION_DIR, "representative_speeches.csv"),
  bom = TRUE
)

write_xlsx(
  list(
    validation_cosine = as.data.frame(cosine_summary),
    validation_npmi = as.data.frame(npmi_summary),
    clustering_summary = as.data.frame(clustering_summary),
    cluster_sizes = as.data.frame(cluster_sizes),
    cluster_interpretation = as.data.frame(cluster_interpretation),
    representative_speeches = as.data.frame(representative_speeches)
  ),
  path = file.path(OUTPUT_DIR, "doc2vec_2025_analysis_results.xlsx")
)

# ------------------------------------------------------------
# 10. Final summary
# ------------------------------------------------------------

log_message("Analysis completed successfully.")

cat("\n")
cat("============================================================\n")
cat("DOC2VEC 2025 SAMPLE — FINAL SUMMARY\n")
cat("============================================================\n")
cat("Speeches:              ", format(nrow(speeches), big.mark = ","), "\n", sep = "")
cat("Embedding dimension:   ", ncol(embeddings), "\n", sep = "")
cat("Graph edges:           ", format(ecount(graph), big.mark = ","), "\n", sep = "")
cat("Leiden clusters:       ", nrow(cluster_sizes), "\n", sep = "")
cat("Mean neighbour cosine: ", sprintf("%.4f", mean(cosine_values)), "\n", sep = "")
cat("Mean local NPMI:       ", sprintf("%.4f", mean(npmi_scores, na.rm = TRUE)), "\n", sep = "")
cat("Output folder:         ", OUTPUT_DIR, "\n", sep = "")
cat("============================================================\n")
