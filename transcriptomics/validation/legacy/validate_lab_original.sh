#!/usr/bin/env bash
# =============================================================================
# validate_lab.sh  -  End-to-end validation of the "Lab - RNAseq" (mouse chr19)
# =============================================================================
# Reproduces the RNA-seq workflow using compatible tool commands and,
# after every step, checks the RESULTS and not just the exit
# code: read counts of the fastq files, alignment rates, featureCounts assigned
# %, number of MultiQC reports, agreement of the DE genes with the reference
# files, muscle GO terms, PNG sizes, etc.
#
# Usage:
#   bash validate_lab.sh
#   # in the background (survives a dropped SSH connection):
#   nohup bash validate_lab.sh > run.out 2>&1 &
#   tail --pid=$! -f run.out        # follows the log and exits when the run ends
#
# Optional environment variables:
#   ENV_NAME=rnaseq_lab     conda environment to activate
#   THREADS=4               threads for HISAT2 / featureCounts
#   ROOT=/path/to/output    optional working directory (default: timestamped in HOME)
#   SKIP_ANNOT=1            skip the bonus part (goseq / Reactome)
#
# Output: ~/rnaseq_validation_<timestamp>/
#           rnaseq/             working pipeline folder
#           logs/               one log per step
#           reference_outputs/  reference files downloaded for comparisons
#           REPORT.txt          the final report
# Exit code: 0 = no FAIL, 1 = at least one FAIL
# =============================================================================

export LC_ALL=C
shopt -s nullglob

ENV_NAME="${ENV_NAME:-rnaseq_lab}"
THREADS="${THREADS:-4}"
SKIP_ANNOT="${SKIP_ANNOT:-0}"
ROOT="${ROOT:-$HOME/rnaseq_validation_$(date +%Y%m%d_%H%M%S)}"
LAB="$ROOT/rnaseq"
LOGS="$ROOT/logs"
REFOUT="$ROOT/reference_outputs"
T_START=$SECONDS

# Dataset and reference URLs (independent of any HTML page)
URL_DATA="https://github.com/Nilsson-D/dummy_data/raw/refs/heads/main/RNA-seq/data"
URL_RAW="https://raw.githubusercontent.com/Nilsson-D/dummy_data/refs/heads/main/RNA-seq"
URL_ENS="https://ftp.ensembl.org/pub/release-99"
SAMPLES=(SRR3222409 SRR3222410 SRR3222411 SRR3222412 SRR3222413 SRR3222414)

# Baseline values for dataset validation (SRR3222409: 156992 pairs, 98.10% overall)
EXP_S1_PAIRS=156992
EXP_S1_RATE=98.10
EXP_CHR19_LEN=61431566

mkdir -p "$LOGS" "$REFOUT"

# -----------------------------------------------------------------------------
# Helpers
# NOTE: result arrays are prefixed with R_ on purpose. Conda environments export
# variables such as NM, AR, AS, LD... and a plain array called NM would collide.
# -----------------------------------------------------------------------------
nP=0; nF=0; nW=0; nS=0
R_ICON=(); R_NAME=(); R_INFO=(); TIMES=()

add() {  # add STATUS "check name" "evidence"
  local st=$1 name=$2 info=${3:-} ic
  case $st in
    PASS) nP=$((nP+1)); ic="✅";;
    FAIL) nF=$((nF+1)); ic="❌";;
    WARN) nW=$((nW+1)); ic="⚠️ ";;
    *)    nS=$((nS+1)); ic="⏭️ ";;
  esac
  R_ICON+=("$ic"); R_NAME+=("$name"); R_INFO+=("$info")
  printf '   %s %s%s\n' "$ic" "$name" "${info:+  ->  $info}"
}

run() {  # run "label" logfile command...   (saves log + elapsed time)
  local label=$1 log=$2; shift 2
  printf '\n▶ %s ...\n' "$label"
  local t0=$SECONDS
  "$@" >"$log" 2>&1
  local rc=$?
  local dt=$((SECONDS - t0))
  TIMES+=("$(printf '%-48s %5ss   exit=%s' "$label" "$dt" "$rc")")
  if [ $rc -ne 0 ]; then
    echo "   (exit code $rc - last lines of $log)"
    tail -n 8 "$log" | sed 's/^/   | /'
  fi
  return $rc
}

in_dir() { local d=$1; shift; ( cd "$LAB/$d" && "$@" ); }

need() {  # need "check name" file...   -> SKIP if an input is missing
  local n=$1; shift; local f
  for f in "$@"; do
    [ -s "$f" ] || { add SKIP "$n" "missing $(basename "$f") (an earlier step failed)"; return 1; }
  done
  return 0
}

fge() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a+0 >= b+0)}'; }   # a >= b
flt() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a+0 <  b+0)}'; }   # a <  b
kv()  { grep -m1 "^$2=" "$1" 2>/dev/null | cut -d= -f2-; }       # kv file KEY

print_report() {
  echo
  echo "======================================================================="
  echo "📊  VALIDATION REPORT - RNA-seq Lab"
  echo "======================================================================="
  local i
  for i in "${!R_NAME[@]}"; do
    printf '%s %s\n' "${R_ICON[$i]}" "${R_NAME[$i]}"
    [ -n "${R_INFO[$i]}" ] && printf '      %s\n' "${R_INFO[$i]}"
  done
  echo
  echo "-----------------------------------------------------------------------"
  echo "Time per step:"
  printf '   %s\n' "${TIMES[@]}"
  echo "-----------------------------------------------------------------------"
  printf '✅ PASS: %d   ⚠️  WARN: %d   ❌ FAIL: %d   ⏭️  SKIP: %d   (total time: %dm%02ds)\n' \
    $nP $nW $nF $nS $(( (SECONDS-T_START)/60 )) $(( (SECONDS-T_START)%60 ))
  echo "Detailed logs: $LOGS"
  echo "Lab folder:    $LAB"
  echo "======================================================================="
  if [ $nF -eq 0 ] && [ $nS -eq 0 ]; then
    echo "🎉 LAB OK: all result checks passed."
    [ $nW -gt 0 ] && echo "   (still read the ⚠️  items above: not blocking, but worth a look)"
  elif [ $nF -eq 0 ]; then
    echo "🟡 No FAIL, but some checks were skipped: see the ⏭️  items."
  else
    echo "🚨 LAB NOT READY: there are ❌ items - see the log indicated for each one."
  fi
}

