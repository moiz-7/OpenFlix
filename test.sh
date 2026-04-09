#!/usr/bin/env bash
set -euo pipefail

PASS=0
FAIL=0
BINARY=".build/debug/vortex"

pass() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

echo "=== VortexCLI Hardening Tests ==="
echo ""

# ── 1. Build check ──────────────────────────────────────
echo "1. Build check (debug)"
if swift build 2>&1 | tail -1 | grep -q "Build complete"; then
    pass "debug build"
else
    fail "debug build"
fi

# ── 2. Flag / command existence ─────────────────────────
echo "2. Flag & command existence"

if $BINARY generate --help 2>&1 | grep -q "\-\-skip-download"; then
    pass "--skip-download flag on generate"
else
    fail "--skip-download flag on generate"
fi

if $BINARY generate --help 2>&1 | grep -q "\-\-retry"; then
    pass "--retry flag on generate"
else
    fail "--retry flag on generate"
fi

if $BINARY status --help 2>&1 | grep -q "\-\-cached"; then
    pass "--cached flag on status"
else
    fail "--cached flag on status"
fi

if $BINARY list --help 2>&1 | grep -q "\-\-oldest"; then
    pass "--oldest flag on list"
else
    fail "--oldest flag on list"
fi

# --newest should be gone
if $BINARY list --help 2>&1 | grep -q "\-\-newest"; then
    fail "--newest flag removed from list (still present)"
else
    pass "--newest flag removed from list"
fi

if $BINARY cancel --help 2>&1 | grep -q "Cancel a running generation"; then
    pass "cancel command exists"
else
    fail "cancel command exists"
fi

if $BINARY status --help 2>&1 | grep -q "\-\-skip-download"; then
    pass "--skip-download flag on status"
else
    fail "--skip-download flag on status"
fi

# ── 3. dryRun validates API key ─────────────────────────
echo "3. dryRun API key validation"

# Unset all possible key sources
unset VORTEX_FAL_KEY 2>/dev/null || true
unset VORTEX_API_KEY 2>/dev/null || true

output=$(env -u VORTEX_FAL_KEY -u VORTEX_API_KEY $BINARY generate "test" \
    --provider fal --model fal-ai/minimax/hailuo-02 --dry-run 2>&1 || true)

if echo "$output" | grep -q "no_api_key"; then
    pass "dry-run rejects missing API key"
else
    fail "dry-run rejects missing API key (got: $output)"
fi

# ── 4. cost field name ──────────────────────────────────
echo "4. Cost field naming"

# Check Models.swift source for actual_cost_usd
if grep -q '"actual_cost_usd"' Sources/vortex/Core/Models.swift; then
    pass "actual_cost_usd in Models.swift"
else
    fail "actual_cost_usd in Models.swift"
fi

# Ensure old cost_usd key is gone from Models.swift jsonRepresentation
if grep '"cost_usd"' Sources/vortex/Core/Models.swift | grep -v actual | grep -q cost_usd; then
    fail "old cost_usd still in Models.swift"
else
    pass "old cost_usd removed from Models.swift"
fi

# ── 5. notComplete error message fix ────────────────────
echo "5. notComplete error message"
if grep -q 'is not yet complete' Sources/vortex/Core/Models.swift; then
    pass "notComplete message fixed"
else
    fail "notComplete message not fixed"
fi

# ── 6. CryptoKit import removed ────────────────────────
echo "6. Dead import cleanup"
if grep -q 'import CryptoKit' Sources/vortex/Core/VideoDownloader.swift; then
    fail "CryptoKit import still present"
else
    pass "CryptoKit import removed"
fi

# ── 7. rateLimited carries retryAfter ──────────────────
echo "7. rateLimited retryAfter"
if grep -q 'rateLimited(String, retryAfter: Int?)' Sources/vortex/Core/Models.swift; then
    pass "rateLimited has retryAfter parameter"
else
    fail "rateLimited missing retryAfter parameter"
fi

# ── 8. Kling poll uses statusURL ────────────────────────
echo "8. Kling I2V poll fix"
if grep -q 'statusURL ?? base' Sources/vortex/Providers/KlingClient.swift; then
    pass "Kling poll uses statusURL when available"
else
    fail "Kling poll doesn't use statusURL"
fi

# ── 9. GenerationStore file lock ────────────────────────
echo "9. File lock"
if grep -q 'withFileLock' Sources/vortex/Core/GenerationStore.swift; then
    pass "GenerationStore uses file lock"
else
    fail "GenerationStore missing file lock"
fi

# ── 10. Keychain error humanization ─────────────────────
echo "10. Keychain error humanization"
if grep -q 'keychainError' Sources/vortex/Commands/KeysCommand.swift; then
    pass "keychainError helper used"
else
    fail "keychainError helper missing"
fi

# ── 11. Release build ──────────────────────────────────
echo "11. Release build"
if swift build -c release 2>&1 | tail -1 | grep -q "Build complete"; then
    pass "release build"
else
    fail "release build"
fi

# ── 12. Round 2: delete command ────────────────────────
echo "12. Round 2: delete command"
if $BINARY delete --help 2>&1 | grep -q "Delete a generation from local history"; then
    pass "delete command exists"
else
    fail "delete command exists"
fi

# ── 13. Round 2: list --status validation ──────────────
echo "13. Round 2: list --status validation"
output=$($BINARY list --status bogus 2>&1 || true)
if echo "$output" | grep -q "invalid_status"; then
    pass "list --status rejects invalid value"
else
    fail "list --status rejects invalid value (got: $output)"
fi

# ── 14. Round 2: cancel idempotency (source check) ────
echo "14. Round 2: cancel idempotency"
if grep -q 'gen.status == .cancelled' Sources/vortex/Commands/CancelCommand.swift; then
    pass "cancel handles already-cancelled"
else
    fail "cancel missing already-cancelled check"
fi

# ── 15. Round 2: modelJSON no nulls (source check) ────
echo "15. Round 2: modelJSON uses jsonRepresentation"
if grep -q 'm.jsonRepresentation' Sources/vortex/Commands/ProvidersCommand.swift; then
    pass "modelJSON uses model's jsonRepresentation"
else
    fail "modelJSON not using jsonRepresentation"
fi

# ── 16. Round 2: StatusCommand stream emits final JSON ─
echo "16. Round 2: StatusCommand stream emits final JSON"
if grep -q 'if !stream { Output.emitDict' Sources/vortex/Commands/StatusCommand.swift; then
    fail "StatusCommand still guards final emit with !stream"
