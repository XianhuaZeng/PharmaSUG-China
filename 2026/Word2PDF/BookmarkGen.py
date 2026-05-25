"""
BookmarkGen.py
==============
Scan a folder of RTF files, extract the Table / Figure / Listing title from
each file's raw RTF code, sort in clinical order (Tables -> Figures ->
Listings), and write Bookmark.xls to the same folder.

Supports two Chinese encoding styles produced by SAS on Windows:
  • Unicode escapes   \\uN;    e.g. \\u34920; → 表   (SAS Unicode / UTF-8 mode)
  • GBK hex escapes   \\'XX   e.g. \\'B1\\'ED → 表   (SAS GBK / DBCS mode)

Title extraction strategy (tried in order):
  1. Outermost \\bkmkstart bookmark name — most reliable for SAS clinical RTFs.
     When multiple bookmarks are nested, only the first (outermost) is used.
  2. Inline text scan on the fully-decoded RTF content (fallback).

Usage
-----
    python BookmarkGen.py <folder>      # scan folder, write Bookmark.xls
    python BookmarkGen.py               # uses current directory

Requirements
------------
    pip install xlwt
"""

import os
import re
import sys
import xlwt


# Keywords for Table / Figure / Listing in English and Chinese.
# 表格 / 图形 must come BEFORE 表 / 图 so the longer form matches first.
_KW = r'(?:Table|Figure|Listing|表格|表|图形|图表|图|列表|清单)'

# Regex to find a title after it has been decoded to plain Unicode text
_DECODED_TITLE_RE = re.compile(
    r'(?:' + _KW + r')\s*[\d.:A-Za-z]+\b[^\n\r{]{0,200}',
    re.IGNORECASE,
)

# Outermost \bkmkstart bookmark: {\*\bkmkstart <name>}
_BKMK_RE = re.compile(r'\{\\\*\\bkmkstart\s+([^}]+)\}', re.IGNORECASE)

# Strategy 3: original brace-block scan — English / plain ASCII RTF fallback
_RAW_TITLE_RE = re.compile(
    r'\{([^{}]*(?:Table|Figure|Listing)\s+[\d.:]+[^{}]*)\}',
    re.IGNORECASE,
)

# A title that is ONLY "Keyword Number" with no description (needs enrichment)
_BARE_RE = re.compile(
    r'^(?:Table|Figure|Listing|表格?|图表?|列表|清单)\s*[\d.]+$',
    re.IGNORECASE,
)


# ─────────────────────────────────────────────────────────────────────────────
# RTF → Unicode decoder  (handles both \uN; and \'XX encodings)
# ─────────────────────────────────────────────────────────────────────────────

