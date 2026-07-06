#!/usr/bin/env bash
set -euo pipefail

PASS=0
FAIL=0
BINARY=".build/debug/openflix"

pass() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

echo "=== OpenFlix CLI Tests ==="
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

# Unset all possible key sources (both new OPENFLIX_* and legacy VORTEX_*)
unset OPENFLIX_FAL_KEY 2>/dev/null || true
unset OPENFLIX_API_KEY 2>/dev/null || true
unset VORTEX_FAL_KEY 2>/dev/null || true
unset VORTEX_API_KEY 2>/dev/null || true

output=$(env -u OPENFLIX_FAL_KEY -u OPENFLIX_API_KEY -u VORTEX_FAL_KEY -u VORTEX_API_KEY $BINARY generate "test" \
    --provider fal --model fal-ai/minimax/hailuo-02 --dry-run 2>&1 || true)

if echo "$output" | grep -q "no_api_key"; then
    pass "dry-run rejects missing API key"
else
    fail "dry-run rejects missing API key (got: $output)"
fi

# ── 4. cost field name ──────────────────────────────────
echo "4. Cost field naming"

# Check Models.swift source for actual_cost_usd
if grep -q '"actual_cost_usd"' Sources/openflix/Core/Models.swift; then
    pass "actual_cost_usd in Models.swift"
else
    fail "actual_cost_usd in Models.swift"
fi

# Ensure old cost_usd key is gone from Models.swift jsonRepresentation
if grep '"cost_usd"' Sources/openflix/Core/Models.swift | grep -v actual | grep -q cost_usd; then
    fail "old cost_usd still in Models.swift"
else
    pass "old cost_usd removed from Models.swift"
fi

# ── 5. notComplete error message fix ────────────────────
echo "5. notComplete error message"
if grep -q 'is not yet complete' Sources/openflix/Core/Models.swift; then
    pass "notComplete message fixed"
else
    fail "notComplete message not fixed"
fi

# ── 6. CryptoKit import removed ────────────────────────
echo "6. Dead import cleanup"
if grep -q 'import CryptoKit' Sources/openflix/Core/VideoDownloader.swift; then
    fail "CryptoKit import still present"
else
    pass "CryptoKit import removed"
fi

# ── 7. rateLimited carries retryAfter ──────────────────
echo "7. rateLimited retryAfter"
if grep -q 'rateLimited(String, retryAfter: Int?)' Sources/openflix/Core/Models.swift; then
    pass "rateLimited has retryAfter parameter"
else
    fail "rateLimited missing retryAfter parameter"
fi

# ── 8. Kling poll uses statusURL ────────────────────────
echo "8. Kling I2V poll fix"
if grep -q 'statusURL ?? base' Sources/openflix/Providers/KlingClient.swift; then
    pass "Kling poll uses statusURL when available"
else
    fail "Kling poll doesn't use statusURL"
fi

# ── 9. GenerationStore file lock ────────────────────────
echo "9. File lock"
if grep -q 'withFileLock' Sources/openflix/Core/GenerationStore.swift; then
    pass "GenerationStore uses file lock"
else
    fail "GenerationStore missing file lock"
fi

# ── 10. Keychain error humanization ─────────────────────
echo "10. Keychain error humanization"
if grep -q 'keychainError' Sources/openflix/Commands/KeysCommand.swift; then
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
if grep -q 'gen.status == .cancelled' Sources/openflix/Commands/CancelCommand.swift; then
    pass "cancel handles already-cancelled"
else
    fail "cancel missing already-cancelled check"
fi

# ── 15. Round 2: modelJSON no nulls (source check) ────
echo "15. Round 2: modelJSON uses jsonRepresentation"
if grep -q 'm.jsonRepresentation' Sources/openflix/Commands/ProvidersCommand.swift; then
    pass "modelJSON uses model's jsonRepresentation"
else
    fail "modelJSON not using jsonRepresentation"
fi

# ── 16. Round 2: StatusCommand stream emits final JSON ─
echo "16. Round 2: StatusCommand stream emits final JSON"
if grep -q 'if !stream { Output.emitDict' Sources/openflix/Commands/StatusCommand.swift; then
    fail "StatusCommand still guards final emit with !stream"
else
    pass "StatusCommand emits final JSON unconditionally"
fi

# ── 17. Round 2: Output serialization fallback ─────────
echo "17. Round 2: Output serialization fallback"
if grep -q 'JSON serialization failed' Sources/openflix/Output/Output.swift; then
    pass "Output.emitDict/emitArray have serialization fallback"
else
    fail "Output missing serialization fallback"
fi

# ── 18. Round 2: jsonRepresentation includes statusURL ─
echo "18. Round 2: statusURL in jsonRepresentation"
if grep -q '"status_url"' Sources/openflix/Core/Models.swift; then
    pass "statusURL in jsonRepresentation"
else
    fail "statusURL missing from jsonRepresentation"
fi

# ── 19. Round 2: KeysCommand no account mismatch ──────
echo "19. Round 2: KeysCommand account mismatch fixed"
if grep -q 'kSecAttrAccount' Sources/openflix/Commands/KeysCommand.swift; then
    fail "KeysCommand still uses kSecAttrAccount"
else
    pass "KeysCommand account mismatch fixed"
fi

# ── 20. Round 2: Retry orphan cleanup ─────────────────
echo "20. Round 2: Retry orphan generation cleanup"
if grep -q 'GenerationStore.shared.delete(prevId)' Sources/openflix/Core/GenerationEngine.swift; then
    pass "Retry loop cleans up orphan generations"
else
    fail "Retry loop missing orphan cleanup"
fi

# ── 21. Round 2: dry-run generic error catch ──────────
echo "21. Round 2: dry-run generic catch"
if grep -A1 'catch let e as OpenFlixError { Output.fail(e) }' Sources/openflix/Commands/GenerateCommand.swift | grep -q 'catch { Output.failMessage'; then
    pass "dry-run has generic error catch"
else
    fail "dry-run missing generic error catch"
fi

# ── 22. Round 2: StatusCommand skips poll for terminal ─
echo "22. Round 2: StatusCommand terminal status check"
if grep -q 'terminal.contains(gen.status)' Sources/openflix/Commands/StatusCommand.swift; then
    pass "StatusCommand skips poll for terminal statuses"
else
    fail "StatusCommand missing terminal status check"
fi

# ── 23. Round 3: emitEvent stderr fallback ───────────────
echo "23. Round 3: emitEvent stderr fallback"
if grep -q 'Event serialization failed' Sources/openflix/Output/Output.swift; then
    pass "emitEvent has stderr fallback"
else
    fail "emitEvent missing stderr fallback"
fi

# ── 24. Round 3: emit<T> stderr fallback ─────────────────
echo "24. Round 3: emit<T> stderr fallback"
if grep -q 'JSON encoding failed' Sources/openflix/Output/Output.swift; then
    pass "emit<T> has stderr fallback"
else
    fail "emit<T> missing stderr fallback"
fi

# ── 25. Round 3: persist() error logging ─────────────────
echo "25. Round 3: persist() error logging"
if grep -q 'Store encode failed' Sources/openflix/Core/GenerationStore.swift; then
    pass "persist() logs encode errors"
else
    fail "persist() missing encode error logging"
fi

# ── 26. Round 3: HTTP body 500-char truncation ───────────
echo "26. Round 3: HTTP body 500-char truncation"
if grep -q 'prefix(500)' Sources/openflix/Providers/ProviderProtocol.swift; then
    pass "HTTP error body truncated to 500 chars"
else
    fail "HTTP error body still using old truncation"
fi

# ── 27. Round 3: URLSession timeout configured ───────────
echo "27. Round 3: URLSession timeout configured"
if grep -q 'timeoutIntervalForRequest = 30' Sources/openflix/Providers/ProviderProtocol.swift; then
    pass "URLSession has request timeout"
else
    fail "URLSession missing request timeout"
fi

# ── 28. Round 3: VideoDownloader timeout ─────────────────
echo "28. Round 3: VideoDownloader timeout"
if grep -q 'timeoutIntervalForResource = 3600' Sources/openflix/Core/VideoDownloader.swift; then
    pass "VideoDownloader has resource timeout"
else
    fail "VideoDownloader missing resource timeout"
fi

# ── 29. Round 3: MiniMax no force unwraps ────────────────
echo "29. Round 3: MiniMax no force unwraps"
if grep -q 'URLComponents.*!)' Sources/openflix/Providers/MiniMaxClient.swift; then
    fail "MiniMax still has force unwraps"
else
    pass "MiniMax force unwraps removed"
fi