finish() { print_report | tee "$ROOT/REPORT.txt"; [ $nF -eq 0 ]; exit $?; }

# -----------------------------------------------------------------------------
# Helper R scripts (used ONLY for the checks, they are NOT part of the lab)
# -----------------------------------------------------------------------------
cat > "$LOGS/chk_pkgs.R" <<'EOF'
pk <- c("edgeR","DESeq2","goseq","GO.db","reactome.db","org.Mm.eg.db",
        "tidyverse","pheatmap","EnsDb.Mmusculus.v79","geneLenDataBase")
ok <- vapply(pk, function(p) nzchar(system.file(package = p)), logical(1))
cat("MISSING=", paste(pk[!ok], collapse = ","), "\n", sep = "")
v <- vapply(pk[ok], function(p) as.character(packageVersion(p)), "")
cat("VERSIONS=", paste(names(v), v, collapse = "; "), "\n", sep = "")
EOF

cat > "$LOGS/chk_counts.R" <<'EOF'
# compares counts.txt (chr19, generated here) with counts_full.txt (lab backup, whole genome)
a <- commandArgs(TRUE)
rd <- function(f) read.delim(f, skip = 1, check.names = FALSE)
x <- rd(a[1]); y <- rd(a[2])
mk <- function(d) { m <- as.matrix(d[, -(1:6)])
  colnames(m) <- sub(".*(SRR[0-9]+).*", "\\1", colnames(m)); rownames(m) <- d$Geneid; m }
cx <- mk(x); cy <- mk(y)
cat("SAMPLES=", paste(colnames(cx), collapse = ","), "\n", sep = "")
cat("NSAMPLES=", ncol(cx), "\n", sep = "")
cat("NGENES_X=", nrow(cx), "\nNGENES_Y=", nrow(cy), "\n", sep = "")
cat("IDS_IDENTICAL=", identical(sort(rownames(cx)), sort(rownames(cy))), "\n", sep = "")
is19 <- grepl("^19(;19)*$", x$Chr)
cat("N_CHR19_GENES=", sum(is19), "\n", sep = "")
cat("COUNTS_OFF_CHR19=", sum(cx[!is19, , drop = FALSE]), "\n", sep = "")
cat("COUNTS_ON_CHR19=", sum(cx[is19, , drop = FALSE]), "\n", sep = "")
keep <- intersect(x$Geneid[is19], rownames(cy))
cx2 <- cx[keep, , drop = FALSE]; cy2 <- cy[keep, colnames(cx), drop = FALSE]
act <- rowSums(cx2) > 0 | rowSums(cy2) > 0
rho <- cor(cx2[act, ], cy2[act, ], method = "spearman")
best <- colnames(rho)[apply(rho, 1, which.max)]
cat("RHO_DIAG=", paste(sprintf("%.3f", diag(rho)), collapse = ","), "\n", sep = "")
cat("RHO_DIAG_MIN=", sprintf("%.3f", min(diag(rho))), "\n", sep = "")
cat("BEST_MATCH_OK=", all(best == rownames(rho)), "\n", sep = "")
EOF

cat > "$LOGS/chk_dge.R" <<'EOF'
# compares the freshly generated dge_results_full.txt with the reference one
a <- commandArgs(TRUE)
n <- read.delim(a[1]); r <- read.delim(a[2])
cnt <- function(d) c(sig  = sum(d$padj < 0.05, na.rm = TRUE),
                     up   = sum(d$padj < 0.05 & d$log2FoldChange >  0.5, na.rm = TRUE),
                     down = sum(d$padj < 0.05 & d$log2FoldChange < -0.5, na.rm = TRUE))
cn <- cnt(n); cr <- cnt(r)
cat("N_NEW=", nrow(n), "\nN_REF=", nrow(r), "\n", sep = "")
cat("IDS_IDENTICAL=", identical(sort(n$ensembl_gene_id), sort(r$ensembl_gene_id)), "\n", sep = "")
m <- merge(n, r, by = "ensembl_gene_id", suffixes = c(".n", ".r"))
cat("LFC_COR=", sprintf("%.5f", cor(m$log2FoldChange.n, m$log2FoldChange.r, use = "complete.obs")), "\n", sep = "")
cat("SIG_NEW=", cn["sig"], "\nSIG_REF=", cr["sig"], "\n", sep = "")
cat("UP_NEW=", cn["up"], "\nUP_REF=", cr["up"], "\nDOWN_NEW=", cn["down"], "\nDOWN_REF=", cr["down"], "\n", sep = "")
EOF

cat > "$LOGS/chk_pca.R" <<'EOF'
# PCA on the vst data: KO and Wt must separate along PC1 or PC2
a <- commandArgs(TRUE)
v <- read.delim(a[1], check.names = FALSE)
p <- prcomp(t(v), scale. = TRUE)
ko <- colnames(v) %in% c("SRR3222409", "SRR3222410", "SRR3222411")
sep <- function(x) max(x[ko]) < min(x[!ko]) || max(x[!ko]) < min(x[ko])
ve <- 100 * p$sdev^2 / sum(p$sdev^2)
cat("NCOL=", ncol(v), "\n", sep = "")
cat("PC1_SEPARATES=", sep(p$x[, 1]), "\nPC2_SEPARATES=", sep(p$x[, 2]), "\n", sep = "")
cat("PC1_VAR=", sprintf("%.1f", ve[1]), "\nPC2_VAR=", sprintf("%.1f", ve[2]), "\n", sep = "")
EOF

echo "======================================================================="
echo "🚀 End-to-end validation of the RNA-seq Lab"
echo "📂 Working directory: $ROOT"
echo "======================================================================="

# -----------------------------------------------------------------------------
# STEP 0 - Environment, tools, R packages
# -----------------------------------------------------------------------------
echo; echo "━━ STEP 0: preflight ━━"

if command -v conda >/dev/null 2>&1; then
  eval "$(conda shell.bash hook)"
  conda activate "$ENV_NAME" >"$LOGS/00_conda.log" 2>&1
