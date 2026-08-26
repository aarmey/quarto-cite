# Contributing to pandoc-cite

Thanks for your interest in improving pandoc-cite! This document covers how
to set up a development environment, run the tests, and open a pull request.

---

## Development setup

You need:

- [Quarto](https://quarto.org) >= 1.4 (which bundles a compatible Pandoc, >=
  3.1) on your `PATH`
- `curl` on your `PATH`

See the README's [Requirements](README.md#requirements) section for details.
There's no separate build step — the filter is plain Lua, so cloning the
repo is enough to start editing.

```bash
git clone git@github.com:aarmey/quarto-cite.git
cd quarto-cite
```

---

## File layout

- `_extensions/pandoc-cite/pandoc-cite.lua` — the filter itself. This is the
  only file that implements filter behavior; everything else is packaging,
  tests, or docs.
- `_extensions/pandoc-cite/_extension.yml` — the Quarto extension manifest
  (metadata Quarto uses to register the filter as `pandoc-cite`).
- `tests/unit_tests.lua` — pure-Lua unit tests (no network, no Quarto
  rendering).
- `tests/integration.qmd` — a Quarto document used to exercise the filter
  end-to-end (real network fetches, real citeproc rendering).
- `tests/run_tests.sh` — the test runner; see below.

---

## Running tests

Unit tests only (fast, no internet required):

```bash
bash tests/run_tests.sh
```

Unit tests plus integration tests (requires internet access, since it
fetches live citation data, and renders a real Quarto document):

```bash
bash tests/run_tests.sh --integration
```

Run `bash tests/run_tests.sh --help` for a summary of what each mode does
and what it requires.

---

## Naming: pandoc-cite vs. quarto-cite

You'll see two names in this repo, and they refer to different things on
purpose:

- **`pandoc-cite`** is the name of the filter/extension itself — the code in
  `_extensions/pandoc-cite/`, and the name you reference in a document's
  `filters:` list.
- **`quarto-cite`** is the name of this GitHub repository, i.e. the
  distribution channel (`quarto add aarmey/quarto-cite` installs the
  `pandoc-cite` extension from it).

This split is intentional and won't be changed. The filter itself has no
Quarto-specific dependencies — it's written against standard Pandoc Lua
filter APIs (`pandoc.pipe`, `pandoc.system`, `pandoc.path`, `pandoc.json`,
`pandoc.read`) and works with plain Pandoc, not
just Quarto. For example:

```bash
pandoc --lua-filter=_extensions/pandoc-cite/pandoc-cite.lua --citeproc doc.md
```

Only the packaging around it — the `_extension.yml` manifest, the
`_extensions/` folder convention, and `quarto add` — is Quarto-specific.
Keep this distinction in mind when writing docs or code comments: don't
assume Quarto APIs are available inside `pandoc-cite.lua`.

---

## Coding style

There's no linter or formatter configured in this repo at present. If
`.luacheckrc` or `stylua.toml` exist at the repo root, run the corresponding
tool (`luacheck .` / `stylua .`) before submitting. Otherwise, just match
the existing code style in `pandoc-cite.lua` and the test files (indentation,
naming, comment style, etc.).

---

## Opening a pull request

- Keep changes small and focused — one logical change per PR is easier to
  review and easier to revert if something goes wrong.
- Make sure `bash tests/run_tests.sh` passes before opening a PR. If your
  change affects citation fetching/rendering, also run
  `bash tests/run_tests.sh --integration`.
- Don't change unrelated files (formatting-only diffs, CI workflow changes,
  etc.) as part of an otherwise-unrelated PR — split them out.
- Describe *why* the change is needed in the PR description, not just what
  changed.