# ── 30. Round 3: Fal default returns .queued ─────────────
echo "30. Round 3: Fal default returns .queued"
if grep -q 'Unknown fal.ai status' Sources/openflix/Providers/FalClient.swift && \
   grep -A1 'Unknown fal.ai status' Sources/openflix/Providers/FalClient.swift | grep -q '.queued'; then
    pass "Fal default returns .queued with warning"
else
    fail "Fal default not returning .queued"
fi

# ── 31. Round 3: All providers warn on unknown status ────
echo "31. Round 3: All providers warn on unknown status"
ALL_WARN=true
for client in Kling Luma Runway Replicate MiniMax Fal; do
    if [ "$client" = "Replicate" ]; then
        CLIENT_FILE="Sources/OpenFlixKit/${client}Client.swift"   # lives in the kit
    else
        CLIENT_FILE="Sources/openflix/Providers/${client}Client.swift"
    fi
    if ! grep -q 'unknown_status' "$CLIENT_FILE"; then
        ALL_WARN=false
        fail "${client}Client missing unknown_status warning"
    fi
done
if [ "$ALL_WARN" = true ]; then
    pass "All providers warn on unknown status"
fi

# ── 32. Round 3: Replicate safe URL ──────────────────────
echo "32. Round 3: Replicate safe URL"
if grep -q 'addingPercentEncoding' Sources/OpenFlixKit/ReplicateClient.swift; then
    pass "Replicate uses safe URL construction"
else
    fail "Replicate missing safe URL construction"
fi

# ── 33. Round 3: DownloadCommand exception handling ──────
echo "33. Round 3: DownloadCommand exception handling"
if grep -q 'download_failed' Sources/openflix/Commands/DownloadCommand.swift; then
    pass "DownloadCommand has exception handling"
else
    fail "DownloadCommand missing exception handling"
fi

# ── 34. Round 3: Stale cached path detection ────────────
echo "34. Round 3: Stale cached path detection"
if grep -q 'Stale cached path' Sources/openflix/Commands/DownloadCommand.swift; then
    pass "Stale cached path detection in DownloadCommand"
else
    fail "Stale cached path detection missing"
fi

# ── 35. Round 3: Poll transient error retry ─────────────
echo "35. Round 3: Poll transient error retry"
if grep -q 'isTransient' Sources/openflix/Core/GenerationEngine.swift; then
    pass "Poll has transient error retry"
else
    fail "Poll missing transient error retry"
fi

# ── 36. Round 3: Timeout includes last status ───────────
echo "36. Round 3: Timeout includes last status"
if grep -q 'lastKnownStatus' Sources/openflix/Core/GenerationEngine.swift; then
    pass "Timeout message includes last known status"
else
    fail "Timeout message missing last known status"
fi

# ── 37. Round 3: Empty prompt rejected ──────────────────
echo "37. Round 3: Empty prompt rejected"
output=$(env -u OPENFLIX_FAL_KEY -u OPENFLIX_API_KEY -u VORTEX_FAL_KEY -u VORTEX_API_KEY $BINARY generate "   " \
    --provider fal --model fal-ai/minimax/hailuo-02 2>&1 || true)
if echo "$output" | grep -q "invalid_input"; then
    pass "Empty prompt rejected"
else
    fail "Empty prompt not rejected (got: $output)"
fi

