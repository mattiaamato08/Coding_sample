# European Parliament Speeches — Doc2Vec Coding Sample

This repository contains a restricted and reproducible version of a larger NLP pipeline developed to analyse European Parliament speeches.

The original project applies Doc2Vec document embeddings to a corpus covering the 1999–2026 period. This coding sample focuses on speeches delivered in 2025 and reproduces the main post-training stages of the analysis.

## Files

The analysis uses:

- `ep_2025_aligned.csv.gz`
- `ep_2025_embeddings_float64.npy`
- `doc2vec_2025_sample_analysis.R`

The compressed CSV and NumPy files are row-aligned: row `i` of the speech dataset corresponds to row `i` of the embedding matrix. The R script reads the `.csv.gz` file directly; manual extraction is not required. The embeddings are stored as `float64` to ensure compatibility with `RcppCNPy` and contain one 100-dimensional vector for each speech.

The repository uses a reduced 2025 sample from the full 1999–2026 corpus.

## Analysis

The R script performs the following steps:

1. checks the alignment between speeches and document embeddings;
2. computes cosine nearest-neighbour diagnostics;
3. evaluates local semantic coherence using NPMI;
4. constructs a cosine k-nearest-neighbour graph;
5. applies Leiden community detection;
6. identifies the most representative TF-IDF terms for each cluster;
7. selects speeches closest to each cluster centroid.

## Required columns

The speech dataset must contain:

- `text_preprocessed_bigrams`

The following columns are used when available:

- `translatedText`
- `text`
- `speaker`
- `date`
- `agenda`
- `party`
- `political_group`
- `period`
- `legislature`
- `speechnumber`
- `original_doc_index`

## Running the analysis

Place the CSV, NumPy matrix, and R script in the same folder. Then run:

```r
source("doc2vec_2025_sample_analysis.R")
```

The script installs any missing CRAN packages and writes the results to:

```text
doc2vec_2025_outputs/
├── 01_validation/
├── 02_clustering/
├── 03_interpretation/
└── doc2vec_2025_analysis_results.xlsx
```

## Outputs

### `01_validation/`

- `nearest_neighbour_cosine_summary.csv` reports the mean, median, standard deviation and selected quantiles of cosine similarity across each speech's 20 nearest neighbours. Higher values indicate that nearby Doc2Vec vectors represent more semantically similar speeches.
- `nearest_neighbour_cosine_by_speech.csv` reports the mean, median, minimum and maximum neighbour similarity separately for every speech. It can be used to identify speeches located in especially coherent or isolated areas of the embedding space.
- `local_npmi_summary.csv` summarises lexical coherence for a reproducible sample of up to 2,000 semantic neighbourhoods. For each target speech, the script selects the highest-TF-IDF terms from the target and its nearest neighbours and evaluates their corpus-level co-occurrence using normalized pointwise mutual information (NPMI). Scores range from `-1` to `1`: higher values indicate stronger-than-random co-occurrence and therefore greater lexical coherence.
- `local_npmi_by_speech.csv` contains the individual NPMI score and document index for each sampled target speech.

### `02_clustering/`

- `cluster_assignments.csv` maps every speech to a zero-based Leiden cluster label.
- `cluster_sizes.csv` reports the number and share of speeches assigned to each cluster.
- `clustering_summary.csv` records the principal graph and clustering diagnostics, including the number of nodes and edges, embedding dimension, neighbourhood size, Leiden settings, number of clusters and modularity. Modularity measures how strongly the graph is partitioned into internally connected communities, although it should mainly be compared across runs built from the same graph specification.
- `knn_graph.rds` stores the weighted, undirected cosine k-nearest-neighbour graph as an R object. Nodes represent speeches; edges connect semantic neighbours; edge weights are non-negative cosine similarities.

### `03_interpretation/`

- `cluster_interpretation.csv` reports cluster size, corpus share and the 20 terms with the highest mean TF-IDF weight within each cluster. These terms provide descriptive labels rather than supervised topic assignments.
- `representative_speeches.csv` reports up to five speeches per cluster that are closest to the cluster's normalized embedding centroid. It includes their centroid cosine similarity, available metadata and readable speech text.

### Consolidated workbook

`doc2vec_2025_analysis_results.xlsx` collects the main validation, clustering and interpretation tables in separate worksheets for convenient inspection. Large intermediate objects, the complete graph and per-speech cluster assignments remain in their corresponding CSV/RDS files. The generated output directory is ignored by Git and is not written back to the repository automatically.
