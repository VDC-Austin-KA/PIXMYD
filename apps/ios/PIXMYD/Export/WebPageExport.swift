import Foundation

/// A scan as one self-contained web page.
///
/// This is the format for handing a result to someone who is not going to
/// install anything. A `.glb` is the right interchange format and the wrong
/// deliverable — a site manager sent one has nothing that opens it — whereas a
/// web page opens on every phone and laptop that exists.
///
/// Mirrors `packages/formats/src/webpage.ts`, which has the test suite. Kept
/// deliberately simple on this side.
///
/// The model is embedded as a data URI rather than sitting next to the page.
/// That costs about a third in base64 overhead and buys three things worth
/// more:
///
///   - **No CORS.** A page fetching a `.glb` from Google Drive or Dropbox
///     fails. Consumer file hosts serve share links as HTML preview pages, and
///     the few that return the bytes rarely send `Access-Control-Allow-Origin`,
///     without which WebGL will not touch the file. Embedding removes the
///     entire class of problem.
///   - **No hosting.** One file: AirDrop it, put it in Drive, drop it on
///     Cloudflare Pages. It also works straight off the filesystem.
///   - **Nothing to keep alive.** A link to a server is a promise to run that
///     server.
enum WebPageExport {

    struct Fact {
        let label: String
        let value: String
    }

    static func write(
        glb: Data,
        name: String,
        capturedAt: Date?,
        facts: [Fact],
        to url: URL
    ) throws {
        let title = escape(name)

        let captured: String
        if let capturedAt {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            captured = "<p class=\"captured\">Captured \(escape(formatter.string(from: capturedAt)))</p>"
        } else {
            captured = ""
        }

        let rows = facts
            .map { "<div class=\"fact\"><dt>\(escape($0.label))</dt><dd>\(escape($0.value))</dd></div>" }
            .joined()
        let factList = rows.isEmpty ? "" : "<dl>\(rows)</dl>"

        // Foundation's base64 is chunk-free and handles a 100 MB model without
        // the stack games the JavaScript side needs.
        let encoded = glb.base64EncodedString()

        let html = """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
        <title>\(title) — PIXMYD</title>
        <script type="module" src="https://ajax.googleapis.com/ajax/libs/model-viewer/4.0.0/model-viewer.min.js"></script>
        <style>
        :root { color-scheme: dark; --bg:#0b0d10; --panel:#14181d; --line:#232a32; --text:#e8edf2; --dim:#93a1b0; --accent:#4da3ff; }
        * { box-sizing: border-box; }
        html, body { margin:0; height:100%; }
        body { background:var(--bg); color:var(--text); font:15px/1.5 -apple-system, system-ui, "Segoe UI", sans-serif; display:flex; flex-direction:column; }
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
        /* iOS Safari collapses a percentage height inside a flex column. */
        @supports (-webkit-touch-callout: none) { model-viewer { height:60vh; flex:none; } }
        </style>
        </head>
        <body>
        <header>
          <span class="brand">PIXMYD</span>
          <h1>\(title)</h1>
          \(captured)
        </header>

        <model-viewer
          src="data:model/gltf-binary;base64,\(encoded)"
          alt="3D scan of \(title)"
          camera-controls
          touch-action="pan-y"
          auto-rotate
          shadow-intensity="1"
          environment-image="neutral"
          ar
          ar-modes="webxr scene-viewer quick-look">
        </model-viewer>

        \(factList)

        <footer>
          Made with <a href="https://github.com/VDC-Austin-KA/PIXMYD">PIXMYD</a>.
          Drag to orbit, scroll to zoom. On a phone, tap the AR button to place it at full size.
        </footer>
        </body>
        </html>
        """

        try Data(html.utf8).write(to: url)
    }

    /// Project names are typed on a phone and go straight into markup. A name
    /// containing a quote must not be able to close an attribute and start
    /// writing tags.
    private static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
