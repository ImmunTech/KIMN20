# RNA-seq Lab — Pre-course Validation

Run this check on the bioinformatics server **before each annual KIMN20 RNA-seq lab** to confirm that the software environment, input data and complete analysis pipeline still work.

## 0. Get the files

If you don't already have the validator on the server, get the two required files. They must sit in the same directory, because the script looks for `environment.yml` next to itself.

Simplest — clone the repo (or run `git pull` if you already have it):

```bash
git clone https://github.com/ImmunTech/KIMN20.git
cd KIMN20/transcriptomics/validation
```

Or download both files into any directory of your choice (e.g. `~/validation/`):

```bash
mkdir -p ~/validation
cd ~/validation
curl -fO https://raw.githubusercontent.com/ImmunTech/KIMN20/main/transcriptomics/validation/validate_lab.sh
curl -fO https://raw.githubusercontent.com/ImmunTech/KIMN20/main/transcriptomics/validation/environment.yml
```

Then continue with §1.

## 1. Run the validation

It can be launched from any working directory, because it resolves `environment.yml` relative to its own script location:

```bash
bash validate_lab.sh
echo "Exit code: $?"
```

The script automatically:

- Checks Conda and Mamba (installs Mamba in Conda `base` if missing).
- Creates a fresh temporary environment using `environment.yml`.
- Runs the complete RNA-seq pipeline and 46 validation checks.
- Saves results and software versions.
- Removes the temporary environment when finished.

**Counting:** featureCounts is run with `-p --countReadPairs`, counting paired-end fragments explicitly — the same command as the 2026 lab. Fragment counts are about half of read-level counts, but all downstream checks (assignment rate, sample matching, correlations, DE, PCA) are independent of the counting unit, so their thresholds are unchanged.

**GO dot plot:** the lab's optional GO enrichment dot plot (the 12 most significant up-regulated GO terms in `funannot/go_up.txt`) is reproduced with the lab's own R script and validated as a **mandatory** check — a broken optional step would still block students who follow it. Two checks run: the script executes and produces a non-empty 1800×1080 `go_up_top_terms.png`, and the data behind it is sane (≥ 12 terms with BH-adjusted p < 0.05, a muscle term on top, ontologies only BP/CC/MF). With `SKIP_ANNOT=1` it is skipped together with the rest of the functional annotation.

**Note:** Installing Mamba into `base` modifies that environment. On `bioinf-serv2`, Mamba was installed manually with `conda install mamba -c conda-forge -y` and was subsequently used by the validator in two complete runs; only the validator's automatic Mamba installation branch remains untested.

## 2. Check the result

Expected output:

```text
PASS: 46   WARN: 0   FAIL: 0   SKIP: 0
LAB OK: all result checks passed.
Validator exit code: 0
```

The complete results are saved under:

```text
~/rnaseq_validation_<timestamp>/
├── REPORT.txt        # Summary of all 46 checks
├── logs/             # Individual pipeline logs
├── evidence/         # Software versions and Conda environment details
└── rnaseq/           # Generated laboratory outputs
```

If any check fails, open `REPORT.txt` and inspect the relevant file in `logs/` or `evidence/`. Resolve the problem before the course.

## 3. Optional: keep the environment for debugging

```bash
KEEP_ENV=1 bash validate_lab.sh
```

The temporary environment will remain installed. Its name is printed at the end; remove it manually when no longer needed.

## 4. Last verified baseline

**11 November 2026 — `bioinf-serv2`**

- Two successful complete runs: **44 PASS, 0 WARN, 0 FAIL, 0 SKIP**.
- Scientific pipeline: approximately 3–4 minutes.
- Total runtime including environment setup: approximately 8 minutes.
- Automatic environment removal successfully verified.
- Mamba installed manually (`conda install mamba -c conda-forge -y`) and used successfully in both runs; the validator's automatic Mamba installation branch: **not yet tested**.

The validation uses mouse chromosome 19 for mapping; DESeq2 uses the separately provided whole-genome count matrix.

Since this baseline, the validator has been updated for the revised 2026 lab and now runs **46 checks** (the 44-check baseline above is preserved, nothing removed or weakened): featureCounts uses explicit paired-end fragment counting (`-p --countReadPairs`), and two new checks validate the lab's GO enrichment dot plot (script + PNG, and the data behind it). New artifacts in the working folder: `rnaseq/funannot/plot_go_up.R`, `rnaseq/funannot/go_up_top_terms.png`, `logs/10b_go_plot.log`, `logs/10c_go_check.log`.

**Files:** `validate_lab.sh` (validator), `environment.yml` (pinned dependencies), `legacy/validate_lab_original.sh` (previous working validator).