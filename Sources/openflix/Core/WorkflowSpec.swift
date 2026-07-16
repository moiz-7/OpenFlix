import CryptoKit
import Foundation
import OpenFlixKit

// MARK: - Workflow file format (v1, JSON)
//
// Minimal declarative pipeline over the existing engine. JSON only in v1:
// no YAML dependency exists in this package and adding one for syntax sugar
// is not worth it ("JSON now, YAML later" — .yaml/.yml files are rejected
// with a clear error).
//
// {
//   "name": "my-film",
//   "budget_usd": 5.0,                  // optional approval gate
//   "stages": [
//     {
//       "id": "establishing",           // required, unique
//       "needs": ["storyboard"],        // DAG edges (stage ids)
//       "prompt": "...",                // or "prompt_from": "<stage-id>"
//       "provider": "fal",              // with "model", or "route": "smart"
//       "model": "fal-ai/veo3",
//       "category": "cinematic",        // optional smart-routing hint
//       "duration": 5,                  // seconds
//       "aspect_ratio": "16:9",
//       "negative_prompt": "...",
//       "params": {"seed": "42"},       // provider extra params
//       "fanout": 4,                    // N candidates via scatter-gather
//       "judge": {"keep": 1, "min_score": 60}   // keep top K by quality score
//     }
//   ]
// }

struct WorkflowSpec: Codable {
    var name: String
    var budgetUsd: Double?
    var stages: [WorkflowStage]

    enum CodingKeys: String, CodingKey {
        case name, stages
        case budgetUsd = "budget_usd"
    }
}

struct WorkflowStage: Codable {
    var id: String
    var needs: [String]?
    var prompt: String?
    var promptFrom: String?
    var recipe: String?               // recipe id in the local RecipeStore (XOR with prompt/prompt_from)
    var args: [String: String]?       // values for the recipe's declared args
    var provider: String?
    var model: String?
    var route: String?
    var category: String?
    var duration: Double?
    var aspectRatio: String?
    var negativePrompt: String?
    var params: [String: String]?
    var fanout: Int?
    var judge: JudgeSpec?
    var referenceFrom: String?        // upstream stage whose output feeds forward as the I2V reference
    var referenceImages: [String]?    // consistency intent: reference image paths or URLs (recipe or stage)
    var styleLock: StyleLock?         // consistency intent: seed policy across fanout candidates

    enum CodingKeys: String, CodingKey {
        case id, needs, prompt, recipe, args, provider, model, route, category, duration, params, fanout, judge
        case promptFrom = "prompt_from"
        case aspectRatio = "aspect_ratio"
        case negativePrompt = "negative_prompt"
        case referenceFrom = "reference_from"
        case referenceImages = "reference_images"
        case styleLock = "style_lock"
    }
}

struct JudgeSpec: Codable {
    var keep: Int
    var minScore: Double?

    enum CodingKeys: String, CodingKey {
        case keep
        case minScore = "min_score"
    }
}

// MARK: - Errors

enum WorkflowSpecError: Error, LocalizedError {
    case invalidFile(String)
    case yamlNotSupported
    case duplicateStageId(String)
    case unknownDependency(stage: String, dependency: String)
    case missingPrompt(String)
    case unknownPromptFrom(stage: String, source: String)
    case invalidFanout(stage: String, fanout: Int)
    case invalidJudge(stage: String, reason: String)
    case unknownRoute(stage: String, route: String)
    case missingProvider(String)
    case cyclicDependency(String)
    case emptyStages
    case recipeConflict(String)
    case argsWithoutRecipe(String)
    case unknownRecipe(stage: String, recipeId: String)
    case unknownReference(stage: String, source: String)

