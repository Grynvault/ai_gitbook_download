# GitBook → Markdown (AI‑ready) Downloader

Turn any GitBook space (custom domain or `*.gitbook.io`) into **clean Markdown** that's easy to feed into RAG/LLM pipelines.  
The script discovers pages from a site's table of contents (ToC) and saves each page as a separate `.md` file while **skipping images/videos/assets**.

---

## What you get

- **AI‑ready Markdown** (uses Jina Reader to strip site chrome)
- **No media**: filters out images, videos, and static assets
- **Safe filenames**: short `<label>__<last-segment>-<hash>.md` to avoid path-length limits
- **Idempotent**: won't re‑download pages you already saved
- **macOS/Linux friendly** (zsh/bash compatible)

> Examples  
> - `https://docs.radfi.co` → output folder `docs-md/`  
> - `https://hyperliquid.gitbook.io/hyperliquid-docs` → `hyperliquid-md/`

---

## Installation & Setup

### Prerequisites (macOS/Linux)

**No installation needed!** All required tools are built into macOS and most Linux distributions:
- `bash`, `curl`, `grep`, `sed`, `awk`, `shasum` ✅ (pre-installed)

**Optional dependency** (only for spider fallback):
```bash
# macOS
brew install wget

# Ubuntu/Debian
sudo apt install wget

# RHEL/CentOS/Fedora
sudo yum install wget  # or dnf install wget
```

### Quick Install

1. **Download the script:**
   ```bash
   curl -fsSL -o dl_gitbook_simple.sh https://raw.githubusercontent.com/Grynvault/ai_gitbook_download/main/dl_gitbook_simple.sh
   chmod +x dl_gitbook_simple.sh
   ```

