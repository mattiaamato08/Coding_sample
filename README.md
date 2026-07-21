# European Parliament Speeches — Doc2Vec Coding Sample

This repository contains a restricted and reproducible version of a larger NLP pipeline developed to analyse European Parliament speeches.

The original project applies Doc2Vec document embeddings to a corpus covering the 1999–2026 period. This coding sample focuses on speeches delivered in 2025 and reproduces the main post-training stages of the analysis.

The aim is to identify recurring topics in parliamentary debate without assigning predefined labels to the speeches. Speeches that discuss similar issues should have similar Doc2Vec representations; the analysis connects these nearby speeches, groups them into communities and then uses their most distinctive words and representative texts to understand what each group is about.

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

- `nearest_neighbour_cosine_summary.csv` summarises cosine similarity between speeches and their 20 nearest neighbours. Higher values mean that nearby speeches are more similar in meaning.
- `nearest_neighbour_cosine_by_speech.csv` provides the same diagnostics for each individual speech, making it easier to identify very coherent or relatively isolated observations.
- `local_npmi_summary.csv` summarises the lexical coherence of up to 2,000 sampled neighbourhoods. NPMI checks whether their most important words tend to occur together; higher scores indicate more coherent content.
- `local_npmi_by_speech.csv` reports the NPMI score for each sampled speech neighbourhood.

### `02_clustering/`

- `cluster_assignments.csv` assigns each speech to a Leiden cluster.
- `cluster_sizes.csv` reports how many speeches belong to each cluster and their share of the sample.
- `clustering_summary.csv` contains the main settings and diagnostics, including the number of clusters and modularity. Higher modularity generally indicates more clearly separated communities.
- `knn_graph.rds` stores the semantic-neighbour graph used for clustering: speeches are nodes and similar speeches are connected by weighted edges.

### `03_interpretation/`

- `cluster_interpretation.csv` reports cluster size and the 20 most distinctive TF-IDF terms, which help describe the topic represented by each cluster.
- `representative_speeches.csv` contains up to five speeches closest to each cluster centre, together with their metadata and text. These examples support the qualitative interpretation of the clusters.

### Consolidated workbook

`doc2vec_2025_analysis_results.xlsx` collects the main validation, clustering and interpretation tables in separate worksheets for convenient inspection. The complete graph and other detailed results remain in their corresponding CSV/RDS files.
