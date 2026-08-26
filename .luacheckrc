-- luacheck configuration for the pandoc-cite Lua filter.
--
-- This filter runs inside Pandoc's embedded Lua 5.4 interpreter, which
-- exposes a set of filter-specific globals (`pandoc`, `PANDOC_VERSION`,
-- element-constructor globals such as `Pandoc`/`Meta`/`Cite`, etc.) that
-- are not part of stock Lua and must be declared here so luacheck doesn't
-- flag them as undefined.

std = "lua54"

-- Pandoc's Lua filters run in an environment pre-populated with these
-- read-only globals (see https://pandoc.org/lua-filters.html).
read_globals = {
  "pandoc",
  "PANDOC_VERSION",
  "PANDOC_API_VERSION",
  "PANDOC_SCRIPT_FILE",
  "PANDOC_STATE",
  "FORMAT",
}

files["_extensions/pandoc-cite/pandoc-cite.lua"] = {
  -- Pandoc filters export their handlers as top-level global functions
  -- named after the AST element they process (e.g. `function Pandoc(doc)`).
  -- These are intentionally global so Pandoc's filter runner can find them.
  globals = {"Pandoc", "Meta", "Cite"},

  ignore = {
    -- W512 (wikidata P31 claim lookup, ~line 448): the `for _, v in
    -- pairs(labels) do ... break end` pattern is an intentional
    -- "take the first available value" idiom, not a mistaken loop.
    "512",
    -- W231 (`combined` in build_references_meta, ~line 523): kept as
    -- documentation of the merge strategy described in the comment above
    -- it (existing refs are merged at the MetaList level afterwards, not
    -- via this variable); removing it would require touching filter logic.
    "231",
  },
}

files["tests/*.lua"] = {
  -- Test scripts are run directly with `pandoc lua` and don't need the
  -- filter-handler globals, but do use the standard test-runner pattern
  -- of unused local helper functions defined for documentation/coverage.

  ignore = {
    -- W311 (reused `p, a` locals in the citekey-parsing tests, ~line 176):
    -- intentional pattern of reassigning `p, a = parse_citekey(...)` before
    -- each pair of assertions; some cases only assert on `p`, leaving the
    -- previous `a` unread, which is expected test-table-style reuse.
    "311",
  },
}

-- Long lines happen in a few URL-construction/comment spots; allow a wider
-- margin than the luacheck default of 120.
max_line_length = 160