2. **Or create it locally:**
   ```bash
   cat > dl_gitbook_simple.sh <<'BASH'
   #!/usr/bin/env bash
   # Simple GitBook -> Markdown downloader (excludes images/videos)
   # Usage: bash dl_gitbook_simple.sh <ROOT_URL> [OUT_DIR]
   set -euo pipefail

   ROOT="${1:-}"
   if [ -z "$ROOT" ]; then
     echo "Usage: bash dl_gitbook_simple.sh <ROOT_URL> [OUT_DIR]" >&2
     exit 1
   fi
   ROOT="$(printf "%s" "$ROOT" | sed -E 's/[#?].*$//' | sed -E 's#/$##')"

   HOST="$(printf "%s" "$ROOT" | awk -F/ '{print $3}')"
   LABEL="$(printf "%s" "$HOST" | awk -F. '{print $1}')"
   OUT="${2:-${LABEL}-md}"
   mkdir -p "$OUT"

   UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome Safari"

   # Escape host for regex use
   HOST_RE="$(printf '%s' "$HOST" | sed -E 's/[][\.^$*+?|(){}\\]/\\&/g')"

   # 1) Fetch homepage HTML
   TMP_HTML="$(mktemp)"
   curl -fsSL -A "$UA" "$ROOT/" -o "$TMP_HTML"

   # 2) Build URL list from ToC (absolute + root-relative) and filter
   URLS="$OUT/urls.txt"
   {
     # absolute links on same host
     grep -oE "href=\"https?://$HOST_RE[^\"]*\"" "$TMP_HTML" | sed -E 's/^href="|"$//g' || true
     # root-relative links -> absolutize
     grep -oE 'href="/[^"]*"' "$TMP_HTML" | sed -E 's/^href="|"$//g' | sed -E "s#^/#$ROOT/#" || true
   } \
   | sed -E 's/[#?].*$//' \
   | sed -E 's#//$#/#' \
   | sed -E 's#/$##' \
   | grep -E "^$ROOT(/|$)" \
   | grep -vi 'image' \
   | grep -vi 'video' \
   | grep -Ev '/(assets|__gitbook|_next|fonts|tags|search)($|/)' \
   | grep -Ev '\.(png|jpe?g|gif|svg|webp|ico|css|js|json|xml|txt|woff2?|mp4|mov|webm|m3u8|mpd)$' \
   | sort -u > "$URLS"

   COUNT=$(wc -l < "$URLS" | tr -d ' ')
   if [ "$COUNT" -eq 0 ]; then
     echo "No URLs discovered from homepage ToC for $ROOT."
     echo "Tip: Some spaces render ToC via JS. If so, use a spider crawl:"
     echo "  brew install wget"
     echo "  wget --spider --recursive --level=3 --no-verbose --no-parent \"$ROOT/\" 2>&1 \\"
     echo "    | awk '/^--/ {print \$3}' \\"
     echo "    | sed -E 's/[#?].*\$//' | sed -E 's#//$#/#' | sed -E 's#/\$##' \\"
     echo "    | grep -E \"^$ROOT(/|\$)\" \\"
     echo "    | grep -vi 'image' | grep -vi 'video' \\"
     echo "    | grep -Ev '/(assets|__gitbook|_next|fonts|tags|search)(\$|/)' \\"
     echo "    | grep -Ev '\\.(png|jpe?g|gif|svg|webp|ico|css|js|json|xml|txt|woff2?|mp4|mov|webm|m3u8|mpd)\$' \\"
     echo "    | sort -u > \"$URLS\""
     exit 1
   fi

   echo "Discovered $COUNT pages. Downloading via Jina Reader…"

   # 3) Download each page to Markdown
   : > "$OUT/failed.txt"
   i=0; ok=0
   while IFS= read -r url; do
     i=$((i+1))
     # short, safe filename: <label>__<last-segment>-<8char-hash>.md
     last="$(basename "${url#https://}")"; [ -z "$last" ] && last="index"
     safe_last="$(printf "%s" "$last" | tr -c 'A-Za-z0-9._- ' '_' | awk '{print substr($0,1,80)}')"
     hash="$(printf "%s" "$url" | shasum | awk '{print substr($1,1,8)}')"
     file="$OUT/${LABEL}__${safe_last}-${hash}.md"

     # Skip if present
     [ -s "$file" ] && { printf "[%d/%d] SKIP  %s\n" "$i" "$COUNT" "$url"; continue; }

     # Try up to 3 variants: as-is, add slash, drop .md (if any)
     variants=("$url" "${url%/}/")
     [[ "$url" == *.md ]] && variants+=("${url%.md}")

     got=0; code="000"
     for v in "${variants[@]}"; do
       code=$(curl -sS -A "$UA" -w '%{http_code}' -o "$file.tmp" "https://r.jina.ai/$v" || echo "000")
       if [ "$code" = "200" ] && [ -s "$file.tmp" ]; then
         mv "$file.tmp" "$file"
         printf "[%d/%d] OK    %s\n" "$i" "$COUNT" "$v"
         got=1; ok=$((ok+1))
         break
       fi
       sleep 1
     done

     if [ "$got" -ne 1 ]; then
       echo "$code $url" >> "$OUT/failed.txt"
       printf "[%d/%d] FAIL(%s) %s\n" "$i" "$COUNT" "$code" "$url"
       rm -f "$file.tmp"
     fi

     sleep 0.2
   done < "$URLS"

   echo "Saved $ok / $COUNT pages to: $OUT/"
   [ -s "$OUT/failed.txt" ] && echo "Some failed (422/404/etc). See $OUT/failed.txt"
   BASH

   chmod +x dl_gitbook_simple.sh
   ```

---

## Usage

### Basic Usage

```bash
# GitBook.io subdomain
./dl_gitbook_simple.sh "https://hyperliquid.gitbook.io/hyperliquid-docs"

# Custom domain GitBook
./dl_gitbook_simple.sh "https://docs.radfi.co" radfi-md

# With zsh (fully compatible)
zsh dl_gitbook_simple.sh "https://example.gitbook.io/docs"
```

**Output:** Files saved to `<label>-md/` (e.g., `docs-md/docs__economics-16340fdd.md`)

### Advanced Usage

```bash
# Custom output directory
./dl_gitbook_simple.sh "https://docs.example.com" my-custom-output

# Make it globally available
sudo cp dl_gitbook_simple.sh /usr/local/bin/dl-gitbook
dl-gitbook "https://docs.example.com"
```

---

## Spider Fallback (JS-rendered ToCs)

Some GitBook spaces hide links in client-side JavaScript. If you see `No URLs discovered...`, use this fallback:

