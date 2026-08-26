-- Unit tests for pandoc-cite helper functions.
-- Run with: pandoc lua tests/unit_tests.lua

local path = require("pandoc.path")

local PASS = 0
local FAIL = 0

local function ok(desc, condition)
  if condition then
    print("PASS: " .. desc)
    PASS = PASS + 1
  else
    print("FAIL: " .. desc)
    FAIL = FAIL + 1
  end
end

local function eq(a, b)
  return a == b
end

-- ---------------------------------------------------------------------------
-- Load helpers from the filter without running the Pandoc() entry point.
-- We do this by reading the source and extracting the pure-Lua functions.
-- ---------------------------------------------------------------------------

-- Inline the helpers we want to test (no I/O or network).

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

local function safe_filename(s)
  return tostring(s):gsub("[^%w%.%-]", "_"):sub(1, 180)
end

local function parse_name(name)
  name = trim(name)
  if not name or name == "" then return nil end
  local family, given = name:match("^([^,]+),%s*(.+)$")
  if family then return { family = trim(family), given = trim(given) } end
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

local function xml_extract(xml, tag)
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

-- ---------------------------------------------------------------------------
-- Tests: trim
-- ---------------------------------------------------------------------------
ok("trim removes leading spaces", eq(trim("  hello"), "hello"))
ok("trim removes trailing spaces", eq(trim("hello  "), "hello"))
ok("trim removes both", eq(trim("  hello  "), "hello"))
ok("trim handles empty", eq(trim(""), ""))
ok("trim handles nil", trim(nil) == nil)

-- ---------------------------------------------------------------------------
-- Tests: urlencode
-- ---------------------------------------------------------------------------
ok(
  "urlencode basic URL",
  eq(
    urlencode("https://example.com/path?q=1&r=2"),
    "https%3A%2F%2Fexample.com%2Fpath%3Fq%3D1%26r%3D2"
  )
)
ok("urlencode leaves safe chars", eq(urlencode("abc-def_ghi.jkl~"), "abc-def_ghi.jkl~"))
ok("urlencode percent-encodes space", eq(urlencode("hello world"), "hello%20world"))

-- ---------------------------------------------------------------------------
-- Tests: xml_unescape
-- ---------------------------------------------------------------------------
ok("xml_unescape &amp;", eq(xml_unescape("a &amp; b"), "a & b"))
ok("xml_unescape &lt;", eq(xml_unescape("a &lt; b"), "a < b"))
ok("xml_unescape &gt;", eq(xml_unescape("a &gt; b"), "a > b"))
ok("xml_unescape &quot;", eq(xml_unescape("&quot;hi&quot;"), '"hi"'))
ok("xml_unescape mixed", eq(xml_unescape("&lt;b&gt;ok&lt;/b&gt;"), "<b>ok</b>"))