def _decode_rtf_text(chunk: str) -> str:
    """
    Decode a fragment of raw RTF (read as latin-1) to a plain Unicode string.

    • \\uN;   — Unicode scalar value (signed 16-bit decimal).  SAS sometimes
                appends ';' as a terminator; the spec allows a single fallback
                character which we also skip.
    • \\'XX  — Two-hex-digit byte.  Consecutive bytes are grouped and decoded
                as GBK (the dominant Chinese Windows codepage for SAS GBK mode).
    • \\word — RTF control word, discarded.
    • { }    — Group delimiters, discarded.
    """
    out: list[str] = []
    gbk: list[int] = []      # accumulate consecutive \'XX bytes for GBK decode
    i = 0
    n = len(chunk)

    def flush_gbk() -> None:
        if gbk:
            out.append(bytes(gbk).decode("gbk", errors="replace"))
            gbk.clear()

    while i < n:
        c = chunk[i]

        # ── non-backslash character ──────────────────────────────────────────
        if c != "\\":
            flush_gbk()
            if c not in "{}":
                out.append(c)
            i += 1
            continue

        # ── backslash sequence ───────────────────────────────────────────────
        nxt = chunk[i + 1] if i + 1 < n else ""

        # \uN;   Unicode escape
        if nxt == "u" and i + 2 < n and (chunk[i + 2].isdigit() or chunk[i + 2] == "-"):
            flush_gbk()
            j = i + 2
            if chunk[j] == "-":
                j += 1
            while j < n and chunk[j].isdigit():
                j += 1
            num = int(chunk[i + 2:j])
            if num < 0:
                num += 65536
            out.append(chr(num))
            i = j
            # skip optional ';' terminator (non-standard but used by SAS)
            if i < n and chunk[i] == ";":
                i += 1
                continue
            # skip standard RTF fallback char (one ASCII char or \'XX)
            if i < n and chunk[i] == "\\" and chunk[i:i + 2] == "\\'":
                i += 4          # skip \'XX fallback
            elif i < n and chunk[i] not in "\\":
                i += 1          # skip single ASCII fallback
            continue

        # \'XX   hex byte (GBK when consecutive)
        if nxt == "'" and i + 4 <= n:
            h = chunk[i + 2:i + 4]
            if len(h) == 2 and all(c2 in "0123456789abcdefABCDEF" for c2 in h):
                gbk.append(int(h, 16))
                i += 4
                continue

        # \\ or \{ or \}  — literal character
        if nxt in r"\{}|~-_":
            flush_gbk()
            out.append(nxt)
            i += 2
            continue

        # \*  \!  etc. — non-alphabetic control symbol, skip both chars
        if not nxt.isalpha():
            flush_gbk()
            i += 2
            continue

        # \word  or  \word-N  or  \wordN — RTF control word, discard
        flush_gbk()
        j = i + 1
        while j < n and chunk[j].isalpha():
            j += 1
        if j < n and chunk[j] in "+-":
            j += 1
        while j < n and chunk[j].isdigit():
            j += 1
        if j < n and chunk[j] == " ":   # delimiter space consumed
            j += 1
        i = j

    flush_gbk()
    return "".join(out)


# ─────────────────────────────────────────────────────────────────────────────
# Strategy 1 — extract from \bkmkstart bookmark name  (GBK / mixed)
# ─────────────────────────────────────────────────────────────────────────────

def _decode_bookmark_name(name: str) -> str:
    """Decode a raw RTF bookmark name to plain text.

    SAS GBK RTF generators encode the title as the bookmark name, using
    @w as a word separator and @d as a dot separator.
    """
    text = _decode_rtf_text(name)
    text = text.replace("@w", " ").replace("@d", ".")
    return text.strip()


def _extract_title_from_bookmarks(raw: str) -> str:
    """Return the first outermost \\bkmkstart name that looks like a TFL title.

    When bookmarks are nested, the first occurrence in the file is the
    outermost (enclosing) one and therefore represents the full title scope.
    Cross-reference lists (containing '、' or multiple TFL keywords) are skipped.
    """
    for m in _BKMK_RE.finditer(raw):
        name = _decode_bookmark_name(m.group(1))

        # Skip cross-reference lists: "表16.2.4.2、列表16.2.4.5.2.1、..."
        if '、' in name or '，' in name:
            continue
        # Skip if more than one TFL keyword found (e.g. "Table 1 and Table 2")
        if len(re.findall(_KW, name, re.IGNORECASE)) > 1:
            continue

        if re.search(_KW + r'\s*[\d.:A-Za-z]', name, re.IGNORECASE) \
                or re.match(r'\d[\d.]*\.\s*\S', name):   # e.g. "16.2.10. Description"
            # Fix colon-as-dot inside numbers (e.g. "14.1:1.2" → "14.1.1.2")
            name = re.sub(
                r'(' + _KW + r'\s*)([\d.:]+)',
                lambda mm: mm.group(1) + mm.group(2).replace(":", "."),
                name, flags=re.IGNORECASE,
            )
            return name
    return ""


# ─────────────────────────────────────────────────────────────────────────────
# Strategy 2 — scan decoded inline text  (Unicode \uN; or plain English)
# ─────────────────────────────────────────────────────────────────────────────

def _extract_title_from_text(raw: str) -> str:
    """Decode the whole RTF and search for a TFL title pattern in plain text."""
    decoded = _decode_rtf_text(raw)

    m = _DECODED_TITLE_RE.search(decoded)
    if not m:
        return ""

    text = m.group(0).strip()

    # Fix colon-as-dot in numbers
    text = re.sub(
        r'(' + _KW + r'\s*)([\d.:]+)',
        lambda mm: mm.group(1) + mm.group(2).replace(":", "."),
        text, flags=re.IGNORECASE,
    )

    # Strip leading numeric noise like "00001221 "
    text = re.sub(r"^\d+\s+", "", text)

    # Trim anything after 3+ consecutive spaces (RTF noise that slipped through)
    text = re.sub(r"\s{3,}.*$", "", text)

    return text.strip()