    var errorDescription: String? {
        switch self {
        case .invalidFile(let m):
            return "Invalid workflow file: \(m)"
        case .yamlNotSupported:
            return "YAML workflow files are not supported yet (JSON now, YAML later). Convert the file to JSON."
        case .duplicateStageId(let id):
            return "Duplicate stage id: '\(id)'"
        case .unknownDependency(let stage, let dep):
            return "Stage '\(stage)' needs unknown stage '\(dep)'"
        case .missingPrompt(let id):
            return "Stage '\(id)' requires 'prompt' or 'prompt_from'"
        case .unknownPromptFrom(let stage, let source):
            return "Stage '\(stage)' has prompt_from unknown stage '\(source)'"
        case .invalidFanout(let stage, let fanout):
            return "Stage '\(stage)' has invalid fanout \(fanout) (must be >= 1)"
        case .invalidJudge(let stage, let reason):
            return "Stage '\(stage)' has invalid judge: \(reason)"
        case .unknownRoute(let stage, let route):
            return "Stage '\(stage)' has unknown route '\(route)'. Supported: smart"
        case .missingProvider(let id):
            return "Stage '\(id)' requires 'provider'+'model' or 'route': \"smart\""
        case .cyclicDependency(let m):
            return "Cyclic dependency in workflow: \(m)"
        case .emptyStages:
            return "Workflow has no stages"
        case .recipeConflict(let id):
            return "Stage '\(id)' has both 'recipe' and 'prompt'/'prompt_from' — use exactly one"
        case .argsWithoutRecipe(let id):
            return "Stage '\(id)' has 'args' but no 'recipe' to apply them to"
        case .unknownRecipe(let stage, let recipeId):
            return "Stage '\(stage)' references unknown recipe '\(recipeId)' (not in the local recipe store). Import it first: openflix recipe import <file-or-url>"
        case .unknownReference(let stage, let source):
            return "Stage '\(stage)' has reference_from unknown stage '\(source)'"
        }
    }

    var code: String {
        switch self {
        case .invalidFile:        return "invalid_workflow_file"
        case .yamlNotSupported:   return "yaml_not_supported"
        case .duplicateStageId:   return "duplicate_stage_id"
        case .unknownDependency:  return "unknown_dependency"
        case .missingPrompt:      return "missing_prompt"
        case .unknownPromptFrom:  return "unknown_prompt_from"
        case .invalidFanout:      return "invalid_fanout"
        case .invalidJudge:       return "invalid_judge"
        case .unknownRoute:       return "unknown_route"
        case .missingProvider:    return "missing_provider"
        case .cyclicDependency:   return "cyclic_dependency"
        case .emptyStages:        return "empty_stages"
        case .recipeConflict:     return "recipe_conflict"
        case .argsWithoutRecipe:  return "args_without_recipe"
        case .unknownRecipe:      return "unknown_recipe"
        case .unknownReference:   return "unknown_reference"
        }
    }
}

// MARK: - Parsing + validation (pure)

enum WorkflowParser {

    static func parse(data: Data, path: String) throws -> WorkflowSpec {
        let lower = path.lowercased()
        if lower.hasSuffix(".yaml") || lower.hasSuffix(".yml") {
            throw WorkflowSpecError.yamlNotSupported
        }
        let decoder = JSONDecoder()
        var spec: WorkflowSpec
        do { spec = try decoder.decode(WorkflowSpec.self, from: data) }
        catch { throw WorkflowSpecError.invalidFile(error.localizedDescription) }
        spec = normalized(spec)
        try validate(spec)
        return spec
    }

    /// Normalization: `reference_from` implies a DAG edge — if the referenced
    /// stage exists but is not in `needs`, add it (a stage cannot consume an
    /// upstream output that is not guaranteed to run first). Unknown ids are
    /// left alone so `validate` reports `unknown_reference`.
    static func normalized(_ spec: WorkflowSpec) -> WorkflowSpec {
        var out = spec
        let ids = Set(spec.stages.map { $0.id })
        for i in out.stages.indices {
            guard let ref = out.stages[i].referenceFrom,
                  ids.contains(ref), ref != out.stages[i].id else { continue }
            var needs = out.stages[i].needs ?? []
            if !needs.contains(ref) {
                needs.append(ref)
                out.stages[i].needs = needs
            }
        }
        return out
    }

