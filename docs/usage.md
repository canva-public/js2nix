## Usage

Create a Nix expression that represents Node.js dependencies defined in `package.json` and `yarn.lock` files by creating a `./package.nix` file with the following content:

```nix
with import <nixpkgs> { };

let
  js2nix = callPackage (builtins.fetchGit {
    url = "ssh://git@github.com/Canva/js2nix.git";
    ref = "main";
  }) { };
  nodeModules = js2nix.makeNodeModules ./package.json {
    name = "example";
    tree = js2nix.load ./yarn.lock { };
  };
in nodeModules
```

This Nix expression does the following:

1. Import nixpkgs if not given and expose its content into the global scope.
1. Import the js2nix project from the Github repo.
1. Generate a Nix expression out of the `yarn.lock` file.
1. Create a Nix derivation that builds all top-level dependencies. That is, all the dependencies from the `dependencies` and `devDependencies` sections in the `./package.json` file.
1. Return this resulting derivation for further use.

The approach above is [Import From Derivation](https://nixos.wiki/wiki/Import_From_Derivation) (IFD). While it's easy to use, it has some limitations that we may wish to avoid for advanced use cases. 

To avoid IFD, you can generate Nix expressions by using the js2nix executable (available from `js2nix.bin`):

```
λ js2nix --lock ./yarn.lock --out ./yarn.lock.nix
```

Then, import this expression by changing the file above with the following:

```diff
-    tree = js2nix.load ./yarn.lock { };
+    tree = js2nix.loadNixExpression ./yarn.lock.nix { };
```

### Using `nix-build`

You can create a symlink to a resulting derivation using the following command:

```
λ nix-build --max-jobs auto --out-link ./node_modules ./package.nix
λ realpath ./node_modules
/nix/store/nicz6jxz740772d9bg1pcj4cvs4xgsg2-example-node-modules
```

### Using `nix-shell`

Manually import using `nix-shell` with the following example:

```nix
with import <nixpkgs> { };
let nodeModules = import ./package.nix;
in mkShell {
  shellHook = ''
    ln -sT ${nodeModules} ./node_modules || true
  '';
}
```

The symlink `node_modules` folder appears in the current directory:

```
λ nix-shell --run 'realpath node_modules'
/nix/store/<...>-example-node-modules
```

You can also use the [`nodejs`'s setup hook](https://github.com/NixOS/nixpkgs/blob/046f091/pkgs/development/web/nodejs/setup-hook.sh#L2), which hooks any provided `buildInputs` into the `NODE_PATH` environment variable if the derivation contains the `lib/node_modules` path. The `makeNodeModules` function does not do this by default, but an override can be used to set the prefix. `nodejs` should also be provided in `buildInputs` to make the hook work. For example, in `./shell.nix`:

```nix
with import <nixpkgs> { };
let nodeModules = import ./package.nix;
in mkShell {
  buildInputs = [
    nodejs
    (nodeModules.override { prefix = "/lib/node_modules"; })
  ];
}
```

Then, it appears in the `$NODE_PATH`:

```
λ nix-shell -j auto --run 'echo $NODE_PATH | tr \: \\n | grep example'
/nix/store/<...>-example-node-modules/lib/node_modules
```

You can also set the `NODE_PATH` environment variable directly into the shell derivation:

```nix
with import <nixpkgs> { };
let
  nodeModules = import ./package.nix;
in mkShell {
  NODE_PATH = nodeModules;
}
```

Then, it appears in the `$NODE_PATH`:

```
λ nix-shell --run 'echo $NODE_PATH | tr \: \\n | grep example'
/nix/store/<...>-example-node-modules
```

### Proxy mode for Yarn CLI

> WARNING! The proxy mode is subject to change or deletion. Use at your own risk.

You can proxy Yarn invocations to hijack regular workflow commands and provide a seamless developer experience of Node.js module installation using js2nix with Nix. This is done using the `js2nix.proxy` derivation in your `buildInputs` section, which provides a `yarn` executable that does that proxying feature.

By convention, this proxy tool looks for a `package.nix` file, relative to the `package.json` file, that returns a result of the `makeNodeModules` function. This is a derivation that links Node.js modules inside and executes the `nix-build` command and symlinks the output of the build result as `node_modules`, next to the `package.nix` file.

To do this, replace Yarn with the proxied executable:

```nix
with import <nixpkgs> { };
mkShell {
  buildInputs = [
    # your build inputs
    js2nix.proxy
  ];
}
```

The previous expression provides you with a `yarn` executable which is actually this proxy. The executable is self-descriptive and was designed to not introduce any new workflows for Yarn users. So, the workflow process remains the same, and instead of getting `node_modules` created by Yarn you will be getting such folder symlinked to the Nix store artefact.


### js2nix's runtime dependency on `node-gyp`

Packages that implement native extensions (for example, those that have `binding.gyp` files) must be built via `node-gyp`. This is an npm package that must be built in Nix first and then provided as native build inputs to the standard build process. To make this possible, js2nix bootstraps itself with no dependency on `node-gyp` to instantiate a minimal viable tool to be able to create the `node-gyp` Nix package, then js2nix instantiates itself with this pre-built `node-gyp` as it's native build input dependency.

This `node-gyp` package is available as:

```nix
js2nix.node-gyp
```

You can instantiate js2nix with the external `node-gyp` Nix package:

```nix
with import <nixpkgs> { };

let
  node-gyp = callPackage ./from/your/source.nix { };
  js2nix = callPackage (builtins.fetchGit {
    url = "ssh://git@github.com/Canva/js2nix.git";
    ref = "main";
  }) { inherit node-gyp; };
in js2nix
```

### Caveats

A full installation from scratch using Nix can take more time than one of the Node.js ecosystem's package managers like yarn or npm. This is because these tools are written for Node.js, which executes concurrent jobs within a single thread using an [event-loop](https://nodejs.dev/learn/the-nodejs-event-loop), so no context switching happens. This is a different approach to the traditional operating system threads used by Nix. You can still improve the speed using the [`--max-jobs`](https://nixos.org/manual/nix/stable/#opt-max-jobs) option or more [advanced techniques](https://nixos.org/manual/nix/unstable/advanced-topics/cores-vs-jobs.html).

This is the expected behaviour for Nix. A [substituters](https://nixos.org/manual/nix/stable/#conf-substituters) option (also known as a binary cache) exists to address this particular issue. Since Nix is optimised to use binary caches and handle such cases in a reasonable time, it is assumed that all artefacts of `node_modules` will be cached. A slow package-building process is not an issue, because it should only happen once in most cases.

[yarn]: https://classic.yarnpkg.com
[npm]: https://npmjs.com