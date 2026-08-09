/**
 * Studio: load a capture, process it, export it. All in the browser.
 *
 * Plain DOM rather than a framework. The app is four steps in sequence with no
 * shared mutable state worth abstracting, and a framework would be more code
 * than the thing it manages. It also keeps the dependency list at one build
 * tool, which matters for something a team is meant to be able to fork and fix.
 */

import type { CaptureBundle } from '@pixmyd/core/bundle';
import {
  exportMesh,
  exportPointCloud,
  rcsBridgeInstructions,
  type ExportFile,
} from '@pixmyd/formats/export';
import {
  directorySource,
  fileListSource,
  readBundle,
  zipSource,
  type BundleSource,
} from './lib/bundle-reader.ts';
import {
  DETAIL_LEVELS,
  estimateSeconds,
  processBundle,
  ProcessingError,
  type Detail,
  type ProcessResult,
} from './lib/pipeline.ts';

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

let source: BundleSource | null = null;
let bundle: CaptureBundle | null = null;
let result: ProcessResult | null = null;
let detail: Detail = 'balanced';
let controller: AbortController | null = null;

const $ = <T extends HTMLElement>(id: string): T => {
  const element = document.getElementById(id);
  if (!element) throw new Error(`missing element #${id}`);
  return element as T;
};

// ---------------------------------------------------------------------------
// Loading
// ---------------------------------------------------------------------------

$('pick-directory').addEventListener('click', async () => {
  // The File System Access API is the good path; Safari and Firefox need the
  // input fallback, so both exist rather than one with a broken half.
  if ('showDirectoryPicker' in window) {
    try {
      const handle = await (window as unknown as {
        showDirectoryPicker(options?: unknown): Promise<FileSystemDirectoryHandle>;
      }).showDirectoryPicker({ mode: 'read' });
      await load(directorySource(handle));
    } catch (error) {
      // An abort is the user changing their mind, not a failure.
      if ((error as Error).name !== 'AbortError') showLoadError(error);
    }
    return;
  }
  $('directory-input').click();
});

$('directory-input').addEventListener('change', async (event) => {
  const files = (event.target as HTMLInputElement).files;
  if (files && files.length > 0) await load(fileListSource(files));
});

$('pick-zip').addEventListener('click', () => $('zip-input').click());

$('zip-input').addEventListener('change', async (event) => {
  const file = (event.target as HTMLInputElement).files?.[0];
  if (!file) return;
  try {
    const bytes = new Uint8Array(await file.arrayBuffer());
    await load(await zipSource(bytes, file.name.replace(/\.zip$/i, '')));
  } catch (error) {
    showLoadError(error);
  }
});

async function load(next: BundleSource): Promise<void> {
  hide('load-error');
  try {
    bundle = await readBundle(next);
    source = next;
    result = null;
    renderCapture();
    show('capture-panel');
    show('process-panel');
    hide('result-panel');
    renderEstimate();
  } catch (error) {
    showLoadError(error);
  }
}

function showLoadError(error: unknown): void {
  const panel = $('load-error');
  panel.innerHTML = '';
  panel.append(strong('Could not open that capture'), text(String((error as Error).message ?? error)));
  show('load-error');
}

// ---------------------------------------------------------------------------
// Capture summary
// ---------------------------------------------------------------------------

function renderCapture(): void {
  if (!bundle) return;
  const { manifest, frames } = bundle;

  const posed = frames.filter((f) => f.pose).length;
  const withDepth = frames.filter((f) => f.depth).length;
  const rtkFixes = (bundle.gnss ?? []).filter((f) => f.quality === 4).length;

  const grid = $('capture-readouts');
  grid.innerHTML = '';
  grid.append(
    readout('Name', manifest.name),
    readout('Frames', String(frames.length)),
    readout('With depth', String(withDepth), undefined, withDepth === 0 ? 'bad' : 'good'),
    readout('Posed', String(posed), undefined, posed === frames.length ? 'good' : 'caution'),
    readout('Device', manifest.device.model ?? manifest.device.kind),
  );
  if (bundle.gnss?.length) {
    grid.append(
      readout(
        'RTK fixed',
        `${rtkFixes}/${bundle.gnss.length}`,
        undefined,
        rtkFixes > 0 ? 'good' : 'caution',
      ),
    );
  }

  // The warnings that actually change what the user should do next.
  const warning = $('capture-warning');
  warning.innerHTML = '';
  if (withDepth === 0) {
    warning.append(
      strong('No depth in this capture'),
      text(
        'Fusion needs measured depth. Reconstructing from imagery alone requires ' +
        'structure-from-motion, which is not built yet, so there is nothing to process here.',
      ),
    );
    show('capture-warning');
  } else if (posed < frames.length) {
    warning.append(
      strong(`${frames.length - posed} frames have no pose`),
      text('They will be skipped. That usually means tracking was lost mid-scan.'),
    );
    show('capture-warning');
  } else if (bundle.gnss?.length && rtkFixes === 0) {
    warning.append(
      strong('No RTK fixed solutions'),
      text(
        'Every position in this capture is metre-level or better only. The geometry is ' +
        'unaffected, but the georeference is not survey grade.',
      ),
    );
    show('capture-warning');
  } else {
    hide('capture-warning');
  }
}