else
    pass "StatusCommand emits final JSON unconditionally"
fi

# ── 17. Round 2: Output serialization fallback ─────────
echo "17. Round 2: Output serialization fallback"
if grep -q 'JSON serialization failed' Sources/vortex/Output/Output.swift; then
    pass "Output.emitDict/emitArray have serialization fallback"
else
    fail "Output missing serialization fallback"
fi

# ── 18. Round 2: jsonRepresentation includes statusURL ─
echo "18. Round 2: statusURL in jsonRepresentation"
if grep -q '"status_url"' Sources/vortex/Core/Models.swift; then
    pass "statusURL in jsonRepresentation"
else
    fail "statusURL missing from jsonRepresentation"
fi

# ── 19. Round 2: KeysCommand no account mismatch ──────
echo "19. Round 2: KeysCommand account mismatch fixed"
if grep -q 'kSecAttrAccount' Sources/vortex/Commands/KeysCommand.swift; then
    fail "KeysCommand still uses kSecAttrAccount"
else
    pass "KeysCommand account mismatch fixed"
fi

# ── 20. Round 2: Retry orphan cleanup ─────────────────
echo "20. Round 2: Retry orphan generation cleanup"
if grep -q 'GenerationStore.shared.delete(prevId)' Sources/vortex/Core/GenerationEngine.swift; then
    pass "Retry loop cleans up orphan generations"
else
    fail "Retry loop missing orphan cleanup"
fi

# ── 21. Round 2: dry-run generic error catch ──────────
echo "21. Round 2: dry-run generic catch"
if grep -A1 'catch let e as VortexError { Output.fail(e) }' Sources/vortex/Commands/GenerateCommand.swift | grep -q 'catch { Output.failMessage'; then
    pass "dry-run has generic error catch"
else
    fail "dry-run missing generic error catch"
fi

# ── 22. Round 2: StatusCommand skips poll for terminal ─
echo "22. Round 2: StatusCommand terminal status check"
if grep -q 'terminal.contains(gen.status)' Sources/vortex/Commands/StatusCommand.swift; then
    pass "StatusCommand skips poll for terminal statuses"
else
    fail "StatusCommand missing terminal status check"
fi

# ── 23. Round 3: emitEvent stderr fallback ───────────────
echo "23. Round 3: emitEvent stderr fallback"
if grep -q 'Event serialization failed' Sources/vortex/Output/Output.swift; then
    pass "emitEvent has stderr fallback"
else
    fail "emitEvent missing stderr fallback"
fi

# ── 24. Round 3: emit<T> stderr fallback ─────────────────
echo "24. Round 3: emit<T> stderr fallback"
if grep -q 'JSON encoding failed' Sources/vortex/Output/Output.swift; then
    pass "emit<T> has stderr fallback"
else
    fail "emit<T> missing stderr fallback"
fi

# ── 25. Round 3: persist() error logging ─────────────────
echo "25. Round 3: persist() error logging"
if grep -q 'Store encode failed' Sources/vortex/Core/GenerationStore.swift; then
    pass "persist() logs encode errors"
else
    fail "persist() missing encode error logging"
fi

# ── 26. Round 3: HTTP body 500-char truncation ───────────
echo "26. Round 3: HTTP body 500-char truncation"
if grep -q 'prefix(500)' Sources/vortex/Providers/ProviderProtocol.swift; then
    pass "HTTP error body truncated to 500 chars"
else
    fail "HTTP error body still using old truncation"
fi

# ── 27. Round 3: URLSession timeout configured ───────────
echo "27. Round 3: URLSession timeout configured"
if grep -q 'timeoutIntervalForRequest = 30' Sources/vortex/Providers/ProviderProtocol.swift; then
    pass "URLSession has request timeout"
else
    fail "URLSession missing request timeout"
fi

# ── 28. Round 3: VideoDownloader timeout ─────────────────
echo "28. Round 3: VideoDownloader timeout"
if grep -q 'timeoutIntervalForResource = 3600' Sources/vortex/Core/VideoDownloader.swift; then
    pass "VideoDownloader has resource timeout"
else
    fail "VideoDownloader missing resource timeout"
fi

# ── 29. Round 3: MiniMax no force unwraps ────────────────
echo "29. Round 3: MiniMax no force unwraps"
if grep -q 'URLComponents.*!)' Sources/vortex/Providers/MiniMaxClient.swift; then
    fail "MiniMax still has force unwraps"
else
    pass "MiniMax force unwraps removed"
fi

# ── 30. Round 3: Fal default returns .queued ─────────────
echo "30. Round 3: Fal default returns .queued"
if grep -q 'Unknown fal.ai status' Sources/vortex/Providers/FalClient.swift && \
   grep -A1 'Unknown fal.ai status' Sources/vortex/Providers/FalClient.swift | grep -q '.queued'; then
    pass "Fal default returns .queued with warning"
else
    fail "Fal default not returning .queued"
fi

# ── 31. Round 3: All providers warn on unknown status ────
echo "31. Round 3: All providers warn on unknown status"
ALL_WARN=true
for client in Kling Luma Runway Replicate MiniMax Fal; do
    if ! grep -q 'unknown_status' Sources/vortex/Providers/${client}Client.swift; then
        ALL_WARN=false
        fail "${client}Client missing unknown_status warning"
    fi
done
if [ "$ALL_WARN" = true ]; then
    pass "All providers warn on unknown status"
fi

# ── 32. Round 3: Replicate safe URL ──────────────────────
echo "32. Round 3: Replicate safe URL"
if grep -q 'addingPercentEncoding' Sources/vortex/Providers/ReplicateClient.swift; then
    pass "Replicate uses safe URL construction"
else
    fail "Replicate missing safe URL construction"
fi

# ── 33. Round 3: DownloadCommand exception handling ──────
echo "33. Round 3: DownloadCommand exception handling"
if grep -q 'download_failed' Sources/vortex/Commands/DownloadCommand.swift; then
    pass "DownloadCommand has exception handling"
else
    fail "DownloadCommand missing exception handling"
fi

# ── 34. Round 3: Stale cached path detection ────────────
echo "34. Round 3: Stale cached path detection"
if grep -q 'Stale cached path' Sources/vortex/Commands/DownloadCommand.swift; then
    pass "Stale cached path detection in DownloadCommand"
else
    fail "Stale cached path detection missing"
fi

# ── 35. Round 3: Poll transient error retry ─────────────
echo "35. Round 3: Poll transient error retry"
if grep -q 'isTransient' Sources/vortex/Core/GenerationEngine.swift; then
    pass "Poll has transient error retry"
