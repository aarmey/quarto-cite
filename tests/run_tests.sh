#!/usr/bin/env bash
# Run pandoc-cite tests.
# Usage: bash tests/run_tests.sh [--integration]
#
# Unit tests run always; integration tests require internet access and
# Quarto, and are opt-in via --integration.

set -euo pipefail
cd "$(dirname "$0")/.."

INTEGRATION=false
for arg in "$@"; do
  if [[ "$arg" == "--integration" ]]; then INTEGRATION=true; fi
  if [[ "$arg" == "-h" || "$arg" == "--help" ]]; then
    cat <<'EOF'
Usage: bash tests/run_tests.sh [--integration]

Runs the pandoc-cite test suite.

  (no flags)      Run unit tests only.
                   - Pure Lua tests, no internet or network access needed.
                   - Requires: Quarto (for its bundled `pandoc lua` runner).

  --integration    Also run integration tests, in addition to unit tests.
                   - Renders tests/integration.qmd and checks the output
                     for real resolved citations.
                   - Requires: Quarto, curl, and internet access.

  -h, --help       Show this help message and exit.
EOF
    exit 0
  fi
done

# ---------------------------------------------------------------------------
# Unit tests (pure Lua, no internet, no Quarto)
# ---------------------------------------------------------------------------
echo "=== Unit tests ==="
if ! command -v quarto &>/dev/null; then
  echo "ERROR: quarto not found on PATH" >&2
  exit 1
fi

# Use quarto's bundled pandoc (the `pandoc` command may be an alias)
PANDOC="quarto pandoc"
$PANDOC lua tests/unit_tests.lua
echo ""

# ---------------------------------------------------------------------------
# Integration tests (requires curl, Quarto, internet)
# ---------------------------------------------------------------------------
if [[ "$INTEGRATION" == "true" ]]; then
  echo "=== Integration tests ==="

  if ! command -v curl &>/dev/null; then
    echo "ERROR: curl not found on PATH" >&2
    exit 1
  fi

  # Clean cache so we exercise live fetches
  rm -rf .citation-cache

  echo "Rendering integration.qmd ..."
  quarto render tests/integration.qmd --output-dir tests/_output 2>&1

  # Quarto preserves subdirectory structure inside --output-dir
  OUTPUT="tests/_output/tests/integration.html"
  if [[ ! -f "$OUTPUT" ]]; then
    echo "FAIL: $OUTPUT not produced" >&2
    exit 1
  fi

  check_contains() {
    local desc="$1"
    local pattern="$2"
    if grep -qi "$pattern" "$OUTPUT"; then
      echo "PASS: $desc"
    else
      echo "FAIL: $desc — pattern not found: $pattern" >&2
      FAILED=1
    fi
  }

  FAILED=0
  check_contains "DOI citation rendered"      "Kucsko"
  check_contains "arXiv citation rendered"    "Vaswani"
  check_contains "PubMed citation rendered"   "Cöster\|C.ster"
  check_contains "PMCID citation rendered"    "Bowling"
  check_contains "ISBN citation rendered"     "Scientific Revolutions"
  check_contains "URL citation rendered"      "quarto.org"
  check_contains "Wikidata citation rendered" "wikidata"

  # Verify cache was populated (Quarto renders from the document dir, so
  # the cache lands next to the source document)
  if [[ -d "tests/.citation-cache" ]]; then
    echo "PASS: cache directory created"
  else
    echo "FAIL: cache directory not created" >&2
    FAILED=1
  fi

  # Second render should use cache (no network needed if offline)
  echo "Re-rendering to verify cache hits ..."
  quarto render tests/integration.qmd --output-dir tests/_output 2>&1

  # -------------------------------------------------------------------------
  # Custom (non-default) CSL style: verify pandoc-cite doesn't interfere
  # with citeproc's own style handling by rendering with a numeric/IEEE
  # style and checking for numeric markers instead of author-date text.
  # -------------------------------------------------------------------------
  echo "Rendering custom-style.qmd (IEEE numeric CSL) ..."
  quarto render tests/custom-style.qmd --output-dir tests/_output 2>&1

  CUSTOM_OUTPUT="tests/_output/tests/custom-style.html"
  if [[ ! -f "$CUSTOM_OUTPUT" ]]; then
    echo "FAIL: $CUSTOM_OUTPUT not produced" >&2
    FAILED=1
  else
    check_contains_in() {
      local desc="$1"
      local pattern="$2"
      local file="$3"
      if grep -qi "$pattern" "$file"; then
        echo "PASS: $desc"
      else
        echo "FAIL: $desc — pattern not found: $pattern" >&2
        FAILED=1
      fi
    }
    check_contains_in "Custom style: DOI citation rendered"   "Kucsko" "$CUSTOM_OUTPUT"
    check_contains_in "Custom style: arXiv citation rendered" "Vaswani" "$CUSTOM_OUTPUT"
    check_contains_in "Custom style: URL citation rendered"   "quarto.org" "$CUSTOM_OUTPUT"
    # IEEE is a numeric in-text style, so citation markers should look like
    # "[1]" rather than the "(Author, Year)" style used by integration.qmd.
    check_contains_in "Custom style: numeric citation marker present" "\[1\]" "$CUSTOM_OUTPUT"
  fi

  if [[ $FAILED -ne 0 ]]; then
    echo "" >&2
    echo "One or more integration tests FAILED." >&2
    exit 1
  fi

  echo ""
  echo "All integration tests passed."
fi

echo "Done."
