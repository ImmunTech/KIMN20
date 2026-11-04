# Basic Linux and R

Introductory lesson decks for KIMN20 covering Linux commands, R basics, and IDEs.

All teaching material is delivered as **self-contained HTML presentations** rendered from Quarto (`.qmd`) source files (reveal.js).

## Presentations

| Deck | Source | Rendered output |
| --- | --- | --- |
| Introduction to Linux | `intro_to_linux.qmd` | `intro_to_linux.html` |
| Introduction to R | `intro_to_r.qmd` | `intro_to_r.html` |
| IDEs | `IDEs.qmd` | `IDEs.html` |

## Quick start

```bash
# View a presentation locally
open intro_to_linux.html
```

Navigate slides with the arrow keys.

## For instructors: edit & re-render

1. Edit the `.qmd` source file (e.g. `intro_to_linux.qmd`)
2. Re-render with Quarto:
   ```bash
   quarto render intro_to_linux.qmd
   ```
3. Open the resulting `.html` — it is self-contained and ready to present.

## Project structure

```
basic_linux_r/
├── README.md                # This file
├── custom.css               # Shared styling for the presentations
├── intro_to_linux.qmd       # Source: Linux intro deck
├── intro_to_linux.html      # Rendered: Linux intro deck
├── intro_to_r.qmd           # Source: R intro deck
├── intro_to_r.html          # Rendered: R intro deck
├── IDEs.qmd                 # Source: IDE deck
├── IDEs.html                # Rendered: IDE deck
├── assets/                  # Images, logos, data files used by the decks
└── labs/                    # Hands-on lab material and cheat sheet
```

The `.qmd` files stay at the top level on purpose: Quarto resolves
`assets/` and `custom.css` relative to the source file, and the render
workflow refers to these paths directly.

Earlier material that is no longer taught (the chalkboard deck, the
legacy Jupyter notebooks and the Docker setup) was removed in November
2026. It is preserved in the [`KIMN20-2025`](https://github.com/ImmunTech/KIMN20/tree/KIMN20-2025)
tag and can be restored with, for example:

```bash
git checkout KIMN20-2025 -- basic_linux_r/chalkboard
```

## Topics covered

**Linux** — Navigation (`pwd`, `ls`, `cd`), file operations (`mkdir`, `touch`, `cp`, `mv`, `rm`), text processing (`cat`, `grep`), system info (`whoami`, `uname`, `df`), package management (`apt`, `yum`, `brew`), shortcuts & wildcards

**R** — Language basics and help, packages, variables & data types, data structures (vectors, matrices, lists, data frames), reading data, writing functions, Bioconductor

**IDEs** — Overview of environments for R work (VS Code, Positron, RStudio, Cursor; Firebase Studio slide hidden as outdated)
