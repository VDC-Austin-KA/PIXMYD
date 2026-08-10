/**
 * A scan as one self-contained HTML file.
 *
 * The problem this solves is handing a result to somebody who is not going to
 * install anything. A `.glb` is the right interchange format and the wrong
 * deliverable — a site manager sent one has nothing that opens it. A web page
 * opens on every phone and laptop that exists.
 *
 * The model is embedded as a data URI rather than referenced alongside the
 * page, which costs about 33% in base64 overhead and buys three things that
 * matter more:
 *
 *   - **No CORS.** A viewer fetching a `.glb` from Google Drive or Dropbox
 *     fails: consumer file hosts serve share links as HTML preview pages, and
 *     the ones that do serve the bytes rarely send
 *     `Access-Control-Allow-Origin`. WebGL cannot load a cross-origin model
 *     without it. Embedding sidesteps the entire class of problem.
 *   - **No hosting.** One file. Email it, drop it in Drive, put it on
 *     Cloudflare Pages — all the same file, and it works from `file://` too.
 *   - **Nothing to keep alive.** A link to a server is a promise to run that
 *     server. A file is a file.
 */

/** Everything the page needs to describe the scan it is showing. */
export interface WebPageOptions {
  /** Shown as the page title and heading. */
  name: string;
  /** ISO 8601, if known. */
  capturedAt?: string;
  /** Free-text lines shown under the heading — counts, units, accuracy. */
  facts?: Array<{ label: string; value: string }>;
  /** Set false for a model whose orientation is already Y-up. */
  autoRotate?: boolean;
}

/** Base64 without pulling in a dependency, and without a 100 MB call stack. */
function base64(bytes: Uint8Array): string {
  if (typeof Buffer !== 'undefined') return Buffer.from(bytes).toString('base64');

  // btoa takes a string of code points 0-255. Chunked because
  // String.fromCharCode(...bytes) on a 20 MB model overflows the stack —
  // the limit is somewhere around 100k arguments and varies by engine, so
  // this is not a size a test would reliably catch.
  let binary = '';
  const chunk = 0x8000;
  for (let i = 0; i < bytes.length; i += chunk) {
    binary += String.fromCharCode(...bytes.subarray(i, i + chunk));
  }
  return btoa(binary);
}

function escapeHtml(text: string): string {
  return text
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

/**
 * Wrap a GLB in a viewer page.
 *
 * Rendering is Google's `<model-viewer>`, loaded from a CDN. That is the one
 * external dependency in the file, and it is a deliberate trade: inlining a
 * WebGL renderer would add ~300 KB to every export to buy offline use of a
 * document whose entire purpose is being sent to someone. It also brings
 * `ar` mode for free, so opening the page on an iPhone puts the scan in the
 * room at 1:1 — which for a construction scan is the feature people actually
 * react to.
 */
export function writeWebPage(glb: Uint8Array, options: WebPageOptions): string {
  const facts = options.facts ?? [];
  const title = escapeHtml(options.name);

  const factRows = facts
    .map(
      (fact) =>
        `<div class="fact"><dt>${escapeHtml(fact.label)}</dt><dd>${escapeHtml(fact.value)}</dd></div>`,
    )
    .join('');

  const captured = options.capturedAt
    ? `<p class="captured">Captured ${escapeHtml(options.capturedAt)}</p>`
    : '';

  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>${title} — PIXMYD</title>
<script type="module" src="https://ajax.googleapis.com/ajax/libs/model-viewer/4.0.0/model-viewer.min.js"></script>
<style>
  :root { color-scheme: dark; --bg:#0b0d10; --panel:#14181d; --line:#232a32; --text:#e8edf2; --dim:#93a1b0; --accent:#4da3ff; }
  * { box-sizing: border-box; }
  html, body { margin:0; height:100%; }
  body { background:var(--bg); color:var(--text); font:15px/1.5 ui-sans-serif, system-ui, -apple-system, "Segoe UI", sans-serif; display:flex; flex-direction:column; }
  header { padding:14px 18px; border-bottom:1px solid var(--line); display:flex; align-items:baseline; gap:12px; flex-wrap:wrap; }
  h1 { font-size:17px; margin:0; font-weight:600; }
  .brand { font-size:11px; letter-spacing:.14em; text-transform:uppercase; color:var(--dim); }
  .captured { margin:0; font-size:13px; color:var(--dim); }
  model-viewer { flex:1; width:100%; min-height:0; background:radial-gradient(circle at 50% 40%, #1b2129 0%, var(--bg) 70%); }
  dl { display:flex; flex-wrap:wrap; gap:0 26px; margin:0; padding:11px 18px; border-top:1px solid var(--line); background:var(--panel); }
  .fact { padding:3px 0; }
  dt { font-size:11px; letter-spacing:.06em; text-transform:uppercase; color:var(--dim); }
  dd { margin:0; font-variant-numeric:tabular-nums; }
  footer { padding:9px 18px; font-size:12px; color:var(--dim); border-top:1px solid var(--line); }
  a { color:var(--accent); }
  /* The viewer needs a real height; on iOS Safari a percentage height inside a
     flex column collapses to zero without this. */
  @supports (-webkit-touch-callout: none) { model-viewer { height:60vh; flex:none; } }
</style>
</head>
<body>
<header>
  <span class="brand">PIXMYD</span>
  <h1>${title}</h1>
  ${captured}
</header>

<model-viewer
  src="data:model/gltf-binary;base64,${base64(glb)}"
  alt="3D scan of ${title}"
  camera-controls
  touch-action="pan-y"
  ${options.autoRotate === false ? '' : 'auto-rotate'}
  shadow-intensity="1"
  environment-image="neutral"
  ar
  ar-modes="webxr scene-viewer quick-look">
</model-viewer>

${factRows ? `<dl>${factRows}</dl>` : ''}

<footer>
  Made with <a href="https://github.com/VDC-Austin-KA/PIXMYD">PIXMYD</a>.
  Drag to orbit, scroll to zoom. On a phone, tap the AR button to place it at full size.
</footer>
</body>
</html>
`;
}
