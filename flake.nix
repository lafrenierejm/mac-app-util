# Copyright © 2023–2025  Hraban Luyat
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published
# by the Free Software Foundation, version 3 of the License.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    cl-nix-lite.url = "github:hraban/cl-nix-lite";
    flake-compat = {
      # Use my own fixed-output-derivation branch because I don’t want users to
      # need to eval-time download dependencies.
      url = "github:hraban/flake-compat/fixed-output";
      flake = false;
    };
    systems.url = "github:nix-systems/default-darwin";
    flake-utils = {
      url = "flake-utils";
      inputs.systems.follows = "systems";
    };
    treefmt-nix.url = "github:numtide/treefmt-nix";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      cl-nix-lite,
      treefmt-nix,
      ...
    }:
    {
      homeManagerModules.default =
        {
          pkgs,
          lib,
          config,
          ...
        }:
        let
          cfg = config.targets.darwin.mac-app-util;
        in
        {
          options = with lib; {
            targets.darwin.mac-app-util.enable = mkOption {
              type = types.bool;
              default = builtins.hasAttr pkgs.stdenv.system self.packages;
              example = true;
              description = "Whether to enable mac-app-util home manager integration";
            };
            targets.darwin.mac-app-util.signingIdentity = mkOption {
              type = types.str;
              default = "mac-app-util user signing";
              example = "My Code Signing Certificate";
              description = ''
                Name or SHA-1 hash of the code-signing certificate (in your login
                keychain) used to sign the copies of your apps.  Signing with a
                fixed certificate is what keeps privacy grants such as Full Disk
                Access across app updates.
              '';
            };
            targets.darwin.mac-app-util.createSigningIdentity = mkOption {
              type = types.bool;
              default = true;
              example = false;
              description = ''
                Whether to create a self-signed certificate named
                `signingIdentity` in your login keychain during activation, if it
                does not exist yet and there are apps to sign.  macOS asks for
                your password once, to trust the new certificate.  Disable this to
                manage the certificate yourself (e.g. with `mac-app-util
                create-cert`).
              '';
            };
          };
          config = lib.mkIf cfg.enable {
            home.activation = {
              trampolineApps =
                let
                  mac-app-util = self.packages.${pkgs.stdenv.system}.default;
                in
                lib.hm.dag.entryAfter [ "writeBoundary" ] ''
                  fromDir="$HOME/Applications/Home Manager Apps"
                  toDir="$HOME/Applications/Home Manager Trampolines"
                  export MAC_APP_UTIL_SIGN_IDENTITY=${lib.escapeShellArg cfg.signingIdentity}
                  ${lib.optionalString cfg.createSigningIdentity "export MAC_APP_UTIL_CREATE_CERT=1"}
                  ${mac-app-util}/bin/mac-app-util sync-trampolines "$fromDir" "$toDir"
                '';
            };
          };
        };
      darwinModules.default =
        {
          config,
          pkgs,
          lib,
          ...
        }:
        let
          cfg = config.services.mac-app-util;
        in
        {
          options = {
            # Technically this isn’t a “service” but this seems like the most
            # polite place to put this?
            services.mac-app-util.enable = lib.mkOption {
              type = lib.types.bool;
              default = true;
              example = false;
            };
            services.mac-app-util.signingIdentity = lib.mkOption {
              type = lib.types.str;
              default = "mac-app-util system signing";
              example = "My Code Signing Certificate";
              description = ''
                Name or SHA-1 hash of the code-signing certificate used to sign
                the copies of your apps.  Activation scripts run as root, so it
                must be in the System keychain.
              '';
            };
            services.mac-app-util.createSigningIdentity = lib.mkOption {
              type = lib.types.bool;
              default = true;
              example = false;
              description = ''
                Whether to create a self-signed certificate named
                `signingIdentity` in the System keychain during activation, if it
                does not exist yet and there are apps to sign.  macOS asks for an
                administrator password once, to trust the new certificate.
                Disable this to manage the certificate yourself (e.g. with `sudo
                mac-app-util create-cert`).
              '';
            };
          };
          config = lib.mkIf cfg.enable {
            system.activationScripts.postActivation.text =
              let
                mac-app-util = self.packages.${pkgs.stdenv.system}.default;
              in
              ''
                export MAC_APP_UTIL_SIGN_IDENTITY=${lib.escapeShellArg cfg.signingIdentity}
                ${lib.optionalString cfg.createSigningIdentity "export MAC_APP_UTIL_CREATE_CERT=1"}
                ${mac-app-util}/bin/mac-app-util sync-trampolines "/Applications/Nix Apps" "/Applications/Nix Trampolines"
              '';
          };
        };
    }
    // (
      with flake-utils.lib;
      eachDefaultSystem (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system}.extend cl-nix-lite.overlays.default;
          treefmt = { ... }: {
            projectRootFile = "flake.nix";
            programs.nixfmt.enable = true;
          };
          treefmtPkg = treefmt-nix.lib.evalModule pkgs treefmt;
        in
        {
          checks = {
            default = self.packages.${system}.default;
            treefmt = treefmtPkg.config.build.check self;
          };
          packages = {
            default = pkgs.callPackage (
              {
                lispPackagesLite,
                dockutil,
                openssl,
                rsync,
              }:
              with lispPackagesLite;
              lispScript rec {
                name = "mac-app-util";
                src = ./main.lisp;
                dependencies = [
                  alexandria
                  inferior-shell
                  str
                  trivia
                ];
                nativeBuildInputs = [ pkgs.makeBinaryWrapper ];
                postInstall = ''
                  wrapProgramBinary "$out/bin/${name}" \
                    --suffix PATH : "${
                      with pkgs;
                      lib.makeBinPath [
                        dockutil
                        openssl
                        rsync
                      ]
                    }"
                '';
                installCheckPhase = ''
                  $out/bin/${name} --help
                '';
                doInstallCheck = true;
                meta.license = pkgs.lib.licenses.agpl3Only;
              }
            ) { };
            # For testing; see tests/e2e-fda.sh.  v2 simulates an update of v1.
            test-app = pkgs.callPackage ./test-app.nix { version = "1"; };
            test-app-v2 = pkgs.callPackage ./test-app.nix { version = "2"; };
          };
          formatter = treefmtPkg.config.build.wrapper;
        }
      )
    );
}
