// Emits assets/banner.svg — a wordmark over a frame-interval trace.
import { writeFileSync } from 'node:fs';

const W = 1200, H = 340;
const OUT = process.argv[2];

let seed = 0x51f3a7;
const rnd = () => ((seed = (seed * 1103515245 + 12345) & 0x7fffffff) / 0x7fffffff);

// The trace band: lower portion of the card.
const X0 = 0, X1 = W;
const BASE = 268;          // the 20 Hz baseline, in svg y
const N = 300;

// One stall, plus a smaller rough patch, on an otherwise flat line. Both sit to
// the right of the wordmark, which ends around x=520 (f≈0.43).
const STALL = 0.74, ROUGH = 0.55;

const pts = [];
for (let i = 0; i <= N; i++) {
    const f = i / N;
    const x = X0 + f * (X1 - X0);

    let amp = 3 + rnd() * 3;                       // baseline jitter

    // The stall: a sharp spike with a short shoulder either side.
    const d = Math.abs(f - STALL);
    if (d < 0.05) amp += 150 * Math.exp(-Math.pow(d / 0.008, 2)) + 40 * Math.exp(-Math.pow(d / 0.03, 2));

    // A milder rough patch.
    const r = Math.abs(f - ROUGH);
    if (r < 0.07) amp += 26 * Math.exp(-Math.pow(r / 0.035, 2));

    pts.push([x.toFixed(1), (BASE - amp).toFixed(1)]);
}

const line = 'M' + pts.map((p) => p.join(' ')).join(' L');
const area = `${line} L${X1} ${BASE + 40} L${X0} ${BASE + 40} Z`;

const svg = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${W} ${H}" width="${W}" height="${H}" role="img" aria-label="tickwatch — Prometheus metrics for FiveM servers">
  <defs>
    <linearGradient id="card" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#161b22"/>
      <stop offset="1" stop-color="#0d1117"/>
    </linearGradient>
    <linearGradient id="fade" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#ff9830" stop-opacity="0.30"/>
      <stop offset="1" stop-color="#ff9830" stop-opacity="0"/>
    </linearGradient>
    <clipPath id="clip"><rect x="0" y="0" width="${W}" height="${H}" rx="14"/></clipPath>
  </defs>

  <g clip-path="url(#clip)">
    <rect width="${W}" height="${H}" fill="url(#card)"/>

    <g stroke="#21262d" stroke-width="1">
      ${[80, 140, 200, 260].map((y) => `<line x1="0" y1="${y}" x2="${W}" y2="${y}"/>`).join('\n      ')}
      ${Array.from({ length: 11 }, (_, i) => `<line x1="${(i + 1) * 100}" y1="0" x2="${(i + 1) * 100}" y2="${H}"/>`).join('\n      ')}
    </g>

    <path d="${area}" fill="url(#fade)"/>
    <path d="${line}" fill="none" stroke="#ff9830" stroke-width="2.2" stroke-linejoin="round"/>

    <line x1="0" y1="196" x2="${W}" y2="196" stroke="#f2495c" stroke-width="1.4" stroke-dasharray="7 6" opacity="0.75"/>
    <text x="${W - 22}" y="188" text-anchor="end" font-family="ui-monospace, SFMono-Regular, Menlo, Consolas, monospace"
          font-size="13" fill="#f2495c" opacity="0.9">150 ms budget</text>

    <text x="56" y="132" font-family="-apple-system, BlinkMacSystemFont, Segoe UI, Roboto, Helvetica, Arial, sans-serif"
          font-size="76" font-weight="700" fill="#e6edf3" letter-spacing="-2.5">tickwatch</text>

    <text x="60" y="172" font-family="-apple-system, BlinkMacSystemFont, Segoe UI, Roboto, Helvetica, Arial, sans-serif"
          font-size="23" font-weight="400" fill="#8b949e">Prometheus metrics for FiveM servers</text>

    <rect x="0.5" y="0.5" width="${W - 1}" height="${H - 1}" rx="14" fill="none" stroke="#30363d"/>
  </g>
</svg>
`;

writeFileSync(OUT, svg, 'utf8');
process.stderr.write(`${OUT}: ${svg.length} bytes\n`);
