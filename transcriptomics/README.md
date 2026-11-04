# Transcriptomics

RNA-seq module for KIMN20: the hands-on lab, the assignment, and the
reference material that goes with them.

## Lab material

| File | What it is |
| --- | --- |
| `labs/lab_RNAseq.html` | The guided lab: the full RNA-seq pipeline, step by step |
| `labs/RNAseq_Assignment.html` | The assignment questions students hand in |
| `labs/FastQC_Manual.pdf` | FastQC manual (16 pages), kept for offline use during the lab |
| `labs/FastQC_TutorialAndFAQ.pdf` | FastQC tutorial and FAQ (8 pages) |

Open the `.html` files in any browser; nothing needs to be rendered.

## The pipeline the lab follows

```
FastQC  ->  HISAT2  ->  featureCounts  ->  MultiQC  ->  DESeq2
  QC         align        count            report       differential
                                                        expression
```

Bonus exercises cover installing R packages, functional annotation, and
RNA-seq plots.

## What the assignment asks about

- **Reads** — single-end vs paired-end
- **Quality control** — Phred scores, sequence duplication levels, what
  MultiQC adds on top of FastQC
- **Mapping** — why an aligner index is built, spliced alignment, SAM vs
  BAM, why genome build versions must not be mixed
- **Differential expression** — the goal of the analysis, the biological
  questions it answers, raw vs adjusted p-values

## FastQC resources

The two PDFs in `labs/` are local copies, kept so the lab works without
a network connection. They came from:

- `FastQC_Manual.pdf` —
  <https://mugenomicscore.missouri.edu/PDF/FastQC_Manual.pdf>
- `FastQC_TutorialAndFAQ.pdf` —
  <https://rtsf.natsci.msu.edu/sites/_rtsf/assets/File/FastQC_TutorialAndFAQ_080717.pdf>
  (this host sits behind bot protection: a direct download returns an
  HTML challenge page, so open it in a browser)

Both are third-party copies. FastQC itself is maintained at the Babraham
Institute, which is where to look for the current documentation:
<https://www.bioinformatics.babraham.ac.uk/projects/fastqc/Help/>

## Lecture deck

Not in the repository yet. When it is added it will follow the same
conventions as the decks in `basic_linux_r/`: a Quarto `.qmd` source
rendered to a self-contained reveal.js `.html`, reusing the shared
`custom.css` and the LTH logo.

## Project structure

```
transcriptomics/
├── README.md                     # This file
└── labs/
    ├── lab_RNAseq.html           # Guided lab
    ├── RNAseq_Assignment.html    # Assignment questions
    ├── FastQC_Manual.pdf         # Reference: FastQC manual
    └── FastQC_TutorialAndFAQ.pdf # Reference: FastQC tutorial and FAQ
```

## Course archives

Previous editions are preserved as git tags; see the
[top-level README](../README.md). Note that the 2025 transcriptomics
material predates the tagging convention and is not in the repository.
