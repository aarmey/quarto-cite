-- pandoc-cite.lua
-- Quarto/Pandoc Lua filter for automatic bibliography resolution.
-- Resolves citation keys with typed prefixes (doi:, arxiv:, pmid:, pmcid:,
-- isbn:, url:, wikidata:) by fetching CSL JSON metadata from public APIs,
-- caching results locally, and injecting them into the document bibliography
-- so Pandoc's built-in citeproc can render them.
--
-- Requires: Pandoc >= 3.1, curl on PATH, internet access for uncached keys.

local system = require("pandoc.system")
local path   = require("pandoc.path")

-- ---------------------------------------------------------------------------
-- Configuration (overridable via document metadata)
-- ---------------------------------------------------------------------------

local DEFAULT_CACHE_DIR = ".citation-cache"
local CACHE_DIR         = DEFAULT_CACHE_DIR   -- may be updated from meta
local BIB_FILENAME      = "pandoc-cite-bibliography.json"

local SUPPORTED_PREFIXES = {
  doi      = true,
  arxiv    = true,
  pmid     = true,
  pmcid    = true,
  isbn     = true,
  url      = true,
  wikidata = true,
  http     = true,   -- bare http://… citekeys
  https    = true,   -- bare https://… citekeys
}

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
  return s
    :gsub("&amp;",  "&")
    :gsub("&lt;",   "<")
    :gsub("&gt;",   ">")
    :gsub("&quot;", '"')
    :gsub("&apos;", "'")
end

-- Make a filesystem-safe filename component from an arbitrary string.
local function safe_filename(s)
  return tostring(s):gsub("[^%w%.%-]", "_"):sub(1, 180)
end

-- ---------------------------------------------------------------------------
-- HTTP
-- ---------------------------------------------------------------------------

