# KIMN20
Omics - Analysis of large-scale biomolecular datasets

## Linux Commands Interactive Presentation

An interactive Quarto presentation for teaching basic Linux commands to students.

### � Project Structure

```
basic_linux_r/
├── README.md              # This file - setup and usage guide
├── custom.css             # Custom styling for the presentation
├── linux-commands-tutorial.qmd    # Source file (Quarto format)
├── linux-commands-tutorial.html   # Rendered presentation (reveal.js slides)
├── linux-commands-tutorial.ipynb  # Jupyter notebook for live coding
├── docker/
│   └── Dockerfile         # Docker container definition
└── docs/
    ├── LIVE_READY.md      # Live teaching preparation guide
    ├── LIVE_TEACHING.md   # Live session instructions
    ├── QUICKSTART.md      # Quick start guide
    └── SETUP_COMPLETE.md  # Setup verification checklist
```

### �🚀 Quick Start

**Option 1: View the HTML presentation locally**
```bash
open linux-commands-tutorial.html
```

**Option 2: Live Interactive Coding with Docker**

For teaching and live execution:
```bash
# Build the container (one time)
docker build --platform linux/amd64 -t kimn20 docker/

# Run with a different port if 8888 is busy
docker run -p 8889:8888 kimn20
```

Then open in your browser:
- **JupyterLab (interactive)**: http://localhost:8889
- Open `linux-commands-tutorial.ipynb` in JupyterLab
- **Execute cells with Shift+Enter** to run bash commands live!

### 📚 What's Included

- `linux-commands-tutorial.qmd` - Source file (Quarto format)
- `linux-commands-tutorial.html` - Rendered presentation (reveal.js slides)
- `linux-commands-tutorial.ipynb` - Jupyter notebook for live coding
- `Dockerfile` - Container with all dependencies
- `custom.css` - Presentation styling
- `docs/` - Teaching guides and setup documentation

### 📖 Topics Covered

✅ Navigation (pwd, ls, cd)  
✅ File operations (mkdir, touch, cp, mv, rm)  
✅ Text processing (cat, grep)  
✅ System info (whoami, uname, df)  
✅ Package management (apt, yum, brew)  
✅ Useful shortcuts & wildcards  

### 💡 How to Use for Teaching

**Static presentation (no execution needed):**
```bash
open linux-commands-tutorial.html
# Use arrow keys to navigate slides
# Show command examples to students
```

**Live coding with students:**
```bash
docker run -p 8888:8888 kimn20
# Open http://localhost:8888 in browser
# Open linux-commands-tutorial.ipynb
# Click any cell and press Shift+Enter to execute
# Students see real bash output instantly!
```

**Teaching Resources:**
- Check `docs/LIVE_READY.md` for preparation steps
- Follow `docs/LIVE_TEACHING.md` during live sessions
- Use `docs/QUICKSTART.md` for rapid setup
- Verify setup with `docs/SETUP_COMPLETE.md`

### 🛠️ For Instructors: Edit & Rebuild

1. Edit `linux-commands-tutorial.qmd` with your changes
2. Rebuild the container: `docker build --platform linux/amd64 -t kimn20 docker/`
3. Files will automatically render and be ready to serve

### ✨ Why This Approach

- **No installation needed for students** - Just Docker
- **Works on Windows, macOS, Linux** - Same container
- **Two ways to present** - Static HTML for lectures or Jupyter for live coding
- **Clean and maintainable** - Simple Quarto + Docker setup
