// Print one bench report (the newest in results/ by default) as a compact per-phase table.
'use strict';

const fs = require('fs');
const path = require('path');

const directory = path.join(__dirname, '..', 'results');
const args = process.argv.slice(2);
const cpuFlag = args.indexOf('--cpu');
const cpuFile = cpuFlag >= 0 ? args.splice(cpuFlag, 2)[1] : null;
const file = args[0] ?? fs.readdirSync(directory).filter((name) => name.endsWith('.json')).sort().pop();
const report = JSON.parse(fs.readFileSync(path.isAbsolute(file) ? file : path.join(directory, file), 'utf8'));
const env = report.environment;

// With --cpu, replace getAppMetrics CPU with cycle-accurate numbers from scripts/sample-cpu-windows.ps1.
if (cpuFile) {
  applyCycleSamples(report, fs.readFileSync(path.resolve(cpuFile), 'utf8'));
}

// Convert per-process cycle deltas inside each phase window into % of one core, summed per process kind.
function applyCycleSamples(target, csv) {
  const lines = csv.trim().split(/\r?\n/);
  const cyclesPerCoreSecond = Number(lines[0].split(',')[1]);
  const samples = lines.slice(2).map((line) => {
    const [at, pid, kind, cycles] = line.split(',');
    return { at: Number(at), pid, kind, cycles: Number(cycles) };
  });
  for (const phase of target.phases) {
    const byPid = new Map();
    for (const sample of samples) {
      if (sample.at >= phase.wallStart && sample.at <= phase.wallEnd && sample.cycles > 0) {
        byPid.set(sample.pid, [...(byPid.get(sample.pid) ?? []), sample]);
      }
    }
    const totals = {};
    for (const pidSamples of byPid.values()) {
      const first = pidSamples[0];
      const last = pidSamples[pidSamples.length - 1];
      const seconds = (last.at - first.at) / 1000;
      if (seconds <= 0) continue;
      const percent = ((last.cycles - first.cycles) / cyclesPerCoreSecond / seconds) * 100;
      totals[first.kind] = (totals[first.kind] ?? 0) + percent;
    }
    for (const [kind, percent] of Object.entries(totals)) {
      phase.processes[kind] = { ...(phase.processes[kind] ?? {}), cpuCorePercent: Math.round(percent * 10) / 10 };
    }
  }
  console.log(`CPU from cycle samples (${Math.round(cyclesPerCoreSecond / 1e6)} M cycles per core-second)`);
}

console.log(`${file}`);
console.log(`${env.osVersion ?? env.platform} ${env.arch} · ${env.cpuModel} x${env.cpuCount} · ${env.totalMemoryGB} GB · `
  + `Electron ${env.electron} · ${env.display.refreshHz} Hz · ${env.gpu?.glRenderer ?? 'unknown GPU'}`);
console.log(`rate ${report.config.rate}/s · phases ${report.config.phaseSeconds}s · final rows ${report.finalCount}`);
console.log();

const header = ['phase', 'ingest/s', 'req/s', 'rtt p50', 'rtt p95', 'rows/req', 'build µs', 'fps', 'frame p95',
  '>33ms', 'placeholder%', 'tail lag p95', 'CPU% renderer', 'CPU% engine', 'CPU% GPU', 'CPU% main'];
const rows = report.phases.map((phase) => {
  const rtt = phase.pingMs ?? phase.rttMs;
  const cpu = (key) => phase.processes[key]?.cpuCorePercent ?? '';
  return [
    phase.encoding === 'none' ? phase.name : `${phase.name}/${phase.encoding}`,
    phase.ingestRowsPerSecond,
    phase.pingsPerSecond ?? phase.requestsPerSecond,
    rtt.p50,
    rtt.p95,
    phase.rowsPerReply.p50 ?? '',
    phase.engineBuildUs.p50 ?? '',
    phase.frames.fps,
    phase.frames.p95Ms,
    phase.frames.over33Ms,
    phase.placeholderFramePercent,
    phase.tailLagMs ? `${phase.tailLagMs.p95} ms` : '',
    cpu('Tab'),
    cpu('Utility:TCPViewer Engine'),
    cpu('GPU'),
    cpu('Browser'),
  ].map(String);
});
const widths = header.map((title, column) => Math.max(title.length, ...rows.map((row) => row[column].length)));
const line = (cells) => cells.map((cell, column) => cell.padEnd(widths[column])).join('  ');
console.log(line(header));
for (const row of rows) {
  console.log(line(row));
}

const last = report.phases[report.phases.length - 1];
console.log();
console.log('Peak memory in the last phase (MB, working set / private where reported):');
for (const [key, value] of Object.entries(last.processes)) {
  console.log(`  ${key.padEnd(28)} ${String(value.workingSetMaxMB).padStart(8)}  ${value.privateMaxMB ?? ''}`);
}
console.log(`  engine native rows: ${last.engine.nativeRowMB} MB for ${last.engine.count} rows; renderer JS heap: ${last.rendererHeapMB} MB`);