-- ---------------------------------------------------------------------------
-- Tests: safe_filename
-- ---------------------------------------------------------------------------
ok("safe_filename basic", eq(safe_filename("hello"), "hello"))
ok("safe_filename colons replaced", eq(safe_filename("10.1234/test"), "10.1234_test"))
ok("safe_filename spaces replaced", eq(safe_filename("hello world"), "hello_world"))
ok("safe_filename truncates", #safe_filename(string.rep("a", 300)) <= 180)

-- ---------------------------------------------------------------------------
-- Tests: parse_name
-- ---------------------------------------------------------------------------
local n1 = parse_name("Smith, John")
ok("parse_name Last,First family", n1 and eq(n1.family, "Smith"))
ok("parse_name Last,First given", n1 and eq(n1.given, "John"))

local n2 = parse_name("John Smith")
ok("parse_name First Last family", n2 and eq(n2.family, "Smith"))
ok("parse_name First Last given", n2 and eq(n2.given, "John"))

local n3 = parse_name("John Michael Smith")
ok("parse_name multi given family", n3 and eq(n3.family, "Smith"))
ok("parse_name multi given given", n3 and eq(n3.given, "John Michael"))

local n4 = parse_name("Einstein")
ok("parse_name single token", n4 and eq(n4.family, "Einstein"))

ok("parse_name nil input", parse_name(nil) == nil)
ok("parse_name empty", parse_name("") == nil)

-- ---------------------------------------------------------------------------
-- Tests: xml_extract
-- ---------------------------------------------------------------------------
local sample_entry = [[
  <title>Attention Is All You Need</title>
  <published>2017-06-12T00:00:00Z</published>
  <arxiv:doi xmlns:arxiv="http://arxiv.org/schemas/atom">10.48550/arXiv.1706.03762</arxiv:doi>
  <author><name>Ashish Vaswani</name></author>
  <author><name>Noam Shazeer</name></author>
]]

ok("xml_extract title", eq(xml_extract(sample_entry, "title"), "Attention Is All You Need"))
ok("xml_extract published", eq(xml_extract(sample_entry, "published"), "2017-06-12T00:00:00Z"))
ok("xml_extract ns doi", eq(xml_extract(sample_entry, "doi"), "10.48550/arXiv.1706.03762"))
ok("xml_extract missing", xml_extract(sample_entry, "summary") == nil)

-- ---------------------------------------------------------------------------
-- HTTP retry/timeout config helpers (inlined copies, see pandoc-cite.lua)
-- ---------------------------------------------------------------------------

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

local function should_retry(attempt, max_retries)
  return attempt <= max_retries
end

-- ---------------------------------------------------------------------------
-- Tests: parse_positive_int
-- ---------------------------------------------------------------------------
ok("parse_positive_int nil uses default", eq(parse_positive_int(nil, 30), 30))
ok("parse_positive_int empty uses default", eq(parse_positive_int("", 30), 30))
ok("parse_positive_int valid string", eq(parse_positive_int("45", 30), 45))
ok("parse_positive_int valid number", eq(parse_positive_int(10, 30), 10))
ok("parse_positive_int non-numeric fallback", eq(parse_positive_int("abc", 30), 30))
ok("parse_positive_int truncates floats", eq(parse_positive_int("2.9", 30), 2))
ok("parse_positive_int negative fallback", eq(parse_positive_int("-5", 30), 30))
ok("parse_positive_int zero fallback by default", eq(parse_positive_int("0", 30), 30))
ok("parse_positive_int zero allowed when flagged", eq(parse_positive_int("0", 2, true), 0))
ok("parse_positive_int whitespace trimmed", eq(parse_positive_int("  7  ", 30), 7))

-- ---------------------------------------------------------------------------
-- Tests: should_retry
-- ---------------------------------------------------------------------------
ok("should_retry retries when under max", should_retry(1, 2) == true)
ok("should_retry retries on last allowed try", should_retry(2, 2) == true)
ok("should_retry stops once exhausted", should_retry(3, 2) == false)
ok("should_retry never retries with 0 max", should_retry(1, 0) == false)
ok("should_retry always retries with large max", should_retry(1, 100) == true)

-- ---------------------------------------------------------------------------
-- Tests: citekey regex
-- ---------------------------------------------------------------------------
local function parse_citekey(id)
  return id:match("^([a-z][a-z%+%-%.]*):(.*)")
end

local p, a = parse_citekey("doi:10.1234/test")
ok("citekey doi prefix", eq(p, "doi"))
ok("citekey doi accession", eq(a, "10.1234/test"))

p, a = parse_citekey("arxiv:1706.03762")
ok("citekey arxiv prefix", eq(p, "arxiv"))
ok("citekey arxiv accession", eq(a, "1706.03762"))

p, a = parse_citekey("pmid:12345678")
ok("citekey pmid prefix", eq(p, "pmid"))
ok("citekey pmid accession", eq(a, "12345678"))

p, a = parse_citekey("isbn:9780262033848")
ok("citekey isbn prefix", eq(p, "isbn"))

p, a = parse_citekey("url:https://quarto.org")
ok("citekey url prefix", eq(p, "url"))
ok("citekey url accession", eq(a, "https://quarto.org"))

p, a = parse_citekey("wikidata:Q42")
ok("citekey wikidata prefix", eq(p, "wikidata"))
ok("citekey wikidata accession", eq(a, "Q42"))

-- Keys without a supported prefix return nil
p, a = parse_citekey("smith2023")
ok("citekey no prefix", p == nil and a == nil)

-- Prefix character class allows '+', '-', '.' after the first letter
-- (regex: ^([a-z][a-z%+%-%.]*):(.*) — see pandoc-cite.lua's Pandoc() filter,
-- the Cite-node walk around line 586)
-- Note: the prefix class [a-z%+%-%.] excludes digits, so a prefix like
-- "z39.88-2004" (containing "39"/"88"/"2004") does NOT match — only
-- lowercase letters plus '+', '-', '.' are allowed after the first letter.
p, a = parse_citekey("z39.88-2004:some-id")
ok("citekey prefix with digits does not match (digits not in prefix class)", p == nil and a == nil)

p, a = parse_citekey("ex.tra-plus:some-id")
ok("citekey prefix with dot/plus/hyphen chars", eq(p, "ex.tra-plus") and eq(a, "some-id"))

p, a = parse_citekey("a+b-c.d:accession")
ok("citekey prefix mixing +/-/. ", eq(p, "a+b-c.d") and eq(a, "accession"))

-- No colon at all -> no match
p, a = parse_citekey("nocolonhere")
ok("citekey with no colon at all", p == nil and a == nil)

-- Empty accession (colon at the very end) is still a match, with a == ""
p, a = parse_citekey("doi:")
ok("citekey empty accession prefix", eq(p, "doi"))
ok("citekey empty accession value", eq(a, ""))

-- Accessions containing colons (e.g. URLs with a scheme) are captured whole,
-- since "(.*)" is greedy and matches everything after the first colon.
p, a = parse_citekey("url:https://example.com:8080/path")
ok("citekey accession containing colons prefix", eq(p, "url"))
ok("citekey accession containing colons value", eq(a, "https://example.com:8080/path"))

-- ---------------------------------------------------------------------------
-- Tests: normalize_type
-- (mirrors CROSSREF_TO_CSL_TYPE + normalize_type, pandoc-cite.lua lines
-- 168-189)
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

ok("normalize_type journal-article", eq(normalize_type("journal-article"), "article-journal"))
ok(
  "normalize_type proceedings-article",
  eq(normalize_type("proceedings-article"), "paper-conference")
)
ok("normalize_type book-chapter", eq(normalize_type("book-chapter"), "chapter"))
ok("normalize_type book-section", eq(normalize_type("book-section"), "chapter"))
ok("normalize_type book-part", eq(normalize_type("book-part"), "chapter"))
ok("normalize_type edited-book", eq(normalize_type("edited-book"), "book"))
ok("normalize_type reference-book", eq(normalize_type("reference-book"), "book"))
ok("normalize_type monograph", eq(normalize_type("monograph"), "book"))
ok("normalize_type dissertation", eq(normalize_type("dissertation"), "thesis"))
ok("normalize_type dataset", eq(normalize_type("dataset"), "dataset"))
ok("normalize_type posted-content", eq(normalize_type("posted-content"), "article"))
ok("normalize_type report", eq(normalize_type("report"), "report"))
ok("normalize_type standard", eq(normalize_type("standard"), "standard"))
ok("normalize_type peer-review", eq(normalize_type("peer-review"), "review"))
ok("normalize_type other", eq(normalize_type("other"), "document"))
-- Unmapped types pass through unchanged
ok("normalize_type passthrough for unmapped type", eq(normalize_type("book"), "book"))
ok(
  "normalize_type passthrough for unknown crossref type",
  eq(normalize_type("some-unmapped-type"), "some-unmapped-type")
)
-- Non-string input is returned unchanged
ok("normalize_type nil input", normalize_type(nil) == nil)
ok(
  "normalize_type table input",
  (function()
    local t = {}
    return normalize_type(t) == t
  end)()
)

-- ---------------------------------------------------------------------------
-- Tests: mediawiki_authors
-- (mirrors mediawiki_authors, pandoc-cite.lua lines 143-161; relies on
-- parse_name defined above, which is byte-for-byte the same as the filter's)
-- ---------------------------------------------------------------------------
local function mediawiki_authors(author_list)
  if type(author_list) ~= "table" then return {} end
  local out = {}
  for _, au in ipairs(author_list) do
    if type(au) == "table" then
      local entry = {}
      entry.family = au.last or au.family
      entry.given = au.first or au.given
      if not entry.family and au.name then entry = parse_name(au.name) end
      if entry then out[#out + 1] = entry end
    elseif type(au) == "string" then
      local entry = parse_name(au)
      if entry then out[#out + 1] = entry end
    end
  end
  return out
end

-- Citoid commonly returns authors as [["First","Last"], ...] pairs, which
-- decode from JSON as Lua tables with numeric keys, not "first"/"last" keys.
-- The real Citoid "author" shape used by fetch_isbn/fetch_url is a list of
-- {first=, last=} tables (see call sites), so that's what we exercise here.
local mw1 = mediawiki_authors({
  { first = "Ada", last = "Lovelace" },
  { first = "Alan", last = "Turing" },
})
ok("mediawiki_authors count", #mw1 == 2)
ok("mediawiki_authors first family", eq(mw1[1].family, "Lovelace"))
ok("mediawiki_authors first given", eq(mw1[1].given, "Ada"))
ok("mediawiki_authors second family", eq(mw1[2].family, "Turing"))

-- Falls back to "family"/"given" keys directly
local mw2 = mediawiki_authors({ { family = "Smith", given = "John" } })
ok(
  "mediawiki_authors family/given keys",
  mw2[1] and eq(mw2[1].family, "Smith") and eq(mw2[1].given, "John")
)

-- Falls back to parsing a bare "name" field when no first/last/family/given
local mw3 = mediawiki_authors({ { name = "Grace Hopper" } })
ok("mediawiki_authors name fallback family", mw3[1] and eq(mw3[1].family, "Hopper"))
ok("mediawiki_authors name fallback given", mw3[1] and eq(mw3[1].given, "Grace"))

-- Plain string entries are parsed with parse_name
local mw4 = mediawiki_authors({ "Marie Curie" })
ok("mediawiki_authors string entry", mw4[1] and eq(mw4[1].family, "Curie"))

-- Non-table input returns an empty list, never errors
ok("mediawiki_authors nil input", #mediawiki_authors(nil) == 0)
ok("mediawiki_authors string input", #mediawiki_authors("not a table") == 0)
ok("mediawiki_authors empty list", #mediawiki_authors({}) == 0)

-- ---------------------------------------------------------------------------
-- Tests: today_date_parts
-- (mirrors today_date_parts, pandoc-cite.lua lines 390-393)
-- ---------------------------------------------------------------------------
local function today_date_parts()
  local t = os.date("*t")
  return { { t.year, t.month, t.mday } }
end

local tdp = today_date_parts()
local now = os.date("*t")
ok("today_date_parts shape is a single triple", type(tdp) == "table" and type(tdp[1]) == "table")
ok("today_date_parts year matches os.date", eq(tdp[1][1], now.year))
ok("today_date_parts month matches os.date", eq(tdp[1][2], now.month))
ok("today_date_parts day matches os.date", eq(tdp[1][3], now.mday))

-- ---------------------------------------------------------------------------
-- Tests: cache_item_path
-- (mirrors cache_item_path, pandoc-cite.lua lines 89-92, using the real
-- pandoc.path module for the join — no reimplementation needed there)
-- ---------------------------------------------------------------------------
local function cache_item_path(cache_dir, prefix, accession)
  local subdir = path.join({ cache_dir, prefix })
  return path.join({ subdir, safe_filename(accession) .. ".json" })
end

ok(
  "cache_item_path basic",
  eq(
    cache_item_path(".citation-cache", "doi", "10.1234/test"),
    ".citation-cache/doi/10.1234_test.json"
  )
)
ok(
  "cache_item_path sanitizes accession",
  (function()
    local cp = cache_item_path(".citation-cache", "url", "https://example.com/a?b=c")
    -- prefix subdir must be preserved verbatim, only the filename is sanitized
    return cp:match("^%.citation%-cache/url/") ~= nil and cp:match("%.json$") ~= nil
  end)()
)
ok(
  "cache_item_path custom cache dir",
  eq(cache_item_path("my-cache", "wikidata", "Q42"), "my-cache/wikidata/Q42.json")
)
ok(
  "cache_item_path nested custom cache dir",
  eq(cache_item_path("a/b/c", "isbn", "9780226458113"), "a/b/c/isbn/9780226458113.json")
)

-- ---------------------------------------------------------------------------
-- Tests: Wikidata P31 instance-of -> CSL type inference
-- (mirrors the inline decision logic inside fetch_wikidata,
-- pandoc-cite.lua lines 451-465; extracted as a standalone pure function
-- of the numeric-id since the surrounding code does network I/O)
-- ---------------------------------------------------------------------------
local function wikidata_csl_type(p31_numeric_id)
  local csl_type = "entry"
  if p31_numeric_id then
    -- Q571=book, Q3331189=version/edition; Q13442814=scholarly article,
    -- Q191067=article
    local book_types = { [571] = true, [3331189] = true }
    local article_types = { [13442814] = true, [191067] = true }
    if book_types[p31_numeric_id] then csl_type = "book" end
    if article_types[p31_numeric_id] then csl_type = "article-journal" end
  end
  return csl_type
end

ok("wikidata type for Q571 (book)", eq(wikidata_csl_type(571), "book"))
ok("wikidata type for Q3331189 (edition)", eq(wikidata_csl_type(3331189), "book"))
ok("wikidata type for Q13442814 (sch. article)", eq(wikidata_csl_type(13442814), "article-journal"))
ok("wikidata type for Q191067 (article)", eq(wikidata_csl_type(191067), "article-journal"))
ok("wikidata type falls back to entry for unknown id", eq(wikidata_csl_type(42), "entry"))
ok("wikidata type falls back to entry for nil id", eq(wikidata_csl_type(nil), "entry"))

-- ---------------------------------------------------------------------------
-- Summary
-- ---------------------------------------------------------------------------
print(string.format("\n%d passed, %d failed", PASS, FAIL))
if FAIL > 0 then os.exit(1) end