```bash
# Install wget if needed (one-time setup)
brew install wget

# Set your variables
ROOT="https://hyperliquid.gitbook.io/hyperliquid-docs"
OUT="hyperliquid-md"
mkdir -p "$OUT"

# Crawl to discover URLs
wget --spider --recursive --level=3 --no-verbose --no-parent "$ROOT/" 2>&1 \
  | awk '/^--/ {print $3}' \
  | sed -E 's/[#?].*$//' | sed -E 's#//$#/#' | sed -E 's#/$##' \
  | grep -E "^$ROOT(/|$)" \
  | grep -vi 'image' | grep -vi 'video' \
  | grep -Ev '/(assets|__gitbook|_next|fonts|tags|search)($|/)' \
  | grep -Ev '\.(png|jpe?g|gif|svg|webp|ico|css|js|json|xml|txt|woff2?|mp4|mov|webm|m3u8|mpd)$' \
  | sort -u > "$OUT/urls.txt"

# Re-run the downloader
./dl_gitbook_simple.sh "$ROOT" "$OUT"
```

---

## System Requirements

### macOS (Recommended)
- **Built-in tools:** ✅ All required (`bash`, `curl`, `grep`, `sed`, `awk`, `shasum`)
- **Optional:** `brew install wget` (for spider fallback only)
- **Shells:** Works with both `bash` and `zsh`

### Linux
- **Built-in tools:** ✅ All required (standard on most distributions)
- **Optional:** `sudo apt install wget` / `sudo yum install wget`

### Windows
- **WSL:** ✅ Recommended (Ubuntu/Debian subsystem)
- **Git Bash:** ✅ Should work
- **PowerShell:** ❌ Not supported (use WSL)

---

## AI/RAG Integration Tips

### Concatenate for Single File Input
```bash
cd docs-md
awk '{print}' urls.txt | while read -r u; do \
  h=$(printf "%s" "$u" | shasum | awk '{print substr($1,1,8)}'); \
  f=$(ls *-"$h".md 2>/dev/null | head -n1); \
  [ -n "$f" ] && { echo -e "\n\n---\n\n"; cat "$f"; }; \
done > ../docs-all.md
```

### Chunk by Headers
- Split Markdown files by `#`, `##`, `###` headings for better retrieval
- Maintain the `urls.txt` for canonical page ordering
- Use filename hashes to link chunks back to source URLs

---

## Troubleshooting

### "No URLs discovered from homepage ToC"
**Solution:** Use the spider fallback above. Many GitBook spaces render navigation via JavaScript.

### Many 422/404 errors
**Solutions:**
1. Re-run the script once (transient 422s often resolve)
2. Check `<output>/failed.txt` for patterns
3. Test individual URLs: `curl -s https://r.jina.ai/<failed-url> | head`

### "File name too long" errors
**Solution:** The script uses short filenames with 8-char hashes. This should prevent path length issues on most systems.

### Permission denied on script execution
**Solution:** 
```bash
chmod +x dl_gitbook_simple.sh
./dl_gitbook_simple.sh "https://example.com"
```

---

## Customization

### Modify Content Filters
Edit these lines in the script:
```bash
| grep -vi 'image' \           # Remove to include image pages
| grep -vi 'video' \           # Remove to include video pages
| grep -Ev '/(assets|__gitbook|_next|fonts|tags|search)($|/)' \  # Path exclusions
```

### Change Output Naming
Modify this section for different filename patterns:
```bash
file="$OUT/${LABEL}__${safe_last}-${hash}.md"
```

### Add Parallelism (Advanced)
Replace the download loop with `xargs` for faster processing:
```bash
cat "$URLS" | xargs -I {} -P 4 curl -sS "https://r.jina.ai/{}" -o "{}.md"
```

---

## Ethics & Best Practices

- ✅ **Respect robots.txt** and site Terms of Service
- ✅ **Rate limiting included** (0.2s delay between requests)
- ✅ **Only process content you have rights to use**
- ✅ **Be considerate** with site resources

---

## Contributing

Issues and PRs welcome! This tool is designed to be simple and reliable.

### Common Enhancements
- Parallel downloading
- Better error handling for specific GitBook versions
- Support for additional content types
- Integration with vector databases

---

## License

MIT License - feel free to modify and distribute.