# ── 38. Round 3: Negative retry rejected ────────────────
echo "38. Round 3: Negative retry rejected"
# ArgumentParser requires --retry=-1 syntax for negative values
output=$(env -u OPENFLIX_FAL_KEY -u OPENFLIX_API_KEY -u VORTEX_FAL_KEY -u VORTEX_API_KEY $BINARY generate "test" \
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
if $BINARY daemon --help 2>&1 | grep -q "Manage the openflix daemon"; then
    pass "daemon command exists"
else
    fail "daemon command missing"
fi

# ── 55. Round 4: daemon start exists ────────────────────
echo "55. Round 4: daemon start exists"
if $BINARY daemon start --help 2>&1 | grep -q "Start the openflix daemon"; then
    pass "daemon start command exists"
else
    fail "daemon start command missing"
fi

# ── 56. Round 4: daemon stop exists ─────────────────────
echo "56. Round 4: daemon stop exists"
if $BINARY daemon stop --help 2>&1 | grep -q "Stop the openflix daemon"; then
    pass "daemon stop command exists"
else
    fail "daemon stop command missing"
fi

# ── 57. Round 4: DAGResolver in source ──────────────────
echo "57. Round 4: DAGResolver in source"
if grep -q 'struct DAGResolver' Sources/openflix/Core/DAGExecutor.swift; then
    pass "DAGResolver defined"
else
    fail "DAGResolver missing"
fi

# ── 58. Round 4: ProviderRouter in source ────────────────
echo "58. Round 4: ProviderRouter in source"
if grep -q 'struct ProviderRouter' Sources/openflix/Core/ProviderRouter.swift; then
    pass "ProviderRouter defined"
else
    fail "ProviderRouter missing"
fi

# ── 59. Round 4: ScatterGather in source ─────────────────
echo "59. Round 4: ScatterGatherExecutor in source"
if grep -q 'struct ScatterGatherExecutor' Sources/openflix/Core/ScatterGather.swift; then
    pass "ScatterGatherExecutor defined"
else
    fail "ScatterGatherExecutor missing"
fi

# ── 60. Round 4: Routing strategies defined ──────────────
echo "60. Round 4: Routing strategies defined"
if grep -q 'case cheapest, fastest, quality, manual, scatterGather' Sources/openflix/Core/ProjectModels.swift; then
    pass "All routing strategies defined"
else
    fail "Routing strategies missing"
fi

# ── 61. Round 4: DaemonServer uses NWListener ────────────
echo "61. Round 4: DaemonServer uses NWListener"
if grep -q 'NWListener' Sources/openflix/Core/DaemonServer.swift; then
    pass "DaemonServer uses NWListener"
else
    fail "DaemonServer missing NWListener"
fi

# ── 62. Round 4: Unix socket path configured ─────────────
echo "62. Round 4: Unix socket path configured"
if grep -q 'daemon.sock' Sources/openflix/Core/DaemonServer.swift; then
    pass "Unix socket path configured"
else
    fail "Unix socket path missing"
fi

# ── 63. Round 4: ProjectStore file locking ───────────────
echo "63. Round 4: ProjectStore file locking"
if grep -q 'withFileLock' Sources/openflix/Core/ProjectStore.swift; then
    pass "ProjectStore uses file locking"
else
    fail "ProjectStore missing file locking"
fi

# ── 64. Round 4: Project status enum complete ────────────
echo "64. Round 4: Project status enum complete"
if grep -q 'case draft, running, paused, succeeded, partialFailure, failed, cancelled' Sources/openflix/Core/ProjectModels.swift; then
    pass "Project status enum complete"
else
    fail "Project status enum incomplete"
fi

# ── 65. Round 4: Shot status enum complete ───────────────
echo "65. Round 4: Shot status enum complete"
if grep -q 'case pending, ready, dispatched, processing, evaluating' Sources/openflix/Core/ProjectModels.swift; then
    pass "Shot status enum complete"
else
    fail "Shot status enum incomplete"
fi

# ── 66. Round 4: BatchItem model defined ─────────────────
echo "66. Round 4: BatchItem model defined"
if grep -q 'struct BatchItem: Codable' Sources/openflix/Core/ProjectModels.swift; then
    pass "BatchItem model defined"
else
    fail "BatchItem model missing"
fi

# ── 67. Round 4: project create from spec file ──────────
echo "67. Round 4: project create from spec"
SPEC_FILE=$(mktemp /tmp/openflix_spec_XXXXXX.json)
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
if grep -q 'protocol VideoEvaluator' Sources/openflix/Core/EvaluatorProtocol.swift; then
    pass "VideoEvaluator protocol defined"
else
    fail "VideoEvaluator protocol missing"
fi

# ── 78. Round 5: HeuristicEvaluator defined ─────────────
echo "78. Round 5: HeuristicEvaluator defined"
if grep -q 'struct HeuristicEvaluator: VideoEvaluator' Sources/openflix/Core/HeuristicEvaluator.swift; then
    pass "HeuristicEvaluator defined"
else
    fail "HeuristicEvaluator missing"
fi

# ── 79. Round 5: LLMVisionEvaluator defined ─────────────
echo "79. Round 5: LLMVisionEvaluator defined"
if grep -q 'struct LLMVisionEvaluator: VideoEvaluator' Sources/openflix/Core/LLMVisionEvaluator.swift; then
    pass "LLMVisionEvaluator defined"
else
    fail "LLMVisionEvaluator missing"
fi

# ── 80. Round 5: ProviderMetricsStore defined ───────────
echo "80. Round 5: ProviderMetricsStore defined"
if grep -q 'final class ProviderMetricsStore' Sources/openflix/Core/ProviderMetricsStore.swift; then
    pass "ProviderMetricsStore defined"
else
    fail "ProviderMetricsStore missing"
fi

# ── 81. Round 5: QualityGate defined ────────────────────
echo "81. Round 5: QualityGate defined"
if grep -q 'struct QualityGate' Sources/openflix/Core/QualityGate.swift; then
    pass "QualityGate defined"
else
    fail "QualityGate missing"
fi

# ── 82. Round 5: EvaluationResult struct defined ────────
echo "82. Round 5: EvaluationResult struct defined"
if grep -q 'struct EvaluationResult: Codable' Sources/openflix/Core/EvaluatorProtocol.swift; then
    pass "EvaluationResult struct defined"
else
    fail "EvaluationResult struct missing"
fi

# ── 83. Round 5: QualityConfig struct defined ───────────
echo "83. Round 5: QualityConfig struct defined"
if grep -q 'struct QualityConfig: Codable' Sources/openflix/Core/EvaluatorProtocol.swift; then
    pass "QualityConfig struct defined"
else
    fail "QualityConfig struct missing"
fi

# ── 84. Round 5: metrics.json store path ────────────────
echo "84. Round 5: metrics.json store path"
if grep -q 'metrics.json' Sources/openflix/Core/ProviderMetricsStore.swift; then
    pass "metrics.json store path"
else
    fail "metrics.json store path missing"
fi

# ── 85. Round 5: ffprobe integration in heuristic ───────
echo "85. Round 5: ffprobe integration in heuristic"
if grep -q 'ffprobe' Sources/openflix/Core/HeuristicEvaluator.swift; then
    pass "ffprobe integration in heuristic"
else
    fail "ffprobe missing from heuristic"
fi

# ── 86. Round 5: Claude API in LLM evaluator ────────────
echo "86. Round 5: Claude API in LLM evaluator"
if grep -q 'api.anthropic.com' Sources/openflix/Core/LLMVisionEvaluator.swift; then
    pass "Claude API in LLM evaluator"
else
    fail "Claude API missing from LLM evaluator"
fi

# ── 87. Round 5: Quality gate check method ──────────────
echo "87. Round 5: Quality gate check method"
if grep -q 'static func check' Sources/openflix/Core/QualityGate.swift; then
    pass "Quality gate check method"
else
    fail "Quality gate check method missing"
fi

# ── 88. Round 5: Shot has qualityScore field ────────────
echo "88. Round 5: Shot has qualityScore field"
if grep -q 'var qualityScore: Double?' Sources/openflix/Core/ProjectModels.swift; then
    pass "Shot has qualityScore field"
else
    fail "Shot qualityScore field missing"
fi

# ── 89. Round 5: Shot has evaluationDimensions ──────────
echo "89. Round 5: Shot has evaluationDimensions"
if grep -q 'var evaluationDimensions:' Sources/openflix/Core/ProjectModels.swift; then
    pass "Shot has evaluationDimensions"
else
    fail "Shot evaluationDimensions missing"
fi

# ── 90. Round 5: ProjectSettings has qualityConfig ──────
echo "90. Round 5: ProjectSettings has qualityConfig"
if grep -q 'var qualityConfig: QualityConfig' Sources/openflix/Core/ProjectModels.swift; then
    pass "ProjectSettings has qualityConfig"
else
    fail "ProjectSettings qualityConfig missing"
fi

# ── 91. Round 5: ProviderRouter uses ProviderMetricsStore
echo "91. Round 5: ProviderRouter uses ProviderMetricsStore"
if grep -q 'ProviderMetricsStore' Sources/openflix/Core/ProviderRouter.swift; then
    pass "ProviderRouter uses ProviderMetricsStore"
else
    fail "ProviderRouter not using ProviderMetricsStore"
fi

# ── 92. Round 5: ScatterGather async selectBest ─────────
echo "92. Round 5: ScatterGather async selectBest"
if grep -q 'qualityConfig: QualityConfig) async' Sources/openflix/Core/ScatterGather.swift; then
    pass "ScatterGather async selectBest"
else
    fail "ScatterGather async selectBest missing"
fi

# ── 93. Round 5: DAGExecutor has qualityConfig ──────────
echo "93. Round 5: DAGExecutor has qualityConfig"
if grep -q 'qualityConfig: QualityConfig' Sources/openflix/Core/DAGExecutor.swift; then
    pass "DAGExecutor has qualityConfig"
else
    fail "DAGExecutor qualityConfig missing"
fi

# ── 94. Round 5: DaemonMethods has evaluate ─────────────
echo "94. Round 5: DaemonMethods has evaluate"
if grep -q 'static let evaluate' Sources/openflix/Core/DaemonProtocol.swift; then
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
FEEDBACK_SPEC=$(mktemp /tmp/openflix_fb_XXXXXX.json)
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
if grep -q "enum ErrorCode: String, Codable" Sources/openflix/Core/Models.swift; then
    pass "ErrorCode enum defined"
else
    fail "ErrorCode enum defined"
fi

# ── 98. Round 6: StructuredError struct defined ───────────
echo "98. Round 6: StructuredError struct defined"
if grep -q "struct StructuredError: Codable" Sources/openflix/Core/Models.swift; then
    pass "StructuredError struct defined"
else
    fail "StructuredError struct defined"
fi

# ── 99. Round 6: StructuredError.from maps OpenFlixError ────
echo "99. Round 6: StructuredError.from maps OpenFlixError"
if grep -q "static func from(_ error: OpenFlixError)" Sources/openflix/Core/Models.swift; then
    pass "StructuredError.from maps OpenFlixError"
else
    fail "StructuredError.from maps OpenFlixError"
fi

# ── 100. Round 6: ErrorCode retryable property ───────────
echo "100. Round 6: ErrorCode retryable property"
if grep -q "var retryable: Bool" Sources/openflix/Core/Models.swift; then
    pass "ErrorCode retryable property"
else
    fail "ErrorCode retryable property"
fi

# ── 101. Round 6: budgetExceeded OpenFlixError case ────────
echo "101. Round 6: budgetExceeded OpenFlixError case"
if grep -q "case budgetExceeded" Sources/openflix/Core/Models.swift; then
    pass "budgetExceeded OpenFlixError case"
else
    fail "budgetExceeded OpenFlixError case"
fi

# ── 102. Round 6: promptBlocked OpenFlixError case ─────────
echo "102. Round 6: promptBlocked OpenFlixError case"
if grep -q "case promptBlocked" Sources/openflix/Core/Models.swift; then
    pass "promptBlocked OpenFlixError case"
else
    fail "promptBlocked OpenFlixError case"
fi

# ── 103. Round 6: Output.failStructured defined ──────────
echo "103. Round 6: Output.failStructured defined"
if grep -q "static func failStructured" Sources/openflix/Output/Output.swift; then
    pass "Output.failStructured defined"
else
    fail "Output.failStructured defined"
fi

# ── 104. Round 6: BudgetManager actor defined ────────────
echo "104. Round 6: BudgetManager actor defined"
if grep -q "actor BudgetManager" Sources/openflix/Core/BudgetManager.swift; then
    pass "BudgetManager actor defined"
else
    fail "BudgetManager actor defined"
fi

# ── 105. Round 6: BudgetManager preFlightCheck ──────────
echo "105. Round 6: BudgetManager preFlightCheck"
if grep -q "func preFlightCheck" Sources/openflix/Core/BudgetManager.swift; then
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
if grep -q "BudgetManager.shared.preFlightCheck" Sources/openflix/Core/GenerationEngine.swift; then
    pass "Budget check in GenerationEngine"
else
    fail "Budget check in GenerationEngine"
fi

# ── 111. Round 6: PromptSafetyChecker defined ────────────
echo "111. Round 6: PromptSafetyChecker defined"
if grep -q "struct PromptSafetyChecker" Sources/openflix/Core/PromptSafetyChecker.swift; then
    pass "PromptSafetyChecker defined"
else
    fail "PromptSafetyChecker defined"
fi

# ── 112. Round 6: Safety check in GenerationEngine ───────
echo "112. Round 6: Safety check in GenerationEngine"
if grep -q "PromptSafetyChecker.check" Sources/openflix/Core/GenerationEngine.swift; then
    pass "Safety check in GenerationEngine"
else
    fail "Safety check in GenerationEngine"
fi

# ── 113. Round 6: Safety blocked patterns ────────────────
echo "113. Round 6: Safety blocked patterns"
if grep -q "blockedPatterns" Sources/openflix/Core/PromptSafetyChecker.swift; then
    pass "Safety blocked patterns defined"
else
    fail "Safety blocked patterns defined"
fi

# ── 114. Round 6: Safety warning patterns ────────────────
echo "114. Round 6: Safety warning patterns"
if grep -q "warningPatterns" Sources/openflix/Core/PromptSafetyChecker.swift; then
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
if grep -q "actor MCPServer" Sources/openflix/Core/MCPServer.swift; then
    pass "MCPServer actor defined"
else
    fail "MCPServer actor defined"
fi

# ── 117. Round 6: MCPToolRegistry has 14 tools ──────────
echo "117. Round 6: MCPToolRegistry has 14 tools"
tool_count=$(grep -c "MCPToolDefinition(" Sources/openflix/Core/MCPToolRegistry.swift)
if [ "$tool_count" -eq 14 ]; then
    pass "MCPToolRegistry has 14 tools"
else
    fail "MCPToolRegistry has 14 tools (got $tool_count)"
fi

# ── 118. Round 6: MCPToolRegistry has 3 resources ───────
echo "118. Round 6: MCPToolRegistry has 3 resources"
res_count=$(grep -c "MCPResourceDefinition(" Sources/openflix/Core/MCPToolRegistry.swift)
if [ "$res_count" -eq 3 ]; then
    pass "MCPToolRegistry has 3 resources"
else
    fail "MCPToolRegistry has 3 resources (got $res_count)"
fi

# ── 119. Round 6: MCP JSON-RPC protocol types ───────────
echo "119. Round 6: MCP JSON-RPC protocol types"
if grep -q "struct MCPRequest: Codable" Sources/openflix/Core/MCPProtocol.swift && \
   grep -q "struct MCPResponse: Codable" Sources/openflix/Core/MCPProtocol.swift; then
    pass "MCP JSON-RPC protocol types"
else
    fail "MCP JSON-RPC protocol types"
fi

# ── 120. Round 6: MCP initialize handler ────────────────
echo "120. Round 6: MCP initialize handler"
if grep -q "handleInitialize" Sources/openflix/Core/MCPServer.swift; then
    pass "MCP initialize handler"
else
    fail "MCP initialize handler"
fi

# ── 121. Round 6: MCP tools/list handler ────────────────
echo "121. Round 6: MCP tools/list handler"
if grep -q "handleToolsList" Sources/openflix/Core/MCPServer.swift; then
    pass "MCP tools/list handler"
else
    fail "MCP tools/list handler"
fi

# ── 122. Round 6: MCP tools/call handler ────────────────
echo "122. Round 6: MCP tools/call handler"
if grep -q "handleToolsCall" Sources/openflix/Core/MCPServer.swift; then
    pass "MCP tools/call handler"
else
    fail "MCP tools/call handler"
fi

# ── 123. Round 6: MCP resources/list handler ────────────
echo "123. Round 6: MCP resources/list handler"
if grep -q "handleResourcesList" Sources/openflix/Core/MCPServer.swift; then
    pass "MCP resources/list handler"
else
    fail "MCP resources/list handler"
fi

# ── 124. Round 6: MCP resources/read handler ────────────
echo "124. Round 6: MCP resources/read handler"
if grep -q "handleResourcesRead" Sources/openflix/Core/MCPServer.swift; then
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
if grep -q "func toAny()" Sources/openflix/Core/DaemonProtocol.swift; then
    pass "AnyCodableValue toAny defined"
else
    fail "AnyCodableValue toAny defined"
fi

# ── 128. Round 6: Budget spend tracking ─────────────────
echo "128. Round 6: Budget spend tracking"
if grep -q "func recordSpend" Sources/openflix/Core/BudgetManager.swift; then
    pass "Budget spend tracking"
else
    fail "Budget spend tracking"
fi

# ── 129. Round 6: Budget in GenerationEngine on success ─
echo "129. Round 6: Budget in GenerationEngine on success"
if grep -q "BudgetManager.shared.recordSpend" Sources/openflix/Core/GenerationEngine.swift; then
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
if grep -q 'guard let url = URL(string: "https://queue.fal.run' Sources/openflix/Providers/FalClient.swift; then
    pass "FalClient guards dynamic URL"
else
    fail "FalClient guards dynamic URL"
fi

# ── 134. Round 7: ReplicateClient guards submit URL ──────
echo "134. Round 7: ReplicateClient guards submit URL"
if grep -q 'guard let url = URL(string: "https://api.replicate.com' Sources/OpenFlixKit/ReplicateClient.swift; then
    pass "ReplicateClient guards submit URL"
else
    fail "ReplicateClient guards submit URL"
fi

# ── 135. Round 7: Replicate encoding throws on failure ───
echo "135. Round 7: Replicate encoding throws on failure"
if grep -q 'guard let encoded = taskId.addingPercentEncoding' Sources/OpenFlixKit/ReplicateClient.swift; then
    pass "Replicate encoding throws on failure"
else
    fail "Replicate encoding throws on failure"
fi

# ── 136. Round 7: LLMVisionEvaluator guards Claude URL ──
echo "136. Round 7: LLMVisionEvaluator guards Claude URL"
if grep -q 'guard let url = URL(string: "https://api.anthropic.com' Sources/openflix/Core/LLMVisionEvaluator.swift; then
    pass "LLMVisionEvaluator guards Claude URL"
else
    fail "LLMVisionEvaluator guards Claude URL"
fi

# ── 137. Round 7: Pipe closeFile in LLMVisionEvaluator ──
echo "137. Round 7: Pipe closeFile in LLMVisionEvaluator"
closecount=$(grep -c 'closeFile()' Sources/openflix/Core/LLMVisionEvaluator.swift)
if [ "$closecount" -ge 4 ]; then
    pass "LLMVisionEvaluator closes pipe handles ($closecount calls)"
else
    fail "LLMVisionEvaluator pipe handles not closed (got $closecount closeFile calls)"
fi

# ── 138. Round 7: Pipe closeFile in HeuristicEvaluator ──
echo "138. Round 7: Pipe closeFile in HeuristicEvaluator"
hclose=$(grep -c 'closeFile()' Sources/openflix/Core/HeuristicEvaluator.swift)
if [ "$hclose" -ge 2 ]; then
    pass "HeuristicEvaluator closes pipe handles ($hclose calls)"
else
    fail "HeuristicEvaluator pipe handles not closed (got $hclose closeFile calls)"
fi

# ── 139. Round 7: Duration 600s upper bound ─────────────
echo "139. Round 7: Duration 600s upper bound"
if grep -q 'd > 600' Sources/openflix/Commands/GenerateCommand.swift; then
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
if grep -q 'dimensions\["ffprobe_available"\]' Sources/openflix/Core/HeuristicEvaluator.swift; then
    pass "ffprobe_available dimension in heuristic"
else
    fail "ffprobe_available dimension missing"
fi

# ── 142. Round 7: Static base URLs use lazy init ────────
echo "142. Round 7: Static base URLs use lazy init"
static_bases=0
for f in Sources/openflix/Providers/RunwayClient.swift \
         Sources/openflix/Providers/LumaClient.swift \
         Sources/openflix/Providers/KlingClient.swift \
         Sources/openflix/Providers/MiniMaxClient.swift; do
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

# ══════════════════════════════════════════════════════════
# Recipe Commands
# ══════════════════════════════════════════════════════════

# ── 145. Recipe init --help ──────────────────────────────
echo "145. Recipe: recipe init --help"
if $BINARY recipe init --help 2>&1 | grep -qi "Create\|recipe"; then
    pass "recipe init --help"
else
    fail "recipe init --help"
fi

# ── 146. Recipe list --help ──────────────────────────────
echo "146. Recipe: recipe list --help"
if $BINARY recipe list --help 2>&1 | grep -qi "List\|recipes"; then
    pass "recipe list --help"
else
    fail "recipe list --help"
fi

# ── 147. Recipe show --help ──────────────────────────────
echo "147. Recipe: recipe show --help"
if $BINARY recipe show --help 2>&1 | grep -qi "Show\|recipe"; then
    pass "recipe show --help"
else
    fail "recipe show --help"
fi

# ── 148. Recipe export --help ────────────────────────────
echo "148. Recipe: recipe export --help"
if $BINARY recipe export --help 2>&1 | grep -qi "Export"; then
    pass "recipe export --help"
else
    fail "recipe export --help"
fi

# ── 149. Recipe import --help ────────────────────────────
echo "149. Recipe: recipe import --help"
if $BINARY recipe import --help 2>&1 | grep -qi "Import"; then
    pass "recipe import --help"
else
    fail "recipe import --help"
fi

# ── 150. Recipe fork --help ──────────────────────────────
echo "150. Recipe: recipe fork --help"
if $BINARY recipe fork --help 2>&1 | grep -qi "Fork"; then
    pass "recipe fork --help"
else
    fail "recipe fork --help"
fi

# ── 151. Recipe run --help ───────────────────────────────
echo "151. Recipe: recipe run --help"
if $BINARY recipe run --help 2>&1 | grep -qi "Run\|Execute"; then
    pass "recipe run --help"
else
    fail "recipe run --help"
fi

# ── 152. Recipe init creates recipe with JSON id ────────
echo "152. Recipe: recipe init creates recipe"
RECIPE_INIT=$($BINARY recipe init "test prompt for recipe" --provider fal --model fal-ai/minimax/hailuo-02 --name "Test Recipe" 2>&1)
if echo "$RECIPE_INIT" | python3 -c "import sys,json; d=json.load(sys.stdin); assert 'id' in d" 2>/dev/null; then
    pass "recipe init produces JSON with id"
else
    fail "recipe init produces JSON with id (got: $RECIPE_INIT)"
fi
RECIPE_ID=$(echo "$RECIPE_INIT" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])" 2>/dev/null || echo "")

