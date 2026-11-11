{
  lib,
  linkFarm,
  runCommandLocal,
  stdenvNoCC,
  writeText,
  pkgs,
  vimPlugins,
  # --
  inputs,
}:

let
  treeSitterParsers = with vimPlugins.nvim-treesitter-parsers; [
    c
    cpp
    css
    html
    javascript
    jsdoc
    lua
    markdown
    markdown_inline
    nix
    rust
    scss
    sql
    svelte
    toml
    typescript
    vimdoc
  ];

  treeSitterQueries = with vimPlugins.nvim-treesitter.queries; [
    c
    cpp
    css
    ecma
    html
    html_tags
    javascript
    jsdoc
    jsx
    lua
    markdown
    markdown_inline
    nix
    rust
    scss
    sql
    svelte
    toml
    typescript
    vimdoc
  ];

  # VSCode's diff algorithm as a C library.
  libvscode-diff = pkgs.stdenv.mkDerivation {
    pname = "libvscode-diff";
    version = lib.trim (builtins.readFile "${inputs.codediff-nvim}/VERSION");
    src = inputs.codediff-nvim;

    nativeBuildInputs = [ pkgs.cmake ];
    buildInputs = [ pkgs.utf8proc ];

    cmakeDir = "../libvscode-diff";
    cmakeFlags = [ "-DENABLE_OPENMP=OFF" ];

    installPhase = ''
      runHook preInstall
      install -Dm644 -t "$out/lib" libvscode_diff${stdenvNoCC.hostPlatform.extensions.sharedLibrary}
      runHook postInstall
    '';
  };

  # The configuration's files.
  config = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../.emmyrc.json
      ../after
      ../filetype.lua
      ../init.lua
      ../lsp
      ../lua
    ];
  };

  localPlugins = lib.mapAttrsToList (name: _: ../plugins + "/${name}") (
    builtins.readDir ../plugins
  );

  # Each of these is a valid Neovim rtp entry.
  plugins = [
    inputs.blink-cmp.packages.${stdenvNoCC.system}.default
    inputs.blink-cmp.inputs.blink-lib.packages.${stdenvNoCC.system}.default
    inputs.blink-emoji-nvim
    inputs.bufdelete-nvim
    inputs.colorful-menu-nvim
    inputs.comment-nvim
    inputs.conform-nvim
    inputs.crates-nvim
    inputs.fzf-lua
    inputs.gruvbox-nvim
    inputs.hop-nvim
    inputs.inc-rename-nvim
    inputs.incline-nvim
    inputs.lsp-progress-nvim
    inputs.lualine-nvim
    inputs.neotab-nvim
    inputs.neotest
    inputs.nvim-autopairs
    inputs.nvim-colorizer-lua
    inputs.nvim-lastplace
    inputs.nvim-lint
    inputs.nvim-lspconfig
    inputs.nvim-nio
    inputs.nvim-notify
    inputs.nvim-surround
    inputs.nvim-treesitter
    inputs.nvim-treesitter-endwise
    inputs.nvim-web-devicons
    inputs.plenary-nvim
    inputs.rustaceanvim
    inputs.toggleterm-nvim
    inputs.tokyonight-nvim
    inputs.treesitter-modules-nvim
    inputs.trouble-nvim
  ]
  ++ treeSitterParsers
  ++ treeSitterQueries;

  # Returns a directory with the given plugins as start packages.
  mkPackDir =
    packName: plugins:
    linkFarm packName (
      builtins.map (
        plugin:
        let
          name = builtins.baseNameOf (builtins.unsafeDiscardStringContext plugin);
        in
        {
          name = "pack/noib3/start/${name}";
          path = plugin;
        }
      ) plugins
    );

  # An init file that replaces the user's configuration directory in the runtime
  # path with this repo's, adds the plugins to the package path, then sources
  # the configuration's `init.lua`. With `$NVIM_CONFIG_DEV` set to a checkout of
  # this repo, the configuration and the local plugins are the checkout's
  # instead of the store's.
  init = writeText "init.lua" ''
    local user = vim.fn.stdpath("config")
    vim.opt.runtimepath:remove({ user, user .. "/after" })
    vim.opt.packpath:prepend("${mkPackDir "nvim-pack" plugins}")

    local config = "${config}"
    local dev = vim.env.NVIM_CONFIG_DEV
    if dev and dev ~= "" then
      config = vim.fs.abspath(dev)
      for name, type in vim.fs.dir(config .. "/plugins") do
        if type == "directory" then
          vim.opt.runtimepath:prepend(config .. "/plugins/" .. name)
        end
      end
    else
      vim.opt.packpath:prepend("${mkPackDir "nvim-local-pack" localPlugins}")
    end

    vim.opt.runtimepath:prepend(config)
    vim.opt.runtimepath:append(config .. "/after")
    dofile(config .. "/init.lua")
  '';

  # Merges the plugins' `lua` directories into a single tree, used by EmmyLua
  # to resolve plugin type definitions. EmmyLua names modules by their path
  # relative to a library root, so the root has to be where `require()` starts
  # looking. Interpolating the plugins' paths copies the ones in this repo to
  # the store.
  mergeLua =
    name: plugins:
    runCommandLocal name { } ''
      mkdir -p "$out"
      for plugin in ${lib.escapeShellArgs (map (plugin: "${plugin}") plugins)}; do
        if [ -d "$plugin/lua" ]; then
          cp -rs --no-preserve=mode "$plugin/lua/." "$out/"
        fi
      done
    '';

  env = {
    LIBVSCODE_DIFF = "${libvscode-diff}/lib/libvscode_diff${stdenvNoCC.hostPlatform.extensions.sharedLibrary}";
    NVIM_PLUGINS_LUA = mergeLua "nvim-plugins-lua" (plugins ++ localPlugins);
  };

  unwrapped = import ./neovim-unwrapped.nix {
    inherit inputs lib pkgs;
  };
in
pkgs.symlinkJoin {
  name = "nvim";
  paths = [ unwrapped ];
  nativeBuildInputs = [ pkgs.makeWrapper ];

  postBuild =
    let
      envWrapperArgs = lib.escapeShellArgs (
        lib.concatLists (
          lib.mapAttrsToList (name: value: [
            "--set"
            name
            value
          ]) env
        )
      );
    in
    ''
      wrapProgram "$out/bin/nvim" ${envWrapperArgs} \
        --add-flags ${lib.escapeShellArg "-u ${init}"}
    '';

  passthru = {
    inherit config env unwrapped;
    # The `lua` directories of the plugins that aren't in this repo, merged
    # into a single tree.
    thirdPartyLua = mergeLua "nvim-third-party-lua" plugins;
  };

  meta.mainProgram = "nvim";
}