# ─────────────────────────────────────────────────────────────────────────────
# Strategy 3 — original brace-block scan  (English plain-ASCII fallback)
# ─────────────────────────────────────────────────────────────────────────────

def _extract_title_from_raw_brace(raw: str) -> str:
    """Scan raw RTF for {... Table/Figure/Listing N.N ...} brace blocks.

    This mirrors the original algorithm and serves as a last-resort fallback
    for English RTF files where the other strategies fail.
    """
    m = _RAW_TITLE_RE.search(raw)
    if not m:
        return ""

    text = m.group(1)

    # Strip RTF control words (\word or \word123)
    text = re.sub(r"\\[a-zA-Z]+\d*\s?", "", text)

    # Decode common hex escapes: \'a8\'43 → en dash (SAS pattern), \'96 → en dash
    text = re.sub(r"\\'a8\\'43", "\u2013", text, flags=re.IGNORECASE)
    text = re.sub(r"\\'96", "\u2013", text)
    text = re.sub(r"\\'[0-9a-fA-F]{2}", "", text)   # drop remaining escapes

    # Fix colon-as-dot in numbers
    text = re.sub(
        r"((?:Table|Figure|Listing)\s+)([\d.:]+)",
        lambda mm: mm.group(1) + mm.group(2).replace(":", "."),
        text, flags=re.IGNORECASE,
    )

    text = re.sub(r"^\d+\s+", "", text.strip())

    # Collect continuation lines from subsequent \intbl cell blocks.
    # SAS RTF titles are often split across rows:
    #   {Table 1.1:1\cell}  {\row}  {Disposition of Patients\cell}  {\row}  {(Randomized Set)\cell}
    # We keep appending until the next block is too far away, looks like data,
    # or starts a new TFL title.
    _NEXT_CELL  = re.compile(r'\{([^{}]{2,150})\\cell\}', re.IGNORECASE)
    _DATA_LIKE  = re.compile(r'\t|\d{1,4}\s{2,}\d{1,4}')
    _BREAK_GAP  = re.compile(r'\\par\}|\{\\footer|\{\\header', re.IGNORECASE)
    _EMPTY_CELL = re.compile(r'\{\s*\\cell\}', re.IGNORECASE)
    pos = m.end()
    for _ in range(4):
        nm = _NEXT_CELL.search(raw, pos, pos + 700)
        if not nm:
            break
        gap = raw[pos:nm.start()]
        # Stop at structural section boundaries or empty cells (end-of-header signal)
        if _BREAK_GAP.search(gap) or _EMPTY_CELL.search(gap):
            break
        cont = re.sub(r"\\[a-zA-Z]+\d*\s?", "", nm.group(1)).strip()
        cont = re.sub(r"\\'[0-9a-fA-F]{2}", "", cont).strip()
        if not cont or _DATA_LIKE.search(cont):
            break
        if re.match(r'(?:Table|Figure|Listing)\s+[\d.]', cont, re.IGNORECASE) and cont != text:
            break
        text = f"{text} {cont}"
        pos = nm.end()

    return text.strip()


# ─────────────────────────────────────────────────────────────────────────────
# Strategy 4 — \outlinelevel scan  (deepest heading = most specific title)
# ─────────────────────────────────────────────────────────────────────────────

# Match \outlinelevelN immediately followed (with optional spaces) by a brace block
_OUTLINE_RE = re.compile(r'\\outlinelevel(\d+)\s*\{([^{}]+)\}', re.IGNORECASE)


def _extract_title_from_outline(raw: str) -> str:
    """Scan all \\outlinelevelN paragraphs and return the text of the deepest one.

    In SAS clinical RTF listings the outline structure is typically:
        \\outlinelevel3  {16.2.10. Laboratory Examination}          ← coarser
        \\outlinelevel4  {16.2.10. Subject Lab Listings: Hematology} ← finer
    We want the largest N (deepest nesting) which has the most specific title.
    """
    best_level = -1
    best_text = ""
    for m in _OUTLINE_RE.finditer(raw):
        level = int(m.group(1))
        text = _decode_rtf_text(m.group(2)).strip()
        if text and level > best_level:
            best_level = level
            best_text = text
    return best_text


