# European Parliament Speeches — Doc2Vec Coding Sample

This repository contains a restricted and reproducible version of a larger NLP pipeline developed to analyse European Parliament speeches.

The original project applies Doc2Vec document embeddings to a corpus covering the 1999–2026 period. This coding sample focuses on speeches delivered in 2025 and reproduces the main post-training stages of the analysis.

## Files

The analysis uses:

- `ep_2025_aligned.csv.gz`
- `ep_2025_embeddings.npy`
- `doc2vec_2025_sample_analysis.R`

The compressed CSV and NumPy files are row-aligned: row `i` of the speech dataset corresponds to row `i` of the embedding matrix. The R script reads the `.csv.gz` file directly; manual extraction is not required.

The repository uses reduced 2025 samples. The speech data are gzip-compressed so that both inputs remain below GitHub's 25 MB browser-upload limit and can be stored without Git Large File Storage (Git LFS).

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

The main outputs include:

- nearest-neighbour cosine summaries;
- local NPMI statistics;
- Leiden cluster assignments;
- cluster-size diagnostics;
- TF-IDF cluster labels;
- representative speeches for each cluster;
- a consolidated Excel workbook.