    static func validate(_ spec: WorkflowSpec) throws {
        guard !spec.stages.isEmpty else { throw WorkflowSpecError.emptyStages }

        var ids = Set<String>()
        for stage in spec.stages {
            guard ids.insert(stage.id).inserted else {
                throw WorkflowSpecError.duplicateStageId(stage.id)
            }
        }

        for stage in spec.stages {
            for dep in stage.needs ?? [] where !ids.contains(dep) {
                throw WorkflowSpecError.unknownDependency(stage: stage.id, dependency: dep)
            }
            if stage.recipe != nil && (stage.prompt != nil || stage.promptFrom != nil) {
                throw WorkflowSpecError.recipeConflict(stage.id)
            }
            if stage.args != nil && stage.recipe == nil {
                throw WorkflowSpecError.argsWithoutRecipe(stage.id)
            }
            if stage.prompt == nil && stage.promptFrom == nil && stage.recipe == nil {
                throw WorkflowSpecError.missingPrompt(stage.id)
            }
            if let src = stage.promptFrom {
                guard ids.contains(src), src != stage.id else {
                    throw WorkflowSpecError.unknownPromptFrom(stage: stage.id, source: src)
                }
            }
            if let src = stage.referenceFrom {
                guard ids.contains(src), src != stage.id else {
                    throw WorkflowSpecError.unknownReference(stage: stage.id, source: src)
                }
            }
            if let f = stage.fanout, f < 1 {
                throw WorkflowSpecError.invalidFanout(stage: stage.id, fanout: f)
            }
            if let j = stage.judge {
                if j.keep < 1 {
                    throw WorkflowSpecError.invalidJudge(stage: stage.id, reason: "keep must be >= 1 (got \(j.keep))")
                }
                if let m = j.minScore, !(0...100).contains(m) {
                    throw WorkflowSpecError.invalidJudge(stage: stage.id, reason: "min_score must be 0-100 (got \(m))")
                }
            }
            if let r = stage.route, r != "smart" {
                throw WorkflowSpecError.unknownRoute(stage: stage.id, route: r)
            }
            // Recipe stages may pull provider/model from the recipe itself;
            // that is enforced after resolution (WorkflowRecipeResolver.inline).
            if stage.route == nil && stage.recipe == nil
                && (stage.provider == nil || stage.model == nil) {
                throw WorkflowSpecError.missingProvider(stage.id)
            }
        }

        // Cycle detection via the existing DAG resolver (Kahn's algorithm).
        try checkCycles(spec)
    }

    private static func checkCycles(_ spec: WorkflowSpec) throws {
        // Reuse DAGResolver by mapping stages to minimal Shots.
        let now = Date()
        let shots = spec.stages.enumerated().map { (idx, stage) in
            Shot(
                id: stage.id, sceneId: "wf", name: stage.id, orderIndex: idx,
                prompt: stage.prompt ?? "", negativePrompt: nil, status: .pending,
                provider: nil, model: nil, duration: nil, aspectRatio: nil,
                width: nil, height: nil, referenceImageURL: nil, referenceAssetId: nil,
                extraParams: [:], dependencies: stage.needs ?? [], generationIds: [],
                selectedGenerationId: nil, routingDecision: nil,
                estimatedCostUSD: nil, actualCostUSD: nil,
                maxRetries: nil, errorMessage: nil, qualityScore: nil,
                evaluationReasoning: nil, evaluationDimensions: nil,
                createdAt: now, startedAt: nil, completedAt: nil
            )
        }
        do { try DAGResolver.validateNoCycles(shots: shots) }
        catch let e as ProjectSpecError {
            if case .cyclicDependency(let m) = e {
                throw WorkflowSpecError.cyclicDependency(m)
            }
            throw e
        }
    }

