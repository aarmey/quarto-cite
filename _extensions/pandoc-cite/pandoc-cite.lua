-- pandoc-cite.lua
-- Quarto/Pandoc Lua filter for automatic bibliography resolution.
-- Resolves citation keys with typed prefixes (doi:, arxiv:, pmid:, pmcid:,
-- isbn:, url:, wikidata:) by fetching CSL JSON metadata from public APIs,
-- caching results locally, and injecting them into the document bibliography
-- so Pandoc's built-in citeproc can render them.
--
-- Any other syntactically valid prefix (e.g. `uniprot:`, `chebi:`, `pdb:`)
-- is treated as a generic CURIE and resolved as a fallback via the
-- identifiers.org resolution service (see fetch_curie below).
--
-- Requires: Pandoc >= 3.1, curl on PATH, internet access for uncached keys.

local system = require("pandoc.system")
local path = require("pandoc.path")

-- ---------------------------------------------------------------------------
-- Configuration (overridable via document metadata)
-- ---------------------------------------------------------------------------

local DEFAULT_CACHE_DIR = ".citation-cache"
local CACHE_DIR = DEFAULT_CACHE_DIR -- may be updated from meta
local BIB_FILENAME = "pandoc-cite-bibliography.json"

-- Per-attempt curl timeout (seconds) and number of retries after the first
-- attempt. Both may be overridden via document metadata (see Pandoc(doc)).
local DEFAULT_HTTP_TIMEOUT = 30
local DEFAULT_HTTP_RETRIES = 2
local HTTP_TIMEOUT = DEFAULT_HTTP_TIMEOUT -- may be updated from meta
local HTTP_RETRIES = DEFAULT_HTTP_RETRIES -- may be updated from meta

-- Prefixes with a dedicated, high-quality handler in fetch_citekey below:
-- doi, arxiv, pmid, pmcid, isbn, url, wikidata, and bare http(s) citekeys.
-- Any other syntactically valid prefix falls through to the generic CURIE
-- resolver (fetch_curie), which is lower quality (generic URL/Citoid
-- resolution rather than a database-specific API). See the `Cite` walker
-- in `Pandoc(doc)` for where prefixes are accepted.

-- ---------------------------------------------------------------------------
-- Utilities
-- ---------------------------------------------------------------------------

local function trim(s)
  if type(s) ~= "string" then return s end
  return s:match("^%s*(.-)%s*$")
end

local function urlencode(s)
  return s:gsub("[^%w%-_%.~]", function(c)
    return string.format("%%%02X", string.byte(c))
  end)
end

local function xml_unescape(s)
  if type(s) ~= "string" then return s end
  return s:gsub("&amp;", "&")
    :gsub("&lt;", "<")
    :gsub("&gt;", ">")
    :gsub("&quot;", '"')
    :gsub("&apos;", "'")
end

-- Make a filesystem-safe filename component from an arbitrary string.
local function safe_filename(s)
  return tostring(s):gsub("[^%w%.%-]", "_"):sub(1, 180)
end

-- Parse a positive integer out of a metadata value (already stringified, or
-- nil). Falls back to `default` if the value is nil, empty, not a valid
-- integer, or not positive (retries of 0 are allowed; timeouts of 0 are not
-- useful and also fall back). Pure function, no I/O — kept separate from
-- metadata plumbing so it can be unit tested directly.
local function parse_positive_int(value, default, allow_zero)
  if value == nil then return default end
  local s = trim(tostring(value))
  if s == "" then return default end
  local n = tonumber(s)
  if not n then return default end
  n = math.floor(n)
  if n < 0 then return default end
  if n == 0 and not allow_zero then return default end
  return n
end

-- Given the attempt number that just failed (1-based) and the configured
-- number of retries (attempts allowed *after* the first try), decide
-- whether another attempt should be made. Pure function so it can be unit
-- tested without mocking pandoc.pipe.
local function should_retry(attempt, max_retries)
  return attempt <= max_retries
end

