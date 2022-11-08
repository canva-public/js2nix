## Implementation details

js2nix is implemented as a CLI tool written in JavaScript and a Nix library that picks up that tool and executes it internally. This then generates a Nix expression out of the given tuple of `package.json` and `yarn.lock` files in a pure manner as a separate derivation, that then can be imported into the Nix runtime and the generated Nix derivations are built via the provided Nix library to install Node.js dependencies. The artifact can then be symlinked to a local location as a `node_modules` folder or can be placed or picked up by Nix as a part of `NODE_PATH` to make it available for the Node.js resolution mechanism. 

Every derivation that represents an npm package is a first-class citizen in Nix and can be used independently, which is a convenient way to provide Node.js based CLIs in Nix. That is, if the npm package exposes a binary, it will be picked up by Nix and made available in `PATH` with no additional effort.

### The `node_modules` folder layout

The classic approach to get Node.js dependencies ready to use is to have nested `node_modules` folders for every package that has dependencies. While this approach is correct, it has a major downside: some dependencies will be duplicated, which leads to unnecessary redundancy.

To address this, yarn and npm use a flat module structure where almost all the dependencies are hoisted to the top-level `node_modules` folder, except those dependencies that have a clash on the top level. This approach makes sense when all the dependencies must be placed in a `node_modules` folder as real paths in order to reduce file duplication, as described earlier.