    /// Resolve prompt chains: prompt_from copies the (resolved) prompt of the
    /// referenced stage. Chains of prompt_from are followed; validation
    /// guarantees the graph is acyclic and references exist.
    static func resolvedPrompts(_ spec: WorkflowSpec) throws -> [String: String] {
        // Tolerate duplicate stage ids rather than trapping — parser validation
        // rejects them upstream; this must not be a hard crash for stray input.
        let byId = Dictionary(spec.stages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var resolved: [String: String] = [:]

        func resolve(_ id: String, seen: Set<String>) throws -> String {
            if let p = resolved[id] { return p }
            guard let stage = byId[id] else {
                throw WorkflowSpecError.unknownPromptFrom(stage: id, source: id)
            }
            if let p = stage.prompt {
                resolved[id] = p
                return p
            }
            // Recipe stages must be inlined (WorkflowRecipeResolver.inline)
            // before prompt resolution.
            if let recipeId = stage.recipe {
                throw WorkflowSpecError.unknownRecipe(stage: id, recipeId: recipeId)
            }
            guard let src = stage.promptFrom, !seen.contains(src) else {
                throw WorkflowSpecError.cyclicDependency("prompt_from chain involving '\(id)'")
            }
            let p = try resolve(src, seen: seen.union([id]))
            resolved[id] = p
            return p
        }

        for stage in spec.stages {
            _ = try resolve(stage.id, seen: [])
        }
        return resolved
    }
}

// MARK: - Recipe-backed stages (pure resolution)

/// Composition v1: a workflow stage may reference a recipe from the local
/// RecipeStore (`"recipe": "<recipe-id>"`). The stage pulls prompt, provider,
/// model, and params from the recipe, applying the recipe's declared args
/// with the stage's `args` values. Stage-level fields override recipe fields.
/// No recursive recipe execution — stages are the composition unit.
enum WorkflowRecipeResolver {

    /// Inline the recipe into the stage. Pure: the recipe is passed in
    /// (nil means the id was not found in the store → `unknown_recipe`).
    /// Throws `RecipeArgError` for arg problems (e.g. `missing_arg`).
    static func inline(stage: WorkflowStage, recipe: CLIRecipe?) throws -> WorkflowStage {
        guard let recipeId = stage.recipe else { return stage }
        guard let recipe else {
            throw WorkflowSpecError.unknownRecipe(stage: stage.id, recipeId: recipeId)
        }

        let values = try RecipeArgResolver.resolve(args: recipe.args ?? [],
                                                   provided: stage.args ?? [:])
        let resolved = recipe.substituting(values)

        var out = stage
        out.prompt = resolved.promptText
        if out.negativePrompt == nil, !resolved.negativePromptText.isEmpty {
            out.negativePrompt = resolved.negativePromptText
        }
        // route: "smart" keeps provider/model open for the router even when
        // the recipe pins them.
        if out.route == nil {
            if out.provider == nil { out.provider = resolved.provider }
            if out.model == nil    { out.model = resolved.model }
        }
        if out.duration == nil    { out.duration = resolved.durationSeconds }
        if out.aspectRatio == nil { out.aspectRatio = resolved.aspectRatio }

        // Consistency intent (recipe v3): carried into the stage plan.
        // Stage-level fields override recipe fields, like everything else.
        if out.referenceImages == nil { out.referenceImages = resolved.referenceImages }
        if out.styleLock == nil       { out.styleLock = resolved.styleLock }

        // Params: recipe params first, stage params override.
        var params = resolved.parameterStrings()
        for (k, v) in stage.params ?? [:] { params[k] = v }
        if !params.isEmpty { out.params = params }

        // styleLock.seedPolicy = fixed: pin the recipe's seed into the stage
        // params so every fanout candidate reuses it (recipe seed is otherwise
        // not carried into params). Random seed generation for seedless fixed
        // stages happens later, in StyleLockSeed.apply.
        if out.styleLock?.seedPolicy == .fixed, out.params?["seed"] == nil, let seed = resolved.seed {
            var p = out.params ?? [:]
            p["seed"] = String(seed)
            out.params = p
        }

        // After inlining, an explicit provider+model (or smart routing) must exist.
        if out.route == nil && (out.provider == nil || out.model == nil) {
            throw WorkflowSpecError.missingProvider(stage.id)
        }
        return out
    }
}

// MARK: - Seed policy (pure)

/// styleLock.seedPolicy semantics for a stage's fanout candidates:
/// - `fixed`: one seed shared by every candidate. An explicit `params["seed"]`
///   (stage or recipe) wins; otherwise a seed is derived deterministically
///   from `seedSource` (workflow name + stage id), so the whole fanout, any
///   `--resume`, and any re-run of the same file reuse the SAME seed —
///   consistency is reproducible, not a per-process dice roll.
/// - `per_shot` (or no styleLock): current behavior — params untouched; a
///   provider without an explicit seed randomizes per candidate.
enum StyleLockSeed {