else
    fail "Poll missing transient error retry"
fi

# ── 36. Round 3: Timeout includes last status ───────────
echo "36. Round 3: Timeout includes last status"
if grep -q 'lastKnownStatus' Sources/vortex/Core/GenerationEngine.swift; then
    pass "Timeout message includes last known status"
else
    fail "Timeout message missing last known status"
fi

# ── 37. Round 3: Empty prompt rejected ──────────────────
echo "37. Round 3: Empty prompt rejected"
output=$(env -u VORTEX_FAL_KEY -u VORTEX_API_KEY $BINARY generate "   " \
    --provider fal --model fal-ai/minimax/hailuo-02 2>&1 || true)
if echo "$output" | grep -q "invalid_input"; then
    pass "Empty prompt rejected"
else
    fail "Empty prompt not rejected (got: $output)"
fi

# ── 38. Round 3: Negative retry rejected ────────────────
echo "38. Round 3: Negative retry rejected"
# ArgumentParser requires --retry=-1 syntax for negative values
output=$(env -u VORTEX_FAL_KEY -u VORTEX_API_KEY $BINARY generate "test" \
    --provider fal --model fal-ai/minimax/hailuo-02 --retry=-1 2>&1 || true)
if echo "$output" | grep -q "invalid_input"; then
    pass "Negative retry rejected"
else
    fail "Negative retry not rejected (got: $output)"
fi

# ── 39. Round 3: retry command exists ───────────────────
echo "39. Round 3: retry command exists"
if $BINARY retry --help 2>&1 | grep -q "Retry a failed or cancelled generation"; then
    pass "retry command exists"
else
    fail "retry command missing"
fi

# ── 40. Round 3: purge command exists ───────────────────
echo "40. Round 3: purge command exists"
if $BINARY purge --help 2>&1 | grep -q "Purge old or failed generations"; then
    pass "purge command exists"
else
    fail "purge command missing"
fi

# ── 41. Round 3: purge requires filter ──────────────────
echo "41. Round 3: purge requires filter"
output=$($BINARY purge 2>&1 || true)
if echo "$output" | grep -q "invalid_input"; then
    pass "purge requires filter"
else
    fail "purge doesn't require filter (got: $output)"
fi

# ── 42. Round 3: health command works ───────────────────
echo "42. Round 3: health command works"
output=$($BINARY health 2>&1 || true)
if echo "$output" | grep -q '"healthy"'; then
    pass "health command works"
else
    fail "health command broken (got: $output)"
fi

# ── 43. Round 3: list --search flag ─────────────────────
echo "43. Round 3: list --search flag"
if $BINARY list --help 2>&1 | grep -q "\-\-search"; then
    pass "list --search flag exists"
else
    fail "list --search flag missing"
fi

# ── 44. Round 4: batch command exists ────────────────────
echo "44. Round 4: batch command exists"
if $BINARY batch --help 2>&1 | grep -q "Submit multiple generations in parallel"; then
    pass "batch command exists"
else
    fail "batch command missing"
fi

# ── 45. Round 4: batch requires input ───────────────────
echo "45. Round 4: batch requires input"
output=$(echo "" | $BINARY batch 2>&1 || true)
if echo "$output" | grep -q "no_input\|invalid_json\|empty"; then
    pass "batch requires input"
else
    fail "batch doesn't require input (got: $output)"
fi

# ── 46. Round 4: project command group exists ────────────
echo "46. Round 4: project command group exists"
if $BINARY project --help 2>&1 | grep -q "Manage multi-shot video generation projects"; then
    pass "project command group exists"
else
    fail "project command group missing"
fi

# ── 47. Round 4: project create exists ──────────────────
echo "47. Round 4: project create exists"
if $BINARY project create --help 2>&1 | grep -q "Create a project from a JSON spec file"; then
    pass "project create command exists"
else
    fail "project create command missing"
fi

# ── 48. Round 4: project run exists ─────────────────────
echo "48. Round 4: project run exists"
if $BINARY project run --help 2>&1 | grep -q "Execute a project"; then
    pass "project run command exists"
else
    fail "project run command missing"
fi

# ── 49. Round 4: project status exists ──────────────────
echo "49. Round 4: project status exists"
if $BINARY project status --help 2>&1 | grep -q "Show project progress and status"; then
    pass "project status command exists"
else
    fail "project status command missing"
fi

# ── 50. Round 4: project list exists ────────────────────
echo "50. Round 4: project list exists"
if $BINARY project list --help 2>&1 | grep -q "List all projects"; then
    pass "project list command exists"
else
    fail "project list command missing"
fi

# ── 51. Round 4: project delete exists ──────────────────
echo "51. Round 4: project delete exists"
if $BINARY project delete --help 2>&1 | grep -q "Delete a project"; then
    pass "project delete command exists"
else
    fail "project delete command missing"
fi

# ── 52. Round 4: project shot exists ────────────────────
echo "52. Round 4: project shot exists"
if $BINARY project shot --help 2>&1 | grep -q "Manage individual shots"; then
    pass "project shot command exists"
else
    fail "project shot command missing"
fi

# ── 53. Round 4: project export exists ──────────────────
echo "53. Round 4: project export exists"
if $BINARY project export --help 2>&1 | grep -q "Export project output manifest"; then
    pass "project export command exists"
else
    fail "project export command missing"
fi

# ── 54. Round 4: daemon command exists ──────────────────
echo "54. Round 4: daemon command exists"
if $BINARY daemon --help 2>&1 | grep -q "Manage the vortex daemon"; then
    pass "daemon command exists"
else
    fail "daemon command missing"
fi

# ── 55. Round 4: daemon start exists ────────────────────
echo "55. Round 4: daemon start exists"
if $BINARY daemon start --help 2>&1 | grep -q "Start the vortex daemon"; then
    pass "daemon start command exists"
else
    fail "daemon start command missing"
fi

# ── 56. Round 4: daemon stop exists ─────────────────────
echo "56. Round 4: daemon stop exists"
if $BINARY daemon stop --help 2>&1 | grep -q "Stop the vortex daemon"; then
    pass "daemon stop command exists"
else
    fail "daemon stop command missing"
fi

# ── 57. Round 4: DAGResolver in source ──────────────────
echo "57. Round 4: DAGResolver in source"
if grep -q 'struct DAGResolver' Sources/vortex/Core/DAGExecutor.swift; then
    pass "DAGResolver defined"
else
    fail "DAGResolver missing"
fi

