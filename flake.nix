{
  description = "A flake for ansible-collection-proxmox repo";

  outputs = { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "x86_64-darwin"
        "i686-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f system);
    in
    {
      packages = forAllSystems (system:
        let
          pythonOverride = final: prev: {
            # Remove collections, add sshpass
            ansible-core = prev.ansible-core.overridePythonAttrs (oldAttrs: {
              propagatedBuildInputs =
                builtins.filter (drv: drv.pname != "ansible") oldAttrs.propagatedBuildInputs;
            });
            # Add missing dependency
            ansible-compat = prev.ansible-compat.overridePythonAttrs (oldAttrs: {
              propagatedBuildInputs = oldAttrs.propagatedBuildInputs ++ [ final.jsonschema ];
            });
          };
          overlay = final: prev: {
            pythonPackagesExtensions = [ pythonOverride ];
          };
          overlays = [ overlay ];
          pkgs = import "${nixpkgs}/pkgs/top-level" { localSystem = system; inherit overlays; };
        in
        with pkgs;
        {
          default = buildEnv {
            name = "ansible-collection-proxmox-env";
            paths = [
              python3Packages.ansible-core
              ansible-lint
            ];
            pathsToLink = [ "/bin" ];
          };
        }
      );

      checks = forAllSystems (system: {
        default = self.packages.${system}.default;
      });
    };
}
