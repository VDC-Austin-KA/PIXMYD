# Contributing

## Toolchain constraints

Packages are **TypeScript run directly by Node's type stripping** — no build
step, no `dist/`. That is what keeps the library and its tests a single source
of truth, and it is why the studio app can import package sources unchanged.

The cost is that only *erasable* TypeScript is allowed. Node strips types; it
does not compile them. Three constructs are therefore banned in `packages/**`
and `apps/studio/**`:

| Banned | Use instead |
|---|---|
| `enum Foo { A }` | `const Foo = { A: 0 } as const` plus a matching `type` |
| `constructor(readonly x: T)` | An explicit field and an assignment in the body |
| `namespace` / `declare` merging | A plain module |

Each of these fails at *load* time with `ERR_UNSUPPORTED_TYPESCRIPT_SYNTAX`,
not at type-check time, so `npm test` catches them immediately — but only for
code a test actually imports.

`apps/ios/**` is ordinary Swift and has none of these restrictions.

## Running things

```sh
npm install
npm test                 # every package and app test
npm run typecheck        # tsc --build, types only
npm run dev              # the studio app
```

There is no network access in the test suite and no fixture downloads. Tests
that need a JPEG, a COLMAP model, or a capture bundle build one in memory, so
what the test expects is stated in the test rather than hidden in a binary.

## What a test is for here

Round-tripping a writer through its own reader proves the pair agrees, not that
the file is correct. Where an independent parser exists, use it — the FBX and
GLB writers are checked against three.js, and that is what caught a footer
length bug that our own reader accepted.

Where no independent parser exists, assert a property the format or the maths
must have rather than a value the code happens to produce:

- Marching tetrahedra: the *signed* volume of a sphere must be positive and
  match 4/3 pi r cubed. That catches an inside-out mesh, which renders
  plausibly and fails only in a tool that backface-culls.
- State Plane zones: each must map its own false origin to exactly its false
  easting and northing, and hold scale factor 1 on its standard parallels. That
  catches a mistyped constant, which is otherwise a silent 40 km error.

## Honesty rules

These are load-bearing, not stylistic.

- **A missing capability is stated, not hidden.** If a format cannot be written
  or a device cannot do a thing, say so and give the alternative. RCS is the
  worked example.
- **Every accuracy number carries its band.** A residual displayed without the
  construction tolerance it falls in is unfinished, because somebody will build
  to whatever is on the screen.
- **Never label a proxy as a measurement.** HDOP is not accuracy. A gimbal angle
  is not a solved orientation. A metadata pose is not an SfM pose.