# ── 58. Round 4: ProviderRouter in source ────────────────
echo "58. Round 4: ProviderRouter in source"
if grep -q 'struct ProviderRouter' Sources/vortex/Core/ProviderRouter.swift; then
    pass "ProviderRouter defined"
else
    fail "ProviderRouter missing"
fi

# ── 59. Round 4: ScatterGather in source ─────────────────
echo "59. Round 4: ScatterGatherExecutor in source"
if grep -q 'struct ScatterGatherExecutor' Sources/vortex/Core/ScatterGather.swift; then
    pass "ScatterGatherExecutor defined"
else
    fail "ScatterGatherExecutor missing"
fi

# ── 60. Round 4: Routing strategies defined ──────────────
echo "60. Round 4: Routing strategies defined"
if grep -q 'case cheapest, fastest, quality, manual, scatterGather' Sources/vortex/Core/ProjectModels.swift; then
    pass "All routing strategies defined"
else
    fail "Routing strategies missing"
fi

# ── 61. Round 4: DaemonServer uses NWListener ────────────
echo "61. Round 4: DaemonServer uses NWListener"
if grep -q 'NWListener' Sources/vortex/Core/DaemonServer.swift; then
    pass "DaemonServer uses NWListener"
else
    fail "DaemonServer missing NWListener"
fi

# ── 62. Round 4: Unix socket path configured ─────────────
echo "62. Round 4: Unix socket path configured"
if grep -q 'daemon.sock' Sources/vortex/Core/DaemonServer.swift; then
    pass "Unix socket path configured"
else
    fail "Unix socket path missing"
fi

# ── 63. Round 4: ProjectStore file locking ───────────────
echo "63. Round 4: ProjectStore file locking"
if grep -q 'withFileLock' Sources/vortex/Core/ProjectStore.swift; then
    pass "ProjectStore uses file locking"
else
    fail "ProjectStore missing file locking"
fi

# ── 64. Round 4: Project status enum complete ────────────
echo "64. Round 4: Project status enum complete"
if grep -q 'case draft, running, paused, succeeded, partialFailure, failed, cancelled' Sources/vortex/Core/ProjectModels.swift; then
    pass "Project status enum complete"
else
    fail "Project status enum incomplete"
fi

# ── 65. Round 4: Shot status enum complete ───────────────
echo "65. Round 4: Shot status enum complete"
if grep -q 'case pending, ready, dispatched, processing, evaluating' Sources/vortex/Core/ProjectModels.swift; then
    pass "Shot status enum complete"
else
    fail "Shot status enum incomplete"
fi

# ── 66. Round 4: BatchItem model defined ─────────────────
echo "66. Round 4: BatchItem model defined"
if grep -q 'struct BatchItem: Codable' Sources/vortex/Core/ProjectModels.swift; then
    pass "BatchItem model defined"
else
    fail "BatchItem model missing"
fi

# ── 67. Round 4: project create from spec file ──────────
echo "67. Round 4: project create from spec"
SPEC_FILE=$(mktemp /tmp/vortex_spec_XXXXXX.json)
cat > "$SPEC_FILE" << 'SPECEOF'
{
  "name": "Test Project",
  "description": "Test project for CI",
  "settings": {
    "default_provider": "fal",
    "default_model": "fal-ai/veo3",
    "routing_strategy": "manual"
  },
  "scenes": [
    {
      "name": "Scene 1",
      "order_index": 0,
      "shots": [
        {
          "name": "shot_a",
          "prompt": "A cat on the moon",
          "order_index": 0,
          "dependencies": []
        },
        {
          "name": "shot_b",
          "prompt": "A dog on mars",
          "order_index": 1,
          "dependencies": ["shot_a"]
        }
      ]
    }
  ]
}
SPECEOF
create_output=$($BINARY project create --file "$SPEC_FILE" 2>&1 || true)
rm -f "$SPEC_FILE"
if echo "$create_output" | grep -q '"id"' && echo "$create_output" | grep -q '"Test Project"'; then
    pass "project create from spec file"
    # Extract project ID for subsequent tests
    PROJECT_ID=$(echo "$create_output" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])" 2>/dev/null || echo "")
else
    fail "project create from spec file (got: $create_output)"
    PROJECT_ID=""
fi

# ── 68. Round 4: project list shows created ──────────────
echo "68. Round 4: project list shows created"
if [ -n "$PROJECT_ID" ]; then
    list_output=$($BINARY project list 2>&1 || true)
    if echo "$list_output" | grep -q "$PROJECT_ID"; then
        pass "project list shows created project"
    else
        fail "project list missing created project (got: $list_output)"
    fi
else
    fail "project list (skipped, no project ID)"
fi

# ── 69. Round 4: project delete cleans up ────────────────
echo "69. Round 4: project delete cleans up"
if [ -n "$PROJECT_ID" ]; then
    delete_output=$($BINARY project delete "$PROJECT_ID" 2>&1 || true)
    if echo "$delete_output" | grep -q '"deleted"'; then
        # Verify it's gone
        list_after=$($BINARY project list 2>&1 || true)
        if echo "$list_after" | grep -q "$PROJECT_ID"; then
            fail "project delete didn't clean up"
        else
            pass "project delete cleans up"
        fi
    else
        fail "project delete failed (got: $delete_output)"
    fi
else
    fail "project delete (skipped, no project ID)"
fi

# ── 70. Round 4: debug build with new files ──────────────
echo "70. Round 4: debug build with all new files"
if swift build 2>&1 | tail -1 | grep -q "Build complete"; then
    pass "debug build with orchestration files"
else
    fail "debug build with orchestration files"
fi

# ── 71. Round 4: release build ───────────────────────────
echo "71. Round 4: release build"
if swift build -c release 2>&1 | tail -1 | grep -q "Build complete"; then
    pass "release build with orchestration files"
else
    fail "release build with orchestration files"
fi

# ── 72. Round 5: evaluate command exists ─────────────────
echo "72. Round 5: evaluate command exists"
if $BINARY evaluate --help 2>&1 | grep -q "Evaluate the quality of a generated video"; then
    pass "evaluate command exists"
else
    fail "evaluate command missing"
fi

# ── 73. Round 5: feedback command exists ─────────────────
echo "73. Round 5: feedback command exists"
if $BINARY feedback --help 2>&1 | grep -q "Record quality feedback for a generation"; then
    pass "feedback command exists"
else
    fail "feedback command missing"
fi

# ── 74. Round 5: metrics command exists ──────────────────
echo "74. Round 5: metrics command exists"
if $BINARY metrics --help 2>&1 | grep -q "Show provider quality and performance metrics"; then
    pass "metrics command exists"
