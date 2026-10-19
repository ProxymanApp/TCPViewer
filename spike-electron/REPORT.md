# Electron spike: engine process + viewport IPC benchmark

Throwaway prototype. It answers one question: if TCP Viewer for Windows/Linux were built on Electron, does the hot
path — native engine → utility process → MessagePort → sandboxed renderer table — stay smooth at 100k packets/s
and millions of rows? It does not capture packets or use Wireshark; the engine is synthetic.

**Answer: yes.** On Windows 11 the table held the display's full frame rate with zero janky frames at 100k and at
300k rows/s, with 4.5M and 13.5M rows. The UI's cost did not grow with the ingest rate. The costs that do matter
are memory (about 265 MB private / 600 MB summed working set before any packets) and renderer/GPU CPU while
scrolling, which the VM inflates because it has no GPU.

## What was built

| Piece | File | Role |
|---|---|---|
| Native engine | `native/engine_addon.cc` | Node-API addon. A native thread appends 40-byte rows at a fixed rate into chunked storage. `rowsClone` / `rowsPacked` format only the requested slice (≤ 2,000 rows). No JS value is created per stored row. |
| Engine host | `src/engine.js` | Runs in `utilityProcess.fork()`. Validates renderer messages, calls the addon, posts replies, and sends a 10 Hz `{count}` tick. |
| Main process | `src/main.js` | Window, engine process, `MessageChannelMain` wiring, per-process metrics, report file. Never on the data path. |
| Preload | `src/preload.js` | Sandboxed; forwards the engine port to the page and exposes only `getConfig` / `reportResults`. |
| Renderer | `src/renderer/*` | `sandbox: true`, `contextIsolation: true`, no Node, strict CSP, `textContent` only. Fixed-height table with ~40 recycled DOM rows, one request in flight, latest position wins. |
| Tools | `scripts/print-results.js`, `scripts/sample-cpu-windows.ps1` | Per-phase table; cycle-accurate Windows CPU sampling. |

Bench phases, run back to back while ingest continues:

- **idle**: view still, the CPU baseline.
- **ping**: back-to-back tiny round trips, the IPC latency floor.
- Then for each encoding (**clone** = structured clone of column arrays, **packed** = one ArrayBuffer of numeric
  columns plus a UTF-8 string blob):
  - **tail**: follow live capture.
  - **scroll**: fling at 200 rows/frame.
  - **jump**: random row every frame, the worst case.

## Environments

| | Windows 11 (the target) | macOS (reference) |
|---|---|---|
| Machine | VMPal VM on an Apple M5 Max: Windows 11 Pro 25H2 **ARM64**, 10 vCPU, 24 GB | Apple M5 Max host, 18 cores, 64 GB |
| Rendering | **Software**: no GPU passthrough, so Chromium uses WARP ("Microsoft Basic Render Driver") | Metal via ANGLE (hardware) |
| Display | 64 Hz | 60 Hz |
| Electron | 44.9.0 (Chromium 152) | 44.9.0 |
| Addon build | MSVC 19.44 ARM64 via cmake-js 8 | Apple Clang 21 |

## Results

Numbers are p50 / p95. CPU is % of one core (100 = one full core). Windows CPU comes from `QueryProcessCycleTime`
(see "Measurement pitfalls").

### Windows 11 ARM64, 100k rows/s (4.5M rows at the end)

| Phase | Round trip (ms) | Rows/req | Engine build (µs) | FPS | Frames > 33 ms | Placeholder frames | Renderer CPU | Engine CPU | GPU CPU |
|---|---|---|---|---|---|---|---|---|---|
| idle | — | — | — | 64.0 | 0 | — | 5.2% | 1.0% | 8.5% |
| ping (9.9k/s) | 0.1 / 0.2 | — | — | 64.0 | 0 | 0% | (saturated) | (saturated) | 1.2% |
| tail, clone | 1.1 / 11.3 | 134 | 314 | 64.0 | 0 | 0% | 15.9% | 1.5% | 15.0% |
| tail, packed | 0.8 / 12.1 | 134 | 185 | 64.0 | 0 | 0% | 17.1% | 1.2% | 15.5% |
| scroll, clone | 1.8 / 2.1 | 1,036 | 756 | 64.0 | 0 | 0.5% | 43.2% | 7.7% | 38.9% |
| scroll, packed | 1.6 / 1.8 | 1,036 | 381 | 64.0 | 0 | 0.5% | 39.2% | 4.2% | 36.8% |
| jump, clone | 1.3 / 2.3 | 236 | 571 | 63.8 | 0 | 100% (by design) | 11.6% | 7.0% | 25.4% |
| jump, packed | 0.8 / 1.8 | 236 | 258 | 63.8 | 0 | 100% (by design) | 10.7% | 4.0% | 20.3% |

