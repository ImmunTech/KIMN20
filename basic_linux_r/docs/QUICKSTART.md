## 🚀 QUICK START - Linux Commands Presentation

### Option 1: Simple (Recommended for most users)
```bash
cd /Users/masvo/Documents/repo/KIMN20
open linux-commands-tutorial.html
```
✅ Done! Your presentation opens in the browser.

---

### Option 2: Docker (if students need interactive practice)
```bash
cd /Users/masvo/Documents/repo/KIMN20
docker run -p 8000:8000 -p 8888:8888 kimn20
```

Then open:
- **Presentation:** http://localhost:8000/linux-commands-tutorial.html
- **Interactive Notebook:** http://localhost:8888

---

### Option 3: Edit & Update
```bash
# Edit the source
nano linux-commands-tutorial.qmd

# Regenerate the presentation
quarto render linux-commands-tutorial.qmd

# View it
open linux-commands-tutorial.html
```

---

## What's Inside?

📊 **Beautiful reveal.js slides** with:
- Navigation commands (pwd, ls)
- File operations (mkdir, cp, mv, rm)
- Text search (grep, cat)
- System info commands
- Package management
- Practice exercises & quiz

## Key Differences from the Old Setup

❌ Removed: Complex Python subprocess code  
❌ Removed: Problematic code execution during rendering  
❌ Removed: Multiple container attempts  

✅ Added: Clean bash code examples  
✅ Added: Simple, reliable workflow  
✅ Added: Clear instructions  

## Support

- View slides: **Just open the HTML**
- Live coding: **Use Docker + Jupyter**
- Edit content: **Edit the .qmd file, re-render**

That's it! 🎉