# ── 153. Recipe list returns JSON array ──────────────────
echo "153. Recipe: recipe list returns JSON array"
RECIPE_LIST=$($BINARY recipe list 2>&1)
if echo "$RECIPE_LIST" | python3 -c "import sys,json; d=json.load(sys.stdin); assert isinstance(d, list)" 2>/dev/null; then
    pass "recipe list produces JSON array"
else
    fail "recipe list produces JSON array (got: $RECIPE_LIST)"
fi

# ── 154. Recipe show returns recipe with name ────────────
echo "154. Recipe: recipe show returns recipe"
if [ -n "$RECIPE_ID" ]; then
    RECIPE_SHOW=$($BINARY recipe show "$RECIPE_ID" 2>&1)
    if echo "$RECIPE_SHOW" | grep -q '"Test Recipe"'; then
        pass "recipe show returns recipe with name"
    else
        fail "recipe show returns recipe with name (got: $RECIPE_SHOW)"
    fi
else
    fail "recipe show (no recipe id from init)"
fi

# ── 155. Recipe export creates .openflix file ────────────
echo "155. Recipe: recipe export creates file"
RECIPE_EXPORT_FILE="/tmp/openflix_test_recipe.openflix"
rm -f "$RECIPE_EXPORT_FILE"
if [ -n "$RECIPE_ID" ]; then
    RECIPE_EXPORT=$($BINARY recipe export "$RECIPE_ID" -o "$RECIPE_EXPORT_FILE" 2>&1)
    if [ -f "$RECIPE_EXPORT_FILE" ]; then
        pass "recipe export creates .openflix file"
    else
        fail "recipe export creates .openflix file (got: $RECIPE_EXPORT)"
    fi
