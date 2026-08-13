#!/bin/bash
# public_surface_lint.sh — this repository is PUBLIC. Keep it that way on purpose.
#
# WHY THIS EXISTS
#   github.com/moiz-7/OpenFlix is public (the product is proprietary; the repo
#   is not private). Every tagged release additionally gets an auto-generated
#   "Source code (zip/tar.gz)" archive that GitHub attaches and that cannot be
#   turned off — so whatever is tracked at a tagged commit becomes a permanent,
#   immutable, downloadable snapshot under an official release.
#
#   Before v1.1.0 this repo tracked 24 internal documents: `openflix-strategy.md`
#   (935 lines, with sections titled "Routing, Recommendation, and Data Moat" and
#   "Risks, Pushback, and What to Avoid"), `pm-audit-report.md` (583 lines,
#   including a code-health assessment and dependency risk analysis),
#   `cli-audit-report.md` (748 lines), and 21 build reports. Read together that
#   is a competitor's briefing document: the roadmap, the moat, the known
#   weaknesses, and where the code is thin.
#
#   They now live in the private monorepo at `docs/internal/cli/`. This check
#   stops them coming back, because the way they come back is nobody noticing —
#   a report is written at the repo root, `git add -A` sweeps it up, and it is
#   public the moment it is pushed.
#
# THE RULE
#   Only documentation that is deliberately user-facing may be tracked here.
#   Adding a doc for users is one line in ALLOWED below. Adding an internal
#   report is a mistake this catches.
#
# USAGE
#   bash scripts/public_surface_lint.sh
#
# Exit 0 = clean. Exit 1 = something is tracked that should not be public.

set -uo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1

# Documentation intended for people who USE the CLI. Everything else belongs in
# the private monorepo. Keep this list short and justified.
ALLOWED_RE='^(README\.md|CHANGELOG\.md|LICENSE(\.md)?|docs/mcp-protocol\.md|docs/mcp-quickstart\.md|docs/workflows-engine\.md|recipes/README\.md|recipes/FEATURED\.md)$'

FAILURES=0

unexpected=$(git ls-files "*.md" | grep -vE "$ALLOWED_RE")
if [ -n "$unexpected" ]; then
    FAILURES=1
    echo "PUBLIC SURFACE: internal documentation is tracked in a public repository."
    echo
    printf '%s\n' "$unexpected" | sed 's/^/    /'
    echo
    echo "This repo is PUBLIC, and a tagged release bakes these into a permanent,"
    echo "un-deletable source archive. Internal reports, audits, strategy and plans"
    echo "belong in the private monorepo under docs/internal/cli/."
    echo
    echo "If one of these really is meant for users, add it to ALLOWED_RE in"
    echo "scripts/public_surface_lint.sh and say why in the commit message."
fi

# A tracked dotenv or key file is the other way a public repo leaks.
secrets=$(git ls-files | grep -iE '(^|/)(\.env|\.env\..*|.*\.pem|.*\.p12|.*_rsa|secrets?\.(json|ya?ml))$')
if [ -n "$secrets" ]; then
    FAILURES=1
    echo
    echo "PUBLIC SURFACE: credential-shaped files are tracked:"
    printf '%s\n' "$secrets" | sed 's/^/    /'
fi

if [ "$FAILURES" -eq 0 ]; then
    echo "public surface clean — only user-facing docs are tracked"
    exit 0
fi
exit 1
