# SiliconScope — Design Doc: Local-AI User Features (①②③) — v2.1 (FINAL, ship-approved)

**Author:** Agent 가 (A) — revised and ship-approved by Agent 라 (D)
**Target repo:** `/Users/kennt/Desktop/Developments/ktop` (product: SiliconScope)
**Scope:** Three sudoless, layer-separated local-AI features. Logic in `SiliconScopeCore` (no SwiftUI), UI in `SiliconScope`.
**Status:** Implementation-ready, GO-WITH-CHANGES. Every load-bearing fact below was re-verified by D against the live codebase and live processes (see §0). Changes folded in by D are marked **[D]**.

---

## 0. Grounding — re-verified facts (D's independent verification)

D confirmed all of the following by reading the live code and running probes:

- **Layer rule is real and currently clean:** `grep -rl 'import SwiftUI' Sources/SiliconScopeCore/` → NONE. `Bottleneck.color` lives in `Theme.swift` via an extension. New AI types follow the same split.
- **`SystemSampler.sample(interval:)`** runs all samplers **serially**; the monitor calls it with `interval: 0.2` inside `Task.detached(.utility)` and it blocks ~3× (three IOReport samplers sleep internally) ≈ **~0.6 s/sample**. New inline work must be cheap and non-blocking. (Note: the doc's "175ms" is the conceptual delta; the live call uses 0.2 — harmless.)
- **`SiliconScopeMonitor`** is `@MainActor @Observable`; the loop **pulls** `refreshInterval` from `UserDefaults` each tick (line 126). No live push. `loopTask` has a `guard loopTask == nil` idempotency guard. Rolling peaks (`gpuClockPeakMHz`, `bandwidthPeakGBs`) are tracked in-loop — the exact pattern the new rate-delta risk logic mirrors.
- **`SettingsView()` is constructed bare** in the `Settings` scene (SiliconScopeApp.swift line 44–46) with **no** monitor reference. `@AppStorage` keys: `refreshInterval`, `temperatureFahrenheit`, `compactGPUMode`. ⇒ 나-M3's pull-based lifecycle is the correct (and only clean) wiring.
- **`ProcessSampler`** builds `[ProcessRow]` via `proc_listallpids` → `proc_pidinfo(PROC_PIDTASKINFO)` + `proc_name`. It does NOT read path. **[D] VERIFIED LIVE:** `proc_pidpath` returns the full executable path sudoless for user-owned pids (e.g. `/Applications/Ollama.app/Contents/MacOS/Ollama`), and **`KERN_PROCARGS2` argv reading works sudoless** for user-owned processes (parsed `ollama serve` and a full swift-frontend cmdline cleanly). **[D] Performance measured:** `proc_pidpath` across **1084 pids = 7.1 ms total** — negligible vs the ~600 ms `sample()` budget.
- **`MemorySample`** has `wiredBytes`, `activeBytes`, `compressedBytes`, `swapUsedBytes`, `pressure`. **[D] VERIFIED in SDK** (`mach/vm_statistics.h`, vm_statistics64): `compressions` (l.167), `swapins` (l.168), `swapouts` (l.169), `pageouts` (l.150), `decompressions` (l.166) all exist as `uint64_t` lifetime counters. `MemorySampler` currently reads only `compressor_page_count`. These are the basis for the predictive swap signal.
- **Ollama process layout (re-verified live):** parent `…/Ollama.app/Contents/MacOS/Ollama`; `…/Ollama.app/Contents/Resources/ollama serve`. Both paths contain `/Ollama.app/` ⇒ bundle-first match collapses them to `.ollama`. **[D] CAVEAT:** at verification time Ollama had **no model loaded** — `/api/ps` returned `{"models":[]}` and **no `llama-server` child existed**. The doc's "verified" runner argv (`--port 63071`, gemma) is from an earlier session and is **stale/not currently reproducible**. ⇒ See **Change C1**.
- **`Bottleneck.classify`** thresholds (verified): `idle` = `gpu.usage < 0.30`; `computeBound` = `gpu.usage ≥ 0.90 && bwFraction < 0.60`. These exact thresholds anchor the CPU-offload heuristic (§1.4). `GPUSample.usagePercent` exists.
- **UI surfaces:** `DashboardView` hosts private `AIWorkloadCard` (hero, line 144) + a grid; `allWarnings()` merges data-level + context warnings; `MenuBarView.fullReadout` is a `KV` stack; `Theme.swift` has `Card`, `Bar`, `KV`, `StackedBar`, `Sparkline`, `heat()`. Monitor exposes `bandwidthPercentOfCeiling`, `bottleneck`, `gpuThrottling`.

### D's folded-in changes (deltas vs Agent A's v2)

- **C1 (must-do at impl time):** The adversarial Ollama-runner unit test must use a **freshly captured live argv**, not the doc's `--port 63071` string. At implementation, start a model (`ollama run <model>`), capture the `llama-server` argv via `ps -ww -o command -p <pid>` or the new KERN_PROCARGS2 reader, and pin THAT into the test. The stale string is illustrative only.
- **C2 (must-do):** The KERN_PROCARGS2 parse is the single most bug-prone new syscall (argc framing, exec-path skip, embedded NULs, KERN_ARGMAX sizing). Ship the concrete, D-tested parser in §0.1 verbatim rather than an inline sketch.
- **C3:** `proc_pidpath` for the system pids it can't read returns 0 → fall back to `name`. Confirmed live: 891/1084 paths resolved; the rest are root/other-user and correctly degrade. No crash, no permission prompt.
- **C4:** Add an explicit "data freshness" guard for ③: `runtimeAPI.lastUpdated` staleness > 3× cadence ⇒ treat as `.unreachable` in the cockpit, so a wedged poll task never shows a frozen rate.
- **C5:** The monitor's previous-counter state for the rate deltas must reset cleanly on `stop()`/`start()` (avoid a huge spurious first-tick delta after a pause). Seed `previous = nil` and emit `risk = .ok`/rates = 0 on the first tick after (re)start.

### 0.1 [D] Battle-tested KERN_PROCARGS2 parser (use verbatim)

```swift
// Sudoless for user-owned processes (verified live). Returns argv, or nil if denied.
// Notes: KERN_ARGMAX sizes the buffer; layout is [Int32 argc][exec_path\0...][\0 padding][argv0\0 argv1\0 ...].
static func processArgs(_ pid: pid_t) -> [String]? {
    var argmax: Int32 = 0
    var sz = MemoryLayout<Int32>.size
    var mibAM = [CTL_KERN, KERN_ARGMAX]
    guard sysctl(&mibAM, 2, &argmax, &sz, nil, 0) == 0, argmax > 0 else { return nil }

    var buf = [CChar](repeating: 0, count: Int(argmax))
    var size = Int(argmax)
    var mib = [CTL_KERN, KERN_PROCARGS2, pid]
    guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }

    var argc: Int32 = 0
    memcpy(&argc, buf, MemoryLayout<Int32>.size)
    guard argc > 0 else { return nil }

    var cursor = MemoryLayout<Int32>.size
    while cursor < size && buf[cursor] != 0 { cursor += 1 }      // skip exec path
    while cursor < size && buf[cursor] == 0 { cursor += 1 }      // skip NUL padding

    var result: [String] = []
    var collected = 0
    while collected < Int(argc) && cursor < size {
        let start = cursor
        while cursor < size && buf[cursor] != 0 { cursor += 1 }
        let arg = buf[start..<cursor].withUnsafeBufferPointer { p in
            String(decoding: p.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
        result.append(arg)
        collected += 1
        cursor += 1
    }
    return result.isEmpty ? nil : result
}
```

Two shared building blocks introduced once:
- **`proc_pidpath` (all pids) + gated `KERN_PROCARGS2` argv (AI-candidate basenames only)** added to `ProcessSampler`; each `ProcessRow` carries `path` and (for matched candidates only) `args`.
- **`LocalHTTP`** — a localhost-only `URLSession` helper (timeouts, no proxy), used only by ③.

---

## Feature ① — AI Runtime Detection + Pin (+ CPU-offload hint)

**Goal:** Detect local AI runtimes by process; surface a dedicated panel (runtime name + RAM / CPU% + an honest engine/offload hint); degrade cleanly when none runs. 100% sudoless, no network.

### 1.1 Data model (`SiliconScopeCore`)

**`AIRuntime.swift`** — catalog + identity (pure, no syscalls):

```swift
public enum AIRuntimeKind: String, Sendable, CaseIterable {
    case ollama, llamaCpp, lmStudio, mlx, jan, gpt4all, vllm
    public var displayName: String { ... }   // "Ollama", "llama.cpp", "LM Studio", "MLX", ...

    /// Bundle/path identity wins over basename (basenames collide — Ollama's
    /// llama-server child). `args` optional (populated only for AI candidates).
    static func match(path: String, name: String, args: String?) -> AIRuntimeKind? { ... }
}
```

**`AIRuntimeSample.swift`** — per-snapshot result:

```swift
public struct AIRuntimeProcess: Sendable, Equatable, Identifiable {
    public let pid: Int32
    public let kind: AIRuntimeKind
    public let displayName: String
    public let cpuPercent: Double      // summed across cores (ProcessRow convention)
    public let memoryBytes: UInt64     // RSS
    public let embeddedPort: Int?      // parsed from argv (Ollama runner --port); nil otherwise
    public var id: Int32 { pid }
}

public struct AIRuntimeSample: Sendable, Equatable {
    public var processes: [AIRuntimeProcess] = []
    public init() {}
    public var isActive: Bool { !processes.isEmpty }
    /// Headline kind = largest *grouped* RSS (bundle identity already collapsed
    /// Ollama parent+runner into .ollama). RSS only ranks *within* a kind.
    public var primaryKind: AIRuntimeKind? { ... }
    public func processes(of kind: AIRuntimeKind) -> [AIRuntimeProcess] { processes.filter { $0.kind == kind } }
    public func memoryBytes(of kind: AIRuntimeKind) -> UInt64 { ... }
    public func cpuPercent(of kind: AIRuntimeKind) -> Double { ... }
    public var totalMemoryBytes: UInt64 { processes.reduce(0) { $0 + $1.memoryBytes } }
    public var totalCPUPercent: Double { processes.reduce(0) { $0 + $1.cpuPercent } }
    public var ollamaEmbeddedPort: Int? { processes.first { $0.kind == .ollama && $0.embeddedPort != nil }?.embeddedPort }
}
```

Field added to **`SystemSnapshot`**: `public var aiRuntime = AIRuntimeSample()`.
Fields added to **`ProcessRow`**: `public let path: String` and `public let args: String?` (default `nil`; populated only for AI candidates). **[D] Keep `init` source-compatible** — give both a default so existing call sites (sscope-cli, tests) compile unchanged.

### 1.2 Matching — bundle-first, two-stage

`proc_name`/`proc_comm` truncate to 15 chars, so **path basename is mandatory** and **bundle identity overrides basename**. Resolution order in `match(path:name:args:)`:

**Stage 1 — bundle / well-known-dir identity (authoritative):**
- path contains `/Ollama.app/` **OR** `/.ollama/` (incl. `--model …/.ollama/models/blobs/…` in args) ⇒ `.ollama`. *Catches the `llama-server` runner child; prevents the llama.cpp collision. **[D] verified:** both the Ollama parent and `ollama serve` paths contain `/Ollama.app/`, so they collapse correctly.*
- path contains `/LM Studio.app/` ⇒ `.lmStudio` (its bundled llama.cpp child forced to `.lmStudio`).
- path contains `/Jan.app/` or `/jan/` ⇒ `.jan`.
- path contains `/GPT4All.app/` or `/gpt4all/` ⇒ `.gpt4all`.

**Stage 2 — basename/args (only if Stage 1 found nothing):**
- basename in `{llama-server, llama-cli, llama-bench}` ⇒ `.llamaCpp` (unambiguous; generic `server`/`main` are **not** matched).
- `args` contains `mlx_lm.server` / `mlx_lm.generate` / `mlx_lm` ⇒ `.mlx`.
- basename `lms` or path/args contain `LM Studio` ⇒ `.lmStudio`.
- args/path contain `vllm` ⇒ `.vllm`.

**Argv** is read (via the §0.1 parser) **only** for processes whose path basename ∈ the AI-candidate shortlist (`llama-server`, `llama-cli`, `python`/`python3`, `lms`, `ollama`), so KERN_PROCARGS2 never runs for all pids. The Ollama runner's `--port` is parsed here into `embeddedPort`.

**Mandatory adversarial unit tests** (real data — **[D] C1: re-capture the runner argv live before pinning**):
- Ollama runner: `path = /Applications/Ollama.app/Contents/Resources/llama-server`, `args = "<freshly captured> --model /Users/…/.ollama/models/blobs/… --port <N> --host 127.0.0.1 -c <ctx> …"` ⇒ **`.ollama`**, `embeddedPort == N`. (Must NOT be `.llamaCpp`.)
- Ollama parent `…/Ollama.app/Contents/MacOS/Ollama` ⇒ `.ollama`; `…/Ollama.app/Contents/Resources/ollama serve` ⇒ `.ollama`; grouped under one kind.
- Bare `…/build/bin/llama-server` (no Ollama/LM Studio in path) ⇒ `.llamaCpp`.
- Generic `/usr/sbin/server`, `/usr/bin/main` ⇒ **no match**.
- `python … mlx_lm.server …` ⇒ `.mlx`; bare `python` ⇒ no match.
- **[D] add:** empty/denied path (system pid) ⇒ no match, no crash.

### 1.3 Sampler & integration

- **`AIRuntimeSampler`** is a stateless struct: `sample(from rows: [ProcessRow]) -> AIRuntimeSample`. Reuses the already-built `[ProcessRow]` (O(n) filter; zero extra pid enumeration). CPU%/RAM straight from matched rows (consistent with the Processes table by construction).
- **`ProcessSampler`** adds `proc_pidpath` for every pid (~7 ms/1084 pids — verified; falls back to `name` on 0), and gated `KERN_PROCARGS2` argv (§0.1) only for AI-candidate basenames.
- **`SystemSampler.sample()`**: after `snapshot.processes = processes.sample()`, add `snapshot.aiRuntime = aiRuntime.sample(from: snapshot.processes)`. No sleep, no IOReport.
- **`SiliconScopeMonitor`**: no new state for ① alone; `monitor.snapshot.aiRuntime` read directly.

### 1.4 Engine / GPU-involvement honesty (no per-pid GPU)

Per-process GPU is sudoless-impossible (NEXT_VERSION out of scope) — never claimed. The cockpit shows:
- **③ reachable:** the runtime's authoritative `size_vram/size` split (e.g. "100% GPU"). Chip-inferred system line **suppressed** to avoid contradiction.
- **③ off/unreachable:** chip-level `bottleneck` / `likelyAIEngine` / `gpu.usagePercent`, always tagged **"(system, not per-process)"**, e.g. `GPU 64% (system) · GPU/Metal (LLM-style)`.
- **CPU-offload hint (sudoless, no network):** when a runtime is active and its own CPU% is high while system `gpu.usage` is only moderate (**[D]** anchor on the existing classifier thresholds: runtime `cpuPercent` high AND `gpu.usage` between idle (0.30) and computeBound (0.90)), show `likely partial CPU offload (est.)`. Available **without** the opt-in; contextually nudges enabling ③ for the exact split.

### 1.5 Edge cases
None running ⇒ `isActive == false` ⇒ dim "No local AI runtime detected" (card persists, no layout shift). Multiple runtimes ⇒ grouped by kind, headline = largest grouped RSS by bundle identity. Path denied (system pids) ⇒ fall back to `name`; user-owned runtimes stay inspectable.

### 1.6 File changes — Effort: **S–M**
New: `AIRuntime.swift`, `AIRuntimeSample.swift`, `AIRuntimeSampler.swift` (Core). Edit: `ProcessRow.swift` (+`path`,+`args`, defaulted), `ProcessSampler.swift` (+`proc_pidpath`,+gated parser §0.1), `SystemSnapshot.swift`, `SystemSampler.swift`, `sscope-cli/main.swift`. UI in the cockpit (§Shared UI).

---

## Feature ② — Model Memory Budget / Headroom (predictive)

**Goal:** From unified memory + wired(Metal) usage, estimate the largest model that fits, with two honest figures, and warn **before** tokens/sec collapses — using the real precursor (compression/swap activity), not a static ratio.

### 2.1 Data model (`SiliconScopeCore`)

**`MemoryBudget.swift`** — pure derivation from `MemorySample` + active runtime RSS:

```swift
public struct MemoryBudget: Sendable, Equatable {
    public enum Risk: String, Sendable { case ok, tight, swapping }

    public let totalBytes, usedBytes, wiredBytes, swapUsedBytes: UInt64
    public let reservedBytes: UInt64                 // OS/UI/app headroom kept back
    public let headroomNowBytes: UInt64              // max(0, total - used - reserved) [coexists with all resident]
    public let loadableBytes: UInt64                 // headroomNow + activeRuntimeRSS  [if you unload the current model]
    public let risk: Risk                            // STATIC part; monitor refines with rates (§2.3)
    public let contextTokens: Int                    // assumption used for KV sizing

    public var headroomNowGB: Double { ... }
    public var loadableGB: Double { ... }
    public func fits(_ bytes: UInt64) -> [ModelFit] { ... }
    public static let empty = ...
}

public struct ModelFit: Sendable, Equatable, Identifiable {
    public let quant: String        // "Q4_K_M","Q8_0","F16"
    public let bytesPerParam: Double
    public let maxParamsBillions: Double
    public var id: String { quant }
    public var label: String { ... } // "~13B (Q4_K_M)"
}

public static func estimate(memory: MemorySample,
                            activeRuntimeRSS: UInt64 = 0,
                            contextTokens: Int = 8192,
                            reserveFraction: Double = 0.10,
                            reserveFloorBytes: UInt64 = 3 << 30) -> MemoryBudget
```

`SystemSnapshot` gets `public var memoryBudget = MemoryBudget.empty` (precomputed in the sampler so the flat value carries to CLI/History).

### 2.2 Estimation math (sudoless; two figures + context-aware KV)

No new syscalls for the budget itself (derives from `MemorySample`).

- **Reserve:** `max(reserveFloorBytes, total * reserveFraction)` — tunable in Settings (defaults `max(3 GB, 10%)`).
- **Two figures:**
  - `headroomNow = max(0, total − used − reserved)` — fits **alongside** everything resident. Conservative because `used` includes evictable cache (documented in tooltip).
  - `loadable = headroomNow + activeRuntimeRSS` — fits **after** the current model unloads (meaningfully > headroom only when ① detects an active runtime). UI labels distinctly: "Free now: ~3B" vs "If you unload <model>: ~30B".
- **Largest model for budget B:** `weights ≈ params × bytesPerParam`; `kvBytes ≈ f(contextTokens)` (per-token KV estimate scaled by a coarse layer/dim heuristic, labeled). `maxParamsB = (B − kvBytes − runtimeOverhead) / bytesPerParam / 1e9`. Bytes/param: Q4_K_M ≈ 0.56, Q8_0 ≈ 1.06, F16 ≈ 2.0. **Context length is an explicit input** (default 8192; `/api/ps context_length` when ③ on). All "~" estimates, ANE-est posture. **[D]:** when ③ provides `parameter_size`/`quantization_level` for the resident model, prefer those authoritative numbers over reverse-engineering for the *running* model; reverse-engineering remains for the hypothetical "what would fit."

### 2.3 Predictive risk (the real precursor)

`usedFraction ≥ 0.85` is **removed** (macOS keeps used high via cache). Instead:

- **`MemorySampler` gains** `compressions`, `swapins`, `swapouts`, `pageouts` (verified present in `vm_statistics64`) on `MemorySample`.
- **`SiliconScopeMonitor`** stores previous counters + timestamp and computes **rates** (Δ/interval), mirroring rolling-peak tracking:
  - `swapping` ⇐ `swapins`/`swapouts` rate > 0 **OR** `pressure == .critical`.
  - `tight` ⇐ `compressions` rate rising **while a runtime is resident** **AND** `headroomNow` near zero.
  - `ok` otherwise.
- **[D] C5:** on `start()`/`stop()`, reset `previousCounters = nil`; the first tick after (re)start emits rates = 0 and `risk = .ok` (no spurious huge delta).
- **Split mirrors `gpuThrottling`:** static `Risk` in Core; temporal refinement (rates) in the monitor. Validation: load a model larger than free RAM; confirm `compressions`-rate moves first, then swap. Cross-link ①: "gemma:26b using 17 GB; <2 GB headroom — larger models will swap."

### 2.4 Integration & edge cases
`SystemSampler.sample()`: after `snapshot.memory`, compute `snapshot.memoryBudget = MemoryBudget.estimate(memory:…, activeRuntimeRSS: snapshot.aiRuntime.memoryBytes(of: primaryKind), contextTokens:…)`. Pure arithmetic. `total == 0` ⇒ `.empty`. `headroomNow ≤ 0` ⇒ "no headroom" + tight/swapping. 8 GB Macs ⇒ honest 0. No runtime ⇒ budget still shown. Warnings: data-level `.swapping` in `SystemSnapshot.warnings`; context `.tight` (runtime active) in `DashboardView.allWarnings`.

### 2.5 File changes — Effort: **S–M**
New: `MemoryBudget.swift`. Edit: `MemorySample.swift` (+counters), `MemorySampler.swift` (read counters), `SystemSnapshot.swift` (+budget,+`.swapping` warning), `SystemSampler.swift`, `SiliconScopeMonitor.swift` (rate deltas, refined risk, C5 reset), `sscope-cli/main.swift`.

---

## Feature ③ — Tokens/sec + CPU/GPU split via runtime localhost APIs (OPT-IN)

**Goal:** Poll local runtime HTTP APIs for loaded model, size, processor split, eval rate. Opt-in (localhost). Never blocks the sampler or main thread; hard timeouts; graceful degradation.

> **Roadmap reconciliation:** `docs/NEXT_VERSION.md` is edited to move "tokens/sec" out of "Out of scope." It uses the runtimes' own HTTP APIs/logs (verified `eval_count`/`eval_duration`; `/metrics`), not chip telemetry — still 100% sudoless, gated opt-in because it opens localhost sockets.

### 3.1 Data model (`SiliconScopeCore`)

**`RuntimeAPISample.swift`:**

```swift
public struct RuntimeModelInfo: Sendable, Equatable, Identifiable {
    public let name: String
    public let sizeBytes: UInt64
    public let sizeVRAMBytes: UInt64       // ollama size_vram
    public let parameterSize: String?      // "25.8B" (verified from /api/ps when model loaded)
    public let quantization: String?       // "Q4_K_M"
    public let contextLength: Int?         // feeds ②'s KV math
    public var id: String { name }
    public var gpuFraction: Double { sizeBytes > 0 ? Double(sizeVRAMBytes)/Double(sizeBytes) : 0 }
    public var processorLabel: String { ... }   // "100% GPU" / "43%/57% CPU/GPU"
}

public struct RuntimeAPISample: Sendable, Equatable {
    public enum Source: String, Sendable { case ollama, llamaCpp, lmStudio }
    public enum Status: String, Sendable {
        case disabled            // feature off
        case unreachable         // no runtime / port closed / stale (C4)
        case runningNoServer     // ① detected runtime but its API/server is off
        case apiNotApplicable    // bare CLI llama.cpp (no HTTP server)
        case ok
    }
    public var status: Status = .disabled
    public var source: Source?
    public var loadedModels: [RuntimeModelInfo] = []
    public var tokensPerSec: Double?       // nil if not observable; never fabricated
    public var lastUpdated: Date?
    public init() {}
    public var isReachable: Bool { status == .ok }
}
```

**Carrying it:** the monitor **owns** `private(set) var runtimeAPI` (separate cadence, behind opt-in) and **stamps the latest into `snapshot.runtimeAPI`** when publishing (a single field added to `SystemSnapshot`, default `.init()`) so CLI/History work without the network living inside `sample()`.

New: **`RuntimeAPIClient.swift`** (probes) and **`LocalHTTP.swift`** (localhost-only `URLSession`).

### 3.2 Endpoints (verified fields)

All requests target the **IP literal `127.0.0.1`** (no DNS, no captive-portal/egress risk).

- **Ollama** `127.0.0.1:11434`:
  - `GET /api/ps` → `name, size, size_vram, context_length, details.{parameter_size, quantization_level}` (verified when a model is loaded; returns `{"models":[]}` when idle — **[D] handle the empty-models case as "no model loaded," distinct from unreachable**). **Split = size_vram/size.**
  - **tokens/sec (without running inference):** (a) embedded `llama-server` `/metrics` at the **dynamic port from argv** (parse `llamacpp:predicted_tokens_seconds`) — only if Ollama was started with metrics; (b) opt-in passive tail of the Ollama server log (user-owned file). If neither yields a value, `tokensPerSec = nil`. The fixed-8080 assumption is gone.
- **llama.cpp server** (`llama-server`, port from argv or default 8080): `GET /health`; `GET /props`; `GET /metrics` (`llamacpp:predicted_tokens_seconds` → real tokens/sec). Bare CLI `llama-cli` with no server ⇒ `status = .apiNotApplicable`.
- **LM Studio** (OpenAI-compat, 1234): `GET /api/v0/models` (newer; may 404) then fall back to `GET /v1/models`. Model id only; no standard rate.

**Discovery:** when enabled, probe order keyed by ①'s `primaryKind` (and `ollamaEmbeddedPort`). ① detected a runtime but no probe responds ⇒ `runningNoServer`. Ports user-overridable in Settings; Ollama embedded server auto-discovered from argv.

### 3.3 Concurrency (the critical part — pull-based wiring)

- **Pull-based lifecycle.** There is no Settings→monitor reference and `refreshInterval` is pulled. So the **always-running monitor loop** checks `UserDefaults` key `aiRuntimeAPIEnabled` each tick and lazily starts/stops the poll task:
  ```swift
  // inside the existing loop body, after publishing the snapshot:
  let apiEnabled = UserDefaults.standard.bool(forKey: "aiRuntimeAPIEnabled")
  if apiEnabled { startAPIPollingIfNeeded() } else { stopAPIPolling() }
  ```
  The Settings toggle just flips the `@AppStorage` key; the loop picks it up next tick.
- **Separate task:** `apiPollTask: Task<Void, Never>?` on the `@MainActor` monitor, guarded `guard apiPollTask == nil` (mirrors `loopTask`). Never runs inside `SystemSampler.sample()`.
- **Cadence:** 2–3 s, floored at 1 s.
- **Transport (`LocalHTTP`):** `URLSessionConfiguration.ephemeral`, `timeoutIntervalForRequest = 0.8`, `timeoutIntervalForResource = 1.5`, `connectionProxyDictionary = [:]`, `waitsForConnectivity = false`, `allowsCellularAccess = false`. Each call wrapped in a `withTimeout` race so a hung socket can't stall the loop.
- **[D] C4 staleness guard:** the cockpit treats `runtimeAPI` as `.unreachable` if `lastUpdated` is older than 3× cadence, so a wedged poll never shows a frozen rate.
- **Off-main:** `URLSession` async runs off-main; results assigned after `await` (monitor is `@MainActor`). Cancellation honored (`Task.isCancelled`); cancelled in `stop()` and when the key flips off. A failed probe sets `.unreachable`/`runningNoServer` and sleeps the cadence — no spin, no crash.

### 3.4 Opt-in / privacy
Default **OFF** (`@AppStorage("aiRuntimeAPIEnabled") = false`; task never spawned). Settings section "Local AI runtime API (opt-in)": enable toggle; one-line rationale ("Connects to AI runtimes on 127.0.0.1 to read loaded model, processor split, and tokens/sec. Nothing leaves your Mac."); optional log-tail sub-toggle for Ollama tokens/sec; port fields (Ollama 11434, LM Studio 1234; Ollama model-server port auto-discovered). Localhost-only guaranteed by IP literal + proxy/cellular off, documented in header + Settings copy. App is non-sandboxed (private IOReport) so no network entitlement needed for dev; packaging note: add `com.apple.security.network.client` if a future hardened/notarized build restricts outbound.

### 3.5 Edge cases
Off ⇒ `.disabled`, no task. Port closed ⇒ `.unreachable` (retry next cadence). Runtime up, server off ⇒ `.runningNoServer`. Bare CLI llama.cpp ⇒ `.apiNotApplicable`. **Ollama up, no model loaded (`{"models":[]}`)** ⇒ `.ok` with empty `loadedModels` (UI: "Ollama running — no model loaded"). Hung runtime ⇒ 0.8 s timeout + outer race + C4 staleness. Malformed/version-drift JSON ⇒ all-optional `Codable`, decode failure ⇒ `.unreachable`; `/api/v0`→`/v1` fallback. tokens/sec unknown ⇒ `nil`, UI omits. Cellular/VPN ⇒ no egress.

### 3.6 File changes — Effort: **L**
New: `LocalHTTP.swift`, `RuntimeAPISample.swift`, `RuntimeAPIClient.swift` (Core). Edit: `SystemSnapshot.swift` (+`runtimeAPI` stamped field), `SiliconScopeMonitor.swift` (state, pull-based lifecycle, poll task, C4 staleness), `SettingsView.swift` (opt-in section — `@AppStorage` only), `sscope-cli/main.swift` (`--ai`), `Package.swift` (no new dep; Foundation `URLSession`), `docs/NEXT_VERSION.md`.

---

## Shared UI — the AI Cockpit

A single new private card in `DashboardView`, directly under the `AIWorkloadCard` hero, constructed as the AI cockpit:

```swift
AIRuntimeCard(
    runtime: snapshot.aiRuntime,
    api: snapshot.runtimeAPI,                       // ③ (or .disabled)
    budget: snapshot.memoryBudget,                  // ②
    bandwidthPercent: monitor.bandwidthPercentOfCeiling,
    bottleneck: monitor.bottleneck,
    likelyEngine: snapshot.likelyAIEngine,
    gpuSystemPercent: snapshot.gpu.usagePercent
)
```

Layout:
- **Header:** runtime name(s) grouped by kind; summed RAM/CPU%. None ⇒ dim "No local AI runtime detected."
- **Engine line:** ③-reachable ⇒ runtime split ("100% GPU"); else chip line "(system, not per-process)" + CPU-offload hint when applicable.
- **Model line (③):** name, parameter_size, quant, context — or "Enable runtime API in Settings" / "runtime running — start its local server" / "API not applicable" / "no model loaded" per status.
- **Tokens/sec:** shown only when known.
- **Budget (②):** "Free now: ~3B (Q4) · If you unload <model>: ~30B" + tight/swapping chip.
- **Bandwidth:** `bandwidthPercentOfCeiling` as a small `Bar`.

All colors/icons for `AIRuntimeKind` and `RuntimeAPISample.Status` live in the app layer (Theme extension), mirroring `Bottleneck.color`.

**Menu bar `fullReadout`:** add `KV("AI runtime", primaryKind?.displayName ?? "none")`; `KV("Model budget", …)`; optional `KV("tok/s", …)` only when known.

**History:** push `tokensPerSec` (when known) and `bandwidthPercentOfCeiling` into `History` for sparklines.

---

## Cross-cutting

- **File headers:** every new file gets the mandatory block (Created/Updated **2026-06-14**, Developer Kennt Kim / Calida Lab, Overview, Notes). Every edited file bumps `Updated:`. English-only comments + UI.
- **Layer separation:** no `import SwiftUI` in any Core file (verified currently clean); UI colors/labels via app-layer extensions.
- **Source compatibility [D]:** `ProcessRow` new fields default so existing call sites (sscope-cli prints, tests) compile unchanged.
- **Concurrency:** ①/② samplers are stateless/value-returning, called serially inside the existing background `sample()`. ③ is the only new long-lived task — owned by the `@MainActor` monitor, pull-gated by `aiRuntimeAPIEnabled`, idempotent guard, explicit cancellation, C4 staleness, C5 counter reset on start/stop.
- **Roadmap edit:** `docs/NEXT_VERSION.md` — move "AI runtime detection" + "Model memory budget" to Shipped; move "tokens/sec" from Out-of-scope to "Shipped (opt-in, via runtime HTTP/logs, sudoless)"; keep "Per-process GPU/ANE attribution" out of scope.
- **Verification (build & run):** `sscope-cli --ai` prints detection (kind, RSS, CPU%, embedded port), budget (headroomNow + loadable + fits), and probe JSON, checkable via `xcrun swift run -q sscope-cli --ai`. GUI smoke-test against a **model-loaded** Ollama (`ollama run <model>`; confirm split, budget, tokens/sec if metrics/log enabled). Confirm `sample()` length doesn't measurably grow on the lowest-end M1 (proc_pidpath per pid + gated argv — measured 7 ms/1084 pids here).

## Suggested sequencing
1. **Step 0 shared plumbing** (path/args + parser) → 2. **②** (counters + budget) → 3. **①** (bundle-first detection; unlocks targeted probing + activeRuntimeRSS) → 4. **Cockpit UI** → 5. **③** (opt-in network).

## Residual risks
- **Stale live capture [D-C1]:** re-capture the Ollama runner argv with a model loaded before pinning the adversarial test (the doc's `--port 63071` is stale).
- **KERN_PROCARGS2 parse:** use the §0.1 parser verbatim; unit-test it.
- **Estimate trust:** ② "largest model" and ① engine/offload hints are estimates — strictly "~"/"est." labeled + tooltips.
- **API drift (③):** all-optional `Codable`, decode failure ⇒ degraded status, never crash.
- **Ollama metrics availability:** embedded `/metrics` exists only if Ollama launched with metrics; log-tail covers the common case, else tokens/sec honestly absent.
- **Task lifecycle (③):** `guard apiPollTask == nil` + cancel-on-disable + cancel-in-`stop()` + C4 staleness + C5 reset.

**Key files (absolute):** `/Users/kennt/Desktop/Developments/ktop/Sources/SiliconScopeCore/{SystemSampler,SystemSnapshot,ProcessSampler,ProcessRow,MemorySample,MemorySampler,Bottleneck,GPUSample,PowerSample,CPUTopology,ProcessControl}.swift`, `/Users/kennt/Desktop/Developments/ktop/Sources/SiliconScope/{SiliconScopeMonitor,SiliconScopeApp,DashboardView,MenuBarView,SettingsView,Theme}.swift`, `/Users/kennt/Desktop/Developments/ktop/Sources/sscope-cli/main.swift`, `/Users/kennt/Desktop/Developments/ktop/Package.swift`, `/Users/kennt/Desktop/Developments/ktop/docs/{NEXT_VERSION,display-spec}.md`.