The frame p95 was 15.7 ms in every phase.

**Tail lag:** the newest row on screen was at most 111 ms (p95) behind the engine, which is one 10 Hz tick plus one
round trip.

**Memory at 4.5M rows (MB, working set / private bytes):**

| Process | Working set | Private |
|---|---|---|
| main | 102 | 36 |
| GPU | 138 | 32 |
| network service | 49 | 12 |
| renderer | 208 | 118 |
| engine | 280 | 241 (of which 172.5 MB is native row storage at 40 B/row) |

The renderer's JS heap was 2–12 MB in every phase.

### Windows 11 ARM64, 300k rows/s (13.5M rows at the end)

| Phase | Round trip (ms) | FPS | Frames > 33 ms | Renderer CPU | Engine CPU | GPU CPU |
|---|---|---|---|---|---|---|
| idle | — | 63.7 | 0 | 5.3% | 1.6% | 3.6% |
| tail, clone / packed | 1.3 / 12.3 · 1.0 / 11.3 | 64.0 | 0 | 17.6% / 17.8% | 2.4% / 3.4% | 14.8% / 14.6% |
| scroll, clone / packed | 1.8 / 2.2 · 2.1 / 3.8 | 64.0 | 0 | 44.8% / 56.2% | 8.5% / 6.7% | 43.2% / 51.5% |
| jump, clone / packed | 1.4 / 2.9 · 1.2 / 2.7 | 64.0 | 0 | 10.8% / 13.9% | 8.1% / 6.9% | 18.4% / 24.5% |

At 13.5M rows the engine's private memory was 584 MB, of which 517.5 MB was row storage. The renderer was unchanged
at 115 MB private and a 3 MB JS heap.

### macOS (hardware GPU), 100k rows/s, for comparison

| Phase | Round trip (ms) | FPS | Frames > 33 ms | Renderer CPU | Engine CPU | GPU CPU |
|---|---|---|---|---|---|---|
| idle | — | 60.0 | 0 | 4.5% | 1.0% | 3.5% |
| ping (45.6k/s) | ≤ 0.1 | 60.0 | 0 | (saturated) | (saturated) | 0.9% |
| tail, clone / packed | 0.8 / 3.3 · 0.7 / 4.2 | 60.0 | 0 | 12.2% / 12.7% | 1.7% / 1.5% | 5.4% / 5.7% |
| scroll, clone / packed | 2.5 / 4.0 · 2.4 / 3.9 | 60.0 | 0 | 26.6% / 27.4% | 9.9% / 4.9% | 8.5% / 8.6% |
| jump, clone / packed | 1.1 / 1.3 · 0.7 / 0.9 | 60.0 | 0 | 9.1% / 10.1% | 5.8% / 3.6% | 4.4% / 4.9% |

Working sets: main 166 MB, GPU 83, network 48, renderer 219, engine 298 (172.5 MB of rows).

## Findings

1. **IPC is not the bottleneck.**
   - A renderer↔engine round trip over a direct MessagePort costs about 0.1 ms on Windows (10k/s back to back)
     and about 22 µs on the Mac (45k/s).
   - A 1,000-row viewport fetch is about 2 ms p95 on Windows at 100k/s, and 2–4 ms p95 at 300k/s and on the Mac.
   - Every phase stayed inside one frame budget.
2. **The UI's cost doesn't depend on the ingest rate.** Tripling ingest to 300k/s left frame rate, renderer CPU and
   renderer memory unchanged, because the renderer only pulls what's on screen and gets a 10 Hz count tick. That
   only holds if nothing is pushed per packet.
3. **Zero frames over 33 ms on Windows, in every phase, at both rates,** even with software rendering.
4. **Use the packed encoding for the packet table.**
   - It halves the engine's build time (756 → 381 µs for 1,036 rows) and engine CPU while scrolling (7.7% → 4.2%).
   - It decodes in 0.1–0.2 ms, and strings are sliced lazily for visible rows only.
   - Round-trip times are similar either way. Structured clone is fine for small, irregular payloads such as a
     detail tree.