-- Run curl and return the response body, or nil on error.
local function http_get(url, headers)
  local args = {"-sS", "-L", "--max-time", "30"}
  if headers then
    for k, v in pairs(headers) do
      args[#args + 1] = "-H"
      args[#args + 1] = k .. ": " .. v
    end
  end
  args[#args + 1] = "--"
  args[#args + 1] = url
  local ok, result = pcall(pandoc.pipe, "curl", args, "")
  if ok and result and result ~= "" then
    return result
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- Cache
-- ---------------------------------------------------------------------------

local function cache_item_path(prefix, accession)
  local subdir = path.join({CACHE_DIR, prefix})
  return path.join({subdir, safe_filename(accession) .. ".json"})
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
  local subdir = path.join({CACHE_DIR, prefix})
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
  if family then
    return {family = trim(family), given = trim(given)}
  end
  -- "Given Family" — last token is family
  local parts = {}
  for tok in name:gmatch("%S+") do parts[#parts + 1] = tok end
  if #parts == 1 then
    return {family = parts[1]}
  elseif #parts >= 2 then
    local fam = table.remove(parts)
    return {family = fam, given = table.concat(parts, " ")}
  end
  return {literal = name}
end

local function mediawiki_authors(author_list)
  if type(author_list) ~= "table" then return {} end
  local out = {}
  for _, a in ipairs(author_list) do
    if type(a) == "table" then
      local entry = {}
      entry.family = a.last or a.family
      entry.given  = a.first or a.given
      if not entry.family and a.name then
        entry = parse_name(a.name)
      end
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
  ["journal-article"]       = "article-journal",
  ["proceedings-article"]   = "paper-conference",
  ["book-chapter"]          = "chapter",
  ["book-section"]          = "chapter",
  ["book-part"]             = "chapter",
  ["edited-book"]           = "book",
  ["reference-book"]        = "book",
  ["monograph"]             = "book",
  ["dissertation"]          = "thesis",
  ["dataset"]               = "dataset",
  ["posted-content"]        = "article",  -- preprint
  ["report"]                = "report",
  ["standard"]              = "standard",
  ["peer-review"]           = "review",
  ["other"]                 = "document",
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
  local url    = "https://doi.org/" .. doi
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
  local url     = "https://export.arxiv.org/api/query?id_list=" .. base_id
  local result  = http_get(url, {})
  if not result then return nil end

  local entry = result:match("<entry>(.-)</entry>")
  if not entry then return nil end

  local title     = xml_extract(entry, "title")
  local published = xml_extract(entry, "published")
  local abstract  = xml_extract(entry, "summary")
  local doi       = xml_extract(entry, "doi")

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
  local id_url  = xml_extract(entry, "id")
  local canon   = (id_url and id_url:match("abs/(.+)$")) or arxiv_id

  local item = {
    type               = "article",
    title              = title,
    author             = authors,
    abstract           = abstract,
    ["container-title"] = "arXiv",
    publisher          = "arXiv",
    URL                = "https://arxiv.org/abs/" .. canon,
    number             = canon,
  }
  if doi then item.DOI = doi end
  if year then
    item.issued = {["date-parts"] = {{tonumber(year), tonumber(month), tonumber(day)}}}
  end
  return item
end

-- ---------------------------------------------------------------------------
-- PubMed handler
-- API: https://api.ncbi.nlm.nih.gov/lit/ctxp/v1/pubmed/?id={pmid}&format=csl
-- Returns CSL JSON directly.
-- ---------------------------------------------------------------------------

local function fetch_pmid(pmid)
  local url    = "https://api.ncbi.nlm.nih.gov/lit/ctxp/v1/pubmed/?id=" .. pmid .. "&format=csl"
  local result = http_get(url, {})
  if not result then return nil end
  local ok, data = pcall(pandoc.json.decode, result)
  if ok and type(data) == "table" and not data.error then
    return data
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- PubMed Central handler
-- ---------------------------------------------------------------------------

local function fetch_pmcid(pmcid)
  local id = pmcid:match("^PMC(.+)$") or pmcid
  local url    = "https://api.ncbi.nlm.nih.gov/lit/ctxp/v1/pmc/?id=" .. id .. "&format=csl"
  local result = http_get(url, {})
  if not result then return nil end
  local ok, data = pcall(pandoc.json.decode, result)
  if ok and type(data) == "table" and not data.error then
    return data
  end
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
  local result     = http_get(citoid_url, {["Accept"] = "application/json"})
  if result then
    local ok, data = pcall(pandoc.json.decode, result)
    if ok and type(data) == "table" then
      local d = data[1] or data
      if type(d) == "table" and not d.error and d.title ~= "Not found." then
        local year
        if d.date then year = d.date:match("(%d%d%d%d)") end
        local item = {
          type              = "book",
          title             = d.title,
          author            = mediawiki_authors(d.author),
          publisher         = d.publisher,
          ["publisher-place"] = d.place,
          edition           = d.edition,
          ISBN              = isbn,
        }
        if year then item.issued = {["date-parts"] = {{tonumber(year)}}} end
        return item
      end
    end
  end

  -- Fallback: OpenLibrary
  local ol_url = "https://openlibrary.org/api/books?bibkeys=ISBN:" .. clean .. "&format=json&jscmd=data"
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
        if entry.publish_date then
          year = entry.publish_date:match("(%d%d%d%d)")
        end
        local item = {
          type      = "book",
          title     = entry.title,
          author    = authors,
          publisher = entry.publishers and entry.publishers[1] and entry.publishers[1].name,
          ISBN      = isbn,
          URL       = entry.url,
        }
        if year then item.issued = {["date-parts"] = {{tonumber(year)}}} end
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
  return {{t.year, t.month, t.mday}}
end

local function fetch_url(url_str)
  -- Try Citoid
  local encoded    = urlencode(url_str)
  local citoid_url = "https://en.wikipedia.org/api/rest_v1/data/citation/mediawiki/" .. encoded
  local result     = http_get(citoid_url, {["Accept"] = "application/json"})
  if result then
    local ok, data = pcall(pandoc.json.decode, result)
    if ok and type(data) == "table" then
      local d = data[1] or data
      if type(d) == "table" and not d.error and d.title ~= "Not found." then
        local year
        if d.date then year = d.date:match("(%d%d%d%d)") end
        local item = {
          type               = d.itemType or "webpage",
          title              = d.title,
          author             = mediawiki_authors(d.author),
          URL                = url_str,
          ["container-title"] = d.websiteTitle or d["container-title"],
          accessed           = {["date-parts"] = today_date_parts()},
        }
        if year then item.issued = {["date-parts"] = {{tonumber(year)}}} end
        return item
      end
    end
  end

  -- Fallback
  return {
    type     = "webpage",
    URL      = url_str,
    accessed = {["date-parts"] = today_date_parts()},
  }
end

-- ---------------------------------------------------------------------------
-- Wikidata handler
-- API: https://www.wikidata.org/wiki/Special:EntityData/{QID}.json
-- ---------------------------------------------------------------------------

local function fetch_wikidata(qid)
  local url    = "https://www.wikidata.org/wiki/Special:EntityData/" .. qid .. ".json"
  local result = http_get(url, {["Accept"] = "application/json"})
  if not result then return nil end
  local ok, data = pcall(pandoc.json.decode, result)
  if not ok then return nil end

  local entity = data.entities and data.entities[qid]
  if not entity then return nil end

  -- English label as title
  local labels = entity.labels or {}
  local title  = (labels.en and labels.en.value)
  if not title then
    for _, v in pairs(labels) do title = v.value; break end
  end

  -- Type from instanceOf (P31)
  local csl_type = "entry"
  local claims   = entity.claims or {}
  local p31      = claims.P31
  if p31 and p31[1] then
    local v = p31[1].mainsnak and p31[1].mainsnak.datavalue
    if v and v.type == "wikibase-entityid" then
      local id = v.value["numeric-id"]
      -- Q571=book, Q13442814=scholarly article, Q732577=publication
      local book_types    = {[571]=true, [3331189]=true}
      local article_types = {[13442814]=true, [191067]=true}
      if book_types[id]    then csl_type = "book"    end
      if article_types[id] then csl_type = "article-journal" end
    end
  end

  return {
    type      = csl_type,
    title     = title or qid,
    URL       = "https://www.wikidata.org/wiki/" .. qid,
    publisher = "Wikidata",
  }
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
  end

  if item then
    cache_write(prefix, accession, item)
  end
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
    combined = csl_items   -- existing refs handled separately below
  end

  local yaml_src  = "---\nreferences: " .. json_str .. "\n---\n"
  local ok2, tmp_doc = pcall(pandoc.read, yaml_src, "markdown")
  if not ok2 or not tmp_doc.meta.references then return nil end

  local refs = tmp_doc.meta.references   -- MetaList from the JSON round-trip

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
  local bib_path = path.join({CACHE_DIR, BIB_FILENAME})
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

  -- Collect all Cite nodes
  local seen     = {}
  local citekeys = {}   -- ordered list for deterministic output

  doc:walk({
    Cite = function(el)
      for _, citation in ipairs(el.citations) do
        local id = citation.id
        if not seen[id] then
          local prefix, accession = id:match("^([a-z][a-z%+%-%.]*):(.*)")
          if prefix and SUPPORTED_PREFIXES[prefix] then
            seen[id] = true
            citekeys[#citekeys + 1] = {id = id, prefix = prefix, accession = accession}
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
  if refs_meta then
    meta.references = refs_meta
  end

  -- Run citeproc now so citations are resolved before Quarto's own pass.
  -- Quarto's citeproc sees already-formatted inline spans and is a no-op.
  local processed = pandoc.utils.citeproc(pandoc.Pandoc(doc.blocks, meta))
  return processed
end