else
    fail "recipe export (no recipe id from init)"
fi

# ── 156. Recipe import from .openflix file ───────────────
echo "156. Recipe: recipe import from file"
if [ -f "$RECIPE_EXPORT_FILE" ]; then
    RECIPE_IMPORT=$($BINARY recipe import "$RECIPE_EXPORT_FILE" 2>&1)
    if echo "$RECIPE_IMPORT" | python3 -c "import sys,json; d=json.load(sys.stdin); assert 'id' in d" 2>/dev/null; then
        pass "recipe import produces JSON with id"
    else
        fail "recipe import produces JSON with id (got: $RECIPE_IMPORT)"
    fi
else
    fail "recipe import (no export file)"
fi
rm -f "$RECIPE_EXPORT_FILE"

# ── 157. Recipe fork produces JSON with parent_recipe_id ─
echo "157. Recipe: recipe fork produces parent_recipe_id"
if [ -n "$RECIPE_ID" ]; then
    RECIPE_FORK=$($BINARY recipe fork "$RECIPE_ID" --name "Forked" 2>&1)
    if echo "$RECIPE_FORK" | grep -q "parent_recipe_id"; then
        pass "recipe fork produces parent_recipe_id"
    else
        fail "recipe fork produces parent_recipe_id (got: $RECIPE_FORK)"
    fi
    # Clean up forked recipe
    FORK_ID=$(echo "$RECIPE_FORK" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])" 2>/dev/null || echo "")
else
    fail "recipe fork (no recipe id from init)"
fi

# ══════════════════════════════════════════════════════════
# Benchmark & Compare Commands
# ══════════════════════════════════════════════════════════

# ── 158. Recipe benchmark --help ─────────────────────────
echo "158. Recipe: recipe benchmark --help"
if $BINARY recipe benchmark --help 2>&1 | grep -qi "benchmark\|Benchmark"; then
    pass "recipe benchmark --help"
else
    fail "recipe benchmark --help"
fi

# ── 159. Compare --help ──────────────────────────────────
echo "159. Compare: compare --help"
if $BINARY compare --help 2>&1 | grep -qi "Compare\|compare"; then
    pass "compare --help"
else
    fail "compare --help"
fi

# ── 160. Recipe benchmark --dry-run ──────────────────────
echo "160. Recipe: recipe benchmark --dry-run"
if [ -n "$RECIPE_ID" ]; then
    BENCH_DRY=$($BINARY recipe benchmark "$RECIPE_ID" --dry-run --providers fal 2>&1)
    if echo "$BENCH_DRY" | grep -q "dry_run"; then
        pass "recipe benchmark --dry-run produces dry_run output"
    else
        fail "recipe benchmark --dry-run (got: $BENCH_DRY)"
    fi
else
    fail "recipe benchmark --dry-run (no recipe id from init)"
fi

# ── 161. Recipe benchmark accepts --providers flag ───────
echo "161. Recipe: recipe benchmark --providers flag"
if $BINARY recipe benchmark --help 2>&1 | grep -q "\-\-providers"; then
    pass "recipe benchmark has --providers flag"
else
    fail "recipe benchmark --providers flag missing"
fi

# ── 162. Recipe benchmark accepts --stream flag ──────────
echo "162. Recipe: recipe benchmark --stream flag"
if $BINARY recipe benchmark --help 2>&1 | grep -q "\-\-stream"; then
    pass "recipe benchmark has --stream flag"
else
    fail "recipe benchmark --stream flag missing"
fi

# ── 163. Compare requires two generation IDs ─────────────
echo "163. Compare: requires two generation IDs"
CMP_ERR=$($BINARY compare 2>&1 || true)
if echo "$CMP_ERR" | grep -qi "generation\|argument\|missing\|expected"; then
    pass "compare requires two generation ID arguments"
else
    fail "compare requires two arguments (got: $CMP_ERR)"
fi

# ── 164. Example recipe files exist ──────────────────────
echo "164. Example recipe files exist"
RECIPE_FILES_OK=0
for rf in recipes/cinematic-sunset.openflix recipes/anime-fight.openflix recipes/product-reveal.openflix recipes/nature-timelapse.openflix recipes/abstract-morph.openflix; do
    if [ -f "$rf" ]; then
        RECIPE_FILES_OK=$((RECIPE_FILES_OK + 1))
    fi
done
if [ "$RECIPE_FILES_OK" -eq 5 ]; then
    pass "All 5 example recipe files exist"
else
    fail "Example recipe files (found $RECIPE_FILES_OK of 5)"
fi

# ── 165. Example recipe files are valid JSON ─────────────
echo "165. Example recipe files are valid JSON"
RECIPE_JSON_OK=0
for rf in recipes/cinematic-sunset.openflix recipes/anime-fight.openflix recipes/product-reveal.openflix recipes/nature-timelapse.openflix recipes/abstract-morph.openflix; do
    if python3 -c "import json; json.load(open('$rf'))" 2>/dev/null; then
        RECIPE_JSON_OK=$((RECIPE_JSON_OK + 1))
    fi
done
if [ "$RECIPE_JSON_OK" -eq 5 ]; then
    pass "All 5 example recipe files are valid JSON"
else
    fail "Valid JSON recipe files ($RECIPE_JSON_OK of 5)"
fi

# ── 166. Example recipe show parses .openflix file ───────
echo "166. Recipe: recipe show parses .openflix file"
SHOW_OPENFLIX=$($BINARY recipe show recipes/cinematic-sunset.openflix 2>&1)
if echo "$SHOW_OPENFLIX" | grep -q "Cinematic Sunset"; then
    pass "recipe show parses .openflix file"
else
    fail "recipe show parses .openflix file (got: $SHOW_OPENFLIX)"
fi

