{
  lib,
  nixpkgs,
  nixcfg,
}: let
  configurationTypes = lib.attrNames requiredInputs;

  requiredInputs = {
    nixos = [ ];
    container = [ "extra-container" ];
    home = [ "home-manager" ];
  };

  configurationToPackage = {
    nixos = configuration: configuration.config.system.build.toplevel;
    container = configuration: removeAttrs configuration [ "config" "containers" ];
    hello = configuration: configuration.activationPackage;
  };

  mkConfig = import ./mkConfig.nix { inherit lib nixcfg; };
  mkNixcfgs = import ./mkNixcfgs.nix { inherit lib; };
  mkChannels = import ./mkChannels.nix { inherit lib; };

  flakeSystemAttrs = lib.genAttrs [
    "checks"
    "packages"
    "apps"
    "formatter"
    "legacyPackages"
    "devShells"
  ] (_: null);

  filterNixpkgsInputs = lib.filterAttrs (
    name: _input:
      lib.elem name [ "nixpkgs" "nixpkgs-unstable" ]
      || lib.hasPrefix "nixos-" name
      || lib.hasPrefix "release-" name
  );

  inputsWithDefaultNixpkgs = inputs: let
    latestInputs =
      lib.mapAttrs (_name: names: inputs.${lib.maximum lib.compareVersions names})
      (lib.groupBy (name: lib.head (lib.splitVersion name)) (lib.attrNames inputs));
  in
    inputs
    // lib.optionalAttrs (!inputs ? nixpkgs) {
      nixpkgs = latestInputs.nixos or latestInputs.release or nixpkgs;
    };
