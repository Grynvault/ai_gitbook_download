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