# ── 167. Compare command registered at top level ─────────
echo "167. Compare: registered as top-level command"
if $BINARY --help 2>&1 | grep -q "compare"; then
    pass "compare registered at top level"
else
    fail "compare not in top-level --help"
fi

# ── 168. Benchmark registered under recipe group ─────────
echo "168. Recipe: benchmark registered under recipe"
if $BINARY recipe --help 2>&1 | grep -q "benchmark"; then
    pass "benchmark registered under recipe subcommand"
else
    fail "benchmark not in recipe --help"
fi

# ── 169. Recipe publish --help ─────────────────────────
echo "169. Recipe: publish --help"
if $BINARY recipe publish --help 2>&1 | grep -qi "registry\|Publish"; then
    pass "recipe publish --help mentions registry or Publish"
else
    fail "recipe publish --help missing registry/Publish"
fi

# ── 170. Recipe search --help ─────────────────────────
echo "170. Recipe: search --help"
if $BINARY recipe search --help 2>&1 | grep -qi "registry\|Search"; then
    pass "recipe search --help mentions registry or Search"
else
    fail "recipe search --help missing registry/Search"
fi

# ── 171. Recipe import --url flag ─────────────────────
echo "171. Recipe: import --help contains url"
if $BINARY recipe import --help 2>&1 | grep -qi "url"; then
    pass "recipe import --help mentions url"
else
    fail "recipe import --help missing url"
fi

# ── 172. Recipe benchmark --publish flag ──────────────
echo "172. Recipe: benchmark --help contains publish"
if $BINARY recipe benchmark --help 2>&1 | grep -qi "publish"; then
    pass "recipe benchmark --help mentions publish"
else
    fail "recipe benchmark --help missing publish"
fi

# ── 173. RegistryClient source exists ─────────────────
echo "173. RegistryClient.swift exists in Core"
if [ -f "Sources/openflix/Core/RegistryClient.swift" ]; then
    pass "RegistryClient.swift exists"
else
    fail "RegistryClient.swift not found"
fi

# ── 174. Quickstart command ───────────────────────────
echo "174. Quickstart: prints THE LOOP (no network)"
qs_output=$($BINARY quickstart 2>&1 || true)
if echo "$qs_output" | grep -q "THE LOOP" && echo "$qs_output" | grep -q "openflix compare"; then
    pass "quickstart prints the generate/compare/vote/publish loop"
else
    fail "quickstart missing loop content"
fi

# ── 175. Generate --route flag exists ─────────────────
echo "175. Generate: --route smart flag"
if $BINARY generate --help 2>&1 | grep -q "\-\-route"; then
    pass "--route flag on generate"
else
    fail "--route flag on generate"
fi

# ── 176. Smart routing dry-run works offline ──────────
echo "176. Smart routing: --route smart --dry-run offline"
# Unreachable registry + fake generic key: must still succeed via fallback
# (or cache) and emit a routing explanation. Never hits a provider (dry-run).
smart_output=$(env OPENFLIX_API_KEY=test-key OPENFLIX_REGISTRY_URL=http://127.0.0.1:1 \
    $BINARY generate "smoke test" --route smart --dry-run 2>/dev/null || true)
if echo "$smart_output" | grep -q '"routing"' && echo "$smart_output" | grep -q '"mode":"smart"'; then
    pass "smart dry-run emits routing JSON offline"
else
    fail "smart dry-run missing routing JSON (got: $smart_output)"
fi

# Clean up test recipes from the recipe store
# (recipes.json is at ~/.openflix/recipes.json — we remove test entries via python)
if [ -n "$RECIPE_ID" ]; then
    python3 -c "
import json, os
path = os.path.expanduser('~/.openflix/recipes.json')
if os.path.exists(path):
    with open(path) as f: store = json.load(f)
    for rid in ['$RECIPE_ID', '${FORK_ID:-}']:
        store.pop(rid, None)
    # Also remove any imported test recipes by name
    to_remove = [k for k, v in store.items() if v.get('name','') == 'Test Recipe']
    for k in to_remove: store.pop(k, None)
    with open(path, 'w') as f: json.dump(store, f, indent=2)
" 2>/dev/null || true
fi

# ══════════════════════════════════════════════════════════
# Phase 2: Agentic Engine (workflow, journal, hooks)
# ══════════════════════════════════════════════════════════

# ── 177. Workflow: command exists ─────────────────────
echo "177. Workflow: workflow run --help"
if $BINARY workflow run --help 2>&1 | grep -qi "workflow file"; then
    pass "workflow run command exists"
else
    fail "workflow run command missing"
fi

# ── 178. Workflow: dry-run resolves plan ──────────────
echo "178. Workflow: --dry-run resolves plan with est. cost"
WF_FILE=$(mktemp /tmp/openflix_wf_XXXXXX.json)
cat > "$WF_FILE" << 'WFEOF'
{
  "name": "ci-smoke-film",
  "budget_usd": 5.0,
  "stages": [
    {"id": "storyboard", "prompt": "storyboard: neon chase", "provider": "fal", "model": "fal-ai/veo3", "duration": 4},
    {"id": "shot1", "needs": ["storyboard"], "prompt_from": "storyboard", "provider": "fal",
     "model": "fal-ai/veo3", "duration": 5, "fanout": 4, "judge": {"keep": 1, "min_score": 60}}
  ]
}
WFEOF
wf_dry=$($BINARY workflow run "$WF_FILE" --dry-run 2>&1 || true)
if echo "$wf_dry" | grep -q '"dry_run":true' && \
   echo "$wf_dry" | grep -q '"total_estimated_cost_usd"' && \
   echo "$wf_dry" | grep -q '"fanout":4' && \
   echo "$wf_dry" | grep -q 'judging skipped in dry-run'; then
    pass "workflow --dry-run emits plan (stages, fanout, est cost, judge note)"
else
    fail "workflow --dry-run plan (got: $wf_dry)"
fi

# ── 179. Workflow: prompt_from chains upstream prompt ──
echo "179. Workflow: prompt_from resolves upstream prompt"
prompt_count=$(echo "$wf_dry" | grep -o "storyboard: neon chase" | wc -l | tr -d ' ')
if [ "$prompt_count" = "2" ]; then
    pass "prompt_from copies upstream prompt into downstream stage"
else
    fail "prompt_from resolution (got: $wf_dry)"
fi

# ── 180. Workflow: --resume unknown run-id errors ──────
echo "180. Workflow: --resume unknown run-id"
wf_resume=$($BINARY workflow run "$WF_FILE" --resume definitely-not-a-run 2>&1 || true)
if echo "$wf_resume" | grep -q "run_not_found"; then
    pass "workflow --resume rejects unknown run-id"
else
    fail "workflow --resume unknown run-id (got: $wf_resume)"
fi
rm -f "$WF_FILE"

# ── 181. Workflow: YAML rejected (JSON now, YAML later) ─
echo "181. Workflow: YAML files rejected"
WF_YAML=$(mktemp /tmp/openflix_wf_XXXXXX.yaml)
echo "name: x" > "$WF_YAML"
wf_yaml=$($BINARY workflow run "$WF_YAML" --dry-run 2>&1 || true)
rm -f "$WF_YAML"
if echo "$wf_yaml" | grep -q "yaml_not_supported"; then
    pass "workflow rejects YAML with yaml_not_supported"
else
    fail "workflow YAML rejection (got: $wf_yaml)"
fi

# ── 182. Workflow: cycle rejected ──────────────────────
echo "182. Workflow: cyclic workflow rejected"
WF_CYCLE=$(mktemp /tmp/openflix_wfc_XXXXXX.json)
cat > "$WF_CYCLE" << 'WFEOF'
{"name": "cycle", "stages": [
  {"id": "a", "needs": ["b"], "prompt": "p", "provider": "fal", "model": "fal-ai/veo3"},
  {"id": "b", "needs": ["a"], "prompt": "p", "provider": "fal", "model": "fal-ai/veo3"}
]}
WFEOF
wf_cycle=$($BINARY workflow run "$WF_CYCLE" --dry-run 2>&1 || true)
rm -f "$WF_CYCLE"
if echo "$wf_cycle" | grep -q "cyclic_dependency"; then
    pass "workflow rejects cyclic dependencies"
else
    fail "workflow cycle rejection (got: $wf_cycle)"
fi

# ── 183. Workflow: budget approval gate ────────────────
echo "183. Workflow: budget_approval_required over --max-spend"
WF_BUDGET=$(mktemp /tmp/openflix_wfb_XXXXXX.json)
cat > "$WF_BUDGET" << 'WFEOF'
{"name": "pricey", "stages": [
  {"id": "a", "prompt": "expensive shot", "provider": "fal", "model": "fal-ai/veo3",
   "duration": 8, "fanout": 4}
]}
WFEOF
wf_budget=$($BINARY workflow run "$WF_BUDGET" --max-spend 0.01 2>&1 || true)
rm -f "$WF_BUDGET"
if echo "$wf_budget" | grep -q "budget_approval_required"; then
    pass "workflow blocks over-budget run without --yes"
