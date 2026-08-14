import { test, describe } from 'node:test';
import assert from 'node:assert/strict';

import { writeWebPage } from '../src/webpage.ts';
import { writeMeshGlb } from '../src/glb.ts';

/** A tetrahedron, so the embedded model is a real GLB rather than noise. */
function tetrahedronGlb(): Uint8Array {
  return writeMeshGlb({
    positions: new Float32Array([0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1]),
    indices: new Uint32Array([0, 2, 1, 0, 1, 3, 0, 3, 2, 1, 2, 3]),
  });
}

describe('web page export', () => {
  test('embeds the model as a data URI so there is nothing to host', () => {
    const glb = tetrahedronGlb();
    const html = writeWebPage(glb, { name: 'Bay 4' });

    const match = html.match(/src="data:model\/gltf-binary;base64,([A-Za-z0-9+/=]+)"/);
    assert.ok(match, 'no embedded model found');

    // Round-trip the payload: a viewer will decode exactly these bytes, so if
    // the encoding is wrong the page renders nothing and says nothing.
    const decoded = new Uint8Array(Buffer.from(match[1], 'base64'));
    assert.deepEqual(decoded, glb);

    // glTF magic survived, which is what a viewer sniffs for.
    assert.equal(new TextDecoder().decode(decoded.subarray(0, 4)), 'glTF');
  });

  test('the page loads nothing from the network but the viewer script', () => {
    const html = writeWebPage(tetrahedronGlb(), { name: 'Site' });

    // What matters is what the page *fetches* — a fetch that fails leaves a
    // blank viewer on someone else's machine. An <a href> the reader clicks is
    // not in that category, so this looks at src= and <link> only.
    const fetched = [
      ...html.matchAll(/\bsrc="(https?:\/\/[^"]+)"/g),
      ...html.matchAll(/<link\b[^>]*\bhref="(https?:\/\/[^"]+)"/g),
    ].map((m) => m[1]);

    assert.equal(fetched.length, 1, `unexpected external loads: ${fetched.join(', ')}`);
    assert.match(fetched[0], /model-viewer/);

    // No stylesheet, font or image host: everything else is inline.
    assert.ok(!html.includes('<link rel="stylesheet"'), 'external stylesheet');
  });

  test('escapes the scan name rather than injecting it', () => {
    // Project names come from a text field on a phone. A name with a quote in
    // it must not be able to close an attribute and start writing markup.
    const html = writeWebPage(tetrahedronGlb(), {
      name: '"><script>alert(1)</script>',
      facts: [{ label: '<b>x</b>', value: '"y"' }],
    });

    assert.ok(!html.includes('<script>alert(1)</script>'), 'name was injected as markup');
    assert.ok(html.includes('&lt;script&gt;alert(1)&lt;/script&gt;'));
    assert.ok(html.includes('&lt;b&gt;x&lt;/b&gt;'));
  });

  test('facts are rendered, and omitted entirely when there are none', () => {
    const withFacts = writeWebPage(tetrahedronGlb(), {
      name: 'Slab',
      capturedAt: '2026-08-09T14:03:11Z',
      facts: [
        { label: 'Triangles', value: '48,210' },
        { label: 'Accuracy', value: '18 mm RMS' },
      ],
    });
    assert.match(withFacts, /Triangles/);
    assert.match(withFacts, /18 mm RMS/);
    assert.match(withFacts, /2026-08-09/);

    const without = writeWebPage(tetrahedronGlb(), { name: 'Slab' });
    assert.ok(!without.includes('<dl>'), 'empty fact list still rendered a container');
  });

  test('auto-rotate is on by default and can be turned off', () => {
    assert.match(writeWebPage(tetrahedronGlb(), { name: 'a' }), /auto-rotate/);
    assert.ok(
      !writeWebPage(tetrahedronGlb(), { name: 'a', autoRotate: false }).includes('auto-rotate'),
    );
  });

  test('base64 handles a model far past the argument-spreading limit', () => {
    // String.fromCharCode(...bytes) throws on roughly 100k arguments, and a
    // real scan is megabytes. This is the size at which the naive encoder
    // breaks, and no smaller test would catch it.
    const big = new Uint8Array(500_000);
    for (let i = 0; i < big.length; i += 1) big[i] = i & 0xff;

    const html = writeWebPage(big, { name: 'Big' });
    const match = html.match(/base64,([A-Za-z0-9+/=]+)"/);
    assert.ok(match);
    assert.deepEqual(new Uint8Array(Buffer.from(match[1], 'base64')), big);
  });
});