fi
if [ "${CONDA_DEFAULT_ENV:-}" = "$ENV_NAME" ]; then
  add PASS "Conda environment '$ENV_NAME' is active"
else
  add WARN "Conda environment '$ENV_NAME' is NOT active (using the tools found in PATH)" "CONDA_DEFAULT_ENV='${CONDA_DEFAULT_ENV:-}'"
fi

# isolate R from the user's own libraries
export R_LIBS_USER=""
export R_LIBS_SITE=""

missing=()
for t in wget gzip gunzip hisat2 hisat2-build samtools featureCounts fastqc multiqc Rscript file; do
  command -v "$t" >/dev/null 2>&1 || missing+=("$t")
done
if [ ${#missing[@]} -gt 0 ]; then
  add FAIL "Command-line tools are installed" "missing: ${missing[*]}"
  finish
fi
FQC_VER="$(fastqc --version 2>&1 | head -1)"
ver="hisat2 $(hisat2 --version 2>&1 | head -1 | awk '{print $NF}')"
ver="$ver | $(samtools --version 2>&1 | head -1)"
ver="$ver | $(featureCounts -v 2>&1 | grep -i featureCounts | head -1 | xargs)"
ver="$ver | $FQC_VER"
ver="$ver | $(multiqc --version 2>&1 | head -1)"
ver="$ver | $(R --version 2>/dev/null | grep -m1 '^R version' | cut -d' ' -f1-3)"
add PASS "Tools found (hisat2, samtools, featureCounts, fastqc, multiqc, R)" "$ver"

if Rscript "$LOGS/chk_pkgs.R" >"$LOGS/00_rpkgs.log" 2>&1; then
  miss=$(kv "$LOGS/00_rpkgs.log" MISSING)
  if [ -z "$miss" ]; then
    add PASS "R packages (DESeq2, edgeR, goseq, reactome.db, org.Mm.eg.db, EnsDb.Mmusculus.v79, pheatmap, tidyverse)" \
      "$(kv "$LOGS/00_rpkgs.log" VERSIONS | tr ';' '\n' | grep -E 'DESeq2|goseq' | xargs)"
  else
    add FAIL "R packages installed" "missing: $miss  (the R steps that need them will fail)"
  fi
else
  add FAIL "Rscript works" "see $LOGS/00_rpkgs.log"
fi

free_gb=$(df -P -BG "$HOME" | awk 'NR==2{gsub("G","",$4); print $4}')
if fge "$free_gb" 5; then add PASS "Disk space in \$HOME" "${free_gb} GB free (~3 GB needed)"
else add WARN "Disk space in \$HOME" "${free_gb} GB free: might not be enough (~3 GB needed)"; fi

# -----------------------------------------------------------------------------
# STEP 1 - Folder layout + fastq download
# -----------------------------------------------------------------------------
echo; echo "━━ STEP 1: folders and fastq download ━━"
mkdir -p "$LAB" && cd "$LAB" || exit 1
mkdir -p 1_raw 2_fastqc 3_mapping 4_dge 5_multiqc reference scripts funannot plots
mkdir -p reference/mouse_chr19_hisat2
dirs_ok=1
for d in 1_raw 2_fastqc 3_mapping 4_dge 5_multiqc reference reference/mouse_chr19_hisat2 scripts funannot plots; do
  [ -d "$LAB/$d" ] || dirs_ok=0; done
[ $dirs_ok -eq 1 ] && add PASS "Lab folder layout created" "1_raw 2_fastqc 3_mapping 4_dge 5_multiqc reference scripts funannot plots"

{ echo '#!/bin/bash'; echo
  for s in "${SAMPLES[@]}"; do for r in 1 2; do echo "wget -nv $URL_DATA/${s}-19_${r}.fq.gz"; done; done
} > scripts/get_data.sh

run "Download 12 fastq (get_data.sh)" "$LOGS/01_get_data.log" in_dir 1_raw bash ../scripts/get_data.sh
rc=$?
fq=( "$LAB"/1_raw/*.fq.gz )
if [ $rc -eq 0 ] && [ ${#fq[@]} -eq 12 ]; then
  add PASS "12 fastq files downloaded" "${#fq[@]} files in 1_raw ($(du -sh 1_raw | cut -f1))"
else
  add FAIL "12 fastq files downloaded" "found ${#fq[@]}/12, wget exit=$rc  (see $LOGS/01_get_data.log)"
fi

if [ ${#fq[@]} -gt 0 ]; then
  badgz=(); for f in "${fq[@]}"; do gzip -t "$f" 2>/dev/null || badgz+=("$(basename "$f")"); done
  if [ ${#badgz[@]} -eq 0 ]; then add PASS "All fastq.gz files are intact gzip archives"
  else add FAIL "Corrupted/truncated fastq.gz files" "${badgz[*]}"; fi

  echo "   (counting reads in every fastq...)"
  mism=(); summ=""
  for s in "${SAMPLES[@]}"; do
    f1="1_raw/${s}-19_1.fq.gz"; f2="1_raw/${s}-19_2.fq.gz"
    if [ -s "$f1" ] && [ -s "$f2" ]; then
      n1=$(zcat "$f1" | awk 'END{print NR/4}'); n2=$(zcat "$f2" | awk 'END{print NR/4}')
      [ "$n1" = "$n2" ] || mism+=("$s:$n1!=$n2")
      summ="$summ $s=$n1"
      [ "$s" = "SRR3222409" ] && N1_S1=$n1
    else mism+=("$s:file missing"); fi
  done
  if [ ${#mism[@]} -eq 0 ]; then add PASS "R1 reads == R2 reads for every sample (pairs intact)" "pairs:${summ}"
  else add FAIL "R1/R2 read counts differ" "${mism[*]}"; fi
  if [ "${N1_S1:-0}" = "$EXP_S1_PAIRS" ]; then
    add PASS "SRR3222409 has $EXP_S1_PAIRS pairs (matches the expected baseline)"
  else
    add WARN "SRR3222409 has ${N1_S1:-?} pairs, baseline expects $EXP_S1_PAIRS" "data changed? verify the input data/baseline"
  fi
fi

# -----------------------------------------------------------------------------
# STEP 2 - Reference (chr19 genome + Ensembl 99 GTF)
# -----------------------------------------------------------------------------
echo; echo "━━ STEP 2: genome and annotation ━━"
cat > scripts/get_ref.sh <<EOF
#!/bin/bash
wget -nv $URL_ENS/fasta/mus_musculus/dna/Mus_musculus.GRCm38.dna.chromosome.19.fa.gz
wget -nv $URL_ENS/gtf/mus_musculus/Mus_musculus.GRCm38.99.gtf.gz
gunzip Mus_musculus.GRCm38.dna.chromosome.19.fa.gz
gunzip Mus_musculus.GRCm38.99.gtf.gz
cat Mus_musculus.GRCm38.99.gtf | grep -E "^#|^19" > Mus_musculus.GRCm38.99-19.gtf
EOF
run "Download + gunzip + chr19 GTF extraction" "$LOGS/02_reference.log" in_dir reference bash ../scripts/get_ref.sh
FA="$LAB/reference/Mus_musculus.GRCm38.dna.chromosome.19.fa"
GTF="$LAB/reference/Mus_musculus.GRCm38.99.gtf"
GTF19="$LAB/reference/Mus_musculus.GRCm38.99-19.gtf"
if need "Genome/GTF checks" "$FA" "$GTF" "$GTF19"; then
  hdr=$(head -1 "$FA")
  len=$(awk '!/^>/{n+=length($0)} END{print n}' "$FA")
  if [[ "$hdr" == ">19 "* ]] && [ "$len" = "$EXP_CHR19_LEN" ]; then
    add PASS "FASTA = complete GRCm38 chromosome 19" "$hdr  |  ${len} bp"
  elif [[ "$hdr" == ">19 "* ]]; then
    add WARN "FASTA is chr19 but with an unexpected length" "${len} bp (expected $EXP_CHR19_LEN)"
  else
    add FAIL "FASTA is not chr19" "header: $hdr"
  fi
  full19=$(awk '!/^#/ && $1=="19"' "$GTF" | wc -l)
  sub19=$(grep -vc '^#' "$GTF19")
  g19=$(awk '$1=="19" && $3=="gene"' "$GTF" | wc -l)
  if [ "$full19" = "$sub19" ] && [ "$sub19" -gt 0 ] && [ "$g19" -gt 500 ]; then
    add PASS "chr19 GTF is consistent with the full GTF" "$sub19 lines, $g19 genes on chr19 | full=$(du -h "$GTF" | cut -f1), chr19=$(du -h "$GTF19" | cut -f1), fa=$(du -h "$FA" | cut -f1)"
  else
    add FAIL "chr19 GTF is inconsistent" "full GTF chr19 lines=$full19 vs subset=$sub19, genes=$g19"
  fi
fi

# -----------------------------------------------------------------------------
# STEP 3 - FastQC
# -----------------------------------------------------------------------------
echo; echo "━━ STEP 3: FastQC ━━"
cat > scripts/fastqc.sh <<'EOF'
#!/usr/bin/env bash
# Run from 2_fastqc/; use the supported long option (FastQC 0.13+).
fastqc --outdir . ../1_raw/*.fq.gz
EOF
if need "FastQC execution" "${fq[0]:-/nonexistent}"; then
  run "FastQC on 12 FASTQ files (--outdir)" "$LOGS/03_fastqc.log" in_dir 2_fastqc bash ../scripts/fastqc.sh
  rc=$?
  if [ "$rc" -ne 0 ]; then
    add FAIL "FastQC execution" "exit=$rc; see $LOGS/03_fastqc.log"
  fi
fi
nh=$(ls 2_fastqc/*_fastqc.html 2>/dev/null | wc -l); nz=$(ls 2_fastqc/*_fastqc.zip 2>/dev/null | wc -l)
if [ "$nh" -eq 12 ] && [ "$nz" -eq 12 ]; then add PASS "FastQC output: 12 .html + 12 .zip (one per fastq)"
else add FAIL "FastQC output incomplete" "html=$nh zip=$nz (expected 12+12) - see $LOGS/03_fastqc.log"; fi
if [ "$nz" -gt 0 ]; then
  if command -v unzip >/dev/null 2>&1; then
    p=0; w=0; f=0; u=0
    for z in 2_fastqc/*_fastqc.zip; do
      s=$(unzip -p "$z" '*/summary.txt' 2>/dev/null | awk -F'\t' '$2=="Per base sequence quality"{print $1; exit}')
      case $s in PASS) p=$((p+1));; WARN) w=$((w+1));; FAIL) f=$((f+1));; *) u=$((u+1));; esac
    done
    if [ $u -gt 0 ]; then add FAIL "FastQC zip files contain a readable summary.txt" "$u of $nz zip files have no readable 'Per base sequence quality' entry"
    elif [ $f -gt 0 ]; then add WARN "FastQC 'Per base sequence quality' has FAILs" "PASS=$p WARN=$w FAIL=$f out of $nz files"
    else add PASS "FastQC 'Per base sequence quality'" "PASS=$p WARN=$w FAIL=$f out of $nz files"; fi
  else
    add SKIP "Reading summary.txt inside the FastQC zip files" "unzip is not installed"
  fi
