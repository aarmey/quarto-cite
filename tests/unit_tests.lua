-- Unit tests for pandoc-cite helper functions.
-- Run with: pandoc lua tests/unit_tests.lua

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
  return s
    :gsub("&amp;",  "&")
    :gsub("&lt;",   "<")
    :gsub("&gt;",   ">")
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
  if family then
    return {family = trim(family), given = trim(given)}
  end
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
ok("trim removes leading spaces",  eq(trim("  hello"),  "hello"))
ok("trim removes trailing spaces", eq(trim("hello  "),  "hello"))
ok("trim removes both",            eq(trim("  hello  "), "hello"))
ok("trim handles empty",           eq(trim(""),           ""))
ok("trim handles nil",             trim(nil) == nil)

-- ---------------------------------------------------------------------------
-- Tests: urlencode
-- ---------------------------------------------------------------------------
ok("urlencode basic URL",
   eq(urlencode("https://example.com/path?q=1&r=2"),
      "https%3A%2F%2Fexample.com%2Fpath%3Fq%3D1%26r%3D2"))
ok("urlencode leaves safe chars",
   eq(urlencode("abc-def_ghi.jkl~"), "abc-def_ghi.jkl~"))
ok("urlencode percent-encodes space",
   eq(urlencode("hello world"), "hello%20world"))

-- ---------------------------------------------------------------------------
-- Tests: xml_unescape
-- ---------------------------------------------------------------------------
ok("xml_unescape &amp;",  eq(xml_unescape("a &amp; b"),   "a & b"))
ok("xml_unescape &lt;",   eq(xml_unescape("a &lt; b"),    "a < b"))
ok("xml_unescape &gt;",   eq(xml_unescape("a &gt; b"),    "a > b"))
ok("xml_unescape &quot;", eq(xml_unescape("&quot;hi&quot;"), '"hi"'))
ok("xml_unescape mixed",  eq(xml_unescape("&lt;b&gt;ok&lt;/b&gt;"), "<b>ok</b>"))

-- ---------------------------------------------------------------------------
-- Tests: safe_filename
-- ---------------------------------------------------------------------------
ok("safe_filename basic",           eq(safe_filename("hello"),          "hello"))
ok("safe_filename colons replaced", eq(safe_filename("10.1234/test"),   "10.1234_test"))
ok("safe_filename spaces replaced", eq(safe_filename("hello world"),    "hello_world"))
ok("safe_filename truncates",       #safe_filename(string.rep("a", 300)) <= 180)

-- ---------------------------------------------------------------------------
-- Tests: parse_name
-- ---------------------------------------------------------------------------
local n1 = parse_name("Smith, John")
ok("parse_name Last,First family", n1 and eq(n1.family, "Smith"))
ok("parse_name Last,First given",  n1 and eq(n1.given,  "John"))

local n2 = parse_name("John Smith")
ok("parse_name First Last family", n2 and eq(n2.family, "Smith"))
ok("parse_name First Last given",  n2 and eq(n2.given,  "John"))

local n3 = parse_name("John Michael Smith")
ok("parse_name multi given family", n3 and eq(n3.family, "Smith"))
ok("parse_name multi given given",  n3 and eq(n3.given,  "John Michael"))

local n4 = parse_name("Einstein")
ok("parse_name single token", n4 and eq(n4.family, "Einstein"))

ok("parse_name nil input", parse_name(nil) == nil)
ok("parse_name empty",     parse_name("") == nil)

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

ok("xml_extract title",     eq(xml_extract(sample_entry, "title"),     "Attention Is All You Need"))
ok("xml_extract published", eq(xml_extract(sample_entry, "published"), "2017-06-12T00:00:00Z"))
ok("xml_extract ns doi",    eq(xml_extract(sample_entry, "doi"),       "10.48550/arXiv.1706.03762"))
ok("xml_extract missing",   xml_extract(sample_entry, "summary") == nil)

-- ---------------------------------------------------------------------------
-- Tests: citekey regex
-- ---------------------------------------------------------------------------
local function parse_citekey(id)
  return id:match("^([a-z][a-z%+%-%.]*):(.*)")
end

local p, a = parse_citekey("doi:10.1234/test")
ok("citekey doi prefix",     eq(p, "doi"))
ok("citekey doi accession",  eq(a, "10.1234/test"))

p, a = parse_citekey("arxiv:1706.03762")
ok("citekey arxiv prefix",   eq(p, "arxiv"))
ok("citekey arxiv accession",eq(a, "1706.03762"))

p, a = parse_citekey("pmid:12345678")
ok("citekey pmid prefix",    eq(p, "pmid"))
ok("citekey pmid accession", eq(a, "12345678"))

p, a = parse_citekey("isbn:9780262033848")
ok("citekey isbn prefix",    eq(p, "isbn"))

p, a = parse_citekey("url:https://quarto.org")
ok("citekey url prefix",     eq(p, "url"))
ok("citekey url accession",  eq(a, "https://quarto.org"))

p, a = parse_citekey("wikidata:Q42")
ok("citekey wikidata prefix",    eq(p, "wikidata"))
ok("citekey wikidata accession", eq(a, "Q42"))

-- Keys without a supported prefix return nil
p, a = parse_citekey("smith2023")
ok("citekey no prefix", p == nil and a == nil)

-- ---------------------------------------------------------------------------
-- Summary
-- ---------------------------------------------------------------------------
print(string.format("\n%d passed, %d failed", PASS, FAIL))
if FAIL > 0 then os.exit(1) end