// ---------------------------------------------------------------------------
// Detail choice
// ---------------------------------------------------------------------------

function renderDetailChoice(): void {
  const container = $('detail-choice');
  container.innerHTML = '';
  for (const key of Object.keys(DETAIL_LEVELS) as Detail[]) {
    const button = document.createElement('button');
    button.type = 'button';
    button.role = 'radio';
    button.textContent = DETAIL_LEVELS[key].label;
    button.setAttribute('aria-checked', String(key === detail));
    button.addEventListener('click', () => {
      detail = key;
      renderDetailChoice();
      renderEstimate();
    });
    container.append(button);
  }
  $('detail-note').textContent = DETAIL_LEVELS[detail].note;
}

function renderEstimate(): void {
  if (!bundle) return;
  const wantMesh = ($('want-mesh') as HTMLInputElement).checked;
  const seconds = estimateSeconds(bundle.frames.length, detail, wantMesh);
  $('estimate').textContent =
    seconds < 60
      ? `Roughly ${Math.round(seconds)} s — a rough estimate.`
      : `Roughly ${Math.round(seconds / 60)} min — a rough estimate.`;
}

$('want-mesh').addEventListener('change', renderEstimate);
renderDetailChoice();

// ---------------------------------------------------------------------------
// Processing
// ---------------------------------------------------------------------------

$('run').addEventListener('click', async () => {
  if (!bundle || !source) return;
  hide('process-error');
  hide('result-panel');
  show('progress');
  $('run').setAttribute('disabled', 'true');
  show('cancel');

  controller = new AbortController();

  try {
    result = await processBundle(bundle, source, {
      detail,
      mesh: ($('want-mesh') as HTMLInputElement).checked,
      signal: controller.signal,
      onProgress(stage, fraction) {
        $('progress-stage').textContent = stage;
        $('progress-percent').textContent = `${Math.round(fraction * 100)}%`;
        ($('progress-fill') as HTMLElement).style.width = `${fraction * 100}%`;
      },
    });
    renderResult();
    show('result-panel');
  } catch (error) {
    if ((error as Error).name === 'AbortError') {
      hide('progress');
    } else {
      const panel = $('process-error');
      panel.innerHTML = '';
      panel.append(strong(String((error as Error).message)));
      if (error instanceof ProcessingError && error.hint) panel.append(text(error.hint));
      show('process-error');
    }
  } finally {
    $('run').removeAttribute('disabled');
    hide('cancel');
    controller = null;
  }
});

$('cancel').addEventListener('click', () => controller?.abort());

// ---------------------------------------------------------------------------
// Result and export
// ---------------------------------------------------------------------------

function renderResult(): void {
  if (!result) return;

  const grid = $('result-readouts');
  grid.innerHTML = '';
  grid.append(
    readout('Points', formatCount(result.points.count)),
    readout(
      'Triangles',
      result.mesh ? formatCount(result.mesh.indices.length / 3) : 'none',
      undefined,
      result.mesh ? 'good' : 'caution',
    ),
    readout('Voxel', String(Math.round(result.voxelSize * 1000)), 'mm'),
    readout('Fused', `${result.integratedFrames}`, 'frames'),
    readout('Elapsed', (result.elapsedMs / 1000).toFixed(1), 's'),
  );

  const skippedTotal =
    result.skipped.noPose + result.skipped.noDepth + result.skipped.unreadable;
  const warning = $('result-warning');
  warning.innerHTML = '';
  if (skippedTotal > 0) {
    warning.append(
      strong(`${skippedTotal} frames were not fused`),
      text(
        `${result.skipped.noPose} had no pose, ${result.skipped.noDepth} had no depth, ` +
        `${result.skipped.unreadable} could not be read. Gaps in the result will ` +
        'correspond to where those frames were.',
      ),
    );
    show('result-warning');
  } else {
    hide('result-warning');
  }

  renderExports();
  renderRcs();
}

interface ExportOption {
  id: string;
  name: string;
  note: string;
  build: () => ExportFile[];
  available: boolean;
}

