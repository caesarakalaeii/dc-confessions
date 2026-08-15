{
  # Keep this line accurate and one line long: `nix flake metadata` prints it,
  # and it is the first thing a cold agent learns about the repo.
  description = "dc-confessions -- Discord bot that relays DMs anonymously into a channel. Run `nix flake show` for the command map.";

  # nixpkgs is the only input, on purpose.
  #
  # flake-utils would buy exactly one thing here -- eachDefaultSystem -- which is
  # the three-line genAttrs below. In exchange it costs a second lock node in
  # every repo (flake-utils transitively pulls `systems`, so really two), a
  # second upstream that can break one repo and not the others, and a hardcoded
  # system list this repo cannot edit. That list is currently broken: it still
  # contains x86_64-darwin, which now throws (see `systems` below).
  #
  # nixos-unstable is the same channel the author's own NixOS config tracks, so
  # `nix develop` here and `nixos-rebuild` there resolve the same store paths and
  # share one cache.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    # `self` is named because the anchor below needs it: it is this flake's own
    # source in the store, which is the only path a wrapper can be sure points at
    # THIS repo no matter where it was invoked from. `...` rather than a closed
    # { self, nixpkgs }: adding a second input later would otherwise fail with
    # "called with unexpected argument '<name>'".
    { self, nixpkgs, ... }:
    let
      lib = nixpkgs.lib;

      # x86_64-darwin is deliberately absent. nixpkgs 26.11 replaced that whole
      # attribute set with `throw "Nixpkgs 26.11 has dropped support for
      # x86_64-darwin"`. genAttrs is lazy, so plain `nix develop` on Linux would
      # not notice -- it detonates later, on `nix flake check --all-systems`.
      # Add it back only against a separate nixpkgs-26.05-darwin input.
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];

      # Stand-in for flake-utils.lib.eachDefaultSystem. Passes `pkgs` rather than
      # a system string, because that is what every call site below wants.
      forAllSystems = f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      # ======================================================================
      # PER-REPO BLOCK 1 -- the toolchain
      # ======================================================================
      # Everything the commands below need. `nix flake check` realises this
      # closure, so a typo'd attr name fails at the flake gate instead of
      # surfacing as "command not found" halfway through a task.
      #
      # Explicit `pkgs.foo`, never `with pkgs; [ ... ]`: when an attr disappears
      # in a nixpkgs bump, `with` reports a bare undefined identifier with no
      # hint of which set it came from, and the name is not greppable.
      #
      # Pin language runtimes by MAJOR (python313), never by rolling alias
      # (python3): an alias that moves under you invalidates every .venv in the
      # fleet on the same afternoon. python313 also matters here specifically --
      # the default python3 is already 3.14 territory and discord.py's wheels
      # lag it.
      toolchain = pkgs: [
        # ---- this repo's ecosystem ----
        # This repo has NO manifest -- no requirements.txt, no pyproject.toml, no
        # CI -- so the dependency set was read off the imports: bot.py imports
        # `discord` plus stdlib (asyncio), logger.py is stdlib only (logging,
        # time, os), and `config` is a local, deliberately gitignored module (see
        # the `run` command below).
        #
        # discord.py is the single third-party import and nixpkgs packages it, so
        # it is baked into the interpreter instead of being installed at runtime.
        # That is why there is no `setup` verb: this shell needs no network at
        # all. If a future dependency has no nixpkgs attr, add it here rather
        # than reaching for a pip install in the hook -- and only fall back to
        # `uv venv` + a requirements.txt if it genuinely is not packaged.
        (pkgs.python313.withPackages (ps: [ ps.discordpy ]))

        # uv is here for the case above -- an agent that needs a dependency
        # nixpkgs does not carry -- not because anything in this repo needs it.
        # Do not add `pkgs.python313` beside the withPackages env above: both
        # ship bin/python3.13 and mkShell resolves that collision silently.
        pkgs.uv
        pkgs.ruff

        # ---- present in every repo in the fleet ----
        pkgs.git
        pkgs.jq
        pkgs.gnumake
      ];

      # ======================================================================
      # PER-REPO BLOCK 2 -- libraries that get dlopened, not linked
      # ======================================================================
      # Nothing this flake installs needs these: discord.py and aiohttp come from
      # nixpkgs, already linked against the right store paths. They are here for
      # the `uv` escape hatch above -- a manylinux wheel carries .so files that
      # are dlopened at runtime, so neither patchelf nor the nix linker ever sees
      # them and NixOS has no /usr/lib for them to find. stdenv.cc.cc.lib
      # supplies libstdc++, which is the one that breaks `import numpy`. Keep
      # this list minimal; LD_LIBRARY_PATH is a blunt instrument.
      #
      # This fixes shared libraries only. A prebuilt *executable* out of a wheel
      # still needs a real ELF interpreter at the FHS path
      # `/lib64/ld-linux-x86-64.so.2`. That is a host setting -- stock NixOS
      # ships a stub there that exits 127 -- and no project flake can supply it.
      nativeLibs = pkgs: [
        pkgs.stdenv.cc.cc.lib
        pkgs.zlib
      ];

      # ======================================================================
      # PER-REPO BLOCK 3 -- constant environment variables
      # ======================================================================
      # Only values that are constants belong here. Anything that must READ an
      # existing value (LD_LIBRARY_PATH), UNSET something (SOURCE_DATE_EPOCH) or
      # touch the work tree goes in the shellHook further down.
      #
      # This attrset is applied to BOTH surfaces -- the dev shell and every
      # `nix run` wrapper -- so a command cannot behave differently depending on
      # how it was invoked.
      envVars = pkgs: {
        # Keep uv on the nix interpreter. Left alone it downloads its own
        # portable CPython, which then resolves a different set of wheels than
        # this shell pins: two Pythons, one venv, no way to tell which is live.
        # Note this is the BARE python313, not the withPackages env on PATH --
        # a `uv venv` does not inherit store site-packages either way, so
        # anything importable from a venv has to be installed into that venv.
        UV_PYTHON = "${pkgs.python313}/bin/python";
        UV_PYTHON_DOWNLOADS = "never";
        # /nix/store and the work tree are usually different filesystems, so
        # uv's default hardlink strategy warns on every single install.
        UV_LINK_MODE = "copy";
        PIP_DISABLE_PIP_VERSION_CHECK = "1";
        # The bot's Logger writes straight to stdout with print(). Block-buffered
        # output means an agent that starts the bot and then kills it on a
        # timeout sees nothing at all; unbuffered, it sees the login banner.
        PYTHONUNBUFFERED = "1";
      };

      # ======================================================================
      # PER-REPO BLOCK 4 -- the command map
      # ======================================================================
      # THE single source of truth. It generates `apps` (so `nix run .#lint`
      # works), the `dev-*` wrappers on PATH inside the shell, and `dev-help`.
      # Nothing is written twice, so `nix flake show` can never disagree with
      # what `dev-lint` actually runs.
      #
      # Only the verbs this repo actually has are listed. Absence is information:
      #   no `setup` -- the toolchain above is complete and offline
      #   no `build` -- two .py files run in place, there is no artifact
      #   no `test`  -- there is no test suite, and a stub that echoed
      #                 "not applicable" would turn this map into a liar
      #
      # `text` is bash under `set -euo pipefail`, shellcheck'd at BUILD time. It
      # runs in the caller's current directory but must never ACT on it: every
      # verb below addresses $REPO_ROOT (see the anchor in the generic machinery)
      # so that `nix run /path/to/repo#<verb>` -- the form CI and a cold agent
      # use, from whatever cwd they happen to have -- reads and writes exactly
      # the same files as `dev-<verb>` from inside the tree, and nothing else.
      # Explicit arguments still win, so an agent can narrow a verb to one file.
      #
      # $REPO_ROOT is only ever THIS repo. It used to be "the enclosing git
      # toplevel, if it holds bot.py and logger.py" -- which the sibling bot
      # repos this one is usually checked out beside (dc-bot,
      # dc-ranked_queue) satisfy exactly, both carrying those two names in
      # their roots. So `nix run /path/to/dc-confessions#lint` from inside
      # dc-bot reported dc-bot's 61 findings as this repo's, and `#fmt` would
      # have rewritten dc-bot's sources. The anchor now demands a
      # byte-identical flake.nix instead of a filename a neighbour can also
      # own. Do not reintroduce a marker list: this repo's entire Python
      # surface is two files whose names half the fleet shares.
      commands = pkgs: {
        run = {
          # (network) twice over: the bot dials the Discord gateway and keeps the
          # connection open, so this verb never returns on its own -- an agent
          # must run it with a timeout and read the log, not wait for exit 0.
          description = "(network) start the confession bot -- needs a local config.py";
          text = ''
            # This verb reads a gitignored file and writes a log, so the store
            # fallback is useless to it: refuse rather than tell the caller to
            # create config.py inside /nix/store.
            need_writable_checkout

            # bot.py does `from config import *` for BOT_TOKEN and CHANNEL_ID,
            # and .gitignore excludes *config*, so a fresh clone has no config.py
            # and the bot dies with a bare ModuleNotFoundError. Fail early with
            # something an agent can act on instead. Never write the file from
            # here: it holds a live bot token.
            if [ ! -f "$REPO_ROOT/config.py" ]; then
              echo "missing $REPO_ROOT/config.py -- create it (it is gitignored) with:" >&2
              echo "  BOT_TOKEN = \"<discord bot token>\"" >&2
              echo "  CHANNEL_ID = <target channel id as an int>" >&2
              exit 1
            fi
            # cd, and not merely `python3 "$REPO_ROOT/bot.py"`: logger.py builds
            # its log filename with no directory part, so the bot OPENS A FILE
            # FOR WRITING relative to cwd. Without the cd, launching this from
            # anywhere but the repo root drops a baselog_log_*.txt in the
            # caller's directory. In $REPO_ROOT it lands on a *baselog* line
            # already in .gitignore. The cd also puts the script's own directory
            # first on sys.path, which is what makes `config` and `logger`
            # importable.
            cd "$REPO_ROOT"
            # Bare `python3` is correct here -- the wrappers prepend this flake's
            # toolchain, so it is the interpreter that has discord.py baked in.
            # exec so the bot inherits this PID: an agent's `timeout`/SIGTERM
            # then reaches python itself instead of a shell that outlives it.
            exec python3 bot.py "$@"
          '';
        };
        lint = {
          # The repo ships no ruff config, so this runs ruff's own defaults --
          # and the code as committed does NOT pass them: 25 findings, all style
          # (import order, .format() over f-strings, one unused import). Exit 1
          # here is a real signal about the code, not a broken flake. Narrow it
          # by committing a ruff.toml or pyproject.toml [tool.ruff]; do not
          # paper over it with flags baked into this flake, where nothing
          # reading the repo would ever find them.
          description = "ruff check";
          # `"''${@:-$REPO_ROOT}"`, not a bare `"$@"`: with no arguments ruff
          # walks the cwd, so this verb used to inspect whatever tree the caller
          # was standing in -- and in an unrelated empty directory it printed
          # "All checks passed!" and exited 0 while the same command from inside
          # the repo exited 1 with 25 findings. A gate that passes by inspecting
          # zero files is worse than no gate. The default also fixes the smaller
          # version of the same bug inside the repo: run from a subdirectory,
          # lint now still covers the whole tree.
          #
          # `--no-cache` closes the last hole in the same defect: ruff puts
          # .ruff_cache next to the CWD, not next to the files it was handed, so
          # even after anchoring the paths, linting from an unrelated directory
          # littered a cache directory in it. Pointing --cache-dir at $REPO_ROOT
          # instead does not work in general -- on the store fallback below that
          # path is read-only and ruff exits 2 with "Failed to initialize cache"
          # rather than degrading -- and two source files have nothing worth
          # caching. This is not a rule flag; it does not change a single finding.
          text = ''ruff check --no-cache "''${@:-$REPO_ROOT}"'';
        };
        fmt = {
          description = "ruff format (rewrites files)";
          text = ''
            # ruff format MUTATES, so the unanchored version of this verb was the
            # serious half of that bug: `nix run /path/to/repo#fmt` from anywhere
            # rewrote the caller's source files. Guard, then default to the repo.
            # An explicit path is the caller's own decision and passes straight
            # through -- that is the one case where touching files outside
            # $REPO_ROOT is exactly what was asked for.
            if [ "$#" -eq 0 ]; then
              need_writable_checkout
            fi
            # --no-cache for the reason spelled out under lint: the cache lands
            # beside the cwd, not beside the target.
            ruff format --no-cache "''${@:-$REPO_ROOT}"
          '';
        };
      };

      # ======================================================================
      # GENERIC MACHINERY -- byte-identical in all 41 repos, do not edit
      # ======================================================================

      # Prepend, never assign: a host LD_LIBRARY_PATH may be carrying something
      # the user needs, and clobbering it breaks binaries they launch from here.
      # Linux only -- on darwin the loader variable is DYLD_*, and exporting a
      # Linux-shaped value there is at best useless.
      ldPreamble =
        pkgs:
        lib.optionalString (pkgs.stdenv.hostPlatform.isLinux && nativeLibs pkgs != [ ]) ''
          export LD_LIBRARY_PATH="${lib.makeLibraryPath (nativeLibs pkgs)}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
        '';

      # Every command gets $SRC_ROOT and $REPO_ROOT. `nix run` and `nix develop`
      # both start in whatever directory they were invoked from, and no verb may
      # act on that directory -- these two are what it acts on instead.
      #
      # $SRC_ROOT is this flake's own source, snapshotted into the store when
      # the flake was evaluated. It is the one anchor that is always available:
      # `nix run /path/to/repo#lint` tells the running program nothing whatever
      # about /path/to/repo (flake refs are location-independent by design, and
      # there is no $FLAKE_DIR to read), so without `self` a wrapper invoked
      # that way has literally no way to name the repo it belongs to. Its one
      # limitation is that it is read-only, being a store path.
      #
      # $REPO_ROOT is the writable checkout when the caller is standing in one,
      # and $SRC_ROOT when they are not. `git rev-parse --show-toplevel` alone
      # is NOT enough to find that checkout: run from inside some OTHER git
      # repo it cheerfully answers with THAT repo's top level, and a verb that
      # trusts the answer formats a stranger's source tree. So a candidate has
      # to prove it is a checkout of this flake, by carrying a byte-identical
      # flake.nix. Compared with bash's own $(<file) rather than cmp or
      # sha256sum, so the check depends on no package at all.
      #
      # Consequence worth knowing: edit flake.nix and the dev-* wrappers in an
      # already-open `nix develop` stop recognising the tree, because they were
      # built from the previous flake.nix. That is a stale shell telling you so
      # -- re-enter it. `nix run` re-evaluates every time and never sees this.
      rootPreamble = ''
        SRC_ROOT=${lib.escapeShellArg self}
        export SRC_ROOT
        REPO_ROOT="$SRC_ROOT"
        _toplevel="$(git rev-parse --show-toplevel 2>/dev/null || true)"
        if [ -n "$_toplevel" ] && [ -f "$_toplevel/flake.nix" ] &&
          [ "$(<"$_toplevel/flake.nix")" = "$(<"$SRC_ROOT/flake.nix")" ]; then
          REPO_ROOT="$_toplevel"
        fi
        unset _toplevel
        export REPO_ROOT
      '';

      # Wrappers only, not the shellHook -- an interactive shell has no business
      # carrying this function around. Any command text that writes files calls
      # it first, and it is the reason a mutating verb can fail loudly instead of
      # falling back to "well, the cwd then".
      guardPreamble = ''
        need_writable_checkout() {
          if [ "$REPO_ROOT" != "$SRC_ROOT" ]; then
            return 0
          fi
          echo "This command rewrites files, so it needs a writable checkout of" >&2
          echo "this repo -- and standing in $PWD there is none: no parent" >&2
          echo "directory is a checkout of this flake. The only tree in reach is" >&2
          echo "the read-only store snapshot $SRC_ROOT, and rewriting $PWD" >&2
          echo "instead is exactly the bug this guard exists to prevent." >&2
          echo "cd into the repo (or \`nix develop\` it), or pass an explicit path." >&2
          exit 1
        }
      '';

      # One derivation per command, reused by both `apps` and the dev shell, so
      # the two can never diverge. `dev-` prefixed because a bare `test` binary
      # earlier on PATH would shadow the POSIX shell builtin and quietly break
      # every script in the repo that uses it.
      wrappers =
        pkgs:
        lib.mapAttrs (
          name: cmd:
          pkgs.writeShellApplication {
            name = "dev-${name}";
            runtimeInputs = toolchain pkgs;
            runtimeEnv = envVars pkgs;
            meta.description = cmd.description;
            text = ''
              ${rootPreamble}
              ${guardPreamble}
              ${ldPreamble pkgs}
              ${cmd.text}
            '';
          }
        ) (commands pkgs);

      helpFor =
        pkgs:
        let
          cmds = commands pkgs;
          names = lib.attrNames cmds;
          width = lib.foldl' (a: n: lib.max a (builtins.stringLength n)) 0 names;
          pad = n: n + lib.concatStrings (lib.genList (_: " ") (width - builtins.stringLength n));
          line = n: c: "  dev-${pad n}  ${c.description}";
        in
        pkgs.writeShellApplication {
          name = "dev-help";
          meta.description = "print this repo's command map (works offline)";
          text = ''
            cat <<'EOF'
            ${lib.concatStringsSep "\n" (lib.mapAttrsToList line cmds)}
            EOF
          '';
        };
    in
    {
      # `nix flake show` -- the discovery entrypoint, and deliberately the whole
      # machine-facing contract: every app carries a meta.description, which
      # `nix flake show` prints inline and `nix flake show --json` exposes at
      # .apps.<system>.<name>.description. Pure evaluation, so an agent gets the
      # entire command map in one cheap call without reading a README.
      #
      # Do NOT invent a top-level output for this (`agentManifest`, `probeThing`
      # ...). Nix answers with `warning: unknown flake output '<name>'` on every
      # single `nix flake check`, forever.
      apps = forAllSystems (
        pkgs:
        lib.mapAttrs (name: cmd: {
          type = "app";
          program = "${(wrappers pkgs).${name}}/bin/dev-${name}";
          meta.description = cmd.description;
        }) (commands pkgs)
      );

      # `nix develop` -- the toolchain, plus a dev-<verb> for every app.
      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = toolchain pkgs ++ lib.attrValues (wrappers pkgs) ++ [ (helpFor pkgs) ];

          env = envVars pkgs;

          # Some C extensions and node-gyp addons compile at -O0, where glibc's
          # _FORTIFY_SOURCE becomes a hard error instead of a warning.
          hardeningDisable = [ "fortify" ];

          shellHook = ''
            # mkShell inherits SOURCE_DATE_EPOCH=315532800 (1980-01-01) from
            # stdenv, and any wheel or zip built in here then dies with "ZIP does
            # not support timestamps before 1980".
            unset SOURCE_DATE_EPOCH

            ${rootPreamble}
            ${ldPreamble pkgs}

            # Nothing networked, nothing stateful and nothing interactive above
            # this line, and nothing below it either. No venv creation, no
            # `pip install`, no `read`, no `exec $SHELL`. Bootstrapping in the
            # hook makes a cold `nix develop -c python3 bot.py` start downloading
            # before it runs anything, on EVERY invocation -- the exact failure an
            # unattended agent cannot diagnose.

            # The banner is interactive-only, and this guard is load-bearing:
            # shellHook output lands on the STDOUT of `nix develop -c <cmd>`, so
            # an unguarded echo corrupts anything parsing it
            # (`nix develop -c cat x.json | jq` fails to parse). $- is the only
            # reliable discriminator here -- it lacks `i` for `nix develop -c`
            # and has it at an interactive prompt. Do not test $PS1 (unset in
            # both) or $IN_NIX_SHELL (set in both). >&2 is the second layer, for
            # the case where a caller runs us on a pty.
            case $- in
              *i*) echo "dc-confessions dev shell -- 'dev-help' for the command map" >&2 ;;
            esac
          '';
        };
      });

      # `nix flake check` -- honest by construction. It realises the toolchain
      # closure (so a typo'd or currently-broken attr fails here) and builds
      # every wrapper, which runs shellcheck over every command text. Add real
      # test derivations beside it. NEVER add a check that always passes: an
      # agent reads "all checks passed!" as a signal, and a fake check makes
      # `nix flake check` a liar.
      checks = forAllSystems (pkgs: {
        toolchain =
          pkgs.runCommand "toolchain-check"
            {
              nativeBuildInputs = toolchain pkgs ++ lib.attrValues (wrappers pkgs);
            }
            ''
              for verb in ${lib.escapeShellArgs (lib.attrNames (commands pkgs))}; do
                command -v "dev-$verb" > /dev/null || {
                  echo "dev-$verb is not on PATH" >&2
                  exit 1
                }
              done
              touch "$out"
            '';
      });

      # `nix fmt` -- formats the *Nix* in this repo; project code is `dev-fmt`.
      # nixfmt-tree (the treefmt wrapper) rather than bare nixfmt, because bare
      # nixfmt tries to parse every path handed to it and fails on non-Nix files.
      # This file ships already formatted, so `nix fmt` is a no-op rather than a
      # diff.
      formatter = forAllSystems (pkgs: pkgs.nixfmt-tree);
    };
}