For more information, see [how npm works](https://npm.github.io/how-npm-works-docs/npm3/how-npm3-works.html).

However, none of these approaches work well for the goals of this project. The nested structure won't allow having full control over every individual package, because all the dependencies are placed in a nested folder and are part of a single artefact. The flat module approach doesn't work well either, because every package in the flat structure is a context-dependent package that cannot be re-used outside of that particular installation, breaking granularity.

Instead, js2nix installs all the dependencies into a `node_modules` folder where every single package is symlinked from the Nix store, replicating [what pnpm does](https://www.kochan.io/nodejs/why-should-we-use-pnpm.html). For example:

```
λ tree ./node_modules
./node_modules
├── @webassemblyjs
│   └── ast -> /nix/store/<...>-babel-core-1.9.1/pkgs/babel---core@1.9.1/node_modules/@webassemblyjs/ast
└── semver -> /nix/store/<...>-semver-7.3.5/pkgs/semver@7.3.5/node_modules/semver
```

And if we check the `semver` package further:

```
λ tree /nix/store/<...>-semver-7.3.5/pkgs/semver@7.3.5/node_modules/
/nix/store/<...>-semver-7.3.5/pkgs/semver@7.3.5/node_modules/
├── lru-cache -> /nix/store/<...>-lru-cache-6.0.0/pkgs/lru-cache@6.0.0/node_modules/lru-cache
└── semver
    ...
    ├── README.md
    ├── package.json
    ...
```

> _<sup>Nix hashes have been replaced with `<...>` because of readability reasons</sup>_

As you can see, every package is placed into the `/nix/store/*/pkgs/<package>@<version>/node_modules/*` folder. This is to allow packages to require themselves, as some of them do, as well as place more than one package into a single derivation to host dependency cycles (see below), since Nix doesn't support a dependency tree that is not a DAG.

### Dependency cycles

You can publish npm packages that have dependency cycles to public registries. For example, `A` depends on `B` that depends on `A`. Since Nix represents dependencies as a directed acyclic graph, it's not possible to express such cases in Nix. However, it's possible to host such dependency cycles within a single Nix derivation so cycles will be scoped by a single module and won't leak outside. 

For a more complex example, assume the following dependency graph:

```
A → B → C → D → ╮
        ╰ ← ← ← E ← ╮
                ╰ → F
```

The `C` package transitively depends on itself. 

Let's see how this can be represented in a form that remains operational and doesn't have cycles between Nix derivation.

We have to have self-containing packages to address granularity and provide re-usability, so we can't pop up all the packages to the top-level. However, we can place cycled packages at the level where a cycle was first introduced and scope such cycle within a single Nix derivation. By doing that, we sacrifice context independence of all the dependencies of `C`, but this happens for the smallest context possible.

So resolved dependency graph will look like this:

```
A → B → C → C+D → ╮
        ╰ ← ←  ← C+E ← ╮
                  ╰ → C+F
```

Where `C+D`, for example, means that the `D` package is physically hosted within the Nix derivation of the `C` package. That is, the `D` package is going to be copied into the `C` package folder rather than symlinked from the Nix store. Note that the `F` package is being hosted by `C` but not `E`, because `E` is being hosted by `C` already.

And the resulting files structure of the `C-x.x.x` derivation resembles the following:

```
λ tree -L 3 /nix/store/<...>-C-x.x.x/pkgs/
/nix/store/<...>-C-x.x.x/pkgs/
├── C@x.x.x
|   └── node_modules
|       ├── C
|       └── D -> ../../D@x.x.x/node_modules/D
├── D@x.x.x
|   └── node_modules
|       ├── D
|       └── E -> ../../E@x.x.x/node_modules/E
├── E@x.x.x
|   └── node_modules
|       ├── E
|       ├── F -> ../../F@x.x.x/node_modules/F
|       └── C -> ../../C@x.x.x/node_modules/C
└── F@x.x.x
    └── node_modules
        ├── F
        └── E -> ../../E@x.x.x/node_modules/E
```

So, every package in this set can access only its direct dependencies but not the others.

> Note: this is a particularly rare case but still needs to be considered.

### Overriding

You can override a node package input, as well as the resulting derivation using the following as an example:

```nix
with import <nixpkgs> { };

let
  tree = js2nix.load ./yarn.lock { 
    overlays = [
      (self: super: {
        "babel-jest@27.0.2" = super."babel-jest@27.0.2".override
          # Add peer dependency
          (x: { modules = x.modules ++ [ (self."@babel/core@7.14.3") ]; });
        "jest@27.0.2" = super."jest@27.0.2".overrideAttrs
          # Make jest run in Node.js@16
          (x: { buildInputs = [ nodejs-16_x ]; });
      })
    ]; 
  };
in tree
```

Due to yarn not providing information about peer dependencies within the `yarn.lock` file, it's only possible to make packages with peer dependencies work by overriding their dependencies and providing them as in the example above. Defining those dependencies on the top-level (in the `package.json` file) won't work due to the nested [node_modules structure](#the-node_modules-folder-layout) that js2nix provides.

### Life-cycle scripts

js2nix supports life-cycle scripts, but this is limited to `install` and `postinstall` by default. Change these using the `lifeCycleScripts` attribute. This attribute affects the resulting `postInstall` attribute on the final derivation, which is a bash script generated according to the  `lifeCycleScripts` attribute's content.

The `install` script is treated as special. This means if there is no `install` section in the `package.json#scripts` file, but the `bindings.gyp` file is present in the package folder, the install script will be generated as `node-gyp rebuild` if the `install` is presented in the `lifeCycleScripts` attribute. Disabling automatic `bindings.gyp` file detection will cut off the `install` from the `lifeCycleScripts` attribute.

Life-cycle scripts downloaded from the internet (for example, precompiled binaries) probably won't work. This is because it might be executed in the Nix sandbox (enabled by default on Linux only), so no networking is not allowed. Or, if the package has downloaded on an environment with no sandbox enabled (for example, macOS) it won't work in pure mode due to requiring system dependencies.

Consider overriding life-cycle scripts and providing the resources that the package is trying to fetch and use manually, as shown in the following example:

```nix
with import <nixpkgs> { };

let
  tree = js2nix.load ./yarn.lock {
    overlays = [
      (self: super: {
        "puppeteer@1.20.0" = super."puppeteer@1.20.0".override (x: {
          # disable life-cycle scripts
          lifeCycleScripts = [ ];
        });
        "fast-cli@3.0.1" = super."fast-cli@3.0.1".overrideAttrs (x: {
          nativeBuildInputs = [ makeWrapper ];
          postInstall = ''
            # Execute the postInstall script, generated according to the 
            # lifeCycleScripts attribute value
            ${x.postInstall}
            # Additionally, wrap the binary with a particular chromium executable
            wrapProgram $out/bin/fast \
              --set PUPPETEER_EXECUTABLE_PATH ${chromium.outPath}/bin/chromium
          '';
        });
      })
    ];
  };
in tree
```

In the previous example, life-cycle scripts for [hosted](#dependency-cycles) packages are not being invoked. To do this, you can override the `postInstall` script of the host's derivation.

### Local packages

NPM allows defining dependencies to packages that are present on the local machine, as shown in the following example:

```json
{
  "dependencies": {
    "local-package": "../../local-package"
  }
}
```

js2nix handles such cases as well, but makes no assumption about where the package is located and shifts the responsibility by allowing the user to provide a location via the override mechanism. 

There are two reasons for that:

- The generated Nix expression is located in the Nix store, so relative paths would be inconvenient and not reproducible, and absolute paths would break the setup on another machine where the main project is located on a different path. 
- Local dependencies can depend on other local dependencies that are defined relative to the local package that depends on them. So, it would require a sophisticated module resolution algorithm, which is out of the scope of this project and wouldn't resolve the problem.

So js2nix makes the package locations the user's responsibility, hence, the locations won't affect the reproducibility. js2nix will however provide a comprehensive message with a code snippet about how to provide this missing piece of information to make the whole dependency closure work.

For example:

```nix
(self: super: {
  "@canva/eslint-rules@0.0.0" = super."@canva/eslint-rules@0.0.0".override
    (x: { src = ../canva/tools/eslint/eslint-rules; });
})
```

> Note: The Nix `path` builtin can be used to filter sources from a project directory containing non-source files, for example a `node_modules` folder used during development:
>
> ```nix
> builtins.path {
>   name = "canva-eslint-rules";
>   path = ../canva/tools/eslint/eslint-rules;
>   # A filter function that can be used to limit the source that will be used.
>   # Filter out node_modules folders from the package's source
>   filter = p: t:
>     !(t == "directory" && lib.hasSuffix "node_modules" p);
> }
> ```
>
> The same can be done for a `./dist/` folder (a commonly used name for a folder with compiled artifacts in it).
> See https://nixos.org/manual/nix/stable/#builtin-path for more details.

### Packages from unknown registries

js2nix relies on the tarball URLs in the `yarn.lock` file being able to contain a SHA1 sum of the tarball content in the URL fragment. That is the case for `registry.yarnpkg.com` and `registry.npmjs.org` hosts, but not for other registries. In an average `yarn.lock` file, the majority of the URLs will point to those first two registries. However, for example, if a dependency is defined as a direct Github one:

```json
{
  "dependencies": {
    "chimp": "hacker/chimp#dfa9125b498297f848e6a5f9eabbf55bf3eb1318"
  }
}
```

yarn won't provide a SHA1 sum for that URL, which makes it impossible to construct a Nix expression for that package since Nix requires SHA sums because of reproducibility. Similar to the local packages approach, js2nix doesn't make assumptions here and doesn't fetch these packages internally and infer such SHAs somehow. Rather, it relies on the user to provide such SHAs. 

This is because if a package content has changed, a new SHA could be inferred implicitly. So, there's no precise control over such package's change. Also, such missing SHAs will be generated every time when new NIx expression are built, which means all the content of such packages will be fetched, causing a high load to networking and slowing down Nix generations and breaking purity.