    static func apply(params: [String: String]?, styleLock: StyleLock?,
                      seedSource: String) -> [String: String]? {
        guard styleLock?.seedPolicy == .fixed else { return params }
        var out = params ?? [:]
        if out["seed"] == nil {
            out["seed"] = String(deterministicSeed(from: seedSource))
        }
        return out
    }

    /// Stable seed in 0..<2^31-1 from an arbitrary source string
    /// (SHA256 prefix — same source, same seed, on every machine).
    static func deterministicSeed(from source: String) -> Int {
        let digest = SHA256.hash(data: Data(source.utf8))
        let bytes = Array(digest.prefix(4))
        let value = bytes.reduce(0) { ($0 << 8) | Int($1) }
        return value % 2_147_483_647
    }
}

// MARK: - Judge selection (pure)

enum JudgeSelector {

    struct Candidate {
        let id: String
        let score: Double?
    }

    /// Keep the top `keep` candidates by score, dropping any below `minScore`.
    /// Candidates without scores are only used as a fallback when nothing was
    /// scored at all (evaluator unavailable) — then the first `keep` are kept
    /// unfiltered, since there is nothing to judge them by.
    static func selectTopK(_ candidates: [Candidate], keep: Int, minScore: Double?) -> [Candidate] {
        guard keep > 0 else { return [] }
        let scored = candidates.filter { $0.score != nil }
        guard !scored.isEmpty else {
            return Array(candidates.prefix(keep))
        }
        var pool = scored
        if let min = minScore {
            pool = pool.filter { ($0.score ?? 0) >= min }
        }
        let sorted = pool.sorted { ($0.score ?? 0) > ($1.score ?? 0) }
        return Array(sorted.prefix(keep))
    }
}

// MARK: - Cost estimate (pure)

enum WorkflowCost {
    /// Up-front stage estimate from the provider cost tables:
    /// cost/second × duration (default 4s, matching generate --dry-run) × fanout.
    static func estimate(costPerSecondUSD: Double?, duration: Double?, fanout: Int) -> Double? {
        guard let cps = costPerSecondUSD else { return nil }
        return cps * (duration ?? 4) * Double(max(1, fanout))
    }
}

// MARK: - Budget approval gate (pure)

enum WorkflowBudgetGate {

    enum Decision: Equatable {
        case proceed
        case approvalRequired(estimate: Double, limit: Double)
    }

    /// Gate math: when a limit exists (--max-spend or budget_usd) and the
    /// up-front estimate exceeds it, approval (--yes) is required.
    static func check(estimatedTotalUSD: Double, limitUSD: Double?, approved: Bool) -> Decision {
        guard let limit = limitUSD else { return .proceed }
        if estimatedTotalUSD > limit && !approved {
            return .approvalRequired(estimate: estimatedTotalUSD, limit: limit)
        }
        return .proceed
    }
}
