{
  inputs.deploy = {
    url = "github:serokell/deploy";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, deploy }@inputs: {
    mkNode = { modules, specialArgs ? { }, packages, deployKey, hosts ? null
      , system ? "x86_64-linux" }:
      let
        inherit (nixpkgs) lib;
        buildSystem = modules:
          lib.nixosSystem { inherit modules specialArgs system; };

        nixos-system = buildSystem ([ deployUser ]
          ++ map sudoRules (builtins.attrValues packages) ++ modules);

        # meta.modulePath of a package may point to a module that uses this package;
        # if that module contains a `serviceName` attribute, restart that systemd service on activation.
        serviceName = pkg:
          let servicePath = pkg.meta.modulePath ++ [ "serviceName" ];
          in if pkg ? meta && pkg.meta ? modulePath
          && lib.hasAttrByPath servicePath nixos-system.config then
            lib.getAttrFromPath servicePath nixos-system.config
          else
            null;

        deployUser = {
          users.users.deploy = {
            isNormalUser = true;
            openssh.authorizedKeys.keys = [ deployKey ];
          };
        };

        restart = pkg:
          "/run/current-system/sw/bin/systemctl restart ${serviceName pkg}";

        sudoRules = pkg: {
          security.sudo.extraRules = lib.optional (!isNull (serviceName pkg)) {
            users = [ "deploy" ];
            commands = [{
              command = restart pkg;
              options = [ "NOPASSWD" ];
            }];
          };
        };

        hostname =
          "${nixos-system.config.networking.hostName}.${nixos-system.config.networking.domain}";

        mkPackageProfile = _: pkg:
          {
            path = pkg;
            user = "deploy";
          } // lib.optionalAttrs (!isNull (serviceName pkg)) {
            activate = "sudo ${restart pkg}";
          };
      in {
        inherit hostname;
        profiles = {
          system = {
            path = nixos-system.config.system.build.toplevel;
            user = "root";
            activate = "$PROFILE/bin/switch-to-configuration switch";
          };
        } // builtins.mapAttrs mkPackageProfile packages;
      };

    mkPipeline = { deploy, packages, checks, deployFromPipeline, agents ? [ ]
      , systems ? [ "x86_64-linux" ] }@args:
      let
        pkgs = nixpkgs.legacyPackages.x86_64-linux;
        inherit (pkgs) lib;
        inherit (lib)
          getAttrFromPath collect concatStringsSep mapAttrsRecursiveCond
          optionalAttrs optionalString concatMapStringsSep splitString last head
          optional;
        inherit (builtins)
          concatMap length filter elemAt listToAttrs unsafeDiscardStringContext;

        namesTree =
          mapAttrsRecursiveCond (x: !(lib.isDerivation x)) (path: _: path);
        names = attrs: collect lib.isList (namesTree attrs);

        filterNative = what:
          listToAttrs (concatMap (system:
            optional (args.${what} ? ${system}) {
              name = system;
              value = args.${what}.${system};
            }) systems);

        buildable = {
          inherit deploy;
          packages = filterNative "packages";
        };

        packageNames = filter (x: last x == "path" || head x == "packages")
          (names buildable);

        pathByValue = listToAttrs (map (path: {
          name =
            unsafeDiscardStringContext (getAttrFromPath path buildable).drvPath;
          value = path;
        }) packageNames);

        drvFromPath = path: getAttrFromPath path buildable;

        build = comp:
          let
            drv = drvFromPath comp;
            hasArtifacts = drv ? meta && drv.meta ? artifacts;
            displayName = if head comp == "packages" then
              elemAt comp 2
            else
              "${elemAt comp 2}.${elemAt comp 4}";
          in {
            label = "Build ${displayName}";
            command = "nix-build -A ${concatStringsSep "." comp}";
            inherit agents;
          } // optionalAttrs hasArtifacts {
            artifact_paths = map (art: "result${art}") drv.meta.artifacts;
          };

        buildSteps = map build (builtins.attrValues pathByValue);

        checkNames = names { checks = filterNative "checks"; };

        check = name: {
          label = elemAt name 2;
          command = "nix-build --no-out-link -A ${concatStringsSep "." name}";
          inherit agents;
        };

        checkSteps = map check checkNames;

        doDeploy = { branch, profile }: {
          label = "Deploy ${branch} ${profile}";
          branches = [ branch ];
          command =
            "sshUser=deploy fastConnection=true NIX_PATH=nixpkgs=${inputs.nixpkgs} ${
              inputs.deploy.defaultApp.${head systems}.program
            } .#${branch}.${profile}";
          inherit agents;
        };

        deploySteps = [ "wait" ] ++ map doDeploy deployFromPipeline;

        steps = buildSteps ++ checkSteps ++ deploySteps;
      in { inherit steps; };

    mkPipelineFile = { deploy, packages, checks, deployFromPipeline
      , agents ? [ ], systems ? [ "x86_64-linux" ] }@flake:
      nixpkgs.legacyPackages.${builtins.head systems}.writeText "pipeline.yml"
      (builtins.toJSON (self.mkPipeline flake));
  };

}
