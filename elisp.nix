/*
Parse an emacs lisp configuration file to derive packages from
use-package declarations.
*/

{ pkgs }:
let
  parse = pkgs.callPackage ./parse.nix { };
  inherit (pkgs) lib;



in
{ config
# bool to use the value of config or a derivation whose name is default.el
, defaultInitFile ? false
# emulate `use-package-always-ensure` behavior (defaulting to false)
, alwaysEnsure ? null
, withoutNotice ? null
# emulate `#+PROPERTY: header-args:emacs-lisp :tangle yes`
, alwaysTangle ? false
, extraEmacsPackages ? epkgs: [ ]
, package ? pkgs.emacs
, override ? (self: super: { })
}:
let
  ensureNotice = ''
    Emacs-overlay API breakage notice:

    Previously emacsWithPackagesFromUsePackage always added every use-package definition to the closure.
    Now we will only add packages with `:ensure`, `:ensure t` or `:ensure <package name>`.

    You can get back the old behaviour by passing `alwaysEnsure = true`.
    For a more in-depth usage example see https://github.com/nix-community/emacs-overlay#extra-library-functionality

    To suppress this notice pass `withoutNotice = true`.
  '';

  doEnsure = if (alwaysEnsure == null) then (if (withoutNotice == null) then
                                               builtins.trace ensureNotice false
                                             else false)
             else alwaysEnsure;

  isOrgModeFile =
    let
      ext = lib.last (builtins.split "\\." (builtins.toString config));
      type = builtins.typeOf config;
    in
      type == "path" && ext == "org";

  configText =
    let
      type = builtins.typeOf config;
    in # configText can be sourced from either:
      # - A string with context { config = "${hello}/config.el"; }
      if type == "string" && builtins.hasContext config && lib.hasPrefix builtins.storeDir config then builtins.readFile config
      # - A config literal { config = "(use-package foo)"; }
      else if type == "string" then config
      # - A config path { config = ./config.el; }
      else if type == "path" then builtins.readFile config
      # - A derivation { config = pkgs.writeText "config.el" "(use-package foo)"; }
      else if lib.isDerivation config then builtins.readFile "${config}"
      else throw "Unsupported type for config: \"${type}\"";

  packages = parse.parsePackagesFromUsePackage {
    inherit configText isOrgModeFile alwaysTangle;
    alwaysEnsure = doEnsure;
  };
  emacsPackages = (pkgs.emacsPackagesFor package).overrideScope' (self: super:
    # for backward compatibility: override was a function with one parameter
    if builtins.isFunction (override super)
    then override self super
    else override super
  );
  emacsWithPackages = emacsPackages.emacsWithPackages;
  mkPackageError = name:
    let
      errorFun = if (alwaysEnsure != null && alwaysEnsure) then builtins.trace else throw;
    in
    errorFun "Emacs package ${name}, declared wanted with use-package, not found." null;
in
emacsWithPackages (epkgs:
  let
    usePkgs = map (name: epkgs.${name} or (mkPackageError name)) packages;
    extraPkgs = extraEmacsPackages epkgs;
    defaultInitFilePkg =
      if !((builtins.isBool defaultInitFile) || (lib.isDerivation defaultInitFile))
      then throw "defaultInitFile must be bool or derivation"
      else
        if defaultInitFile == false
        then null
        else
          let
            # name of the default init file must be default.el according to elisp manual
            defaultInitFileName = "default.el";
          in
          epkgs.trivialBuild {
            pname = "default-init-file";
            src =
              if defaultInitFile == true
              then pkgs.writeText defaultInitFileName configText
              else
                if defaultInitFile.name == defaultInitFileName
                then defaultInitFile
                else throw "name of defaultInitFile must be ${defaultInitFileName}";
            packageRequires = usePkgs;
          };
  in
  usePkgs ++ extraPkgs ++ [ defaultInitFilePkg ])
