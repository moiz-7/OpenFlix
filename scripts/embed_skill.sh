#!/bin/bash
# Regenerates Sources/openflix/Integrations/EmbeddedSkill.swift from
# skills/openflix/SKILL.md (the binary ships the skill for `openflix integrate`).
set -euo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - <<'PY'
t = open('skills/openflix/SKILL.md').read()
assert '"""#' not in t, 'SKILL.md may not contain """#'
open('Sources/openflix/Integrations/EmbeddedSkill.swift', 'w').write(
    '// Generated from skills/openflix/SKILL.md — edit that file, then run\n'
    '// `bash scripts/embed_skill.sh`. SkillEmbedTests fails if the two differ.\n'
    '// Embedded because a Homebrew install ships the binary alone.\n'
    'enum EmbeddedSkill {\n    static let markdown = #"""\n' + t + '"""#\n}\n')
PY
echo "embedded skills/openflix/SKILL.md"
