# Changelog

## v1.3.0 — 2026-06-15

Local-AI monitoring — a dedicated cockpit for people running LLMs on Apple Silicon.

- **AI runtime detection** — recognizes Ollama, llama.cpp, LM Studio, MLX, Jan, GPT4All,
  and vLLM by process (bundle-first matching, sudoless) and surfaces the active runtime
  with its RAM / CPU.
- **Model memory budget** — "largest model that fits now" + "if you unload <model>" (per
  quant), with a rate-based swap/compression risk signal that warns *before* tokens/sec
  collapse (not the static used%).
- **Runtime API (opt-in, off by default)** — reads the loaded model, the authoritative
  GPU/CPU offload split (Ollama `size_vram/size`), and tokens/sec (llama.cpp `/metrics`)
  from `127.0.0.1`. Nothing leaves your Mac. Settings → "Connect to local AI runtimes".
- **AI Workload classifier** retuned against real M1 Max LLM runs (bandwidth-bound at the
  ~50%-of-theoretical regime real decode actually hits) and stabilized with a rolling
  average so the verdict no longer flickers.
- Menu bar gains AI runtime + model-budget lines; `sscope-cli --ai` one-shot probe.

Design + validation: [`docs/ai-local-features-design.md`](docs/ai-local-features-design.md).
The classifier was calibrated against MoE, dense, and memory-pressured runs on an M1 Max.

## v1.2.0 — 2026-06-14

AI-workload monitoring — the next-version hero feature.

- **AI Workload view** — a bottleneck classifier with a single verdict:
  bandwidth-bound / compute-bound / thermal-throttled / memory-pressured (plus idle /
  GPU-active). Front-and-center hero card on the dashboard; mirrored as a `Workload:`
  line in the menu bar.
- **Per-chip memory-bandwidth ceiling table** + a "% of ceiling" gauge (M1–M4; Max bins
  split by P-core count; self-corrects to the observed peak for chips outside the table).
- **GPU throttle detector** — flags the GPU clock held below its slowly-decaying rolling
  peak while thermal pressure has risen (warning banner + menu-bar flame).
- **Compact GPU menu-bar mode** — single line: GPU% / GPU W / GPU GB/s / die °C.

Thanks to @durul for contributing this feature (#2).

## v1.1.0 — 2026-06-14

Renamed **WhisPlayInfo → SiliconScope**.

The project outgrew its origin as a companion utility; the name now reflects what
it is — a general Apple Silicon / SoC inspector. No functional changes to the
metrics in this release.

- App / product name: **SiliconScope** (was WhisPlayInfo)
- Bundle identifier: `ai.calidalab.SiliconScope` (was `ai.calidalab.WhisPlayInfo`)
- SwiftPM targets: `SiliconScope` (app), `SiliconScopeCore` (data library),
  `sscope-cli` (verification CLI)
- Repository: `github.com/kennss/SiliconScope` (the old URL redirects)

> Because the bundle identifier changed, this installs alongside any existing
> WhisPlayInfo rather than upgrading it in place — delete the old app if you have it.

## v1.0.2 — 2026-06-09

Crash fix: launch failure on macOS 27.

- Fixed an immediate crash on launch under macOS 26/27 (`EXC_BREAKPOINT` in
  `Bundle.module`). The SwiftPM resource bundle is a flat folder with no
  `Info.plist`; macOS 27's stricter bundle validation rejects it, so SwiftPM's
  generated `Bundle.module` accessor hit its `fatalError`.
- The app icon is now resolved via the main bundle (with a dev-run fallback),
  removing all dependence on `Bundle.module`. Thanks to @colaH16 (#1).

## v1.0.1 — 2026-06-09

Bug fix: memory-bandwidth Media Engine reporting.

- Fixed Media Engine bandwidth reading 0 while a media-engine app (e.g. video
  transcoding) was active — now classifies the real channels (VENC / VDEC /
  ISP / JPEG / STRM CODEC / ProRes), matching NeoAsitop.
- `MSR` is no longer miscounted as Media; it now falls into Other.
- Total bandwidth now uses the chip-wide `DCS` aggregate, with Other derived as
  total − CPU − GPU − Media, so the parts sum to the real total (previously
  double-counted, ~104 vs ~50 GB/s).

## v1.0.0 — 2026-06-09

First public release. A sudoless Apple Silicon system monitor with a native SwiftUI GUI.

- CPU E-core / P-core usage (tick-based, Activity-Monitor-accurate) + per-cluster frequency
- GPU utilization / power / frequency; ANE power; Media Engine bandwidth
- Memory: Wired / Active / Compressed / Free stacked bar + macOS memory-pressure alerts
- Memory bandwidth: CPU / GPU / Media / total
- Network ↑/↓ and Disk read/write + free capacity, with live graphs
- Temperatures grouped CPU / GPU / Memory / Battery (SMC, per-core folded), fans, thermal pressure
- Per-domain power (CPU/GPU/ANE/DRAM/SoC), battery %
- Processes: sort / filter / kill, in-card scroll
- Menu-bar mode + full dashboard; settings (refresh interval, °C/°F)
- App icon + bar-motif menu-bar glyph