else
    fail "workflow budget gate (got: $wf_budget)"
fi

# ── 184. Journal: RunJournal in source ─────────────────
echo "184. Journal: RunJournal + atomic writes in source"
if grep -q "final class RunJournal" Sources/openflix/Core/RunJournal.swift && \
   grep -q "options: .atomic" Sources/openflix/Core/RunJournal.swift; then
    pass "RunJournal with atomic write-temp-rename"
else
    fail "RunJournal missing or non-atomic"
fi

# ── 185. Hooks: choke point in GenerationEngine ────────
echo "185. Hooks: pre/post hooks wired into GenerationEngine"
if grep -q "HookRunner.runPreGenerate" Sources/openflix/Core/GenerationEngine.swift && \
   grep -q "HookRunner.runPostGenerate" Sources/openflix/Core/GenerationEngine.swift; then
    pass "hooks wired at the GenerationEngine choke point"
else
    fail "hooks not wired into GenerationEngine"
fi

# ── 186. Hooks: pre-generate veto at runtime ───────────
echo "186. Hooks: pre-generate hook vetoes generation"
HOOKS_BACKUP=""
if [ -d ~/.openflix/hooks ]; then
    HOOKS_BACKUP=$(mktemp -d /tmp/openflix_hooks_backup_XXXXXX)
    cp -R ~/.openflix/hooks/ "$HOOKS_BACKUP/" 2>/dev/null || true
fi
mkdir -p ~/.openflix/hooks
cat > ~/.openflix/hooks/pre-generate << 'HOOKEOF'
#!/bin/bash
cat > /dev/null
echo "vetoed by ci hook" >&2
exit 1
HOOKEOF
chmod +x ~/.openflix/hooks/pre-generate
hook_output=$(env OPENFLIX_API_KEY=test-key $BINARY generate "hook veto test" \
    --provider fal --model fal-ai/minimax/hailuo-02 2>&1 || true)
rm -f ~/.openflix/hooks/pre-generate
if [ -n "$HOOKS_BACKUP" ]; then
    cp -R "$HOOKS_BACKUP"/ ~/.openflix/hooks/ 2>/dev/null || true
    rm -rf "$HOOKS_BACKUP"
fi
if echo "$hook_output" | grep -q "hook_veto" && echo "$hook_output" | grep -q "vetoed by ci hook"; then
    pass "pre-generate hook veto surfaces hook_veto with stderr detail"
else
    fail "pre-generate hook veto (got: $hook_output)"
fi

# ── 187. MCP cancel routes through provider path ───────
echo "187. MCP: cancel_generation uses CancelService"
if grep -q "CancelService.attemptRemoteCancel" Sources/openflix/Core/MCPServer.swift && \
   grep -q "CancelService.attemptRemoteCancel" Sources/openflix/Commands/CancelCommand.swift; then
    pass "MCP cancel routes through shared provider cancel path"
else
    fail "MCP cancel not routed through CancelService"
fi

# ── 188. Project run writes run journal ────────────────
echo "188. Project run: journal wired in"
if grep -q "RunJournal()" Sources/openflix/Commands/ProjectRunCommand.swift && \
   grep -q "journalNode" Sources/openflix/Core/DAGExecutor.swift; then
    pass "project run writes run journal via DAGExecutor"
else
    fail "project run journal wiring missing"
fi

# ── 189. Workflow docs exist ───────────────────────────
echo "189. Docs: workflows-engine.md exists"
if [ -f docs/workflows-engine.md ] && grep -q "prompt_from" docs/workflows-engine.md; then
    pass "docs/workflows-engine.md documents the format"
else
    fail "docs/workflows-engine.md missing or incomplete"
fi

# ══════════════════════════════════════════════════════════
# Recipe args (formatVersion 3) & composition
# ══════════════════════════════════════════════════════════

# Shared fixture: a v3 recipe file with declared args
V3_RECIPE_ID=$(uuidgen | tr '[:upper:]' '[:lower:]')
V3_FILE=$(mktemp /tmp/openflix_v3_XXXXXX).openflix
cat > "$V3_FILE" << V3EOF
{
  "formatVersion": 3,
  "exportedAt": "2026-07-04T00:00:00Z",
  "recipes": [{
    "id": "$V3_RECIPE_ID",
    "name": "CI Param Recipe",
    "promptText": "a {{subject}} at golden hour, {{style}} style",
    "negativePromptText": "",
    "provider": "fal",
    "model": "fal-ai/minimax/hailuo-02",
    "durationSeconds": 5,
    "args": [
      {"name": "subject", "type": "string"},
      {"name": "style", "type": "enum", "default": "cinematic", "choices": ["cinematic", "anime"]}
    ]
  }]
}
V3EOF

# ── 190. recipe run has --arg flag ─────────────────────
echo "190. Recipe args: recipe run --arg flag"
if $BINARY recipe run --help 2>&1 | grep -q "\-\-arg"; then
    pass "recipe run has --arg flag"
else
    fail "recipe run --arg flag missing"
fi

# ── 191. Missing required arg → missing_arg ────────────
echo "191. Recipe args: missing required arg is structured"
ARG_ERR=$($BINARY recipe run "$V3_FILE" --dry-run 2>&1 || true)
if echo "$ARG_ERR" | grep -q "missing_arg"; then
    pass "missing required arg fails with missing_arg"
else
    fail "missing required arg (got: $ARG_ERR)"
fi

# ── 192. --arg substitution reaches the prompt ─────────
echo "192. Recipe args: {{name}} substitution in dry-run"
ARG_DRY=$(env OPENFLIX_API_KEY=test-key $BINARY recipe run "$V3_FILE" --arg subject=fox --dry-run 2>&1 || true)
if echo "$ARG_DRY" | grep -q "a fox at golden hour, cinematic style"; then
    pass "--arg value + enum default substituted into prompt"
else
    fail "arg substitution (got: $ARG_DRY)"
fi

# ── 193. Export version: v3 with args, v2 without ──────
echo "193. Recipe args: export formatVersion selection"
$BINARY recipe import "$V3_FILE" > /dev/null 2>&1 || true
V3_EXPORT=$(mktemp /tmp/openflix_v3_export_XXXXXX).openflix
$BINARY recipe export "$V3_RECIPE_ID" -o "$V3_EXPORT" > /dev/null 2>&1 || true
V3_FMT=$(python3 -c "import json; print(json.load(open('$V3_EXPORT'))['formatVersion'])" 2>/dev/null || echo "?")
# Fresh v2 recipe (RECIPE_ID from earlier tests was cleaned up already)
V2_RECIPE_ID=$($BINARY recipe init "ci v2 export check" --provider fal --model fal-ai/minimax/hailuo-02 --name "CI V2 Recipe" 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])" 2>/dev/null || echo "")
V2_FMT="?"
if [ -n "$V2_RECIPE_ID" ]; then
    V2_EXPORT=$(mktemp /tmp/openflix_v2_export_XXXXXX).openflix
    $BINARY recipe export "$V2_RECIPE_ID" -o "$V2_EXPORT" > /dev/null 2>&1 || true
    V2_FMT=$(python3 -c "import json; print(json.load(open('$V2_EXPORT'))['formatVersion'])" 2>/dev/null || echo "?")
    rm -f "$V2_EXPORT"
fi
if [ "$V3_FMT" = "3" ] && [ "$V2_FMT" = "2" ]; then
    pass "export writes v3 only when args exist (v3=$V3_FMT, v2=$V2_FMT)"
else
    fail "export formatVersion selection (v3=$V3_FMT, v2=$V2_FMT)"
fi
rm -f "$V3_EXPORT"

# ── 194. Workflow stage from recipe (composition) ──────
echo "194. Composition: workflow stage pulls from recipe"
WF_FILE=$(mktemp /tmp/openflix_wf_XXXXXX).json
cat > "$WF_FILE" << WFEOF
{
  "name": "ci-compose",
  "stages": [
    {"id": "hero", "recipe": "$V3_RECIPE_ID", "args": {"subject": "red panda", "style": "anime"}},
    {"id": "tail", "needs": ["hero"], "prompt_from": "hero",
     "provider": "fal", "model": "fal-ai/veo3", "duration": 4}
  ]
}
WFEOF
WF_DRY=$($BINARY workflow run "$WF_FILE" --dry-run 2>&1 || true)
if echo "$WF_DRY" | grep -q "a red panda at golden hour, anime style" && \
   echo "$WF_DRY" | grep -q "fal-ai/minimax/hailuo-02"; then
    pass "recipe stage resolves prompt+model with arg substitution"