else
    fail "metrics command missing"
fi

# ── 75. Round 5: evaluate requires generation ID ────────
echo "75. Round 5: evaluate requires generation ID"
output=$($BINARY evaluate 2>&1 || true)
if echo "$output" | grep -qi "generation-id\|missing.*argument\|generation.id"; then
    pass "evaluate requires generation ID"
else
    fail "evaluate requires generation ID (got: $output)"
fi

# ── 76. Round 5: feedback validates score range ─────────
echo "76. Round 5: feedback validates score range"
output=$($BINARY feedback nonexistent --score 150 2>&1 || true)
if echo "$output" | grep -q "invalid_input"; then
    pass "feedback validates score range"
else
    fail "feedback validates score range (got: $output)"
fi

# ── 77. Round 5: VideoEvaluator protocol defined ────────
echo "77. Round 5: VideoEvaluator protocol defined"
if grep -q 'protocol VideoEvaluator' Sources/vortex/Core/EvaluatorProtocol.swift; then
    pass "VideoEvaluator protocol defined"
else
    fail "VideoEvaluator protocol missing"
fi

# ── 78. Round 5: HeuristicEvaluator defined ─────────────
echo "78. Round 5: HeuristicEvaluator defined"
if grep -q 'struct HeuristicEvaluator: VideoEvaluator' Sources/vortex/Core/HeuristicEvaluator.swift; then
    pass "HeuristicEvaluator defined"
else
    fail "HeuristicEvaluator missing"
fi

# ── 79. Round 5: LLMVisionEvaluator defined ─────────────
echo "79. Round 5: LLMVisionEvaluator defined"
if grep -q 'struct LLMVisionEvaluator: VideoEvaluator' Sources/vortex/Core/LLMVisionEvaluator.swift; then
    pass "LLMVisionEvaluator defined"
else
    fail "LLMVisionEvaluator missing"
fi

# ── 80. Round 5: ProviderMetricsStore defined ───────────
echo "80. Round 5: ProviderMetricsStore defined"
if grep -q 'final class ProviderMetricsStore' Sources/vortex/Core/ProviderMetricsStore.swift; then
    pass "ProviderMetricsStore defined"
else
    fail "ProviderMetricsStore missing"
fi

# ── 81. Round 5: QualityGate defined ────────────────────
echo "81. Round 5: QualityGate defined"
if grep -q 'struct QualityGate' Sources/vortex/Core/QualityGate.swift; then
    pass "QualityGate defined"
else
    fail "QualityGate missing"
fi

# ── 82. Round 5: EvaluationResult struct defined ────────
echo "82. Round 5: EvaluationResult struct defined"
if grep -q 'struct EvaluationResult: Codable' Sources/vortex/Core/EvaluatorProtocol.swift; then
    pass "EvaluationResult struct defined"
else
    fail "EvaluationResult struct missing"
fi

# ── 83. Round 5: QualityConfig struct defined ───────────
echo "83. Round 5: QualityConfig struct defined"
if grep -q 'struct QualityConfig: Codable' Sources/vortex/Core/EvaluatorProtocol.swift; then
    pass "QualityConfig struct defined"
else
    fail "QualityConfig struct missing"
fi

# ── 84. Round 5: metrics.json store path ────────────────
echo "84. Round 5: metrics.json store path"
if grep -q 'metrics.json' Sources/vortex/Core/ProviderMetricsStore.swift; then
    pass "metrics.json store path"
else
    fail "metrics.json store path missing"
fi

# ── 85. Round 5: ffprobe integration in heuristic ───────
echo "85. Round 5: ffprobe integration in heuristic"
if grep -q 'ffprobe' Sources/vortex/Core/HeuristicEvaluator.swift; then
    pass "ffprobe integration in heuristic"
else
    fail "ffprobe missing from heuristic"
fi

# ── 86. Round 5: Claude API in LLM evaluator ────────────
echo "86. Round 5: Claude API in LLM evaluator"
if grep -q 'api.anthropic.com' Sources/vortex/Core/LLMVisionEvaluator.swift; then
    pass "Claude API in LLM evaluator"
else
    fail "Claude API missing from LLM evaluator"
fi

# ── 87. Round 5: Quality gate check method ──────────────
echo "87. Round 5: Quality gate check method"
if grep -q 'static func check' Sources/vortex/Core/QualityGate.swift; then
    pass "Quality gate check method"
else
    fail "Quality gate check method missing"
fi

# ── 88. Round 5: Shot has qualityScore field ────────────
echo "88. Round 5: Shot has qualityScore field"
if grep -q 'var qualityScore: Double?' Sources/vortex/Core/ProjectModels.swift; then
    pass "Shot has qualityScore field"
else
    fail "Shot qualityScore field missing"
fi

# ── 89. Round 5: Shot has evaluationDimensions ──────────
echo "89. Round 5: Shot has evaluationDimensions"
if grep -q 'var evaluationDimensions:' Sources/vortex/Core/ProjectModels.swift; then
    pass "Shot has evaluationDimensions"
else
    fail "Shot evaluationDimensions missing"
fi

# ── 90. Round 5: ProjectSettings has qualityConfig ──────
echo "90. Round 5: ProjectSettings has qualityConfig"
if grep -q 'var qualityConfig: QualityConfig' Sources/vortex/Core/ProjectModels.swift; then
    pass "ProjectSettings has qualityConfig"
else
    fail "ProjectSettings qualityConfig missing"
fi

# ── 91. Round 5: ProviderRouter uses ProviderMetricsStore
echo "91. Round 5: ProviderRouter uses ProviderMetricsStore"
if grep -q 'ProviderMetricsStore' Sources/vortex/Core/ProviderRouter.swift; then
    pass "ProviderRouter uses ProviderMetricsStore"
else
    fail "ProviderRouter not using ProviderMetricsStore"
fi

# ── 92. Round 5: ScatterGather async selectBest ─────────
echo "92. Round 5: ScatterGather async selectBest"
if grep -q 'qualityConfig: QualityConfig) async' Sources/vortex/Core/ScatterGather.swift; then
    pass "ScatterGather async selectBest"
else
    fail "ScatterGather async selectBest missing"
fi

# ── 93. Round 5: DAGExecutor has qualityConfig ──────────
echo "93. Round 5: DAGExecutor has qualityConfig"
if grep -q 'qualityConfig: QualityConfig' Sources/vortex/Core/DAGExecutor.swift; then
    pass "DAGExecutor has qualityConfig"