-- ---------------------------------------------------------------------------
-- Citekey inference
--
-- Bare identifiers (no `prefix:` at all) can sometimes be unambiguously
-- classified from their shape alone, mirroring a small subset of
-- manubot-cite's citekey inference. This is intentionally conservative:
-- it must never misfire on an ordinary hand-written citeproc key (e.g.
-- `smith2023`) since this filter is designed to coexist with a
-- hand-written .bib bibliography (see README, "Combining with a
-- hand-written bibliography").
--
-- Supported:
--   * Bare DOI:   10.<registrant>/<suffix>            -> prefix "doi"
--   * Bare arXiv: YYMM.NNNNN[vN] (new-style, 2007+)   -> prefix "arxiv"
--
-- Intentionally NOT supported (too ambiguous without more context):
--   * Bare PMIDs / ISBNs / other plain digit runs — a bare number could
--     be a PMID, an ISBN-10/13 digit run, a plain year, or an ordinary
--     citekey. manubot itself requires additional context to disambiguate
--     these, so we don't attempt it here.
--   * Old-style arXiv IDs (e.g. "hep-th/9901001") — these look enough
--     like a "prefix/accession" citekey that mistakenly matching them
--     carries meaningful collision risk; use the explicit `arxiv:` prefix.
--   * Bare http(s):// URLs — these are already handled: the existing
--     `^([a-z][a-z%+%-%.]*):(.*)` regex in the Cite walker matches
--     "https" or "http" as the prefix directly (both are already in
--     SUPPORTED_PREFIXES), so no inference step is needed for URLs.
-- ---------------------------------------------------------------------------

local function infer_prefix(id)
  if type(id) ~= "string" or id == "" then return nil end

  -- Bare DOI: 10.<digits>/<non-whitespace suffix>
  if id:match("^10%.%d+/%S+$") then return "doi", id end

  -- Bare arXiv new-style ID: YYMM.NNNNN or YYMM.NNNNNN, optional vN suffix
  if id:match("^%d%d%d%d%.%d%d%d%d%d?v?%d*$") then return "arxiv", id end

  return nil
end

-- ---------------------------------------------------------------------------
-- HTTP
-- ---------------------------------------------------------------------------

-- Run curl and return the response body, or nil on error.
--
-- Retries only cover curl/pcall-level failures (network errors, connection
-- resets, timeouts) — i.e. cases where curl exits non-zero and pandoc.pipe
-- raises. The current invocation does not pass `--fail`, so curl exits 0 on
-- HTTP error responses (e.g. 404) and returns the error body as `result`;
-- those are treated as "not found" by the downstream JSON/type checks in
-- each fetch_* function and are correctly NOT retried here, since retrying
-- a 404 would just waste time. There is no artificial sleep between
-- retries: curl's own `--max-time` already bounds each attempt, and a
-- Pandoc filter runs synchronously, so keeping retries immediate avoids
-- adding extra wall-clock delay on top of already-slow networks.
local function http_get(url, headers)
  local args = { "-sS", "-L", "--max-time", tostring(HTTP_TIMEOUT) }
  if headers then
    for k, v in pairs(headers) do
      args[#args + 1] = "-H"
      args[#args + 1] = k .. ": " .. v
    end
  end
  args[#args + 1] = "--"
  args[#args + 1] = url

  local attempt = 0
  while true do
    attempt = attempt + 1
    local ok, result = pcall(pandoc.pipe, "curl", args, "")
    if ok and result and result ~= "" then return result end
    if not should_retry(attempt, HTTP_RETRIES) then return nil end
  end
end

-- ---------------------------------------------------------------------------
-- Cache
-- ---------------------------------------------------------------------------

local function cache_item_path(prefix, accession)
  local subdir = path.join({ CACHE_DIR, prefix })
  return path.join({ subdir, safe_filename(accession) .. ".json" })
end

local function cache_read(prefix, accession)
  local p = cache_item_path(prefix, accession)
  local f = io.open(p, "r")
  if not f then return nil end
  local content = f:read("*all")
  f:close()
  if not content or content == "" then return nil end
  local ok, data = pcall(pandoc.json.decode, content)
  if ok and type(data) == "table" then return data end
  return nil
end

local function cache_write(prefix, accession, data)
  local subdir = path.join({ CACHE_DIR, prefix })
  system.make_directory(subdir, true)
  local p = cache_item_path(prefix, accession)
  local ok, encoded = pcall(pandoc.json.encode, data)
  if not ok then return end
  local f = io.open(p, "w")
  if f then
    f:write(encoded)
    f:close()
  end
end

-- ---------------------------------------------------------------------------
-- Author name helpers
-- ---------------------------------------------------------------------------

local function parse_name(name)
  name = trim(name)
  if not name or name == "" then return nil end
  -- "Family, Given" format
  local family, given = name:match("^([^,]+),%s*(.+)$")
  if family then return { family = trim(family), given = trim(given) } end
  -- "Given Family" — last token is family
  local parts = {}
  for tok in name:gmatch("%S+") do
    parts[#parts + 1] = tok
  end
  if #parts == 1 then
    return { family = parts[1] }
  elseif #parts >= 2 then
    local fam = table.remove(parts)
    return { family = fam, given = table.concat(parts, " ") }
  end
  return { literal = name }
end

local function mediawiki_authors(author_list)
  if type(author_list) ~= "table" then return {} end
  local out = {}
  for _, a in ipairs(author_list) do
    if type(a) == "table" then
      local entry = {}
      entry.family = a.last or a.family
      entry.given = a.first or a.given
      if not entry.family and a.name then entry = parse_name(a.name) end
      if entry then out[#out + 1] = entry end
    elseif type(a) == "string" then
      local entry = parse_name(a)
      if entry then out[#out + 1] = entry end
    end
  end
  return out
end

-- ---------------------------------------------------------------------------
-- Type normalisation: Crossref / other APIs use non-CSL type names.
-- Map them to the canonical CSL item types.
-- ---------------------------------------------------------------------------

local CROSSREF_TO_CSL_TYPE = {
  ["journal-article"] = "article-journal",
  ["proceedings-article"] = "paper-conference",
  ["book-chapter"] = "chapter",
  ["book-section"] = "chapter",
  ["book-part"] = "chapter",
  ["edited-book"] = "book",
  ["reference-book"] = "book",
  ["monograph"] = "book",
  ["dissertation"] = "thesis",
  ["dataset"] = "dataset",
  ["posted-content"] = "article", -- preprint
  ["report"] = "report",
  ["standard"] = "standard",
  ["peer-review"] = "review",
  ["other"] = "document",
}

local function normalize_type(t)
  if type(t) ~= "string" then return t end
  return CROSSREF_TO_CSL_TYPE[t] or t
end

-- ---------------------------------------------------------------------------
-- DOI handler
-- API: https://doi.org/{doi} with Accept: application/vnd.citationstyles.csl+json
-- Returns CSL JSON directly.
-- ---------------------------------------------------------------------------

local function fetch_doi(doi)
  local url = "https://doi.org/" .. doi
  local result = http_get(url, {
    ["Accept"] = "application/vnd.citationstyles.csl+json",
  })
  if not result then return nil end
  local ok, data = pcall(pandoc.json.decode, result)
  if ok and type(data) == "table" and not data.error then
    data.type = normalize_type(data.type)
    return data
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- arXiv handler
-- API: https://export.arxiv.org/api/query?id_list={id}  (Atom/XML)
-- ---------------------------------------------------------------------------

local function xml_extract(xml, tag)
  -- handles optional namespace prefix and attributes, e.g. <arxiv:doi xmlns:...> or <doi>
  local patterns = {
    "<" .. tag .. "[^>]*>(.-)</" .. tag .. ">",
    "<[^:]+:" .. tag .. "[^>]*>(.-)</[^:]+:" .. tag .. ">",
  }
  for _, pat in ipairs(patterns) do
    local m = xml:match(pat)
    if m then return trim(xml_unescape(m)) end
  end
  return nil
end

local function fetch_arxiv(arxiv_id)
  -- Strip trailing version for canonical URL but keep for API query
  local base_id = arxiv_id:match("^(.-)v%d+$") or arxiv_id
  local url = "https://export.arxiv.org/api/query?id_list=" .. base_id
  local result = http_get(url, {})
  if not result then return nil end

  local entry = result:match("<entry>(.-)</entry>")
  if not entry then return nil end

  local title = xml_extract(entry, "title")
  local published = xml_extract(entry, "published")
  local abstract = xml_extract(entry, "summary")
  local doi = xml_extract(entry, "doi")

  -- Parse date
  local year, month, day
  if published then
    year, month, day = published:match("(%d%d%d%d)-(%d%d)-(%d%d)")
  end

  -- Authors
  local authors = {}
  for author_block in entry:gmatch("<author>(.-)</author>") do
    local name_str = xml_extract(author_block, "name")
    if name_str then
      local parsed = parse_name(name_str)
      if parsed then authors[#authors + 1] = parsed end
    end
  end

  -- Canonical arXiv ID from <id> element
  local id_url = xml_extract(entry, "id")
  local canon = (id_url and id_url:match("abs/(.+)$")) or arxiv_id

  local item = {
    type = "article",
    title = title,
    author = authors,
    abstract = abstract,
    ["container-title"] = "arXiv",
    publisher = "arXiv",
    URL = "https://arxiv.org/abs/" .. canon,
    number = canon,
  }
  if doi then item.DOI = doi end
  if year then
    item.issued = { ["date-parts"] = { { tonumber(year), tonumber(month), tonumber(day) } } }
  end
  return item
end

-- ---------------------------------------------------------------------------
-- PubMed handler
-- API: https://api.ncbi.nlm.nih.gov/lit/ctxp/v1/pubmed/?id={pmid}&format=csl
-- Returns CSL JSON directly.
-- ---------------------------------------------------------------------------

local function fetch_pmid(pmid)
  local url = "https://api.ncbi.nlm.nih.gov/lit/ctxp/v1/pubmed/?id=" .. pmid .. "&format=csl"
  local result = http_get(url, {})
  if not result then return nil end
  local ok, data = pcall(pandoc.json.decode, result)
  if ok and type(data) == "table" and not data.error then return data end
  return nil
end

-- ---------------------------------------------------------------------------
-- PubMed Central handler
-- ---------------------------------------------------------------------------

local function fetch_pmcid(pmcid)
  local id = pmcid:match("^PMC(.+)$") or pmcid
  local url = "https://api.ncbi.nlm.nih.gov/lit/ctxp/v1/pmc/?id=" .. id .. "&format=csl"
  local result = http_get(url, {})
  if not result then return nil end
  local ok, data = pcall(pandoc.json.decode, result)
  if ok and type(data) == "table" and not data.error then return data end
  return nil
end

-- ---------------------------------------------------------------------------
-- ISBN handler
-- Primary: Wikipedia Citoid API
-- Fallback: OpenLibrary
-- ---------------------------------------------------------------------------

local function fetch_isbn(isbn)
  local clean = isbn:gsub("[%-%s]", "")

  -- Try Wikipedia Citoid
  local citoid_url = "https://en.wikipedia.org/api/rest_v1/data/citation/mediawiki/" .. clean
  local result = http_get(citoid_url, { ["Accept"] = "application/json" })
  if result then
    local ok, data = pcall(pandoc.json.decode, result)
    if ok and type(data) == "table" then
      local d = data[1] or data
      if type(d) == "table" and not d.error and d.title ~= "Not found." then
        local year
        if d.date then year = d.date:match("(%d%d%d%d)") end
        local item = {
          type = "book",
          title = d.title,
          author = mediawiki_authors(d.author),
          publisher = d.publisher,
          ["publisher-place"] = d.place,
          edition = d.edition,
          ISBN = isbn,
        }
        if year then item.issued = { ["date-parts"] = { { tonumber(year) } } } end
        return item
      end
    end
  end

  -- Fallback: OpenLibrary
  local ol_url = "https://openlibrary.org/api/books?bibkeys=ISBN:"
    .. clean
    .. "&format=json&jscmd=data"
  result = http_get(ol_url, {})
  if result then
    local ok, data = pcall(pandoc.json.decode, result)
    if ok and type(data) == "table" then
      local entry = data["ISBN:" .. clean]
      if entry and type(entry) == "table" then
        local authors = {}
        if entry.authors then
          for _, a in ipairs(entry.authors) do
            local parsed = parse_name(a.name or "")
            if parsed then authors[#authors + 1] = parsed end
          end
        end
        local year
        if entry.publish_date then year = entry.publish_date:match("(%d%d%d%d)") end
        local item = {
          type = "book",
          title = entry.title,
          author = authors,
          publisher = entry.publishers and entry.publishers[1] and entry.publishers[1].name,
          ISBN = isbn,
          URL = entry.url,
        }
        if year then item.issued = { ["date-parts"] = { { tonumber(year) } } } end
        return item
      end
    end
  end

  return nil
end

-- ---------------------------------------------------------------------------
-- URL handler
-- Primary: Wikipedia Citoid
-- Fallback: minimal entry with URL and access date
-- ---------------------------------------------------------------------------

local function today_date_parts()
  local t = os.date("*t")
  return { { t.year, t.month, t.mday } }
end

local function fetch_url(url_str)
  -- Try Citoid
  local encoded = urlencode(url_str)
  local citoid_url = "https://en.wikipedia.org/api/rest_v1/data/citation/mediawiki/" .. encoded
  local result = http_get(citoid_url, { ["Accept"] = "application/json" })
  if result then
    local ok, data = pcall(pandoc.json.decode, result)
    if ok and type(data) == "table" then
      local d = data[1] or data
      if type(d) == "table" and not d.error and d.title ~= "Not found." then
        local year
        if d.date then year = d.date:match("(%d%d%d%d)") end
        local item = {
          type = d.itemType or "webpage",
          title = d.title,
          author = mediawiki_authors(d.author),
          URL = url_str,
          ["container-title"] = d.websiteTitle or d["container-title"],
          accessed = { ["date-parts"] = today_date_parts() },
        }
        if year then item.issued = { ["date-parts"] = { { tonumber(year) } } } end
        return item
      end
    end
  end

  -- Fallback
  return {
    type = "webpage",
    URL = url_str,
    accessed = { ["date-parts"] = today_date_parts() },
  }
end

-- ---------------------------------------------------------------------------
-- Wikidata handler
-- API: https://www.wikidata.org/wiki/Special:EntityData/{QID}.json
-- ---------------------------------------------------------------------------

local function fetch_wikidata(qid)
  local url = "https://www.wikidata.org/wiki/Special:EntityData/" .. qid .. ".json"
  local result = http_get(url, { ["Accept"] = "application/json" })
  if not result then return nil end
  local ok, data = pcall(pandoc.json.decode, result)
  if not ok then return nil end

  local entity = data.entities and data.entities[qid]
  if not entity then return nil end

  -- English label as title
  local labels = entity.labels or {}
  local title = (labels.en and labels.en.value)
  if not title then
    for _, v in pairs(labels) do
      title = v.value
      break
    end
  end

  -- Type from instanceOf (P31)
  local csl_type = "entry"
  local claims = entity.claims or {}
  local p31 = claims.P31
  if p31 and p31[1] then
    local v = p31[1].mainsnak and p31[1].mainsnak.datavalue
    if v and v.type == "wikibase-entityid" then
      local id = v.value["numeric-id"]
      -- Q571=book, Q13442814=scholarly article, Q732577=publication
      local book_types = { [571] = true, [3331189] = true }
      local article_types = { [13442814] = true, [191067] = true }
      if book_types[id] then csl_type = "book" end
      if article_types[id] then csl_type = "article-journal" end
    end
  end

  return {
    type = csl_type,
    title = title or qid,
    URL = "https://www.wikidata.org/wiki/" .. qid,
    publisher = "Wikidata",
  }
end

-- ---------------------------------------------------------------------------
-- Generic CURIE handler (fallback for any prefix without a dedicated
-- handler above).
--
-- identifiers.org (https://identifiers.org) maintains a registry of ~700
-- biological/scientific database prefixes and resolves `prefix:accession`
-- CURIEs to the canonical resource page via an HTTP redirect. We resolve
-- the CURIE to its canonical URL, then reuse the existing `fetch_url`
-- pipeline (Wikipedia Citoid, falling back to a minimal webpage entry) to
-- produce a CSL entry.
--
-- This is intentionally lower-quality than the dedicated handlers above:
-- it depends on (a) identifiers.org recognising the prefix/accession, and
-- (b) the resolved target page being scrapeable by Citoid. If identifiers.org
-- does not recognise the CURIE (no redirect / non-200), we return nil so the
-- citation is reported unresolved, matching the behaviour of any other
-- failed fetch.
-- ---------------------------------------------------------------------------

local function fetch_curie(prefix, accession)
  local ident_url = "https://identifiers.org/" .. prefix .. ":" .. accession
  local args = {
    "-sS",
    "-L",
    "--max-time",
    "20",
    "-o",
    "/dev/null",
    "-w",
    "%{http_code} %{url_effective}",
    "--",
    ident_url,
  }
  local ok, result = pcall(pandoc.pipe, "curl", args, "")
  if not ok or not result or result == "" then return nil end

  local code, resolved_url = result:match("^(%d+)%s+(.+)$")
  if not code or code ~= "200" or not resolved_url or resolved_url == "" then return nil end

  return fetch_url(trim(resolved_url))
end

-- ---------------------------------------------------------------------------
-- Dispatcher
-- ---------------------------------------------------------------------------

local function fetch_citekey(prefix, accession)
  local cached = cache_read(prefix, accession)
  if cached then return cached, true end

  local item
  if prefix == "doi" then
    item = fetch_doi(accession)
  elseif prefix == "arxiv" then
    item = fetch_arxiv(accession)
  elseif prefix == "pmid" then
    item = fetch_pmid(accession)
  elseif prefix == "pmcid" then
    item = fetch_pmcid(accession)
  elseif prefix == "isbn" then
    item = fetch_isbn(accession)
  elseif prefix == "url" then
    item = fetch_url(accession)
  elseif prefix == "http" or prefix == "https" then
    item = fetch_url(prefix .. ":" .. accession)
  elseif prefix == "wikidata" then
    item = fetch_wikidata(accession)
  else
    -- Unknown prefix: fall back to generic CURIE resolution via
    -- identifiers.org.
    item = fetch_curie(prefix, accession)
  end

  if item then cache_write(prefix, accession, item) end
  return item, false
end

-- ---------------------------------------------------------------------------
-- Build a Pandoc `references` metadata value from CSL items.
--
-- We serialise the items as JSON (which is valid YAML), embed them in a
-- throwaway markdown document, parse it with pandoc.read(), and extract the
-- `references` field.  This guarantees that citeproc sees the same metadata
-- structure that it would get from a YAML front-matter block, including
-- proper handling of numeric date-parts.
-- ---------------------------------------------------------------------------

local function build_references_meta(csl_items, existing_meta_refs)
  local ok, json_str = pcall(pandoc.json.encode, csl_items)
  if not ok then return nil end

  -- Inline any pre-existing references into the same list.
  local combined = csl_items
  if existing_meta_refs and existing_meta_refs.t == "MetaList" then
    -- existing_meta_refs is already in MetaValue form; we can't easily merge
    -- with our JSON list, so we let the round-trip handle only new items and
    -- merge at the MetaList level afterwards.
    combined = csl_items -- existing refs handled separately below
  end

  local yaml_src = "---\nreferences: " .. json_str .. "\n---\n"
  local ok2, tmp_doc = pcall(pandoc.read, yaml_src, "markdown")
  if not ok2 or not tmp_doc.meta.references then return nil end

  local refs = tmp_doc.meta.references -- MetaList from the JSON round-trip

  -- Prepend any pre-existing front-matter references
  if existing_meta_refs and existing_meta_refs.t == "MetaList" then
    local merged = pandoc.MetaList({})
    for i = 1, #existing_meta_refs do
      merged:insert(existing_meta_refs[i])
    end
    for i = 1, #refs do
      merged:insert(refs[i])
    end
    refs = merged
  end

  return refs
end

-- Write the combined CSL JSON to the cache (for inspection/reproducibility).
local function write_bib_cache(csl_items)
  system.make_directory(CACHE_DIR, true)
  local bib_path = path.join({ CACHE_DIR, BIB_FILENAME })
  local ok, encoded = pcall(pandoc.json.encode, csl_items)
  if not ok then return end
  local f = io.open(bib_path, "w")
  if f then
    f:write(encoded)
    f:close()
  end
end

-- ---------------------------------------------------------------------------
-- Main filter
-- ---------------------------------------------------------------------------

function Pandoc(doc)
  -- Read configuration from document metadata
  local meta = doc.meta
  if meta["citation-cache"] then
    local v = pandoc.utils.stringify(meta["citation-cache"])
    if v and v ~= "" then CACHE_DIR = v end
  end
  if meta["citation-http-timeout"] then
    HTTP_TIMEOUT = parse_positive_int(
      pandoc.utils.stringify(meta["citation-http-timeout"]),
      DEFAULT_HTTP_TIMEOUT
    )
  end
  if meta["citation-http-retries"] then
    HTTP_RETRIES = parse_positive_int(
      pandoc.utils.stringify(meta["citation-http-retries"]),
      DEFAULT_HTTP_RETRIES,
      true
    )
  end

  -- Collect all Cite nodes
  local seen = {}
  local citekeys = {} -- ordered list for deterministic output

  doc:walk({
    Cite = function(el)
      for _, citation in ipairs(el.citations) do
        local id = citation.id
        if not seen[id] then
          -- Accept any syntactically valid prefix. Known prefixes get a
          -- dedicated high-quality handler in fetch_citekey; anything else
          -- falls through to the generic CURIE resolver (identifiers.org).
          local prefix, accession = id:match("^([a-z][a-z%+%-%.]*):(.*)")
          if not prefix then
            -- No explicit `prefix:` found; try to confidently infer one
            -- from the bare identifier's shape (bare DOI / bare arXiv id).
            prefix, accession = infer_prefix(id)
          end
          if prefix then
            seen[id] = true
            citekeys[#citekeys + 1] = { id = id, prefix = prefix, accession = accession }
          end
        end
      end
    end,
  })

  if #citekeys == 0 then return doc end

  -- Resolve each citekey
  local csl_items = {}
  local n_fetched = 0

  for _, ck in ipairs(citekeys) do
    local item, from_cache = fetch_citekey(ck.prefix, ck.accession)
    if item then
      -- CSL id must match the citekey used in the document
      item.id = ck.id
      csl_items[#csl_items + 1] = item
      if not from_cache then n_fetched = n_fetched + 1 end
    else
      io.stderr:write("[pandoc-cite] WARNING: could not resolve " .. ck.id .. "\n")
    end
  end

  if #csl_items == 0 then return doc end

  if n_fetched > 0 then
    io.stderr:write("[pandoc-cite] Fetched " .. n_fetched .. " new citation(s)\n")
  end

  -- Persist combined CSL JSON to the cache directory for reproducibility
  write_bib_cache(csl_items)

  -- Build and inject references metadata. We use a pandoc.read() round-trip
  -- so that numeric date-parts and other structured values are encoded exactly
  -- as Pandoc's YAML parser would produce them (which citeproc expects).
  local refs_meta = build_references_meta(csl_items, meta.references)
  if refs_meta then meta.references = refs_meta end

  return pandoc.Pandoc(doc.blocks, meta)
end