else
    fail "workflow recipe stage (got: $WF_DRY)"
fi

# ── 195. Workflow unknown recipe → unknown_recipe ──────
echo "195. Composition: unknown recipe id is structured"
WF_BAD=$(mktemp /tmp/openflix_wfbad_XXXXXX).json
sed "s/$V3_RECIPE_ID/nonexistent-recipe-id/" "$WF_FILE" > "$WF_BAD"
WF_BAD_OUT=$($BINARY workflow run "$WF_BAD" --dry-run 2>&1 || true)
if echo "$WF_BAD_OUT" | grep -q "unknown_recipe"; then
    pass "unknown recipe fails with unknown_recipe"
else
    fail "unknown recipe (got: $WF_BAD_OUT)"
fi
rm -f "$WF_FILE" "$WF_BAD" "$V3_FILE"

# Clean up recipes created by this block (same pattern as the earlier cleanup)
python3 -c "
import json, os
path = os.path.expanduser('~/.openflix/recipes.json')
if os.path.exists(path):
    with open(path) as f: store = json.load(f)
    for rid in ['$V3_RECIPE_ID', '${V2_RECIPE_ID:-}']:
        store.pop(rid, None)
    with open(path, 'w') as f: json.dump(store, f, indent=2)
" 2>/dev/null || true

# ── 196. Single pricing table ──────────────────────────
echo "196. Pricing: single table in OpenFlixKit/ModelPricing.swift"
if [ -f Sources/OpenFlixKit/ModelPricing.swift ] && \
   ! grep -q "costPerSecondUSD: 0\." Sources/openflix/Providers/*.swift Sources/OpenFlixKit/ReplicateClient.swift; then
    pass "no per-model cost constants left in provider clients"
else
    fail "pricing constants still duplicated in provider clients"
fi

# ── 197. Generation store is per-record with migration ─
echo "197. Store: per-record layout + legacy migration"
if grep -q 'generations' Sources/openflix/Core/GenerationStore.swift && \
   grep -q 'store.json' Sources/openflix/Core/GenerationStore.swift && \
   grep -q 'migrateLegacyIfNeeded' Sources/openflix/Core/GenerationStore.swift; then
    pass "GenerationStore uses per-record files with legacy migration"
else
    fail "GenerationStore per-record layout missing"
fi

# ── 198. Budget spend file is flock-protected ──────────
echo "198. Budget: daily_spend.json read-modify-write locked"
if grep -q 'flock' Sources/openflix/Core/BudgetManager.swift && \
   grep -q 'daily_spend.lock' Sources/openflix/Core/BudgetManager.swift; then
    pass "BudgetManager locks spend read-modify-write"
else
    fail "BudgetManager spend lock missing"
fi

# ══════════════════════════════════════════════════════════
# Phase 3 Wave 3: local ComfyUI provider (keyless, $0)
# ══════════════════════════════════════════════════════════

# ── 199. Local provider listed ──────────────────────────
echo "199. Local: providers list shows local/comfyui"
providers_out=$($BINARY providers list 2>&1 || true)
if echo "$providers_out" | grep -q '"id":"local"' && echo "$providers_out" | grep -q '"comfyui"'; then
    pass "providers list includes local (comfyui)"
else
    fail "local provider missing from providers list (got: $providers_out)"
fi

# ── 200. Local dry-run plans keyless at $0 ──────────────
echo "200. Local: generate --provider local --dry-run (keyless, offline)"
local_dry=$($BINARY generate "smoke test" --provider local --model comfyui --duration 5 --dry-run 2>&1 || true)
if echo "$local_dry" | grep -q '"dry_run":true' && \
   echo "$local_dry" | grep -q '"estimated_cost_usd":0' && \
   echo "$local_dry" | grep -q '"provider":"local"'; then
    pass "local dry-run plans without an API key at \$0"
else
    fail "local dry-run (got: $local_dry)"
fi

# ══════════════════════════════════════════════════════════
# Phase 3 Wave 2: workflow publish/import (registry, offline)
# ══════════════════════════════════════════════════════════

# ── 201. Workflow publish/import commands exist ─────────
echo "201. Workflow: publish + import subcommands exist"
if $BINARY workflow publish --help 2>&1 | grep -qi "registry" && \
   $BINARY workflow import --help 2>&1 | grep -qi "registry"; then
    pass "workflow publish/import commands exist"
else
    fail "workflow publish/import commands missing"
fi

# ── 202. Workflow publish validates locally before network ─
echo "202. Workflow: publish rejects invalid spec before any network"
WF_BAD_SPEC=$(mktemp /tmp/openflix-test-badwf-XXXX.json)
printf '{"name":"bad","stages":[]}' > "$WF_BAD_SPEC"
# Unreachable registry proves the failure is the LOCAL validation gate.
pub_out=$(env OPENFLIX_REGISTRY_URL=http://127.0.0.1:1 \
    $BINARY workflow publish "$WF_BAD_SPEC" 2>&1 || true)
rm -f "$WF_BAD_SPEC"
if echo "$pub_out" | grep -q '"code":"empty_stages"'; then
    pass "publish fails locally with empty_stages (no network needed)"
else
    fail "publish local validation gate (got: $pub_out)"
fi

# ── 203. Workflow import unreachable registry → structured error ─
echo "203. Workflow: import with unreachable registry fails structured"
imp_out=$(env OPENFLIX_REGISTRY_URL=http://127.0.0.1:1 \
    $BINARY workflow import wf_does_not_exist 2>&1 || true)
if echo "$imp_out" | grep -q '"code"' && echo "$imp_out" | grep -q '"error"'; then
    pass "import emits structured error offline"
else
    fail "import structured error (got: $imp_out)"
fi

# ── 204. Workflow import rejects malformed references ────
echo "204. Workflow: import rejects malformed reference"
ref_out=$($BINARY workflow import "https://registry.openflix.app/recipes/oops" 2>&1 || true)
if echo "$ref_out" | grep -q '"code":"invalid_workflow_ref"'; then
    pass "import rejects non-workflow URL with invalid_workflow_ref"
else
    fail "import reference validation (got: $ref_out)"
fi

# ── 205. Wave 4: reference_from + style_lock in dry-run plan (offline) ────
echo "205. Workflow: reference_from + style_lock render intent in --dry-run"
WF_REF=$(mktemp /tmp/openflix_wfref_XXXXXX.json)
cat > "$WF_REF" <<'EOF'
{
  "name": "two-shot-consistency",
  "stages": [
    {"id": "shot1", "prompt": "hero shot: ceramic robot barista pours latte art",
     "provider": "fal", "model": "fal-ai/veo3", "duration": 5,
     "style_lock": {"seedPolicy": "fixed", "notes": "keep the glaze identical"},
     "fanout": 2, "judge": {"keep": 1}},
    {"id": "shot2", "reference_from": "shot1",
     "prompt": "close-up: the same ceramic robot barista smiles",
     "provider": "kling", "model": "kling-v2.6-pro", "duration": 5}
  ]
}
EOF
ref_dry=$($BINARY workflow run "$WF_REF" --dry-run 2>&1 || true)
if echo "$ref_dry" | grep -q '"reference":{"from":"shot1","resolved_path":null}' && \
   echo "$ref_dry" | grep -q '"seed_policy":"fixed"' && \
   echo "$ref_dry" | grep -q '"seed":"' && \
   echo "$ref_dry" | grep -q '"needs":\["shot1"\]'; then
    pass "dry-run shows reference intent, fixed seed, and implied DAG edge"
else
    fail "reference intent in dry-run (got: $ref_dry)"
fi

echo "206. Workflow: unknown reference_from rejected with unknown_reference"
WF_REFBAD=$(mktemp /tmp/openflix_wfrefbad_XXXXXX.json)
cat > "$WF_REFBAD" <<'EOF'
{"name": "bad-ref", "stages": [
  {"id": "a", "reference_from": "ghost", "prompt": "x",
   "provider": "fal", "model": "fal-ai/veo3"}]}
EOF
refbad_out=$($BINARY workflow run "$WF_REFBAD" --dry-run 2>&1 || true)
if echo "$refbad_out" | grep -q '"code":"unknown_reference"'; then
    pass "unknown reference_from emits structured unknown_reference"
else
    fail "unknown_reference validation (got: $refbad_out)"
fi
rm -f "$WF_REF" "$WF_REFBAD"

# ── Summary ─────────────────────────────────────────────
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
