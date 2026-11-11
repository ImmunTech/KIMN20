# RNA-seq Lab — Pre-course Validation

Run this check on the bioinformatics server **before each annual KIMN20 RNA-seq lab** to confirm that the software environment, input data and complete analysis pipeline still work.

## 1. Run the validation

It can be launched from any working directory, because it resolves `environment.yml` relative to its own script location:

```bash
bash /path/to/KIMN20/transcriptomics/validation/validate_lab.sh
echo "Exit code: $?"
```

The script automatically:

- Checks Conda and Mamba (installs Mamba in Conda `base` if missing).
- Creates a fresh temporary environment using `environment.yml`.
- Runs the complete RNA-seq pipeline and 44 validation checks.
- Saves results and software versions.
- Removes the temporary environment when finished.

**Note:** Installing Mamba into `base` modifies that environment. On `bioinf-serv2`, Mamba was installed manually with `conda install mamba -c conda-forge -y` and was subsequently used by the validator in two complete runs; only the validator's automatic Mamba installation branch remains untested.

## 2. Check the result

Expected output:

```text
PASS: 44   WARN: 0   FAIL: 0   SKIP: 0
LAB OK: all result checks passed.
Validator exit code: 0
```

The complete results are saved under:

```text
~/rnaseq_validation_<timestamp>/
├── REPORT.txt        # Summary of all 44 checks
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

**Files:** `validate_lab.sh` (validator), `environment.yml` (pinned dependencies), `legacy/validate_lab_original.sh` (previous working validator).