# ─────────────────────────────────────────────────────────────────────────────
# Public entry point for a single file
# ─────────────────────────────────────────────────────────────────────────────

def _extract_title(rtf_path: str) -> str:
    """Extract the TFL title from an RTF file, supporting English and Chinese."""
    with open(rtf_path, "rb") as fh:
        raw = fh.read().decode("latin-1")

    # Strategy 1: outermost valid \bkmkstart name  (SAS GBK clinical RTFs)
    title = _extract_title_from_bookmarks(raw)

    # Strategy 2: scan fully-decoded inline text  (Unicode \uN; or plain English)
    if not title:
        title = _extract_title_from_text(raw)

    # Strategy 3: original brace-block scan  (English plain-ASCII, last resort)
    if not title:
        title = _extract_title_from_raw_brace(raw)

    # Strategy 4: deepest \outlinelevelN heading
    # (listings whose title has no TFL keyword prefix, e.g. "16.2.10. Description")
    if not title:
        title = _extract_title_from_outline(raw)

    # If we got only a bare "Keyword Number" with no description, try to enrich
    # it via Strategy 2/3 which may find the full title elsewhere in the file.
    if title and _BARE_RE.match(title):
        for enriched in (
            _extract_title_from_text(raw),
            _extract_title_from_raw_brace(raw),
        ):
            if enriched and len(enriched) > len(title):
                title = enriched
                break

    return title


def _sort_key(stem_label):
    """Tables -> Figures -> Listings, numerically within each group."""
    stem = stem_label[0].lower()
    group = 0 if stem.startswith("t") else 1 if stem.startswith("f") else 2
    return (group, [int(n) for n in re.findall(r"\d+", stem)])


def _write_xls(rows: list, output_path: str) -> None:
    wb = xlwt.Workbook(encoding="utf-8")
    ws = wb.add_sheet("Sheet1")

    header = xlwt.easyxf(
        "font: bold true, name Arial, height 200;"
        "pattern: pattern solid, fore_colour grey25;"
        "borders: left thin, right thin, top thin, bottom thin;"
        "alignment: horiz centre;"
    )
    cell = xlwt.easyxf(
        "font: name Arial, height 200;"
        "borders: left thin, right thin, top thin, bottom thin;"
    )

    ws.write(0, 0, "Output Identifier",      header)
    ws.write(0, 1, "Title", header)
    ws.col(0).width = 256 * 45
    ws.col(1).width = 256 * 70

    for i, (stem, label) in enumerate(rows, start=1):
        ws.write(i, 0, stem,  cell)
        ws.write(i, 1, label, cell)

    wb.save(output_path)


def generate_bookmark(folder: str) -> None:
    folder = os.path.abspath(folder)
    if not os.path.isdir(folder):
        print(f"Error: '{folder}' is not a valid directory.")
        sys.exit(1)

    rtf_files = sorted(
        f for f in os.listdir(folder)
        if f.lower().endswith(".rtf") and not f.startswith("~")
    )
    if not rtf_files:
        print("No RTF files found.")
        sys.exit(0)

    width = max(len(os.path.splitext(f)[0]) for f in rtf_files)
    rows, skipped = [], []
    for filename in rtf_files:
        stem  = os.path.splitext(filename)[0]
        title = _extract_title(os.path.join(folder, filename))
        if title:
            rows.append((stem, title))
            print(f"  [OK] {stem:{width}s} -> {title}")
        else:
            skipped.append(stem)
            print(f"  [SKIPPED] {stem}")

    if not rows:
        print("No titles found - Bookmark.xls not written.")
        return

    rows.sort(key=_sort_key)
    output_path = os.path.join(folder, "Bookmark.xls")
    _write_xls(rows, output_path)
    print(f"\nWrote {len(rows)} entries -> {output_path}")
    if skipped:
        print(f"Skipped: {', '.join(skipped)}")


if __name__ == "__main__":
    generate_bookmark(sys.argv[1] if len(sys.argv) > 1 else ".")