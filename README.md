# KIMN20

**Omics — Analysis of large-scale biomolecular datasets** (LTH)

Course material for KIMN20. The introductory lesson is delivered on **03 November 2026** as self-contained HTML presentations rendered from Quarto (`.qmd`) sources — no notebooks or student installations required.

## Lessons

All lesson material lives in [`basic_linux_r/`](basic_linux_r/README.md):

| Deck | Source | Rendered output |
| --- | --- | --- |
| Introduction to Linux | `basic_linux_r/intro_to_linux.qmd` | `basic_linux_r/intro_to_linux.html` |
| Introduction to R | `basic_linux_r/intro_to_r.qmd` | `basic_linux_r/intro_to_r.html` |
| IDEs | `basic_linux_r/IDEs.qmd` | `basic_linux_r/IDEs.html` |

## Presenting

```bash
# Open a deck directly (self-contained, works offline)
open basic_linux_r/intro_to_linux.html
```

Optionally serve everything over the network with Docker (static server on port 8000) — see `basic_linux_r/README.md`.

## Updating the material

1. Edit the `.qmd` source (and the `date:` front matter / title-slide dates).
2. Re-render with Quarto:
   ```bash
   quarto render basic_linux_r/intro_to_linux.qmd
   ```
3. Commit both the `.qmd` and the rendered `.html` so the deck is always presentable without a render step.

## Versioning per course year

The 2025 edition of this material is preserved as git tag `KIMN20-2025` (on `main`). Each course year continues in the same tree; tag `KIMN20-<year>` after the course is over.