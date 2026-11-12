{
  description = "noib3's Neovim configuration";

  inputs = {
    neovim-src = {
      url = "github:noib3/neovim/noib3";
      flake = false;
    };
    nix-community-neovim = {
      url = "github:nix-community/neovim-nightly-overlay";
      inputs.neovim-src.follows = "neovim-src";
    };
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Remove once nixpkgs has Zig 0.17.
    zig-overlay = {
      url = "github:mitchellh/zig-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Plugins.
    blink-cmp = {
      url = "github:Saghen/blink.cmp";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    blink-emoji-nvim = {
      url = "github:moyiz/blink-emoji.nvim";
      flake = false;
    };
    bufdelete-nvim = {
      url = "github:famiu/bufdelete.nvim";
      flake = false;
    };
    colorful-menu-nvim = {
      url = "github:noib3/colorful-menu.nvim/noib3";
      flake = false;
    };
    comment-nvim = {
      url = "github:numToStr/Comment.nvim";
      flake = false;
    };
    conform-nvim = {
      url = "github:stevearc/conform.nvim";
      flake = false;
    };
    # Only used for its C library, libvscode-diff.
    codediff-nvim = {
      url = "github:esmuellert/codediff.nvim";
      flake = false;
    };
    crates-nvim = {
      url = "github:saecki/crates.nvim";
      flake = false;
    };
    fzf-lua = {
      url = "github:ibhagwan/fzf-lua";
      flake = false;
    };
    gruvbox-nvim = {
      url = "github:ellisonleao/gruvbox.nvim";
      flake = false;
    };
    hop-nvim = {
      url = "github:smoka7/hop.nvim";
      flake = false;
    };
    incline-nvim = {
      url = "github:b0o/incline.nvim/pull/96/head";
      flake = false;
    };
    lsp-progress-nvim = {
      url = "github:linrongbin16/lsp-progress.nvim";
      flake = false;
    };
    lualine-nvim = {
      url = "github:nvim-lualine/lualine.nvim";
      flake = false;
    };
    neotab-nvim = {
      url = "github:kawre/neotab.nvim";
      flake = false;
    };
    neotest = {
      url = "github:nvim-neotest/neotest";
      flake = false;
    };
    nvim-autopairs = {
      url = "github:windwp/nvim-autopairs";
      flake = false;
    };
    nvim-colorizer-lua = {
      url = "github:NiklasV1/nvim-colorizer.lua";
      flake = false;
    };
    nvim-lastplace = {
      url = "github:ethanholz/nvim-lastplace";
      flake = false;
    };
    nvim-lint = {
      url = "github:mfussenegger/nvim-lint";
      flake = false;
    };
    nvim-lspconfig = {
      url = "github:neovim/nvim-lspconfig";
      flake = false;
    };
    nvim-nio = {
      url = "github:nvim-neotest/nvim-nio";
      flake = false;
    };
    nvim-notify = {
      url = "github:rcarriga/nvim-notify";
      flake = false;
    };
    nvim-surround = {
      url = "github:kylechui/nvim-surround";
      flake = false;
    };
    nvim-treesitter = {
      url = "github:nvim-treesitter/nvim-treesitter/main";
      flake = false;
    };
    nvim-treesitter-endwise = {
      url = "github:RRethy/nvim-treesitter-endwise";
      flake = false;
    };
    nvim-web-devicons = {
      url = "github:nvim-tree/nvim-web-devicons";
      flake = false;
    };
    plenary-nvim = {
      url = "github:nvim-lua/plenary.nvim";
      flake = false;
    };
    rustaceanvim = {
      url = "github:mrcjkb/rustaceanvim";
      flake = false;
    };
    tokyonight-nvim = {
      url = "github:folke/tokyonight.nvim";
      flake = false;
    };
    treesitter-modules-nvim = {
      url = "github:MeanderingProgrammer/treesitter-modules.nvim";
      flake = false;
    };
    trouble-nvim = {
      url = "github:folke/trouble.nvim";
      flake = false;
    };
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      treefmt-nix,
      ...
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];

      mkPkgs =
        {
          system,
        }:
        nixpkgs.legacyPackages.${system};

      eachSystem =
        fun:
        nixpkgs.lib.genAttrs systems (
          system:
          fun (mkPkgs {
            inherit system;
          })
        );

      mkTreefmt =
        pkgs:
        treefmt-nix.lib.evalModule pkgs {
          projectRootFile = "flake.nix";
          programs.nixfmt = {
            enable = true;
            width = 80;
          };
          programs.shfmt = {
            enable = true;
            useEditorConfig = true;
          };
          programs.stylua = {
            enable = true;
            settings = builtins.fromTOML (builtins.readFile ./stylua.toml);
          };
        };
    in
    {
      homeManagerModules.default = import ./nix/module.nix { inherit inputs mkPkgs; };

      packages = eachSystem (pkgs: {
        default = pkgs.callPackage ./nix/package.nix { inherit inputs; };
      });

      checks = eachSystem (
        pkgs:
        let
          nvim = self.packages.${pkgs.stdenv.system}.default;
          emmylua_check = pkgs.lib.getExe' pkgs.emmylua-check "emmylua_check";

          # `plugins/.emmyrc.json`, with the third-party plugins' Lua as the
          # library instead of `$NVIM_PLUGINS_LUA`, which also has copies of
          # this repo's plugins.
          pluginsConfig =
            let
              config = builtins.fromJSON (builtins.readFile ./plugins/.emmyrc.json);
              library = map (
                entry:
                if entry.path or null == "$NVIM_PLUGINS_LUA" then
                  entry // { path = "${nvim.thirdPartyLua}"; }
                else
                  entry
              ) config.workspace.library;
              plugins = builtins.attrNames (
                pkgs.lib.filterAttrs (_: type: type == "directory") (builtins.readDir ./plugins)
              );
              missing = builtins.filter (
                name: !builtins.elem "./${name}/lua" config.workspace.workspaceRoots
              ) plugins;
            in
            assert pkgs.lib.assertMsg (
              missing == [ ]
            ) "plugins/.emmyrc.json's workspaceRoots are missing ${toString missing}";
            pkgs.writeText "emmyrc.json" (
              builtins.toJSON (
                pkgs.lib.recursiveUpdate config { workspace.library = library; }
              )
            );
        in
        {
          config =
            pkgs.runCommand "check-config"
              {
                env.NVIM_PLUGINS_LUA = nvim.env.NVIM_PLUGINS_LUA;
                env.VIMRUNTIME = "${nvim.unwrapped}/share/nvim/runtime";
              }
              ''
                ${emmylua_check} --warnings-as-errors ${nvim.config} 2>&1 | tee "$out"
                ${emmylua_check} --warnings-as-errors --config ${pluginsConfig} ${./plugins} \
                  2>&1 | tee -a "$out"
              '';

          formatting = (mkTreefmt pkgs).config.build.check self;

          nix-lints =
            pkgs.runCommand "check-nix-lints"
              {
                nativeBuildInputs = [
                  pkgs.findutils
                  pkgs.jq
                  pkgs.nixf
                ];
              }
              ''
                repo=${self}
                suppressed='["sema-primop-removed-prefix"]'
                failed=0
                total_files=0
                total_diagnostics=0

                while IFS= read -r file; do
                  total_files=$((total_files + 1))
                  raw_diagnostics="$(nixf-tidy --variable-lookup < "$file")"
                  diagnostics="$(printf '%s\n' "$raw_diagnostics" | jq --argjson suppressed "$suppressed" '
                    [ .[] | select((.sname as $s | ($suppressed | index($s))) | not) ]
                  ')"
                  if [ "$diagnostics" != "[]" ]; then
                    rel_path="''${file#$repo/}"
                    diag_count="$(printf '%s\n' "$diagnostics" | jq 'length')"
                    total_diagnostics=$((total_diagnostics + diag_count))

                    printf "\n%s (%s diagnostics)\n" "$rel_path" "$diag_count"
                    printf '%s\n' "$diagnostics" | jq -r '
                      .[]
                      | "  - [\(.sname)] \(.range.lCur.line):\(.range.lCur.column) \(.message)",
                        (if (.fixes | length) > 0
                         then (.fixes[] | "      fix: \(.message)")
                         else "      fix: (no automatic fix available)"
                         end)
                    '
                    failed=1
                  fi
                done < <(find "$repo" -type f -name "*.nix" | sort)

                if [ "$failed" -ne 0 ]; then
                  printf "\nFound %s diagnostics in %s Nix files.\n" "$total_diagnostics" "$total_files"
                  exit 1
                fi

                printf "Checked %s Nix files, no diagnostics.\n" "$total_files"
                touch "$out"
              '';

          shell-lints =
            pkgs.runCommand "check-shell-lints"
              {
                nativeBuildInputs = [
                  pkgs.findutils
                  pkgs.shellcheck
                ];
              }
              ''
                repo=${self}
                failed=0
                total_files=0

                while IFS= read -r file; do
                  total_files=$((total_files + 1))
                  if ! shellcheck "$file"; then
                    failed=1
                  fi
                done < <(find "$repo" -type f -name "*.sh" | sort)

                if [ "$failed" -ne 0 ]; then
                  exit 1
                fi

                printf "Checked %s shell files, no diagnostics.\n" "$total_files"
                touch "$out"
              '';
        }
      );

      # Workaround for https://github.com/NixOS/nix/issues/8881 so that we
      # can run individual checks with `nix run .#check-<foo>`.
      apps = eachSystem (
        pkgs:
        pkgs.lib.mapAttrs' (name: check: {
          name = "check-${name}";
          value = {
            type = "app";
            program =
              (pkgs.writeShellScript "check-${name}" ''
                # Force evaluation of ${check}.
                echo -e "\033[1;32m✓\033[0m Check '${name}' passed"
              '').outPath;
          };
        }) self.checks.${pkgs.stdenv.system}
      );

      tests = eachSystem (
        pkgs:
        let
          nvim = self.packages.${pkgs.stdenv.system}.default;
          localPlugins = builtins.attrNames (builtins.readDir ./plugins);

          # The `lua` directories of the other plugins, which the tests can
          # require, as a single runtimepath entry.
          thirdPartyRtp = pkgs.linkFarm "nvim-third-party-rtp" [
            {
              name = "lua";
              path = nvim.thirdPartyLua;
            }
          ];

          rtp = pkgs.lib.concatStringsSep "," (
            map (name: "${./plugins}/${name}") localPlugins ++ [ "${thirdPartyRtp}" ]
          );
        in
        {
          # Runs the `tests/*.lua` files of the plugins in this repo, each
          # in its own headless Neovim and all at once, then prints their
          # results in order and exits with an error if any of them failed.
          plugins = pkgs.writeShellApplication {
            name = "test-neovim-plugins";
            runtimeInputs = [
              pkgs.git
              pkgs.jujutsu
            ];
            text = ''
              # The tests' repos and jj's config are kept out of the user's.
              tmp=$(mktemp -d)
              trap 'rm -rf "$tmp"' EXIT
              export HOME="$tmp" TMPDIR="$tmp"
              export JJ_USER=test JJ_EMAIL=test@example.com
              export LIBVSCODE_DIFF=${nvim.env.LIBVSCODE_DIFF}

              tests=(${./plugins}/*/tests/*.lua)
              pids=()
              for i in "''${!tests[@]}"; do
                # Each file gets its own temporary directory.
                mkdir "$tmp/$i"
                TEST_FILE="''${tests[$i]}" HOME="$tmp/$i" TMPDIR="$tmp/$i" \
                  ${nvim.unwrapped}/bin/nvim --headless --clean -n -i NONE \
                  --cmd "set rtp^=${rtp}" \
                  -c "luafile ${./tests/run.lua}" >"$tmp/$i.out" 2>&1 &
                pids+=("$!")
              done

              failed=0
              for i in "''${!tests[@]}"; do
                status=0
                wait "''${pids[$i]}" || status=$?
                echo "--- ''${tests[$i]#${./plugins}/}"
                cat "$tmp/$i.out"
                if [ "$status" -ne 0 ]; then failed=1; fi
              done
              exit "$failed"
            '';
          };
        }
      );

      formatter = eachSystem (pkgs: (mkTreefmt pkgs).config.build.wrapper);
    };

  nixConfig = {
    extra-substituters = [
      "https://cache.sub60.dev/noib3/nvim-config"
    ];
    extra-trusted-public-keys = [
      "cache.sub60.dev/noib3/nvim-config-1:Kg7WpOPB6yjSOK8G9qnjnsni45H07Z7eOYmrJozA9B8="
    ];
  };
}
