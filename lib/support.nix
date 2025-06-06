{ lib, self }:
let
  inherit (builtins) fromTOML match;
  inherit (lib)
    readFile mapAttrs mapAttrs' makeOverridable warnIf
    filter elem elemAt
    attrNames attrValues recursiveUpdate optionalAttrs;
  inherit (self.pkg-info) mkPkgOrWorkspaceInfoFromCargoToml getPkgInfoFromIndex toPkgId;
  inherit (self.resolve) resolveDepsFromLock resolveFeatures;
  inherit (self.target-cfg) platformToCfgs evalTargetCfgStr;
in
rec {

  # https://doc.rust-lang.org/cargo/reference/profiles.html#default-profiles
  defaultProfiles = rec {
    dev = {
      name = "dev";
      build-override = defaultBuildProfile;
      opt-level = 0;
      debug = true;
      debug-assertions = true;
      overflow-checks = true;
      lto = false;
      panic = "unwind";
      codegen-units = 256;
      rpath = false;
    };
    release = {
      name = "release";
      build-override = defaultBuildProfile;
      opt-level = 3;
      debug = false;
      debug-assertions = false;
      overflow-checks = false;
      lto = false;
      panic = "unwind";
      codegen-units = 16;
      rpath = false;
    };
    test = dev // { name = "test"; };
    bench = release // { name = "bench"; };
  };

  defaultBuildProfile = {
    opt-level = 0;
    codegen-units = 256;
  };

  profilesFromManifest = manifest:
    let
      knownFields = [
        "name"
        "inherits"
        # "package" # Unsupported yet.
        "build-override"

        "opt-level"
        "debug"
        # split-debug-info # Unsupported.
        "strip"
        "debug-assertions"
        "overflow-checks"
        "lto"
        "panic"
        # incremental # Unsupported.
        "codegen-units"
        "rpath"
      ];

      profiles = mapAttrs (name: p:
        let unknown = removeAttrs p knownFields; in
        warnIf (unknown != {}) "Unsupported fields of profile ${name}: ${toString (attrNames unknown)}"
          (optionalAttrs (p ? inherits) profiles.${p.inherits} // p)
      ) (recursiveUpdate defaultProfiles (manifest.profile or {}));

    in profiles;

  mkRustPackageOrWorkspace =
    { defaultRegistries, pkgsBuildHost, buildRustCrate, stdenv }@default:
    { src # : Path
    , lockPath ? null
    , gitSrcs ? {} # : Attrset Path
    , buildCrateOverrides ? {} # : Attrset (Attrset _)
    , extraRegistries ? {} # : Attrset Registry
    , registries ? defaultRegistries // extraRegistries

      , rustc ? pkgsBuildHost.rustc
      , stdenv ? default.stdenv
    }: let
      manifest = fromTOML (readFile (src + "/Cargo.toml"));
      profiles = profilesFromManifest manifest;
      lockSrc = if lockPath == null then (src + "/Cargo.lock") else lockPath;
      lock = fromTOML (readFile lockSrc);
      localSrcInfos = mkPkgOrWorkspaceInfoFromCargoToml {
        inherit src;
      };
    in mkRustPackageSet {
      gitSrcInfos = mapAttrs (url: src:
        mkPkgOrWorkspaceInfoFromCargoToml { inherit src; }
      ) gitSrcs;
        
      inherit lock profiles localSrcInfos buildRustCrate buildCrateOverrides registries rustc stdenv;
    };

  # -> { <profile-name> = { <member-pkg-name> = <drv>; }; }
  mkRustPackageSet =
    { lock # : <fromTOML>
    , localSrcInfos # : Attrset PkgInfo
    , gitSrcInfos # : Attrset (AttrSet PkgInfo)
    , profiles # : Attrset Profile
    , buildCrateOverrides # : Attrset (Attrset _)
    , buildRustCrate # : Attrset -> Derivation
    , registries # : Attrset Registry

    # FIXME: Cross compilation.
    , rustc
    , stdenv
    }:
    let

      getPkgInfo = { source ? null, name, version, ... }@args: let
        m = match "(registry|git)\\+([^#]*).*" source;
        kind = elemAt m 0;
        url = elemAt m 1;
      in
        # Local crates have no `source`.
        if source == null then
          localSrcInfos.${toPkgId args}
            or (throw "Local crate is outside the workspace: ${toPkgId args}")
          // { isLocalPkg = true; }
        else if m == null then
          throw "Invalid source: ${source}"
        else if kind == "registry" then
          getPkgInfoFromIndex
            (registries.${url} or
              (throw "Registry `${url}` not found. Please define it in `extraRegistries`."))
            args
          // { inherit source; } # `source` is for crate id, which is used for overrides.
        else if kind == "git" then
          gitSrcInfos.${url}.${name}
            or (throw "Git package `${name}` was not found in source `${url}`. Please define it in `gitSrcs`.")
        else
          throw "Invalid source: ${source}";

      hostCfgs = platformToCfgs stdenv.hostPlatform;

      pkgSetRaw = resolveDepsFromLock getPkgInfo lock;
      pkgSet = mapAttrs (id: info: info // {
        dependencies = map (dep: dep // {
          targetEnabled = dep.target != null -> evalTargetCfgStr hostCfgs dep.target;
        }) info.dependencies;
      }) pkgSetRaw;

      selectDeps = pkgs: deps: enabled-deps: selectKind: onlyLinks:
        map
          (dep: { rename = dep.rename or null; drv = pkgs.${dep.resolved}; })
          (filter
            ({ kind, resolved, ... }:
              kind == selectKind && resolved != null 
              && enabled-deps ? ${resolved}
              && (onlyLinks -> pkgSet.${resolved}.links != null))
            deps);

      buildRustCrate' = info: args:
        let
          # TODO: Proc macro crates should behave differently in dependency resolution.
          # But this override is applied just before the `buildRustCrate` call.
          args' = args // (info.__override or lib.id) args;
          args'' = args' // (buildCrateOverrides.${toPkgId info} or lib.id) args';
          workspace-inheritable-fields = [
            "authors" "categories"
            "description" "documentation"
            "edition" "exclude"
            "homepage" "include"
            "keywords" "license"
            "license-file" "publish"
            "readme" "repository"
            "rust-version" "version"
          ];
          args''' = (lib.filterAttrs (name: _: elem name workspace-inheritable-fields)
            info) // args'';
        in
          buildRustCrate args''';

      mkPkg = profile: rootId: makeOverridable (
        { features }:
        let
          rootFeatures = if features != null then features
            else if pkgSet.${rootId}.features ? default then [ "default" ]
            else [];
          resolvedFeatures = resolveFeatures {
            inherit rootId pkgSet rootFeatures;
          };

          buildDependencies = resolvedFeatures.normal // resolvedFeatures.build;
          normalDependencies = resolvedFeatures.normal;
          
          pkgsBuild = mapAttrs (id: features: let info = pkgSet.${id}; in
              buildRustCrate' info {
                inherit (info) version src procMacro;
                inherit features profile rustc;
                pname = info.name;
                capLints = if localSrcInfos ? id then null else "allow";
                buildDependencies = selectDeps pkgsBuild info.dependencies buildDependencies "build" false;
                # Build dependency's normal dependency is still build dependency.
                dependencies = selectDeps pkgsBuild info.dependencies normalDependencies "normal" false;
                linksDependencies = selectDeps pkgsBuild info.dependencies normalDependencies "normal" true;
              }
          ) buildDependencies; 

          pkgs = mapAttrs (id: features: let info = pkgSet.${id}; in
              buildRustCrate' info {
                inherit (info) version src links procMacro;
                inherit features profile rustc;
                pname = info.name;
                capLints = if localSrcInfos ? id then null else "allow";
                buildDependencies = selectDeps pkgsBuild info.dependencies buildDependencies "build" false;
                dependencies = selectDeps pkgs info.dependencies normalDependencies "normal" false;
                linksDependencies = selectDeps pkgs info.dependencies normalDependencies "normal" true;
              }
          ) normalDependencies;
        in
          pkgs.${rootId}
      ) {
        features = null;
      };

    in 
      mapAttrs (_: profile:
        mapAttrs' (pkgId: pkgInfo: {
          name = pkgInfo.name;
          value = mkPkg profile pkgId;
        }) localSrcInfos
      ) profiles;

  build-from-src-dry-tests = { assertEq, pkgs, defaultRegistries, ... }: let
    inherit (builtins) head listToAttrs;

    mkPackage = pkgs.callPackage mkRustPackageOrWorkspace {
      inherit defaultRegistries;
      buildRustCrate = args: args;
    };

    build = src: args:
      head (attrValues (mkPackage ({ inherit src; } // args)).dev);

  in
  {
    features = let ret = build ../tests/features {}; in
      assertEq (lib.naturalSort ret.features) [ "a" "default" "semver" ];

    dependency-features = let
      ret = build ../tests/features { };
      semver = (head ret.dependencies).drv;
      serde = (head semver.dependencies).drv;
    in assertEq
      [ semver.features serde.features ]
      [ ["default" "serde" "std"] [ /* Don't trigger default features */ ] ];

    dependency-overrided = let
      ret = build ../tests/features {
        buildCrateOverrides."" = old: { a = "b"; };
        buildCrateOverrides."serde 1.0.139 (registry+https://github.com/rust-lang/crates.io-index)" = old: {
          buildInputs = [ "some-inputs" ];
        };
      };
      semver = (head ret.dependencies).drv;
      serde = (head semver.dependencies).drv;
    in
      assertEq serde.buildInputs [ "some-inputs" ];

    dependency-kinds = let
      mkSrc = from: { __toString = _: ../tests/fake-semver; inherit from; };
      gitSrcs = {
        "https://github.com/dtolnay/semver?tag=1.0.0" = mkSrc "tag";
        "http://github.com/dtolnay/semver" = mkSrc "branch"; # v1, v2
        "http://github.com/dtolnay/semver?branch=master" = mkSrc "branch"; # v3
        "ssh://git@github.com/dtolnay/semver?rev=a2ce5777dcd455246e4650e36dde8e2e96fcb3fd" = mkSrc "rev";
        "ssh://git@github.com/dtolnay/semver" = mkSrc "nothing";
      };
      extraRegistries = {
        "https://www.github.com/rust-lang/crates.io-index" =
          head (attrValues defaultRegistries);
      };

      ret = build ../tests/dependency-v3 {
        inherit gitSrcs extraRegistries;
      };
      ret' = listToAttrs
        (map (dep: {
          name = if dep.rename != null then dep.rename else dep.drv.pname;
          value = dep.drv.src.from or dep.drv.src.name;
        }) ret.dependencies);
    in
      assertEq ret' {
        cratesio = "crate-semver-1.0.12.tar.gz";
        git_branch = "branch";
        git_head = "nothing";
        git_rev = "rev";
        git_tag = "tag";
        registry_index = "crate-semver-1.0.12.tar.gz";
      };

    libz-propagated = let
      ret = build ../tests/libz-dynamic {};
      libz = (head ret.dependencies).drv;
    in
      assertEq (head libz.propagatedBuildInputs).pname "zlib";

    libz-link = let
      ret = build ../tests/libz-dynamic {};
      libz = (head ret.dependencies).drv;
      libz' = (head ret.linksDependencies).drv;
    in
      assertEq [ libz.links libz'.links ] [ "z" "z" ];
  };

}
