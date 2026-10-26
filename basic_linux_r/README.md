# Basic Linux and R

Introductory lesson decks for KIMN20 covering Linux commands, R basics, and IDEs.

All teaching material is delivered as **self-contained HTML presentations** rendered from Quarto (`.qmd`) source files (reveal.js). The legacy Jupyter notebooks in `tests/` are no longer used.

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
├── chalkboard/              # Bonus chalkboard-format tutorial (Linux commands)
├── docker/
│   └── Dockerfile           # Optional container for serving the HTML decks
└── tests/                   # Legacy notebooks and work-in-progress files (not used in teaching)
```

## Optional: serve via Docker

The container starts a static web server with the rendered HTML:

```bash
# Build the container (one time)
docker build --platform linux/amd64 -t kimn20 docker/

# Run it
docker run -p 8000:8000 kimn20
```

Then open http://localhost:8000 in a browser and pick a deck.

## Topics covered

**Linux** — Navigation (`pwd`, `ls`, `cd`), file operations (`mkdir`, `touch`, `cp`, `mv`, `rm`), text processing (`cat`, `grep`), system info (`whoami`, `uname`, `df`), package management (`apt`, `yum`, `brew`), shortcuts & wildcards

**R** — Language basics and help, packages, variables & data types, data structures (vectors, matrices, lists, data frames), reading data, writing functions, Bioconductor

**IDEs** — Overview of environments for R work (VS Code, Positron, RStudio, Cursor; Firebase Studio slide hidden as outdated)

## Versioning per course year

The 2025 edition of this material is preserved as git tag `KIMN20-2025` (on `main`). Each course year continues in the same tree; tag `KIMN20-<year>` after the course is over — `git checkout KIMN20-<year>` restores that edition, `git diff KIMN20-<year>..main` shows what changed since.
