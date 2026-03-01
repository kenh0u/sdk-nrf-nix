{
  description = "nRF Connect SDK Nix Flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixpkgs-2511.url = "github:NixOS/nixpkgs/nixos-25.11";
    zephyr-sdk-nix.url = "github:kenh0u/zephyr-sdk-nix";
  };

  outputs = { self, nixpkgs, nixpkgs-2511, zephyr-sdk-nix }: let
    systems = [ "x86_64-linux" ];
    forAllSystems = nixpkgs.lib.genAttrs systems;
  in {
    lib = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
      pkgs-2511 = nixpkgs-2511.legacyPackages.${system};
      zsdkLib = zephyr-sdk-nix.lib.${system};
    in {
      buildNrfApplication = {
        pname,
        version ? "0",
        src,
        board,
        ncsVersion ? "3.1.1",
        sysbuild ? false,
        zephyrTargets ? [ "arm-zephyr-eabi" ],

        zephyrSdk ? zsdkLib.mkZephyrSdk { targets = zephyrTargets; },
        westBuildFlags ? []
      }: let

        zephyrPython = pkgs-2511.python313.withPackages (ps: with ps; [
          aenum
          anytree
          appdirs
          bitarray
          boolean-py
          canopen
          capstone
          cbor
          cbor2
          click
          colorama
          coloredlogs
          cryptography
          dill
          gitpython
          graphviz
          intelhex
          intervaltree
          jinja2
          jsonschema
          lark
          lxml
          markupsafe
          mypy
          natsort
          packaging
          pathspec
          patool
          pefile
          pillow
          ply
          prettytable
          progress
          protobuf
          psutil
          pycparser
          pycryptodome
          pyelftools
          pygithub
          pyjwt
          pykwalify
          pylink-square
          pynacl
          pyocd
          pyparsing
          pyserial
          python-can
          python-dateutil
          python-magic
          pyusb
          pyyaml
          qrcode
          regex
          requests
          ruamel-yaml
          semver
          setuptools
          six
          smmap
          tabulate
          toml
          tomlkit
          tqdm
          typing-extensions
          urllib3
          west
          xmltodict
          zcbor
          zipp
        ]);

        ncsSource = pkgs.stdenv.mkDerivation {
          pname = "ncs-source-tree";
          version = "3.1.1";

          nativeBuildInputs = [ pkgs.git pkgs.cacert pkgs-2511.python313Packages.west ];
          outputHashMode = "recursive";
          outputHashAlgo = "sha256";
          outputHash = "sha256-HcxZb0KBLs9YkciLdNAOGQxOFB2SeOoV5ick9X+o9G4=";

          GIT_SSL_CAINFO = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
          SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";

          buildCommand = ''
            export HOME=$(mktemp -d)
            mkdir -p $out
            cd $out

            echo "1/4 Fetching NCS manifest and modules..."
            west init -q -m https://github.com/nrfconnect/sdk-nrf --mr v3.1.1 .
            west update -q

            echo "2/4 Mapping projects and destroying non-deterministic histories..."
            PROJECTS=$(west list -f "{abspath}")
            find . -type d -name ".git" -prune -exec rm -rf {} +
            find . -type d -name "__pycache__" -prune -exec rm -rf {} +

            echo "3/4 Rebuilding dummy deterministic Git repositories for west..."
            export GIT_AUTHOR_DATE="2026-01-01T00:00:00Z"
            export GIT_COMMITTER_DATE="2026-01-01T00:00:00Z"
            export GIT_AUTHOR_NAME="Nix"
            export GIT_AUTHOR_EMAIL="nix@localhost"
            export GIT_COMMITTER_NAME="Nix"
            export GIT_COMMITTER_EMAIL="nix@localhost"

            for proj in $PROJECTS; do
                pushd "$proj" > /dev/null
                git init -q --initial-branch=manifest-rev
                git config core.autocrlf false
                rm -rf .git/hooks .git/info/exclude
                git add .
                git commit -q -m "Nix deterministic commit"
                popd > /dev/null
            done

            echo "4/4 Final security sweep for Nix store leaks..."
            grep -rl "/nix/store/" . | while read -r file; do
                if [[ -f "$file" && ! "$file" == *".git/"* ]]; then
                    sed -i 's|/nix/store/[a-zA-Z0-9]*-|/usr/local/|g' "$file"
                fi
            done || true
          '';
        };

        gitSafeConfig = pkgs.writeText "git-safe-config" ''
          [safe]
          directory = *
        '';

      in pkgs.stdenv.mkDerivation {
        inherit pname version src;

        ZEPHYR_BASE = "${ncsSource}/zephyr";
        ZEPHYR_SDK_INSTALL_DIR = "${zephyrSdk}";
        ZEPHYR_TOOLCHAIN_VARIANT = "zephyr";

        GIT_CONFIG_SYSTEM = "${gitSafeConfig}";

        PYTHONPATH = "${zephyrPython}/${pkgs-2511.python313.sitePackages}";

        nativeBuildInputs = [
          pkgs.git pkgs.cmake pkgs.ninja zephyrPython zephyrSdk
        ];

        shellHook = ''
          export WEST_CONFIG_LOCAL=$(mktemp)
          cp "${ncsSource}/.west/config" "$WEST_CONFIG_LOCAL"
          chmod +w "$WEST_CONFIG_LOCAL"

          export PATH="${zephyrSdk}/arm-zephyr-eabi/bin:$PATH"

          echo "🚀 nRF Connect SDK Environment Loaded (Board: ${board})"
        '';

        configurePhase = ''
          export WEST_CONFIG_LOCAL=$(mktemp)
          cp "${ncsSource}/.west/config" "$WEST_CONFIG_LOCAL"
          chmod +w "$WEST_CONFIG_LOCAL"
        '';

        buildPhase = ''
          west build -p always -b ${board} ${pkgs.lib.optionalString sysbuild "--sysbuild"} ${pkgs.lib.concatStringsSep " " westBuildFlags}
        '';

        installPhase = ''
          mkdir -p $out/bin
          cp build/merged.hex $out/bin/${pname}-merged.hex 2>/dev/null || true
          cp build/zephyr/zephyr.hex $out/bin/${pname}.hex 2>/dev/null || true
          cp build/zephyr/zephyr.elf $out/bin/${pname}.elf 2>/dev/null || true
        '';
      };
    });

    packages = forAllSystems (system: {
      default = self.lib.${system}.buildNrfApplication {
        pname = "test-nrf-app";
        src = ./.;
        board = "nrf54l15dk/nrf54l15/cpuapp";
      };
    });
  };
}
