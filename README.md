# Quarto Cite

![Test](https://github.com/aarmey/quarto-cite/actions/workflows/test.yml/badge.svg)

A Quarto/Pandoc Lua filter that resolves typed citation keys—such as DOIs,
arXiv IDs, PubMed IDs, ISBNs, and URLs—to full bibliographic entries
automatically, without requiring any Python or external tools beyond `curl`.

This is a standalone reimplementation of the core citation-resolution
functionality of [manubot-cite](https://github.com/manubot/manubot),
written entirely in Lua so it runs natively inside Pandoc's filter
pipeline with no additional runtime dependencies.

**Extension vs. Pandoc:** `pandoc-cite` (the filter) has no Quarto-specific
dependencies — it's built on standard Pandoc Lua filter APIs, so it works
with any Pandoc >= 3.1 setup, e.g.
`pandoc --lua-filter=_extensions/pandoc-cite/pandoc-cite.lua --citeproc doc.md`.
`quarto-cite` (this repo) is simply the recommended, documented distribution
channel via `quarto add`.

---

## Features

| Prefix             | Source                                                       | Example                   |
| ------------------ | ------------------------------------------------------------ | ------------------------- |
| `doi:`             | [doi.org](https://doi.org) content negotiation               | `doi:10.1038/nature12373` |
| `arxiv:`           | [arXiv](https://arxiv.org) Atom API                          | `arxiv:1706.03762`        |
| `pmid:`            | [NCBI](https://pubmed.ncbi.nlm.nih.gov) ctxp API             | `pmid:25015390`           |
| `pmcid:`           | [PubMed Central](https://www.ncbi.nlm.nih.gov/pmc/) ctxp API | `pmcid:PMC4406347`        |
| `isbn:`            | Wikipedia Citoid → OpenLibrary fallback                      | `isbn:9780226458113`      |
| `url:`             | Wikipedia Citoid → minimal fallback                          | `url:https://quarto.org`  |
| `wikidata:`        | [Wikidata](https://www.wikidata.org) Entity Data API         | `wikidata:Q42`            |
| `http:` / `https:` | URL (bare, treated as `url:`)                                | `https://quarto.org`      |

- **Local cache** — each resolved citation is stored in `.citation-cache/`
  as a JSON file. Subsequent renders skip network requests entirely.
- **Full citeproc integration** — resolved citations are injected into
  Pandoc's bibliography pipeline, so any CSL style and locale work as
  normal.
- **No Python, no Node.js** — pure Lua + `curl` (already on most systems).

---

## Requirements

| Dependency                   | Minimum version               |
| ---------------------------- | ----------------------------- |
| [Quarto](https://quarto.org) | 1.4                           |
| Pandoc (bundled with Quarto) | 3.1                           |
| `curl`                       | any modern version            |
| Internet access              | required for first fetch only |

---

## Installation

### As a Quarto extension (recommended)

Install directly from GitHub into your project:

```bash
quarto add aarmey/quarto-cite
```

This copies the extension into `_extensions/pandoc-cite/` alongside your
document or project.

### Manual installation

Copy the `_extensions/` directory into your project root:

```
your-project/
├── _extensions/
│   └── pandoc-cite/
│       ├── _extension.yml
│       └── pandoc-cite.lua
└── document.qmd
```

---

## Usage

### Enable the filter

Add the filter to your document's YAML front matter:

```yaml
---
title: "My Document"
filters:
  - pandoc-cite
---
```

Or to `_quarto.yml` for a whole project:

```yaml
filters:
  - pandoc-cite
```

### Cite by identifier

Use standard Pandoc citation syntax with a typed prefix:

```markdown
DOI paper [@doi:10.1038/nature12373].

arXiv preprint [@arxiv:1706.03762].

PubMed article [@pmid:25015390].

PubMed Central article [@pmcid:PMC4406347].

Book by ISBN [@isbn:9780226458113].

Web page [@url:https://quarto.org/docs/extensions/filters.html].

Wikidata entity [@wikidata:Q42].

Bare HTTPS URL [@https://quarto.org].
```

### Citekey inference (bare DOIs and arXiv IDs)

A small number of identifier shapes are unambiguous enough that the
`doi:`/`arxiv:` prefix can be inferred automatically, even without it being
written explicitly:

```markdown
Bare DOI [@10.1038/nature12373].

Bare arXiv ID [@1706.03762].
```

This is conservative by design: only identifiers with an unmistakable shape
(a bare DOI starting with `10.<digits>/…`, or a new-style arXiv id shaped
like `YYMM.NNNNN[vN]`) are inferred. Anything else — including plain
numbers that could be a PMID, an ISBN, or a year — is left untouched and
falls through to normal citeproc/bibliography handling, so ordinary
hand-written citekeys like `smith2023` are never misinterpreted. Bare
`http://`/`https://` URLs are already handled without any inference step,
since the citekey's own colon is parsed as the `http`/`https` prefix.

### Reference list

Add a `## References` section (or `# References`) at the end of your
document; Pandoc's citeproc will populate it automatically.

```markdown
## References
```

### Specifying a citation style

Use any CSL file as normal:

```yaml
---
csl: apa.csl
filters:
  - pandoc-cite
---
```

---

## Cache

Resolved citations are stored in `.citation-cache/` in the working directory:

```
.citation-cache/
├── doi/
│   └── 10.1038_nature12373.json
├── arxiv/
│   └── 1706.03762.json
├── pmid/
│   └── 25015390.json
└── pandoc-cite-bibliography.json   ← combined bib injected each render
```

Each file contains the raw CSL JSON returned by the upstream API.
To force a re-fetch for a specific citation, delete its cache file.
To clear the entire cache, delete `.citation-cache/`.

### Custom cache directory

Set `citation-cache` in your front matter:

```yaml
---
citation-cache: /path/to/my-cache
---
```

### HTTP timeout and retries

Each upstream fetch is made with `curl`, bounded by a per-attempt timeout,
and retried automatically on network-level failures (connection errors,
timeouts, DNS problems). HTTP error responses (e.g. a genuine 404) are not
retried, since a retry won't change the answer.

Both are configurable via front matter:

```yaml
---
citation-http-timeout: 30   # seconds per attempt (default: 30)
citation-http-retries: 2    # retries after the first attempt (default: 2)
---
```

Retries happen immediately with no artificial delay, since each attempt is
already bounded by `citation-http-timeout` and Pandoc filters run
synchronously. Increase `citation-http-timeout` on slow links or corporate
proxies that add latency, and increase `citation-http-retries` on flaky
networks that intermittently drop connections. Set `citation-http-retries: 0`
to disable retries entirely.

---

## Combining with a hand-written bibliography

You can mix typed citekeys with entries in your own `.bib` or `.json`
bibliography. Both are passed to citeproc:

```yaml
---
bibliography: references.bib
filters:
  - pandoc-cite
---
```

Citations in `references.bib` use their usual keys; typed-prefix citations
are resolved automatically and appended to the bibliography list.

---

## Advanced: filter ordering

By default the filter runs before Quarto's built-in citeproc, which is
correct. If you have other custom filters, place `pandoc-cite` before any
filter that needs the resolved bibliography:

```yaml
filters:
  - pandoc-cite
  - my-other-filter
```

---

## API details

### DOI

Queries [doi.org](https://doi.org) with the HTTP header
`Accept: application/vnd.citationstyles.csl+json`, which triggers DOI
Content Negotiation and returns CSL JSON directly from the Registration
Agency (Crossref for most journals, DataCite for datasets, etc.).

### arXiv

Queries the [arXiv Atom API](https://arxiv.org/help/api/basics):

```
https://export.arxiv.org/api/query?id_list={id}
```

Returns an Atom/XML feed which is parsed with Lua patterns to extract
title, authors, abstract, publication date, and optional DOI.

### PubMed / PubMed Central

Uses the [NCBI Literature Citation Exporter](https://api.ncbi.nlm.nih.gov/lit/ctxp/):

```
https://api.ncbi.nlm.nih.gov/lit/ctxp/v1/pubmed/?id={pmid}&format=csl
https://api.ncbi.nlm.nih.gov/lit/ctxp/v1/pmc/?id={id}&format=csl
```

Both endpoints return CSL JSON directly.

### ISBN

1. Tries the [Wikipedia Citoid API](https://en.wikipedia.org/api/rest_v1/#/Citation/getCitation):
   `https://en.wikipedia.org/api/rest_v1/data/citation/mediawiki/{isbn}`
2. Falls back to the [Open Library Books API](https://openlibrary.org/dev/docs/api#anchor_api_books):
   `https://openlibrary.org/api/books?bibkeys=ISBN:{isbn}&format=json&jscmd=data`

### URL

1. Tries the [Wikipedia Citoid API](https://en.wikipedia.org/api/rest_v1/#/Citation/getCitation)
   (URL-encoded).
2. Falls back to a minimal entry containing just the URL and access date.

### Wikidata

Queries the [Wikidata Entity Data API](https://www.wikidata.org/wiki/Wikidata:Data_access):

```
https://www.wikidata.org/wiki/Special:EntityData/{QID}.json
```

Extracts the English label as the title and inspects the `instance of`
(P31) claim to assign an appropriate CSL item type.

---

## Troubleshooting

**"could not resolve doi:…"** — `curl` couldn't reach the upstream API.
Check your network connection or proxy settings. Inspect the error by
running `curl -v "https://doi.org/..."` manually. Transient network
failures (timeouts, connection resets) are retried automatically — see
[HTTP timeout and retries](#http-timeout-and-retries) — so a warning here
means every attempt failed.

**No reference list appears** — Make sure `--citeproc` is being used.
Quarto enables it automatically when citations are present; for plain
Pandoc add `--citeproc` to your command.

**Stale cached data** — Delete the relevant file in `.citation-cache/`
to force a fresh fetch.

**Windows path issues** — The filter uses `pandoc.system.make_directory`
and `pandoc.path.join` for cross-platform compatibility. If you encounter
path problems, set `citation-cache` to a simple relative path with no
spaces.

---

## Running tests

```bash
# Unit tests (no internet required)
bash tests/run_tests.sh

# Integration tests (requires internet + Quarto)
bash tests/run_tests.sh --integration
```

Unit tests run via `pandoc lua tests/unit_tests.lua` and cover:

- String utilities (trim, urlencode, xml_unescape, safe_filename)
- Author name parsing, including Citoid-style `mediawiki_authors` normalization
- XML field extraction
- Citekey regex patterns, including prefix edge cases (`+`/`-`/`.` characters,
  missing colons, empty accessions, and accessions that themselves contain
  colons such as URLs)
- Bare-identifier citekey inference (`infer_prefix`)
- Crossref-to-CSL type normalization (`normalize_type`)
- Access-date construction (`today_date_parts`)
- Cache file path construction (`cache_item_path`, including custom cache
  directories)
- Wikidata `P31` (instance-of) to CSL item-type inference

Integration tests render `tests/integration.qmd` and verify that
the output HTML contains content from each citation type. A second
document, `tests/custom-style.qmd`, renders the same kind of typed
citekeys (`doi:`, `arxiv:`, `url:`) with a non-default numeric CSL style
(`tests/ieee.csl`, vendored from the
[CSL styles repository](https://github.com/citation-style-language/styles),
CC-BY-SA licensed) to confirm pandoc-cite doesn't interfere with citeproc's
own style handling — citations render as `[1]`-style numeric markers
instead of author-date text.

---

## Differences from manubot-cite

| Feature                   | manubot-cite               | pandoc-cite                   |
| ------------------------- | -------------------------- | ----------------------------- |
| Runtime                   | Python                     | Pure Lua + curl               |
| CURIE prefixes            | 700+ biological DBs        | Not supported                 |
| Zotero translation server | Yes (primary for URL/ISBN) | No (uses Citoid)              |
| Unpaywall integration     | Yes                        | No                            |
| Short DOI support         | Yes                        | Handled by doi.org redirect   |
| Citation pruning          | Yes (`--prune-csl`)        | No                            |
| Citekey inference         | Yes (broad)                | Partial (bare DOI + bare arXiv id only; no bare PMID/ISBN inference) |
| Wikidata                  | Yes                        | Yes                           |

---

## License

MIT
