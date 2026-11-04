# 🎯 Live Interactive Linux Commands Presentation

## For Live Teaching (Jupyter Notebook)

### Step 1: Start Docker Container
```bash
cd /Users/masvo/Documents/repo/KIMN20

# Start the container (use 8889 if 8888 is busy)
docker run -p 8889:8888 kimn20
```

### Step 2: Open JupyterLab in Browser
```
http://localhost:8889
```

### Step 3: Open the Notebook
- Click on `linux-commands-tutorial.ipynb`
- You'll see cells with bash commands

### Step 4: Execute Commands Live
- **Click on a cell** (gray code box)
- **Press `Shift + Enter`** to execute
- **Watch the output appear below!**

---

## What Students Will See

Each cell contains a bash command like:
```bash
pwd
```

When you press Shift+Enter, students see:
```
/workspace
```

This is **real bash execution** - not simulated!

---

## Benefits

✅ **Students learn by doing** - They see live command execution  
✅ **Interactive Q&A** - Modify commands on the fly during class  
✅ **Hands-on practice** - Students can follow along in their own terminals  
✅ **No confusion** - Real output, not theoretical examples  

---

## Troubleshooting

### Port 8888 Already in Use?
```bash
# Use a different port
docker run -p 8889:8888 kimn20
# Then open: http://localhost:8889
```

### Docker Not Running?
On macOS, start Docker Desktop from Applications folder.

### Want to Edit the Content?
1. Edit `linux-commands-tutorial.qmd`
2. Run: `quarto render linux-commands-tutorial.qmd --to ipynb`
3. Restart the container

---

## Two Presentation Modes

| Mode | Use Case | How |
|------|----------|-----|
| **HTML Slides** | Quick overview lecture | `open linux-commands-tutorial.html` |
| **Jupyter Notebook** | Live coding + interaction | `docker run -p 8889:8888 kimn20` then `http://localhost:8889` |

Choose based on what you need that day!