function renderExports(): void {
  if (!result) return;
  const name = bundle?.manifest.name.replace(/[^\w.-]+/g, '-') ?? 'capture';
  const mesh = result.mesh;
  const points = result.points;

  const options: ExportOption[] = [
    {
      id: 'glb',
      name: 'GLB',
      note: 'One file, opens nearly everywhere.',
      available: !!mesh,
      build: () => exportMesh(mesh!, 'glb', { name }),
    },
    {
      id: 'obj',
      name: 'OBJ',
      note: 'Universal. Opens with no plugin.',
      available: !!mesh,
      build: () => exportMesh(mesh!, 'obj', { name }),
    },
    {
      id: 'fbx',
      name: 'FBX',
      note: 'For Revit, Navisworks, 3ds Max.',
      available: !!mesh,
      build: () => exportMesh(mesh!, 'fbx', { name }),
    },
    {
      id: 'ply',
      name: 'PLY',
      note: 'Point cloud. The scan interchange format.',
      available: points.count > 0,
      build: () => exportPointCloud(points, 'ply', { name }),
    },
    {
      id: 'e57',
      name: 'E57',
      note: 'Survey interchange, with georeference.',
      available: points.count > 0,
      build: () => exportPointCloud(points, 'e57', { name }),
    },
    {
      id: 'las',
      name: 'LAS',
      note: 'For GIS and Civil 3D.',
      available: points.count > 0,
      build: () => exportPointCloud(points, 'las', { name }),
    },
  ];

  const grid = $('export-grid');
  grid.innerHTML = '';
  for (const option of options) {
    const card = document.createElement('button');
    card.type = 'button';
    card.className = 'export-card';
    card.disabled = !option.available;

    const title = document.createElement('span');
    title.className = 'export-name';
    title.textContent = option.name;

    const note = document.createElement('span');
    note.className = 'export-note';
    note.textContent = option.available
      ? option.note
      : 'Needs a surface mesh — re-process with meshing on.';

    card.append(title, note);
    card.addEventListener('click', () => {
      card.disabled = true;
      title.textContent = `${option.name} …`;
      // Serialising a large cloud blocks the main thread; yield first so the
      // button visibly changes rather than the page appearing to hang.
      setTimeout(() => {
        try {
          for (const file of option.build()) download(file);
          title.textContent = option.name;
        } catch (error) {
          note.textContent = `Export failed: ${(error as Error).message}`;
          title.textContent = option.name;
        } finally {
          card.disabled = false;
        }
      }, 0);
    });
    grid.append(card);
  }
}

function renderRcs(): void {
  if (!result) return;
  const bridge = rcsBridgeInstructions(result.points, {
    name: bundle?.manifest.name ?? 'capture',
  });

  const body = $('rcs-body');
  body.innerHTML = '';
  body.append(
    text(
      'RCS and RCP are Autodesk formats with no published specification, so PIXMYD ' +
      'does not write them — a guessed file that fails to open in ReCap would be ' +
      'worse than an honest absence. Export E57 and convert in one step; the E57 ' +
      'carries the georeference, the per-scan poses and the colour, so nothing is lost.',
    ),
  );

  for (const route of bridge.routes) {
    const heading = document.createElement('p');
    heading.innerHTML = `<strong>${route.name}</strong> — needs ${route.requires}`;
    const list = document.createElement('ol');
    for (const step of route.steps) {
      const item = document.createElement('li');
      // Steps containing a path or a command read better as code.
      if (step.includes('\\') || step.includes('/import')) {
        const code = document.createElement('code');
        code.textContent = step;
        item.append(code);
      } else {
        item.textContent = step;
      }
      list.append(item);
    }
    body.append(heading, list);
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function download(file: ExportFile): void {
  // Blob wants a view backed by a plain ArrayBuffer. Typed arrays in TS 5.7+
  // carry their backing-store type, and an exporter's output may be backed by
  // anything, so this narrows explicitly rather than casting the whole view.
  const bytes = new Uint8Array(file.bytes);
  const blob = new Blob([bytes], { type: file.mimeType });
  const url = URL.createObjectURL(blob);
  const anchor = document.createElement('a');
  anchor.href = url;
  anchor.download = file.filename;
  anchor.click();
  // Revoking immediately can cancel the download in some browsers; a tick is
  // enough for the navigation to have started.
  setTimeout(() => URL.revokeObjectURL(url), 10_000);
}

function readout(
  label: string,
  value: string,
  unit?: string,
  tone?: 'good' | 'caution' | 'bad',
): HTMLElement {
  const wrapper = document.createElement('div');
  const labelElement = document.createElement('span');
  labelElement.className = 'readout-label';
  labelElement.textContent = label;

  const valueElement = document.createElement('span');
  valueElement.className = `readout-value${tone ? ` tone-${tone}` : ''}`;
  valueElement.textContent = value;
  if (unit) {
    const unitElement = document.createElement('span');
    unitElement.className = 'unit';
    unitElement.textContent = unit;
    valueElement.append(unitElement);
  }

  wrapper.append(labelElement, valueElement);
  return wrapper;
}

function strong(content: string): HTMLElement {
  const element = document.createElement('strong');
  element.textContent = content;
  return element;
}

function text(content: string): Text {
  return document.createTextNode(content);
}

function formatCount(n: number): string {
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(1)}M`;
  if (n >= 1_000) return `${(n / 1_000).toFixed(0)}k`;
  return String(Math.round(n));
}

function show(id: string): void {
  $(id).hidden = false;
}

function hide(id: string): void {
  $(id).hidden = true;
}
