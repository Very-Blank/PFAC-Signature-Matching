{
  description = "Hip flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = {nixpkgs, ...}: let
    system = "x86_64-linux";
  in {
    devShells."${system}".default = let
      pkgs = import nixpkgs {inherit system;};
    in
      pkgs.mkShell {
        packages = [
          pkgs.rocmPackages.clr
          pkgs.zig_0_16
        ];

        shellHook = ''
          export CPLUS_INCLUDE_PATH=${pkgs.stdenv.cc.cc}/include/c++/${pkgs.stdenv.cc.cc.version}:${pkgs.stdenv.cc.cc}/include/c++/${pkgs.stdenv.cc.cc.version}/${pkgs.stdenv.hostPlatform.config}:$CPLUS_INCLUDE_PATH
        '';
      };
  };
}