else
    fail "DAGExecutor qualityConfig missing"
fi

# ── 94. Round 5: DaemonMethods has evaluate ─────────────
echo "94. Round 5: DaemonMethods has evaluate"
if grep -q 'static let evaluate' Sources/vortex/Core/DaemonProtocol.swift; then
    pass "DaemonMethods has evaluate"
else
    fail "DaemonMethods evaluate missing"
fi

# ── 95. Round 5: ProjectRunCommand --evaluate flag ──────
echo "95. Round 5: ProjectRunCommand --evaluate flag"
if $BINARY project run --help 2>&1 | grep -q "\-\-evaluate"; then
    pass "ProjectRunCommand --evaluate flag"
else
    fail "ProjectRunCommand --evaluate flag missing"
fi

# ── 96. Round 5: feedback runtime lifecycle ─────────────
echo "96. Round 5: feedback runtime lifecycle"
# Create a dummy generation to test feedback against
FEEDBACK_SPEC=$(mktemp /tmp/vortex_fb_XXXXXX.json)
cat > "$FEEDBACK_SPEC" << 'FBEOF'
{
  "name": "Feedback Test Project",
  "scenes": [
    {
      "name": "Scene 1",
      "shots": [{"name": "fb_shot", "prompt": "test feedback"}]
    }
  ]
}
FBEOF
fb_create=$($BINARY project create --file "$FEEDBACK_SPEC" 2>&1 || true)
rm -f "$FEEDBACK_SPEC"
# Test that feedback with non-existent gen returns not_found
fb_output=$($BINARY feedback nonexistent-gen-id --score 75 2>&1 || true)
if echo "$fb_output" | grep -q "not_found"; then
    pass "feedback runtime: not_found for missing gen"
else
    fail "feedback runtime (got: $fb_output)"
fi
# Clean up test project
FB_PID=$(echo "$fb_create" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])" 2>/dev/null || echo "")
if [ -n "$FB_PID" ]; then
    $BINARY project delete "$FB_PID" >/dev/null 2>&1 || true
fi

# ══════════════════════════════════════════════════════════
# Round 6: Agentic Platform
# ══════════════════════════════════════════════════════════

# ── 97. Round 6: ErrorCode enum defined ───────────────────
echo "97. Round 6: ErrorCode enum defined"
if grep -q "enum ErrorCode: String, Codable" Sources/vortex/Core/Models.swift; then
    pass "ErrorCode enum defined"
else
    fail "ErrorCode enum defined"
fi

# ── 98. Round 6: StructuredError struct defined ───────────
echo "98. Round 6: StructuredError struct defined"
if grep -q "struct StructuredError: Codable" Sources/vortex/Core/Models.swift; then
    pass "StructuredError struct defined"
else
    fail "StructuredError struct defined"
fi

# ── 99. Round 6: StructuredError.from maps VortexError ────
echo "99. Round 6: StructuredError.from maps VortexError"
if grep -q "static func from(_ error: VortexError)" Sources/vortex/Core/Models.swift; then
    pass "StructuredError.from maps VortexError"
else
    fail "StructuredError.from maps VortexError"
fi

# ── 100. Round 6: ErrorCode retryable property ───────────
echo "100. Round 6: ErrorCode retryable property"
if grep -q "var retryable: Bool" Sources/vortex/Core/Models.swift; then
    pass "ErrorCode retryable property"
else
    fail "ErrorCode retryable property"
fi

# ── 101. Round 6: budgetExceeded VortexError case ────────
echo "101. Round 6: budgetExceeded VortexError case"
if grep -q "case budgetExceeded" Sources/vortex/Core/Models.swift; then
    pass "budgetExceeded VortexError case"
else
    fail "budgetExceeded VortexError case"
fi

# ── 102. Round 6: promptBlocked VortexError case ─────────
echo "102. Round 6: promptBlocked VortexError case"
if grep -q "case promptBlocked" Sources/vortex/Core/Models.swift; then
    pass "promptBlocked VortexError case"
else
    fail "promptBlocked VortexError case"
fi

# ── 103. Round 6: Output.failStructured defined ──────────
echo "103. Round 6: Output.failStructured defined"
if grep -q "static func failStructured" Sources/vortex/Output/Output.swift; then
    pass "Output.failStructured defined"
else
    fail "Output.failStructured defined"
fi

# ── 104. Round 6: BudgetManager actor defined ────────────
echo "104. Round 6: BudgetManager actor defined"
if grep -q "actor BudgetManager" Sources/vortex/Core/BudgetManager.swift; then
    pass "BudgetManager actor defined"
else
    fail "BudgetManager actor defined"
fi

# ── 105. Round 6: BudgetManager preFlightCheck ──────────
echo "105. Round 6: BudgetManager preFlightCheck"
if grep -q "func preFlightCheck" Sources/vortex/Core/BudgetManager.swift; then
    pass "BudgetManager preFlightCheck"
else
    fail "BudgetManager preFlightCheck"
fi

# ── 106. Round 6: budget command exists ──────────────────
echo "106. Round 6: budget command exists"
if $BINARY budget --help 2>&1 | grep -qi "budget\|spend"; then
    pass "budget command exists"
else
    fail "budget command exists"
fi

# ── 107. Round 6: budget status subcommand ───────────────
echo "107. Round 6: budget status subcommand"
budget_output=$($BINARY budget status 2>&1)
if echo "$budget_output" | grep -q "daily_spend_usd"; then
    pass "budget status works"
else
    fail "budget status works (got: $budget_output)"
fi

# ── 108. Round 6: budget set subcommand ──────────────────
echo "108. Round 6: budget set subcommand"
budget_set=$($BINARY budget set --daily-limit 50.00 2>&1)
if echo "$budget_set" | grep -q '"ok"'; then
    pass "budget set works"
else
    fail "budget set works (got: $budget_set)"
fi

# ── 109. Round 6: budget reset subcommand ────────────────
echo "109. Round 6: budget reset subcommand"
budget_reset=$($BINARY budget reset 2>&1)
if echo "$budget_reset" | grep -q '"ok"'; then
    pass "budget reset works"
else
    fail "budget reset works (got: $budget_reset)"
fi

# ── 110. Round 6: Budget check in GenerationEngine ───────
echo "110. Round 6: Budget check in GenerationEngine"
if grep -q "BudgetManager.shared.preFlightCheck" Sources/vortex/Core/GenerationEngine.swift; then
    pass "Budget check in GenerationEngine"
else
    fail "Budget check in GenerationEngine"
fi