fi

# -----------------------------------------------------------------------------
# STEP 4 - HISAT2: index, mapping, BAM indexing
# -----------------------------------------------------------------------------
echo; echo "━━ STEP 4: HISAT2 ━━"
cat > scripts/hisat2_index.sh <<'EOF'
#!/bin/bash

hisat2-build \
  -p 1 \
  Mus_musculus.GRCm38.dna.chromosome.19.fa \
  mouse_chr19_hisat2/mouse_chr19_hisat2
EOF
sed -i "s/-p 1/-p $THREADS/" scripts/hisat2_index.sh

run "hisat2-build (chr19 index)" "$LOGS/04_hisat2_index.log" in_dir reference bash ../scripts/hisat2_index.sh
idx=0; idxempty=0
for i in 1 2 3 4 5 6 7 8; do
  f="reference/mouse_chr19_hisat2/mouse_chr19_hisat2.$i.ht2"
  [ -f "$f" ] && idx=$((idx+1)); [ -f "$f" ] && [ ! -s "$f" ] && idxempty=$((idxempty+1))
done
if [ $idx -eq 8 ] && [ $idxempty -eq 0 ]; then
  add PASS "HISAT2 index: 8 non-empty .ht2 files" "$(du -sh reference/mouse_chr19_hisat2 | cut -f1) in total"
