/**
 * three.js ships types for its main entry point but not for the loaders under
 * `examples/jsm`, which are published as plain JavaScript. These are used only
 * by the interop tests — where our own writers' output is parsed back by an
 * independent implementation — so the surface needed is small and typing it
 * loosely here is better than turning off `noImplicitAny` for the whole repo.
 */
declare module 'three/examples/jsm/loaders/FBXLoader.js' {
  export class FBXLoader {
    parse(buffer: ArrayBuffer, path: string): {
      traverse(callback: (object: any) => void): void;
    };
  }
}

declare module 'three/examples/jsm/loaders/GLTFLoader.js' {
  export class GLTFLoader {
    parse(
      buffer: ArrayBuffer,
      path: string,
      onLoad: (gltf: any) => void,
      onError: (error: unknown) => void,
    ): void;
  }
}
