## Usage

Create a Nix expression that represents Node.js dependencies defined in `package.json` and `yarn.lock` files by creating a `./package.nix` file with the following content:

```nix
with import <nixpkgs> { };

let
  js2nix = callPackage (builtins.fetchGit {
    url = "ssh://git@github.com/Canva/js2nix.git";
    ref = "main";
  }) { };
  env = js2nix.buildEnv {
    package-json = ./package.json;
    yarn-lock = ./yarn.lock;
  };
in env.nodeModules
```

This Nix expression does the following:

1. Import nixpkgs if not given and expose its content into the global scope.
1. Import the js2nix project from the Github repo.
1. Build environment dependency closure as a Nix expression out of the `package.json` and `yarn.lock` files (see more about `buildEnv` function below).
1. Return a Nix derivation that builds all top-level dependencies. That is, all the dependencies from the `dependencies` and `devDependencies` sections in the `./package.json` file.

The approach above is [Import From Derivation](https://nixos.wiki/wiki/Import_From_Derivation) (IFD). While it's easy to use, it has some limitations that we may wish to avoid for advanced use cases. 

To avoid IFD, you can generate Nix expressions by using the js2nix executable (available from `js2nix.bin`):

```
λ js2nix --lock ./yarn.lock --out ./yarn.lock.nix
```

Then, import this expression by changing the file above with the following:

```diff
-    yarn-lock = ./yarn.lock;
+    yarn-lock-nix = ./yarn.lock.nix;
```

### `buildEnv` function

This `js2nix.buildEnv` (or simply `js2nix`) is the main functionality js2nix provides as its API, however, there are a couple more function that are also exposed for more granular advanced use-cases (see the [`../lib.nix`](../lib.nix) for more information).

This function accepts the following arguments:
- `package-json` - a path to a `package.json` file.
- `yarn-lock` - a path to a `yarn.lock` file, or
- `yarn-lock-nix` - a path to a file that was generated by the `js2nix` executable directly from `yarn.lock` file. Used to avoid IFD situation, where needed.
- `overlays` - a list of overlay functions to override the dependency tree, see [overiding](#overiding) section below for more details.

Note, `yarn-lock` and `yarn-lock-nix` arguments are mutually exclusive.

The function returns an environment object that consists of the following:

- `nodeModules` - a Nix derivation that represents a folder that holds top-level packages (declared in `package.json` file)
- `nodeModules.prod` - same as above but for production use, i.e. no dependencies from `devDependencies` section included, similarly as would `yarn install --prod` give.
- `pkgs` - an attribute set of all the packages that are present in the `yarn.lock` file with the overlays applied to it (see the [overiding](#overiding) section below for more details). The structure of the attrset is similar to:

  ```nix
  self: super: {
    # represents a package derivation by direct name with a version
    "yargs@16.2.0" = self.buildNodeModule { 
      # ... a package build logic, internal js2nix implementation
    };
    "yargs@^16.0.3" = self."yargs@16.2.0";
    "yargs" = self."yargs@16.2.0";
  }
  ```

  This is an overlay function and can look unfamiliar, but don't be stressed, this basically means that there is a package at the property of `"yargs@16.2.0"` and two references to that package from the `"yargs@^16.0.3"` and `"yargs"` aliases. This means, if the package implementation has been changed, you will be getting the new version of the package via the aliases as well.

  The short alias, with no version in it (`"yargs"` for example) is not guaranteed to work for every package in the closure because there could be a clash of short names. But if you will be trying to access a package whose names clash, you will see an error instead, with an explanation of which versions are clashing so you can choose a more appropriate one for your use case.

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
### Overriding

You can override a node package input, as well as the resulting derivation using the following as an example:

```nix
with import <nixpkgs> { };

let
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
  env = js2nix.buildEnv {
    package-json = ./package.json;
    yarn-lock = ./yarn.lock;
    inherit overlays;
  };
in env
```

Due to yarn not providing information about peer dependencies within the `yarn.lock` file, it's only possible to make packages with peer dependencies work by overriding their dependencies and providing them as in the example above. Note that defining those dependencies on the top-level (in the `package.json` file) won't address this peer dependencies due to the nested [node_modules structure](#the-node_modules-folder-layout) that js2nix provides.

#### Basic overrides in `package.json` file

Writing Nix expressions for non-Nix folks can be overwhelming and probably is not necessary so there is another simpler mechanism of overriding that can make the dependency tree work without dealing with Nix expressions at all. For example, developers from product teams can bump and update Node.js packages and deal with a JSON file only, while an infrastructure team will be handling the whole setup. This is inconvenient to reach out to the infrastructure team each time they need to update the dependency tree so this mechanism addresses this inconvenience. And it's very similar to additional sections that different package managers support. For example, Yarn supports the` resolutions` section, PNPM supports `pnpm.overrides` (and more), and so on.

For example, instead of creating an overlay function as a Nix expression like this:

```nix
self: super: {
  "@jest/globals@27.0.3" = super."@jest/globals@27.0.3".override {
    doChecks = false; };
  "babel-jest@27.0.2" = super."babel-jest@27.0.2".override
    # Add peer dependency
    (x: { modules = x.modules ++ [ (self."@babel/core@7.14.3") ]; });
  "yargs@16.2.0" = super."yargs@16.2.0".override {
    patches = [
      ./patches/0001_yargs_cve.patch
    ]; };
  "left-pad@1.3.0" = super."left-pad@1.3.0".override {
    src = ./vendor/left-pad; };
  "yo@*" = super."yo@*".override (x: {
    # Disable life-cycle scripts
    lifeCycleScripts = [ ];
  });
}
```

the same can be done in `package.json` file:
```json
{
  "js2nix": {
    "overlay": {
      "@jest/globals": {
        "doCheck": false
      },
      "babel-jest": {
        "addDependencies": [
          "@babel/core"
        ]
      },
      "yargs": {
        "patches": [
          "./patches/0001_yargs_cve.patch"
        ]
      },
      "left-pad": {
        "src": "./vendor/left-pad"
      },
      "yo": {
        "lifeCycleScripts": []
      }
    }
  }
}
```

##### Supported overlay directives:
- `js2nix.overlay.<package>.addDependencies` - list of strings. Can be an alias or a direct name with version, for example can be `"@babel/core"` or `"@babel/core@^7.1.0"` or `"@babel/core@7.14.3"`.
- `js2nix.overlay.<package>.src` - string or an object. Overrides a package source. It can be a local folder path, relative to the `package.json` file or an absolute path. Also can be an object that overrides the `fetchurl` function attributes.
- `js2nix.overlay.<package>.doCheck` - boolean. Overrides the `doCheck` argument for the package builder. It's `true` by default.
- `js2nix.overlay.<package>.patches` - a list of strings. Overrides patches with the given list. Items in the list can be strings that represent a path to a patch file, an absolute or relative the `package.json` file.
- `js2nix.overlay.<package>.lifeCycleScripts` - a list of strings. Overrides `lifeCycleScripts`, can contains scripts' names, declared in the `package.json` of the package. TIP: you can use patch feature to add some scripts you need there.

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

[yarn]: https://classic.yarnpkg.com
[npm]: https://npmjs.com