else
  add FAIL "HISAT2 index incomplete" "$idx/8 files (empty: $idxempty) - see $LOGS/04_hisat2_index.log"
fi

cat > scripts/hisat2_align.sh <<'EOF'
#!/bin/bash

# get output filename prefix
prefix=$( basename $1 | sed -E 's/_.+$//' )

hisat2 \
  -p 1 \
  -x ../reference/mouse_chr19_hisat2/mouse_chr19_hisat2 \
  --summary-file "${prefix}.summary" \
  -1 $1 \
  -2 $2 | samtools sort -O BAM > "${prefix}.bam"
EOF
sed -i "s/-p 1/-p $THREADS/" scripts/hisat2_align.sh

cat > scripts/hisat2_align_batch.sh <<'EOF'
#!/bin/bash

# Loop through each read1 file
for r1 in ../1_raw/*1.fq.gz; do
  # Define the corresponding read2 file by replacing "r1" with "r2" in the filename

  r2="${r1/1.fq.gz/2.fq.gz}"

  # Extract the base name of the sample
  sample_name=$(basename "$r1" | sed 's/_1.fastq.gz//')

  # Define output files
  out_sam="./${sample_name}.sam"

  ## use the sample name and add suffix (_1.fq.gz or _2.fq.gz)
  echo "Mapping ${r1} and ${r2} ..."
  bash ../scripts/hisat2_align.sh ${r1} ${r2}
done
EOF

if need "HISAT2 mapping" "$LAB/reference/mouse_chr19_hisat2/mouse_chr19_hisat2.1.ht2" "${fq[0]:-/nonexistent}"; then
  run "hisat2_align_batch.sh (6 samples)" "$LOGS/05_hisat2_align.log" in_dir 3_mapping bash ../scripts/hisat2_align_batch.sh
fi
bams=( "$LAB"/3_mapping/*.bam ); sums=( "$LAB"/3_mapping/*.summary )
if [ ${#bams[@]} -eq 6 ] && [ ${#sums[@]} -eq 6 ]; then
  add PASS "Mapping: 6 BAM + 6 .summary files with the expected names" "$(basename "${bams[0]}") ... $(basename "${bams[5]}")"
else
  add FAIL "Mapping: incomplete output" "bam=${#bams[@]} summary=${#sums[@]} (expected 6+6) - see $LOGS/05_hisat2_align.log"
fi

if [ ${#bams[@]} -gt 0 ]; then
  badq=(); unsorted=(); empty=()
  for b in "${bams[@]}"; do
    [ -s "$b" ] || { empty+=("$(basename "$b")"); continue; }
    samtools quickcheck -v "$b" >/dev/null 2>&1 || badq+=("$(basename "$b")")
    samtools view -H "$b" 2>/dev/null | grep -q 'SO:coordinate' || unsorted+=("$(basename "$b")")
  done
  if [ ${#empty[@]} -eq 0 ] && [ ${#badq[@]} -eq 0 ]; then add PASS "BAM files are non-empty and valid (samtools quickcheck)"
  else add FAIL "Empty or corrupted BAM files" "empty: ${empty[*]:-none}  corrupted: ${badq[*]:-none}"; fi
  if [ ${#unsorted[@]} -eq 0 ]; then add PASS "BAM files are coordinate-sorted (SO:coordinate)"
  else add FAIL "Unsorted BAM files" "${unsorted[*]}"; fi
fi

if [ ${#sums[@]} -gt 0 ]; then
  low=(); mid=(); line=""; wrongreads=0
  for s in "${sums[@]}"; do
    name=$(basename "$s" .summary)
    reads=$(awk 'NR==1{print $1}' "$s"); rate=$(awk '/overall alignment rate/{gsub("%","",$1); print $1}' "$s")
    line="$line $name:${reads}pairs/${rate}%;"
    [ -z "$rate" ] && { low+=("$name(no rate)"); continue; }
    if flt "$rate" 90; then low+=("$name=$rate"); elif flt "$rate" 95; then mid+=("$name=$rate"); fi
    if [ "$name" = "SRR3222409-19" ]; then
      [ "$reads" = "$EXP_S1_PAIRS" ] || wrongreads=1
      S1RATE=$rate
    fi
  done
  if [ ${#low[@]} -gt 0 ]; then add FAIL "Overall alignment rate < 90%" "${low[*]}"
  elif [ ${#mid[@]} -gt 0 ]; then add WARN "Overall alignment rate between 90 and 95%" "${mid[*]}"
  else add PASS "Overall alignment rate >= 95% in every sample" "$line"; fi
  if [ -n "${S1RATE:-}" ]; then
    if awk -v a="$S1RATE" -v b="$EXP_S1_RATE" 'BEGIN{d=a-b; if(d<0)d=-d; exit !(d<=0.5)}' && [ $wrongreads -eq 0 ]; then
      add PASS "SRR3222409-19 matches the expected alignment baseline" "${S1RATE}% (baseline: ${EXP_S1_RATE}%), $EXP_S1_PAIRS pairs"
    else
      add WARN "SRR3222409-19 differs from the alignment baseline" "rate=${S1RATE}% (baseline ${EXP_S1_RATE}%) - verify HISAT2 version and input data"
    fi
  fi
fi

if [ ${#bams[@]} -gt 0 ] && [ -s "${bams[0]}" ]; then
  worst=100
  for b in "${bams[@]}"; do
    [ -s "$b" ] || continue
    samtools index "$b" >/dev/null 2>&1   # temporary index, needed by idxstats
    pct=$(samtools idxstats "$b" | awk '{if($1=="19")m=$3; t+=$3} END{if(t>0)printf "%.2f",100*m/t; else print 0}')
    flt "$pct" "$worst" && worst=$pct
  done
  rm -f "$LAB"/3_mapping/*.bai   # the lab's own indexing step recreates them from scratch
  if fge "$worst" 99.9; then add PASS "All mapped reads are on chr19 (idxstats)" "minimum $worst%"
  else add WARN "Reads mapped outside chr19?" "minimum $worst% on contig 19"; fi
fi

cat > scripts/samtools_index_bam.sh <<'EOF'
#!/bin/bash

for i in *.bam
  do
    echo "Indexing $i ..."
    samtools index $i
  done
EOF
run "samtools_index_bam.sh" "$LOGS/06_samtools_index.log" in_dir 3_mapping bash ../scripts/samtools_index_bam.sh
bai=( "$LAB"/3_mapping/*.bam.bai )
if [ ${#bai[@]} -eq 6 ]; then
  add PASS "BAM indexing: 6 .bam.bai files created" "$(du -ch "${bai[@]}" | tail -1 | cut -f1) in total"
else
  add FAIL "BAM indexing" "${#bai[@]}/6 .bai files - see $LOGS/06_samtools_index.log"
fi

# -----------------------------------------------------------------------------
# STEP 5 - featureCounts + counts_full.txt
# -----------------------------------------------------------------------------
echo; echo "━━ STEP 5: featureCounts ━━"
cat > scripts/featurecounts.sh <<'EOF'
#!/bin/bash

featureCounts \
  -a "../reference/Mus_musculus.GRCm38.99.gtf" \
  -o "counts.txt" \
  -F "GTF" \
  -t "exon" \
  -g "gene_id" \
  -p \
  -s 0 \
  -T 1 \
  ../3_mapping/*.bam
EOF
sed -i "s/-T 1/-T $THREADS/" scripts/featurecounts.sh

if need "featureCounts" "$GTF" "${bams[0]:-/nonexistent}"; then
  run "featurecounts.sh (full GTF)" "$LOGS/07_featurecounts.log" in_dir 4_dge bash ../scripts/featurecounts.sh
fi
run "wget counts_full.txt (lab backup)" "$LOGS/07b_counts_full.log" in_dir 4_dge wget -nv "$URL_RAW/counts_full.txt"

CNT="$LAB/4_dge/counts.txt"; CNTS="$LAB/4_dge/counts.txt.summary"; CF="$LAB/4_dge/counts_full.txt"
if [ -s "$CNT" ] && [ -s "$CNTS" ]; then
  add PASS "featureCounts: counts.txt + counts.txt.summary produced"
else
  add FAIL "featureCounts: output files missing" "see $LOGS/07_featurecounts.log"
fi
if [ -s "$CNTS" ]; then
  awk -F'\t' 'NR==1{nf=NF; for(i=2;i<=nf;i++)n[i]=$i}
              NR>1{for(i=2;i<=nf;i++)t[i]+=$i; if($1=="Assigned")for(i=2;i<=nf;i++)a[i]=$i}
              END{for(i=2;i<=nf;i++)printf "%s %.1f\n", n[i], (t[i]>0?100*a[i]/t[i]:0)}' "$CNTS" \
    | sed -E 's/^.*(SRR[0-9]+)[^ ]* /\1 /' > "$LOGS/07_assigned.txt"
  minA=$(awk '{print $2}' "$LOGS/07_assigned.txt" | sort -n | head -1)
  lineA=$(awk '{printf "%s=%s%% ", $1, $2}' "$LOGS/07_assigned.txt")
  if flt "$minA" 20; then add FAIL "featureCounts: Assigned fragments % is too low (<20%)" "$lineA"
  elif flt "$minA" 40; then add WARN "featureCounts: Assigned fragments % is low (<40%)" "$lineA"
  else add PASS "featureCounts: Assigned fragments" "$lineA"; fi
fi
if [ -s "$CF" ]; then
  add PASS "counts_full.txt downloaded" "$(du -h "$CF" | cut -f1), $(($(wc -l < "$CF")-2)) genes"
else
  add FAIL "counts_full.txt not downloaded" "see $LOGS/07b_counts_full.log"
fi
if [ -s "$CNT" ] && [ -s "$CF" ]; then
  if Rscript "$LOGS/chk_counts.R" "$CNT" "$CF" > "$LOGS/07c_counts_check.log" 2>&1; then
    L="$LOGS/07c_counts_check.log"
    [ "$(kv "$L" NSAMPLES)" = "6" ] && add PASS "counts.txt has 6 sample columns" "$(kv "$L" SAMPLES)" \
                                    || add FAIL "counts.txt: wrong number of samples" "$(kv "$L" NSAMPLES)"
    if [ "$(kv "$L" IDS_IDENTICAL)" = "TRUE" ]; then
      add PASS "Gene IDs in counts.txt == gene IDs in counts_full.txt (same Ensembl 99 annotation)" "$(kv "$L" NGENES_X) genes"
    else
      add FAIL "Gene IDs in counts.txt differ from counts_full.txt" "x=$(kv "$L" NGENES_X) full=$(kv "$L" NGENES_Y): annotation differs from the backup"
    fi
    off=$(kv "$L" COUNTS_OFF_CHR19); on=$(kv "$L" COUNTS_ON_CHR19)
    if [ "${off:-1}" = "0" ] && [ "${on:-0}" -gt 0 ]; then
      add PASS "Counts only on chr19 genes (off-chr19 = 0)" "$on fragments over $(kv "$L" N_CHR19_GENES) chr19 genes"
    else
      add FAIL "Unexpected counts outside chr19" "off-chr19=$off on-chr19=$on"
    fi
    if [ "$(kv "$L" BEST_MATCH_OK)" = "TRUE" ] && fge "$(kv "$L" RHO_DIAG_MIN)" 0.8; then
      add PASS "Each chr19 sample correlates best with ITS OWN sample in counts_full (no swaps)" "Spearman diagonal: $(kv "$L" RHO_DIAG)"
    elif [ "$(kv "$L" BEST_MATCH_OK)" = "TRUE" ]; then
      add WARN "Samples matched correctly but the correlation is low" "Spearman diagonal: $(kv "$L" RHO_DIAG)"
    else
      add FAIL "Possible sample swap compared with counts_full" "Spearman diagonal: $(kv "$L" RHO_DIAG)"
    fi
  else
    add FAIL "Comparison of counts.txt vs counts_full.txt" "see $LOGS/07c_counts_check.log"
  fi
fi

# -----------------------------------------------------------------------------
# STEP 6 - MultiQC
# -----------------------------------------------------------------------------
echo; echo "━━ STEP 6: MultiQC ━━"
run "multiqc --interactive ../" "$LOGS/08_multiqc.log" in_dir 5_multiqc multiqc --interactive ../
MQ="$LAB/5_multiqc"
if [ -s "$MQ/multiqc_report.html" ] && [ -d "$MQ/multiqc_data" ]; then
  add PASS "MultiQC: multiqc_report.html + multiqc_data/" "$(du -h "$MQ/multiqc_report.html" | cut -f1)"
else
  add FAIL "MultiQC: report not generated" "see $LOGS/08_multiqc.log"
fi
MQSRC="$MQ/multiqc_data/multiqc_sources.txt"
if [ -s "$MQSRC" ]; then
  nfq=$(awk -F'\t' 'NR>1 && tolower($1)~/fastqc/{print $3}' "$MQSRC" | sort -u | wc -l)
  nfc=$(awk -F'\t' 'NR>1 && tolower($1)~/featurecounts/{print $3}' "$MQSRC" | sort -u | wc -l)
  nal=$(awk -F'\t' 'NR>1 && tolower($1)~/bowtie|hisat/{print $3}' "$MQSRC" | sort -u | wc -l)
  if [ "$nfq" -eq 12 ]; then add PASS "MultiQC found 12 FastQC reports"
  else add FAIL "MultiQC: FastQC reports" "found $nfq (expected 12); fastqc zips on disk: $nz; modules seen: $(awk -F'\t' 'NR>1{print $1}' "$MQSRC" | sort -u | xargs)"; fi
  [ "$nfc" -eq 6 ]  && add PASS "MultiQC found 6 featureCounts reports" || add FAIL "MultiQC: featureCounts reports" "found $nfc (expected 6)"
  [ "$nal" -eq 6 ]  && add PASS "MultiQC found 6 alignment reports (HISAT2 summaries parsed as 'bowtie2')" \
                    || add FAIL "MultiQC: alignment reports" "found $nal (expected 6)"
else
  add WARN "multiqc_sources.txt not found (different MultiQC version?)" "check the 'Found N reports' lines in $LOGS/08_multiqc.log by hand"
fi

# -----------------------------------------------------------------------------
# STEP 7 - DESeq2 (dge.R)
# -----------------------------------------------------------------------------
echo; echo "━━ STEP 7: DESeq2 ━━"
for f in dge_results_full.txt counts_vst_full.txt; do
  wget -nv -O "$REFOUT/$f" "$URL_RAW/$f" >>"$LOGS/09_refoutputs.log" 2>&1
done
run "wget dge.R" "$LOGS/09_wget_dge.log" in_dir 4_dge wget -nv "$URL_RAW/scripts/R/dge.R"
if need "Rscript dge.R" "$LAB/4_dge/dge.R" "$CF"; then
  run "Rscript dge.R" "$LOGS/09_dge.log" in_dir 4_dge Rscript dge.R
  rc=$?
else rc=99; fi
D="$LAB/4_dge"
outs=0; for f in counts_vst_full.txt counts_vst_full.Rds dge_results_full.txt dge_results_full.Rds; do [ -s "$D/$f" ] && outs=$((outs+1)); done
if [ $rc -eq 0 ] && [ $outs -eq 4 ] && grep -q '^Completed' "$LOGS/09_dge.log"; then
  add PASS "dge.R completed: 4 output files produced" "counts_vst_full.{txt,Rds} dge_results_full.{txt,Rds}"
elif [ $rc -ne 99 ]; then
  add FAIL "dge.R did not complete" "exit=$rc, outputs $outs/4 - see $LOGS/09_dge.log"
fi
if [ -s "$LOGS/09_dge.log" ]; then
  grep -qE '^\[1\] TRUE' "$LOGS/09_dge.log" \
    && add PASS "Count columns are in the same order as the metadata (all.equal = TRUE in the log)" \
    || add FAIL "all.equal() is not TRUE: count columns not aligned with the metadata" "see $LOGS/09_dge.log"
  grep -q 'condition_KO_vs_Wt' "$LOGS/09_dge.log" \
    && add PASS "DESeq2 contrast = condition_KO_vs_Wt" \
    || add WARN "Contrast 'condition_KO_vs_Wt' not found in the log"
fi
if [ -s "$D/dge_results_full.txt" ] && [ -s "$REFOUT/dge_results_full.txt" ]; then
  if Rscript "$LOGS/chk_dge.R" "$D/dge_results_full.txt" "$REFOUT/dge_results_full.txt" >"$LOGS/09b_dge_check.log" 2>&1; then
    L="$LOGS/09b_dge_check.log"
    if [ "$(kv "$L" IDS_IDENTICAL)" = "TRUE" ]; then
      add PASS "Same genes tested as in the reference file" "$(kv "$L" N_NEW) genes (ref $(kv "$L" N_REF))"
    else
      add FAIL "Tested genes differ from the reference" "new=$(kv "$L" N_NEW) ref=$(kv "$L" N_REF)"
    fi
    cor=$(kv "$L" LFC_COR)
    if fge "$cor" 0.999; then add PASS "log2FC identical to the reference" "correlation = $cor"
    elif fge "$cor" 0.99; then add WARN "log2FC almost identical to the reference" "correlation = $cor"
    else add FAIL "log2FC differ from the reference" "correlation = $cor"; fi
    sn=$(kv "$L" SIG_NEW); sr=$(kv "$L" SIG_REF)
    if awk -v a="$sn" -v b="$sr" 'BEGIN{d=a-b; if(d<0)d=-d; exit !(b>0 && d/b<=0.02)}'; then
      add PASS "Number of DE genes (padj<0.05) matches the reference (±2%)" "new=$sn  ref=$sr | up(LFC>0.5)=$(kv "$L" UP_NEW)/$(kv "$L" UP_REF) down=$(kv "$L" DOWN_NEW)/$(kv "$L" DOWN_REF)"
    else
      add WARN "Number of DE genes differs from the reference" "new=$sn  ref=$sr"
    fi
  else
    add FAIL "DGE comparison with the reference" "see $LOGS/09b_dge_check.log"
  fi
else
  add SKIP "DGE comparison with the reference" "dge_results_full.txt missing (new or reference)"
fi

# -----------------------------------------------------------------------------
# STEP 8 - Functional annotation (bonus)
# -----------------------------------------------------------------------------
echo; echo "━━ STEP 8: functional annotation (goseq / Reactome) ━━"
if [ "$SKIP_ANNOT" = "1" ]; then
  add SKIP "Functional annotation" "SKIP_ANNOT=1"
else
  run "wget annotate_de_results.R" "$LOGS/10_wget_annot.log" in_dir funannot wget -nv "$URL_RAW/scripts/R/annotate_de_results.R"
  # mm-biomart99-genes.txt is placed in reference/ for the annotation script
  run "wget mm-biomart99-genes.txt (into reference/)" "$LOGS/10_wget_biomart.log" in_dir reference wget -nv "$URL_RAW/mm-biomart99-genes.txt"
  if need "Rscript annotate_de_results.R" "$LAB/funannot/annotate_de_results.R" "$LAB/reference/mm-biomart99-genes.txt" "$D/dge_results_full.txt"; then
    run "Rscript annotate_de_results.R" "$LOGS/10_annot.log" in_dir funannot Rscript annotate_de_results.R
    rc=$?
    FA_D="$LAB/funannot"; ok=1; sz=""
    for f in go_up go_down reactome_up reactome_down; do
      [ -s "$FA_D/$f.txt" ] || ok=0; sz="$sz $f=$(($(wc -l < "$FA_D/$f.txt" 2>/dev/null || echo 1)-1))"
    done
    if [ $rc -eq 0 ] && [ $ok -eq 1 ]; then
      add PASS "annotate_de_results.R: 4 tables produced (term rows:$sz)"
      if [ "$(head -1 "$FA_D/go_up.txt" | cut -f1)" = "category" ] && head -1 "$FA_D/reactome_up.txt" | grep -q PATHNAME \
         && [ "$(($(wc -l < "$FA_D/go_up.txt")-1))" -gt 1000 ]; then
        add PASS "Expected headers (category..., PATHNAME) and >1000 GO terms"
      else
        add FAIL "Unexpected format of the functional tables" "head go_up: $(head -1 "$FA_D/go_up.txt" | cut -c1-80)"
      fi
      nm=$(sed -n '2,21p' "$FA_D/go_up.txt" | awk -F'\t' '{print $6}' | grep -ciE 'muscle|myofibril|sarcomere|contractile|striated|myosin')
      top3=$(awk -F'\t' 'NR>=2&&NR<=4{printf "%s; ",$6}' "$FA_D/go_up.txt")
      topp=$(awk -F'\t' 'NR==2{print $2}' "$FA_D/go_up.txt")
      if [ "$nm" -ge 5 ] && flt "$topp" 1e-20; then
        add PASS "Up-regulated GO: expected muscle terms dominate" "$nm/20 muscle terms; top: $top3 p=$topp"
      else
        add FAIL "Up-regulated GO: the expected muscle terms are not there" "$nm/20 muscle terms; top: $top3 p=$topp"
      fi
      add PASS "Top Reactome pathway up / down" "up: $(awk -F'\t' 'NR==2{print $NF}' "$FA_D/reactome_up.txt") | down: $(awk -F'\t' 'NR==2{print $NF}' "$FA_D/reactome_down.txt")"
    else
      add FAIL "annotate_de_results.R did not complete" "exit=$rc, tables ok=$ok - see $LOGS/10_annot.log"
    fi
  fi
fi

# -----------------------------------------------------------------------------
# STEP 9 - Plots
# -----------------------------------------------------------------------------
echo; echo "━━ STEP 9: plots (PCA, MA, volcano, heatmap) ━━"
run "wget plot_figures.R" "$LOGS/11_wget_plots.log" in_dir plots wget -nv "$URL_RAW/scripts/R/plot_figures.R"
if need "Rscript plot_figures.R" "$LAB/plots/plot_figures.R" "$D/dge_results_full.txt" "$D/counts_vst_full.txt"; then
  run "Rscript plot_figures.R" "$LOGS/11_plots.log" in_dir plots Rscript plot_figures.R
  rc=$?
  PL="$LAB/plots"; badp=(); info=""
  for spec in "pca_plot.png:480 x 480" "ma_plot.png:480 x 480" "volcano_plot.png:480 x 480" "heatmap_top_50.png:480 x 800"; do
    f=${spec%%:*}; want=${spec#*:}
    if [ ! -s "$PL/$f" ]; then badp+=("$f missing"); continue; fi
    dim=$(file "$PL/$f" | grep -oE '[0-9]+ x [0-9]+' | head -1); kb=$(( $(stat -c %s "$PL/$f") / 1024 ))
    info="$info $f(${dim},${kb}KB)"
    [ "$dim" = "$want" ] || badp+=("$f size $dim (expected $want)")
    [ "$kb" -ge 8 ] || badp+=("$f suspiciously small (${kb}KB: empty plot?)")
  done
  if [ $rc -eq 0 ] && [ ${#badp[@]} -eq 0 ]; then
    add PASS "plot_figures.R: 4 correct PNG files (right size, not empty)" "$info"
  else
    add FAIL "plot_figures.R: problems" "exit=$rc ${badp[*]:-} - see $LOGS/11_plots.log"
  fi
  if Rscript "$LOGS/chk_pca.R" "$D/counts_vst_full.txt" >"$LOGS/11b_pca.log" 2>&1; then
    L="$LOGS/11b_pca.log"
    if [ "$(kv "$L" PC1_SEPARATES)" = "TRUE" ] || [ "$(kv "$L" PC2_SEPARATES)" = "TRUE" ]; then
      add PASS "PCA: KO and Wt separate perfectly" "PC1 separates=$(kv "$L" PC1_SEPARATES) ($(kv "$L" PC1_VAR)% var), PC2 separates=$(kv "$L" PC2_SEPARATES) ($(kv "$L" PC2_VAR)% var)"
    else
      add FAIL "PCA: KO and Wt do NOT separate (swapped samples or wrong data?)" "PC1=$(kv "$L" PC1_VAR)% PC2=$(kv "$L" PC2_VAR)%"
    fi
  fi
fi

finish