# ── 111. Round 6: PromptSafetyChecker defined ────────────
echo "111. Round 6: PromptSafetyChecker defined"
if grep -q "struct PromptSafetyChecker" Sources/vortex/Core/PromptSafetyChecker.swift; then
    pass "PromptSafetyChecker defined"
else
    fail "PromptSafetyChecker defined"
fi

# ── 112. Round 6: Safety check in GenerationEngine ───────
echo "112. Round 6: Safety check in GenerationEngine"
if grep -q "PromptSafetyChecker.check" Sources/vortex/Core/GenerationEngine.swift; then
    pass "Safety check in GenerationEngine"
else
    fail "Safety check in GenerationEngine"
fi

# ── 113. Round 6: Safety blocked patterns ────────────────
echo "113. Round 6: Safety blocked patterns"
if grep -q "blockedPatterns" Sources/vortex/Core/PromptSafetyChecker.swift; then
    pass "Safety blocked patterns defined"
else
    fail "Safety blocked patterns defined"
fi

# ── 114. Round 6: Safety warning patterns ────────────────
echo "114. Round 6: Safety warning patterns"
if grep -q "warningPatterns" Sources/vortex/Core/PromptSafetyChecker.swift; then
    pass "Safety warning patterns defined"
else
    fail "Safety warning patterns defined"
fi

# ── 115. Round 6: MCP command exists ─────────────────────
echo "115. Round 6: MCP command exists"
if $BINARY mcp --help 2>&1 | grep -q "MCP"; then
    pass "MCP command exists"
else
    fail "MCP command exists"
fi

# ── 116. Round 6: MCPServer actor defined ────────────────
echo "116. Round 6: MCPServer actor defined"
if grep -q "actor MCPServer" Sources/vortex/Core/MCPServer.swift; then
    pass "MCPServer actor defined"
else
    fail "MCPServer actor defined"
fi

# ── 117. Round 6: MCPToolRegistry has 14 tools ──────────
echo "117. Round 6: MCPToolRegistry has 14 tools"
tool_count=$(grep -c "MCPToolDefinition(" Sources/vortex/Core/MCPToolRegistry.swift)
if [ "$tool_count" -eq 14 ]; then
    pass "MCPToolRegistry has 14 tools"
else
    fail "MCPToolRegistry has 14 tools (got $tool_count)"
fi

# ── 118. Round 6: MCPToolRegistry has 3 resources ───────
echo "118. Round 6: MCPToolRegistry has 3 resources"
res_count=$(grep -c "MCPResourceDefinition(" Sources/vortex/Core/MCPToolRegistry.swift)
if [ "$res_count" -eq 3 ]; then
    pass "MCPToolRegistry has 3 resources"
else
    fail "MCPToolRegistry has 3 resources (got $res_count)"
fi

# ── 119. Round 6: MCP JSON-RPC protocol types ───────────
echo "119. Round 6: MCP JSON-RPC protocol types"
if grep -q "struct MCPRequest: Codable" Sources/vortex/Core/MCPProtocol.swift && \
   grep -q "struct MCPResponse: Codable" Sources/vortex/Core/MCPProtocol.swift; then
    pass "MCP JSON-RPC protocol types"
else
    fail "MCP JSON-RPC protocol types"
fi

# ── 120. Round 6: MCP initialize handler ────────────────
echo "120. Round 6: MCP initialize handler"
if grep -q "handleInitialize" Sources/vortex/Core/MCPServer.swift; then
    pass "MCP initialize handler"
else
    fail "MCP initialize handler"
fi

# ── 121. Round 6: MCP tools/list handler ────────────────
echo "121. Round 6: MCP tools/list handler"
if grep -q "handleToolsList" Sources/vortex/Core/MCPServer.swift; then
    pass "MCP tools/list handler"
else
    fail "MCP tools/list handler"
fi

# ── 122. Round 6: MCP tools/call handler ────────────────
echo "122. Round 6: MCP tools/call handler"
if grep -q "handleToolsCall" Sources/vortex/Core/MCPServer.swift; then
    pass "MCP tools/call handler"
else
    fail "MCP tools/call handler"
fi

# ── 123. Round 6: MCP resources/list handler ────────────
echo "123. Round 6: MCP resources/list handler"
if grep -q "handleResourcesList" Sources/vortex/Core/MCPServer.swift; then
    pass "MCP resources/list handler"
else
    fail "MCP resources/list handler"
fi

# ── 124. Round 6: MCP resources/read handler ────────────
echo "124. Round 6: MCP resources/read handler"
if grep -q "handleResourcesRead" Sources/vortex/Core/MCPServer.swift; then
    pass "MCP resources/read handler"
else
    fail "MCP resources/read handler"
fi

# ── 125. Round 6: MCP initialize response ──────────────
echo "125. Round 6: MCP initialize response"
mcp_init='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}'
MCP_OUT=$(mktemp)
echo "$mcp_init" | $BINARY mcp > "$MCP_OUT" 2>/dev/null &
MCP_PID=$!
sleep 1
kill $MCP_PID 2>/dev/null || true
wait $MCP_PID 2>/dev/null || true
mcp_response=$(cat "$MCP_OUT")
rm -f "$MCP_OUT"
if echo "$mcp_response" | grep -q "protocolVersion"; then
    pass "MCP initialize response valid"
else
    fail "MCP initialize response valid (got: $mcp_response)"
fi

# ── 126. Round 6: MCP tools/list response ──────────────
echo "126. Round 6: MCP tools/list response"
MCP_OUT2=$(mktemp)
printf '%s\n%s\n' "$mcp_init" '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' | $BINARY mcp > "$MCP_OUT2" 2>/dev/null &
MCP_PID2=$!
sleep 1
kill $MCP_PID2 2>/dev/null || true
wait $MCP_PID2 2>/dev/null || true
mcp_toolslist=$(cat "$MCP_OUT2")
rm -f "$MCP_OUT2"
if echo "$mcp_toolslist" | grep -q "generate"; then
    pass "MCP tools/list returns tools"
else
    fail "MCP tools/list returns tools (got: $mcp_toolslist)"
fi

# ── 127. Round 6: AnyCodableValue toAny ────────────────
echo "127. Round 6: AnyCodableValue toAny"
if grep -q "func toAny()" Sources/vortex/Core/DaemonProtocol.swift; then
    pass "AnyCodableValue toAny defined"
else
    fail "AnyCodableValue toAny defined"
fi