in
  rawConfig: let
    config = mkConfig rawConfig;

    inherit (mkNixcfgs config.inputs) nixcfgs nixcfgsAttrs;

    nixcfgsInputs = lib.concatAttrs (lib.mapGetAttrPath [ "config" "inputs" ] nixcfgs);
    nixcfgsNixpkgsInputs = inputsWithDefaultNixpkgs (filterNixpkgsInputs nixcfgsInputs);

    libNixpkgs = let
      channelName = config.lib.channelName or "nixpkgs";
    in
      nixcfgsNixpkgsInputs.${channelName}
      or (throw "The lib nixpkgs channel '${channelName}' does not exist.");

    libOverlays = lib.singleton (final: prev: { lib = nixpkgsLib; }) ++ config.lib.overlays;

    nixpkgsLib = libNixpkgs.lib.extend (final: prev: { input = libNixpkgs; } // builtins);
    nixcfgsLib = lib.extendsList (lib.concatLists (lib.catAttrs "libOverlays" nixcfgs)) (final: nixcfg.lib);
    outputLib = nixpkgsLib.extend (final: prev:
      nixcfgsLib
      //
      # Make sure we never overwrite anything of builtins or standard lib.
      lib.intersectAttrs nixcfgsLib nixpkgsLib);

    mkChannels' = mkChannels {
      nixcfgsOverlays = lib.mapAttrs (_: lib.getAttr "overlays") nixcfgsAttrs;
      inherit (config) channels;
    };

    nixcfgsChannels = mkChannels' nixcfgsNixpkgsInputs config.systems;

    configurationsArgs = lib.genAttrs configurationTypes (
      type:
        lib.mapAttrs (name: {
            system,
            channelName,
            ...
          } @ configuration: let
            inputs = inputsWithDefaultNixpkgs (
              nixcfgsInputs
              // config.inputs
              // configuration.inputs
            );
            inputs' = lib.mapAttrs (_: flake:
              flake
              // lib.attrsGetAttr system (lib.intersectAttrs flakeSystemAttrs flake))
            inputs;
            channels =
              (mkChannels' (filterNixpkgsInputs inputs) [ system ]).${system}
              // nixcfgsChannels.${system};
            pkgs =
              channels.${channelName}
              or (throw "The ${type} nixpkgs channel '${channelName}' does not exist.");
            unavailableInputs =
              lib.filter (requiredInput: !inputs ? ${requiredInput})
              ((requiredInputs.${type} or [ ]) ++ lib.optional config.requireSops "sops-nix");
          in
            if unavailableInputs != [ ]
            then throw "The ${type} configuration '${name}' did not specify '${lib.head unavailableInputs}' as part of their inputs."
            else
              configuration
              // {
                inherit channels inputs inputs' name pkgs;
              })
        config."${type}Configurations"
    );

    mkSpecialArgs = type: {
      name,
      inputs',
      moduleArgs,
      ...
    }:
      {
        # We cannot inherit name, as it will conflict with the workings of submodules.
        # It would for example lead to misconfiguring home manager.
        inherit inputs';
        lib = outputLib;
        nixcfg = {
          inherit (config) name;
          lib = nixcfgsLib;
        };
        data = lib.mapAttrs (_: lib.getAttrPath [ "config" "data" ]) nixcfgsAttrs;
        profiles = lib.mapAttrs (_: lib.getAttr "${type}Profiles") nixcfgsAttrs;
      }
      // moduleArgs;

    mkDefaultModules = type: name:
      lib.concatMap lib.attrValues (lib.catAttrs "${type}Modules" nixcfgs)
      ++ lib.concatMap (lib.optionalAttr "base") (lib.catAttrs "${type}Profiles" nixcfgs)
      ++ lib.optional (config.requireSops && lib.elem type [ "nixos" "home" ]) {
        sops.defaultSopsFile = config.path + "/${type}/configs/${name}/secrets.yaml";
      };

    defaultOverlays = lib.catAttrsPath [ "overlays" "default" ] nixcfgs;

    mkNixosModules = import ./mkNixosModules.nix {
      inherit config defaultOverlays lib mkDefaultModules mkHomeModules mkSpecialArgs;
      homeConfigurationsArgs = configurationsArgs.home;
    };

    mkHomeModules = import ./mkHomeModules.nix {
      inherit config defaultOverlays lib mkDefaultModules;
    };

    mkConfigurations = configurationsArgs: f:
      lib.listToAttrs (lib.concatMapAttrsToList (name: configurationArgs: let
        value = f configurationArgs;
      in
        if !(lib.isList value)
        then lib.singleton (lib.nameValuePair name value)
        else value)
      configurationsArgs);

    configurations = {
      nixos =
        mkConfigurations (removeAttrs configurationsArgs.nixos (lib.attrNames configurationsArgs.container))
        (args: (import (args.pkgs.input + "/nixos/lib/eval-config.nix") {
          inherit (args) system;
          lib = outputLib;
          specialArgs = mkSpecialArgs "nixos" args;
          modules = mkNixosModules args;
        }));

      container =
        mkConfigurations configurationsArgs.container
        ({
            name,
            inputs,
            system,
            channelName,
            modules,
            ...
          } @ args: let
            inherit (lib.types) attrsOf submoduleWith;
          in
            inputs.extra-container.lib.buildContainers {
              inherit system;
              nixpkgs = inputs.${channelName};
              config.imports =
                lib.optional (lib.compareVersions lib.trivial.release "23.05" < 0) (let
                  nixpkgs =
                    inputs.nixos-23_05
                    or inputs.nixos-unstable
                    or (throw ("To have similar module arguments within containers as in nixos we need special argument support."
                        + " This support has only be added in nixpkgs 23.05, so the nixpkgs channel 'nixos-23_05' or 'nixos-unstable' is required."));
                in {
                  disabledModules = [ "virtualisation/nixos-containers.nix" ];
                  imports = [ (nixpkgs.outPath + "/nixos/modules/virtualisation/nixos-containers.nix") ];
                })
                ++ lib.singleton {
                  options.containers = lib.mkOption {
                    type = attrsOf (submoduleWith {
                      shorthandOnlyDefinesConfig = true;
                      modules =
                        mkDefaultModules "container" name
                        ++ modules;
                      specialArgs = mkSpecialArgs "container" args;
                    });
                  };
                  config.containers.${name} = let
                    args = configurationsArgs.nixos.${name};
                  in {
                    specialArgs = mkSpecialArgs "nixos" args;
                    config.imports =
                      mkNixosModules args
                      ++ lib.optional (configurationsArgs.home ? ${name}) {
                        systemd.services.fix-home-manager = {
                          serviceConfig = {
                            Type = "oneshot";
                          };
                          script = lib.concatStrings (lib.mapAttrsToList (name: _: ''
                              mkdir -p /nix/var/nix/{profiles,gcroots}/per-user/${name}
                              chown ${name}:root /nix/var/nix/{profiles,gcroots}/per-user/${name}
                            '')
                            configurationsArgs.home.${name}.users);
                          wantedBy = [ "multi-user.target" ];
                        };
                      };
                  };
                };
            });

      home =
        mkConfigurations configurationsArgs.home
        ({
            name,
            inputs,
            pkgs,
            stateVersion,
            users,
            ...
          } @ args:
            lib.mapAttrsToList (username: user:
              lib.nameValuePair "${name}_${username}" (inputs.home-manager.lib.homeManagerConfiguration (let
                specialArgs = mkSpecialArgs "home" args;
              in {
                inherit pkgs;
                modules = mkHomeModules args username user;
                check = true;

                # Workaround for Home Manager to prevent its extended lib from being overwritten.
                # Related PR: https://github.com/nix-community/home-manager/pull/3969
                extraSpecialArgs = removeAttrs specialArgs [ "lib" ];
                inherit (specialArgs) lib;
              })))
            users);
    };

    packages = let
      list = lib.concatMap (type:
        lib.mapAttrsToList (
          name: configuration: let
            system =
              configuration.system
              or configuration.pkgs.system
              or (throw "The ${type} configuration is missing a system or pkgs attribute.");
          in {
            inherit name system type;
            value = configurationToPackage.${type} configuration;
          }
        )
        configurations.${type})
      configurationTypes;
    in
      lib.mapAttrs (system: group:
        lib.mapAttrs (type: group:
          lib.listToAttrs group)
        (lib.groupBy (x: x.type) group))
      (lib.groupBy (x: x.system) list);

    flakeOutputs =
      {
        inherit packages;
        inherit (config) overlays;
        formatter =
          lib.genAttrs config.systems (system:
            nixcfg.inputs.alejandra.defaultPackage.${system});
        legacyPackages = lib.mapAttrs (_: lib.getAttr "nixpkgs") nixcfgsChannels;
      }
      // lib.mapAttrs' (type: lib.nameValuePair "${type}Configurations") configurations
      // lib.getAttrs (lib.concatMap (type: [ "${type}Modules" "${type}Profiles" ]) configurationTypes) config;

    customOutputs =
      {
        inherit config libOverlays nixcfgs;
        lib = outputLib;
        # This is normally generated by flakes, but is useful to expose outside of flakes too.
        outPath = config.path;
      }
      // lib.mapToAttrs (type: lib.nameValuePair "${type}ConfigurationsArgs" config."${type}Configurations") configurationTypes;
  in
    flakeOutputs // customOutputs