5. **Electron's real cost is memory and rendering CPU, not data flow.**
   - Before any packets, on Windows: about 265 MB private across main, GPU, network service, renderer and an empty
     engine. Summed working sets are about 600 MB, but that double-counts shared DLL pages.
   - A fast fling costs about 40% of a core in the renderer on Windows (27% on the Mac).
   - The GPU process's 37–51% while scrolling is WARP software rasterization in the VM. The Mac's hardware GPU
     needed 8.5% for the same work.
6. **Windows tail round trips have a p95 of 11–13 ms,** against 3–4 ms on the Mac. It never caused a placeholder
   or a late frame. The likely cause is the reply waiting behind the renderer's frame commit under software
   compositing, but this wasn't traced.

### Design rules the spike forced (the real app needs all of them)

- **Hold the tail until data arrives.** Jumping to new rows before they've loaded flashed "Loading…" on about 16%
  of frames; holding the old tail brought that to 0%.
- **Prefetch in the scroll direction.** At 200 rows/frame, a plain overscan put placeholders on 100% of frames.
  Prefetching 4 frames of velocity ahead cut that to 0.5%, which is just the first frame.
- **Scale the scrollbar past about 400k rows.** Chromium caps element height near 33.5M px (about 1.6M rows at
  20 px), so the spacer stops at 8M px and maps proportionally onto rows. The displayed row, not `scrollTop`, is the
  source of truth. Every run here went far past this point.
- **Copy into V8-owned buffers.** Electron's V8 memory cage rejects external ArrayBuffers, so the addon copies into
  `Napi::ArrayBuffer::New`. Keep payloads bounded.
- **Allow one request in flight, latest position wins,** and drop replies whose generation is stale.

## Measurement pitfalls (Windows)

- **`app.getAppMetrics().cpu.percentCPUUsage` is normalized by core count,** so it's not "% of one core".
- **Windows `GetProcessTimes` misses short work.** It charges CPU in 15.6 ms ticks, so work that wakes on a timer
  or vsync and finishes before the next tick is charged almost nothing. The first Windows run showed exact
  multiples of one tick (0.28% per 5.5 s), and `cumulativeCPUUsage` has the same problem.
- **The fix:** `scripts/sample-cpu-windows.ps1` samples `QueryProcessCycleTime` for every `electron.exe` and
  calibrates against one busy core (about 3.05 G cycles per core-second in the VM).
- **Renderer timer resolution:** `performance.now()` is coarsened to 0.1 ms without cross-origin isolation, so
  sub-0.1 ms round trips report as 0–0.1.
- **Precise heap numbers:** `performance.memory` needs `--enable-precise-memory-info`, which `main.js` sets.

## Caveats

- **Synthetic engine.** It doesn't capture or dissect. The engine numbers cover formatting and IPC only; libpcap
  and epan cost is a separate question (the Linux shim spike).
- **VM, not real hardware.** Rendering was software-only, the CPUs are virtualized and on ARM64, and the display was
  64 Hz. Windows x64 on real hardware with a GPU should be better on GPU and renderer CPU, but wasn't tested here,
  and neither was Linux.
- **Table only.** No detail tree, hex view or follow-stream payloads, and a single window.
- **Tail lag is the tick rate.** It's about one tick (100 ms). A 20 Hz tick would halve it, at a small cost.

## Run it

```bash
npm install
npm run build
npm run bench
node scripts/print-results.js
```

- **Options:** `npx electron . --bench --rate=300000 --phase-seconds=6` raises the ingest rate or phase length.
  `npm start` opens the interactive view: `t` toggles tail, `e` toggles the encoding.
- **Windows build requirements:** Visual Studio Build Tools with "MSVC ARM64/x64 build tools" and "C++ CMake tools
  for Windows". Put Visual Studio's `cmake.exe` on PATH. node-gyp isn't used, so Python isn't needed.
- **Accurate Windows CPU:** start
  `powershell -ExecutionPolicy Bypass -File scripts\sample-cpu-windows.ps1 -Out results\cpu.csv` first, then run the
  bench, then `node scripts\print-results.js <report>.json --cpu results\cpu.csv`.
- **Output:** reports go to `results/`, which is ignored by git. They contain only timings, counts and
  OS/CPU/GPU model strings, with no paths or host names.