# ── 128. Round 6: Budget spend tracking ─────────────────
echo "128. Round 6: Budget spend tracking"
if grep -q "func recordSpend" Sources/vortex/Core/BudgetManager.swift; then
    pass "Budget spend tracking"
else
    fail "Budget spend tracking"
fi

# ── 129. Round 6: Budget in GenerationEngine on success ─
echo "129. Round 6: Budget in GenerationEngine on success"
if grep -q "BudgetManager.shared.recordSpend" Sources/vortex/Core/GenerationEngine.swift; then
    pass "Budget recorded on generation success"
else
    fail "Budget recorded on generation success"
fi

# ── 130. Round 6: debug build ────────────────────────────
echo "130. Round 6: debug build"
if swift build 2>&1 | tail -1 | grep -q "Build complete"; then
    pass "debug build with agentic platform"
else
    fail "debug build with agentic platform"
fi

# ── 131. Round 6: release build ──────────────────────────
echo "131. Round 6: release build"
if swift build -c release 2>&1 | tail -1 | grep -q "Build complete"; then
    pass "release build with agentic platform"
else
    fail "release build with agentic platform"
fi

# ══════════════════════════════════════════════════════════
# Round 7: Robustness Fixes
# ══════════════════════════════════════════════════════════

# ── 132. Round 7: No force-unwrapped URLs in Sources ─────
echo "132. Round 7: No force-unwrapped URLs in Sources"
force_unwraps=$(grep -r 'URL(string:.*)\!' Sources/ 2>/dev/null | grep -v '\.build' || true)
if [ -z "$force_unwraps" ]; then
    pass "No force-unwrapped URLs in Sources"
else
    fail "Force-unwrapped URLs found: $force_unwraps"
fi

# ── 133. Round 7: FalClient guards dynamic URL ──────────
echo "133. Round 7: FalClient guards dynamic URL"
if grep -q 'guard let url = URL(string: "https://queue.fal.run' Sources/vortex/Providers/FalClient.swift; then
    pass "FalClient guards dynamic URL"
else
    fail "FalClient guards dynamic URL"
fi

# ── 134. Round 7: ReplicateClient guards submit URL ──────
echo "134. Round 7: ReplicateClient guards submit URL"
if grep -q 'guard let url = URL(string: "https://api.replicate.com' Sources/vortex/Providers/ReplicateClient.swift; then
    pass "ReplicateClient guards submit URL"
else
    fail "ReplicateClient guards submit URL"
fi

# ── 135. Round 7: Replicate encoding throws on failure ───
echo "135. Round 7: Replicate encoding throws on failure"
if grep -q 'guard let encoded = taskId.addingPercentEncoding' Sources/vortex/Providers/ReplicateClient.swift; then
    pass "Replicate encoding throws on failure"
else
    fail "Replicate encoding throws on failure"
fi

# ── 136. Round 7: LLMVisionEvaluator guards Claude URL ──
echo "136. Round 7: LLMVisionEvaluator guards Claude URL"
if grep -q 'guard let url = URL(string: "https://api.anthropic.com' Sources/vortex/Core/LLMVisionEvaluator.swift; then
    pass "LLMVisionEvaluator guards Claude URL"
else
    fail "LLMVisionEvaluator guards Claude URL"
fi

# ── 137. Round 7: Pipe closeFile in LLMVisionEvaluator ──
echo "137. Round 7: Pipe closeFile in LLMVisionEvaluator"
closecount=$(grep -c 'closeFile()' Sources/vortex/Core/LLMVisionEvaluator.swift)
if [ "$closecount" -ge 4 ]; then
    pass "LLMVisionEvaluator closes pipe handles ($closecount calls)"
else
    fail "LLMVisionEvaluator pipe handles not closed (got $closecount closeFile calls)"
fi

# ── 138. Round 7: Pipe closeFile in HeuristicEvaluator ──
echo "138. Round 7: Pipe closeFile in HeuristicEvaluator"
hclose=$(grep -c 'closeFile()' Sources/vortex/Core/HeuristicEvaluator.swift)
if [ "$hclose" -ge 2 ]; then
    pass "HeuristicEvaluator closes pipe handles ($hclose calls)"
else
    fail "HeuristicEvaluator pipe handles not closed (got $hclose closeFile calls)"
fi

# ── 139. Round 7: Duration 600s upper bound ─────────────
echo "139. Round 7: Duration 600s upper bound"
if grep -q 'd > 600' Sources/vortex/Commands/GenerateCommand.swift; then
    pass "Duration 600s upper bound check"
else
    fail "Duration 600s upper bound check"
fi

# ── 140. Round 7: Duration 600s runtime validation ──────
echo "140. Round 7: Duration 600s runtime validation"
dur_output=$($BINARY generate "test" --provider fal --model fal-ai/veo3 --duration 999 2>&1 || true)
if echo "$dur_output" | grep -q "600s\|maximum allowed"; then
    pass "Duration 600s rejected at runtime"
else
    fail "Duration 600s rejected at runtime (got: $dur_output)"
fi

# ── 141. Round 7: ffprobe_available dimension in heuristic
echo "141. Round 7: ffprobe_available dimension in heuristic"
if grep -q 'dimensions\["ffprobe_available"\]' Sources/vortex/Core/HeuristicEvaluator.swift; then
    pass "ffprobe_available dimension in heuristic"
else
    fail "ffprobe_available dimension missing"
fi

# ── 142. Round 7: Static base URLs use lazy init ────────
echo "142. Round 7: Static base URLs use lazy init"
static_bases=0
for f in Sources/vortex/Providers/RunwayClient.swift \
         Sources/vortex/Providers/LumaClient.swift \
         Sources/vortex/Providers/KlingClient.swift \
         Sources/vortex/Providers/MiniMaxClient.swift; do
    if grep -q 'private static let base: URL' "$f"; then
        static_bases=$((static_bases + 1))
    fi
done
if [ "$static_bases" -eq 4 ]; then
    pass "All 4 providers use static base URL"
else
    fail "Static base URLs (got $static_bases of 4)"
fi

# ── 143. Round 7: debug build clean ─────────────────────
echo "143. Round 7: debug build clean"
if swift build 2>&1 | tail -1 | grep -q "Build complete"; then
    pass "debug build with robustness fixes"
else
    fail "debug build with robustness fixes"
fi

# ── 144. Round 7: release build clean ───────────────────
echo "144. Round 7: release build clean"
if swift build -c release 2>&1 | tail -1 | grep -q "Build complete"; then
    pass "release build with robustness fixes"
else
    fail "release build with robustness fixes"
fi

# ── Summary ─────────────────────────────────────────────
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
