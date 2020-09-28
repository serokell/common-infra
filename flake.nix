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

    mkPipeline = { deployAttr, checks, deployFromPipeline, agents ? [ ]
      , system ? "x86_64-linux" }:
      let
        pkgs = nixpkgs.legacyPackages.x86_64-linux;
        inherit (pkgs) lib;
        inherit (lib)
          getAttrFromPath collect concatStringsSep mapAttrsRecursiveCond
          splitString last;
        inherit (builtins)
          length filter elemAt listToAttrs unsafeDiscardStringContext;

        namesTree =
          mapAttrsRecursiveCond (x: !(lib.isDerivation x)) (path: _: path);
        names = attrs: collect lib.isList (namesTree attrs);

        packageNames = filter (x: last x == "path") (names deployAttr);

        pathByValue = listToAttrs (map (path: {
          name = unsafeDiscardStringContext
            (getAttrFromPath path deployAttr).drvPath;
          value = path;
        }) packageNames);

        build = comp: {
          label = "Build ${elemAt comp 1}.${elemAt comp 3}";
          command = "nix-build -A deploy.${concatStringsSep "." comp}";
          inherit agents;
        };

        buildSteps = map build (builtins.attrValues pathByValue);

        checkNames = names checks;

        check = name: {
          label = elemAt name 1;
          command =
            "nix-build --no-out-link -A checks.${concatStringsSep "." name}";
          inherit agents;
        };

        checkSteps = map check checkNames;

        deploy = { branch, profile }: {
          label = "Deploy ${branch} ${profile}";
          branches = [ branch ];
          command = "sshUser=deploy fastConnection=true NIX_PATH=nixpkgs=${inputs.nixpkgs} ${
              inputs.deploy.defaultApp.${system}.program
            } .#${branch}.${profile}";
          inherit agents;
        };

        deploySteps = [ "wait" ] ++ map deploy deployFromPipeline;

        steps = buildSteps ++ checkSteps ++ deploySteps;
      in { inherit steps; };

    mkPipelineFile = flake:
      builtins.toFile "pipeline.yml" (builtins.toJSON (self.mkPipeline flake));
  };

}
