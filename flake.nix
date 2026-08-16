{
  # Keep this line accurate and one line long: `nix flake metadata` prints it,
  # and it is the first thing a cold agent learns about the repo.
  description = "dc-confessions -- Discord bot that relays DMs anonymously into a channel. Run `nix flake show` for the command map.";

  # nixpkgs is the only input, on purpose.
  #
  # flake-utils would buy exactly one thing here -- eachDefaultSystem -- and the
  # canonical machinery below already provides it as `forAllSystems`. In
  # exchange it costs lock nodes (measured: flake-utils declares exactly one
  # input of its own, `systems`, so two nodes rather than one), a second
  # upstream that can break one repo and not the others, and a hardcoded system
  # list this repo cannot edit. Measured, that list --
  # `flake-utils.lib.defaultSystems` -- is
  # [ "aarch64-darwin" "aarch64-linux" "x86_64-darwin" "x86_64-linux" ], and at
  # the revision locked below, touching anything under
  # `legacyPackages.x86_64-darwin` throws
  # `Nixpkgs 26.11 has dropped support for x86_64-darwin.`
  #
  # The channel is nixos-unstable; the exact revision is pinned in flake.lock
  # and is the only thing that decides which store paths this shell resolves.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    # `self` is named because the anchor in the canonical block needs it: it is
    # this flake's own source in the store, the only path a wrapper can be sure
    # points at THIS repo no matter where it was invoked from. `...` rather than
    # a closed { self, nixpkgs }: measured, adding a second input to a closed
    # argument set fails with
    # `function 'outputs' called with unexpected argument '<name>'`.
    { self, nixpkgs, ... }:
    let
      lib = nixpkgs.lib;

      # Cosmetic: the canonical block prints this in the interactive dev-shell
      # banner and nowhere else. It is the clone directory name.
      repoName = "dc-confessions";

      # ======================================================================
      # PER-REPO BLOCK 1 -- the toolchain
      # ======================================================================
      # Everything the commands below need on PATH. `nix flake check` realises
      # this closure, so a typo'd attr name fails at the flake gate instead of
      # surfacing as "command not found" halfway through a task.
      #
      # Explicit `pkgs.foo`, never `with pkgs; [ ... ]`. Measured difference: a
      # missing attr under `with` reports `undefined variable 'noSuchAttr'`,
      # naming no attrset at all, while `pkgs.noSuchAttr` reports
      # `attribute 'noSuchAttr' missing`.
      #
      # Pin language runtimes by MAJOR (python313), never by the rolling alias
      # (python3), so that a lockfile bump cannot change the interpreter major
      # without anyone editing this list. They are already different: measured
      # at the locked revision, `python3` is 3.14.7 and `python313` is 3.13.15.
      # The pin is about not moving, not about a missing package -- nixpkgs
      # carries discord.py 2.6.4 for 3.14 as well.
      toolchain = pkgs: [
        # ---- this repo's ecosystem ----
        # This repo has no dependency manifest. `git ls-files` lists exactly
        # .gitignore, README.md, bot.py, flake.lock, flake.nix and logger.py:
        # no requirements.txt, no pyproject.toml, no CI workflow. The dependency
        # set was therefore read off the imports -- bot.py imports `discord`,
        # `logger`, `asyncio` and `from config import *`; logger.py imports
        # `logging`, `time` and `os` and nothing else. `config` is a local
        # module, excluded by the `*config*` line in .gitignore.
        #
        # discord.py is the only third-party import and nixpkgs packages it
        # (measured at the locked revision: python313Packages.discordpy is
        # python3.13-discord.py-2.6.4), so it is baked into the interpreter
        # rather than installed at runtime. Measured in this shell,
        # `python3 -c "import discord"` succeeds with nothing installed first.
        # That is why there is no `setup` verb -- there is no bootstrap step to
        # run. If a future dependency has no nixpkgs attr, add it here before
        # reaching for a pip install in the shell hook.
        (pkgs.python313.withPackages (ps: [ ps.discordpy ]))

        # uv is the escape hatch for that case; nothing in this repo needs it
        # today. Do not add a bare `pkgs.python313` beside the withPackages env
        # above -- measured, both ship `bin/python` and `bin/python3.13`, so
        # having both on PATH would make the live interpreter depend on package
        # order, and measured, only one of the two can `import discord`.
        pkgs.uv
        pkgs.ruff

        # Not referenced by any command text below (checked: none of the three
        # verbs invokes git, jq or make); on PATH for ad-hoc work at the
        # interactive prompt. Note the anchor in the canonical block does not
        # shell out to git either, so nothing load-bearing depends on
        # `pkgs.git` being here.
        pkgs.git
        pkgs.jq
        pkgs.gnumake
      ];

      # ======================================================================
      # PER-REPO BLOCK 2 -- libraries that get dlopened, not linked
      # ======================================================================
      # Nothing this flake installs needs these. discord.py comes from nixpkgs
      # already linked against the right store paths, and so does its aiohttp
      # (measured: aiohttp is a propagated input of discordpy). They are here
      # for the `uv` escape hatch above: a manylinux wheel carries .so files it
      # dlopens at run time rather than links, so they are resolved by the
      # loader's search path -- and on this host there is no /usr/lib for it to
      # search (measured: /usr contains only bin). Measured contents of the two
      # entries below: stdenv.cc.cc.lib supplies libstdc++.so.6 and zlib
      # supplies libz.so.1. Keep this list minimal; LD_LIBRARY_PATH is a blunt
      # instrument.
      #
      # This fixes shared libraries only. A prebuilt *executable* out of a wheel
      # additionally needs an ELF interpreter at the FHS path
      # /lib64/ld-linux-x86-64.so.2, which is a host setting no project flake
      # can supply.
      nativeLibs = pkgs: [
        pkgs.stdenv.cc.cc.lib
        pkgs.zlib
      ];

      # ======================================================================
      # PER-REPO BLOCK 3 -- constant environment variables
      # ======================================================================
      # Constants only. Anything that must READ an existing value
      # (LD_LIBRARY_PATH) or UNSET something (SOURCE_DATE_EPOCH) is handled by
      # the canonical block. This attrset is applied to BOTH surfaces -- the dev
      # shell and every `nix run` wrapper -- so a command cannot behave
      # differently depending on how it was invoked.
      envVars = pkgs: {
        # Keep uv on the nix interpreter. Left alone it fetches its own:
        # `uv python install --help` documents `--no-python-downloads` as
        # "Disable automatic downloads of Python", so automatic is the default.
        # Note this points at the BARE python313, not the withPackages env on
        # PATH, and that makes no difference to what a venv can import:
        # measured, `uv venv` here produces a .venv whose python cannot
        # `import discord` while the shell's own python3 can, so anything a venv
        # needs has to be installed into that venv.
        UV_PYTHON = "${pkgs.python313}/bin/python";
        UV_PYTHON_DOWNLOADS = "never";
        # uv installs out of its global cache by hardlink and falls back with a
        # warning when the cache and the target are on different filesystems.
        # Precautionary rather than a fix for an observed warning: on the
        # machine this was measured on, /nix/store and the checkout are the same
        # filesystem.
        UV_LINK_MODE = "copy";
        # logger.py reports through print(), so everything the bot says goes to
        # stdout. Unbuffered, so that a bot an agent kills on a timeout has
        # still flushed what it printed before the signal arrived.
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
      # Only the verbs this repo actually has are listed. Absence is
      # information:
      #   no `setup` -- the toolchain above is complete; nothing to bootstrap
      #   no `build` -- the two tracked .py files run in place; no artifact
      #   no `test`  -- `git ls-files` matches no test file, and a stub that
      #                 echoed "not applicable" would turn this map into a liar
      #
      # `text` is bash under `set -euo pipefail`, shellcheck'd at BUILD time. It
      # runs in the caller's current directory but must never ACT on it: every
      # verb below addresses $REPO_ROOT (see the anchor in the canonical block)
      # so that `nix run /path/to/repo#<verb>` -- the form CI and a cold agent
      # use, from whatever cwd they happen to have -- reads and writes exactly
      # the same files as `dev-<verb>` from inside the tree, and nothing else.
      # Explicit arguments still win, so an agent can narrow a verb to one file.
      commands = pkgs: {
        run = {
          # (network), and blocking with it. bot.py ends in `bot.run(token)`,
          # which does not return while the client is connected, so with a
          # working token this verb never exits on its own -- run it under a
          # timeout and read the log rather than waiting for exit 0. Measured
          # with a deliberately invalid token, it reaches Discord's HTTP login
          # and dies with discord.errors.LoginFailure, which is what "it really
          # does dial out" looks like from a smoke test.
          description = "(network) start the confession bot -- needs a local config.py";
          text = ''
            # This verb reads a gitignored file and writes a log, so the store
            # fallback is useless to it: refuse rather than tell the caller to
            # create config.py inside /nix/store.
            need_writable_checkout

            # bot.py does `from config import *` for BOT_TOKEN and CHANNEL_ID,
            # and .gitignore excludes *config*, so a fresh clone has no
            # config.py and the bot dies with a bare ModuleNotFoundError. Fail
            # early with something an agent can act on instead. Never write the
            # file from here: it holds a live bot token.
            if [ ! -f "$REPO_ROOT/config.py" ]; then
              echo "missing $REPO_ROOT/config.py -- create it (it is gitignored) with:" >&2
              echo "  BOT_TOKEN = \"<discord bot token>\"" >&2
              echo "  CHANNEL_ID = <target channel id as an int>" >&2
              exit 1
            fi
            # cd, and not merely `python3 "$REPO_ROOT/bot.py"`: logger.py builds
            # its log filename with no directory part
            # ("baselog_log_<asctime>.txt"), so the bot OPENS A FILE FOR WRITING
            # relative to cwd, and without the cd that file would land wherever
            # the caller happened to stand. Measured: a smoke run dropped a
            # baselog_log_<timestamp>.txt into $REPO_ROOT, where the *baselog*
            # line in .gitignore covers it and `git status` stayed clean. The cd
            # also puts the script's own directory first on sys.path, which is
            # what makes `config` and `logger` importable.
            cd "$REPO_ROOT"
            # Bare `python3` is correct here -- the wrapper prepends this
            # flake's toolchain, so it is the interpreter with discord.py baked
            # in. Measured: the smoke run's traceback came out of
            # <store>/python3-3.13.15-env/lib/python3.13/site-packages/discord.
            # exec so the bot inherits this PID: an agent's timeout/SIGTERM then
            # reaches python itself instead of a shell that outlives it.
            exec python3 bot.py "$@"
          '';
        };
        lint = {
          # The repo ships no ruff config, so this runs ruff's own default rule
          # set -- and the code as committed does not pass it. Measured at this
          # commit with the toolchain's own ruff, which the lock pins at 0.16.2:
          # 25 findings, so `dev-lint` exits 1. Broken down, that is 13 UP032
          # (a .format() call that should be an f-string), 6 LOG015 (a call on
          # the root logger), 2 I001 (unsorted import block), and one each of
          # F401 (`asyncio` imported but unused), F541 (f-string with no
          # placeholders), PIE790 (unnecessary `pass`) and UP039 (unnecessary
          # parentheses after a class definition); 4 in bot.py, 21 in logger.py.
          # Exit 1 is a real signal about the code, not a broken flake.
          #
          # That count is a property of the lock, not of this repo alone: the
          # same tree under ruff 0.15.22 reports 5, because 0.16 widened the
          # default rule set. Re-measure after a lockfile bump rather than
          # trusting this paragraph. Narrow the rules by committing a ruff.toml
          # or a pyproject.toml [tool.ruff]; do not paper over them with flags
          # baked into this flake, where nothing reading the repo would find
          # them.
          description = "ruff check";
          # `"''${@:-$REPO_ROOT}"`, not a bare `"$@"`: with no arguments ruff
          # walks the cwd. Measured in an empty directory, `ruff check` prints
          # "warning: No Python files found under the given path(s)" followed by
          # "All checks passed!" and exits 0 -- a gate that passes by inspecting
          # zero files is worse than no gate. The default also fixes the smaller
          # version of the same bug inside the repo -- measured from a
          # subdirectory of the checkout, lint still grades both bot.py and
          # logger.py at the tree root rather than the empty subdirectory.
          #
          # `--no-cache` closes the last hole in the same defect. Measured: ruff
          # writes .ruff_cache into the process's cwd, not beside the files it
          # was handed, so even with the paths anchored, linting from an
          # unrelated directory littered a cache there. Pointing --cache-dir at
          # $REPO_ROOT instead does not work in general -- measured against a
          # read-only store path, ruff exits 2 with
          # "Failed to initialize cache at <path>: Read-only file system"
          # rather than degrading. This is not a rule flag: measured, the same
          # 25 findings are reported with and without it.
          text = ''ruff check --no-cache "''${@:-$REPO_ROOT}"'';
        };
        fmt = {
          description = "ruff format (rewrites files)";
          text = ''
            # ruff format MUTATES, so an unanchored version of this verb is the
            # serious half of the bug described under lint: `nix run
            # /path/to/repo#fmt` from anywhere would rewrite the caller's source
            # files. Guard, then default to the repo. Measured from a foreign
            # git repo holding its own bot.py and a deliberately misformatted
            # victim.py, this exits 1 with need_writable_checkout's refusal and
            # leaves every file in that tree byte-identical. An explicit path is
            # the caller's own decision and passes straight through -- that is
            # the one case where touching files outside $REPO_ROOT is exactly
            # what was asked for.
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
      # PER-REPO BLOCK 5 -- checks beyond the canonical two
      # ======================================================================
      # The canonical `anchoring` check proves rootPreamble and guardPreamble
      # behave. It does not prove that THIS repo's verbs call them. This one
      # drives the real wrappers against a decoy carrying the marker file a
      # naive anchor would accept for a Python bot repo -- bot.py -- plus one
      # filename this repo does not contain, and asserts three things: dev-lint
      # grades this repo's snapshot and not the decoy, dev-fmt refuses outright
      # instead of rewriting the decoy, and the decoy is unchanged afterwards.
      #
      # `run` is not exercised here: it needs the Discord gateway and a
      # gitignored config.py, neither of which exists in a build sandbox.
      #
      # dev-lint's exit code is deliberately not asserted. It is 1 today because
      # the sources have real findings, and it flips to 0 the day somebody fixes
      # them, which would turn good news into a red check.
      extraChecks = pkgs: {
        verbAnchoring =
          pkgs.runCommand "verb-anchoring-check"
            {
              nativeBuildInputs = lib.attrValues (wrappers pkgs);
            }
            ''
              set -euo pipefail
              mkdir decoy
              cd decoy
              printf 'import discord\nimport asyncio\nx  =1\n' > bot.py
              printf 'import json\ny  =2\n' > sibling_only.py
              printf '{ description = "x"; outputs = _: { }; }\n' > flake.nix
              cp -r . ../decoy.orig

              # Grep by NAME, not by directory: if the anchor wrongly landed on
              # the decoy then ruff is standing in it and prints bare relative
              # paths, so a grep for "decoy" would match nothing and the leak
              # would sail through. A filename this repo does not contain is the
              # thing that cannot be spelled both ways.
              dev-lint > lint.log 2>&1 || true
              if grep -q sibling_only lint.log; then
                echo "dev-lint graded the decoy" >&2
                cat lint.log >&2
                exit 1
              fi
              # ...and it must have graded SOMETHING: a verb that read nothing
              # at all would also pass the test above.
              if ! grep -qF -- ${lib.escapeShellArg "${self}"} lint.log; then
                echo "dev-lint graded neither the decoy nor this repo" >&2
                cat lint.log >&2
                exit 1
              fi

              # Refusal, not silence.
              if dev-fmt > fmt.log 2>&1; then
                echo "dev-fmt succeeded in a foreign tree; it must refuse" >&2
                cat fmt.log >&2
                exit 1
              fi

              # `*.log`, and every log file here must match it -- a file named
              # plainly `log` would not be excluded and would fail this diff.
              diff -r --exclude='*.log' . ../decoy.orig
              touch "$out"
            '';
      };

      # >>>>> BEGIN CANONICAL MACHINERY v1 <<<<<
      # ======================================================================
      # Everything from the BEGIN sentinel above to the END sentinel on the last
      # line of this file is fleet-canonical text: the same bytes in every repo
      # that carries this flake style. That is a checkable claim, not a boast --
      #
      #   sed -n '/BEGIN CANONICAL MACHINERY v1/,$p' flake.nix | sha256sum
      #
      # prints the same digest in every repo, or one of them has been edited.
      # (`,$p`, not a range ending on the END sentinel: a range whose closing
      # pattern were spelled out here would terminate on this very comment.)
      # Nothing here names a repository, a language, a tool or a project file.
      # If you find such a name below, it is contamination: the fix is to move
      # it into the per-repo section above, never to special-case it here.
      #
      # This region READS exactly these names from the per-repo section:
      #   nixpkgs  self  lib  repoName  toolchain  nativeLibs  envVars
      #   commands  extraChecks
      # and DEFINES exactly these:
      #   systems  forAllSystems  ldPreamble  rootPreamble  guardPreamble
      #   wrappers  helpFor  anchorCheck
      # plus the four flake outputs apps / devShells / checks / formatter.
      # Anything else in scope is invisible to it. The types of those eight
      # inputs, and the shell variables this region exports into command texts,
      # are specified in INTERFACE.md, which travels with this block.
      #
      # To change behaviour here you change it in every repo at once and bump
      # the version in both sentinels. A local edit is a bug by construction:
      # the digest above stops matching, and -- because rootPreamble anchors on
      # flake.nix byte-identity -- an edited working tree also stops being
      # recognised by wrappers built from the previous revision.
      # ======================================================================

      # ---- systems policy: decided once for the whole fleet ----
      #
      # Read this list as "evaluated on three, built on one". That is what was
      # measured, and it is all it means:
      #   * `nix flake check --all-systems` passes, so every output attribute
      #     below EVALUATES on all three systems.
      #   * only x86_64-linux has ever been BUILT. The machine this was verified
      #     on has no aarch64 emulation -- no binfmt handler, and `extra-
      #     platforms` is x86-only -- so aarch64 cannot be built there at all.
      # It is not a statement that anything works on aarch64. Do not upgrade it
      # into one in a README.
      #
      # Evaluating all three is still worth its seconds, because the failure it
      # catches is an eval-time failure: a `pkgs.<attr>` that exists on Linux
      # and not on darwin (`stdenv.cc.cc.lib` is the usual one) throws during
      # evaluation, and `nix flake check` without --all-systems checks only the
      # current system and sails straight past it.
      #
      # x86_64-darwin is deliberately absent. nixpkgs 26.11 replaced that whole
      # attribute set with a `throw`. genAttrs is lazy, so plain `nix develop`
      # on Linux would not notice -- it detonates later, on the --all-systems
      # run this policy requires. Add it back only against a separate
      # nixpkgs-26.05-darwin input.
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];

      # Stand-in for flake-utils.lib.eachDefaultSystem. Passes `pkgs` rather
      # than a system string, because that is what every call site wants, and
      # keeps the system list in this file rather than in a second input's
      # hardcoded copy of it.
      forAllSystems = f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      # Prepend, never assign: a host LD_LIBRARY_PATH may be carrying something
      # the user needs, and clobbering it breaks binaries they launch from here.
      # Linux only -- on darwin the loader variable is DYLD_*, and exporting a
      # Linux-shaped value there is at best useless.
      #
      # `&&` short-circuits in Nix, so on darwin `nativeLibs pkgs` is never
      # forced. That is load-bearing for the systems policy above: it is what
      # lets a repo list Linux-only attrs in nativeLibs and still evaluate on
      # aarch64-darwin. Do not reorder the two operands.
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
      # that way has literally no way to name the repo it belongs to. Two
      # limitations worth knowing: it is read-only, being a store path, and in a
      # git checkout it contains only TRACKED files.
      #
      # $REPO_ROOT is the writable checkout when the caller is standing in one,
      # and $SRC_ROOT when they are not. Three things this deliberately is NOT:
      #
      #   * NOT `pwd`. A fallback to the caller's directory is how `fmt`
      #     rewrites a stranger's source tree and how `lint` prints "all checks
      #     passed" having read none of this repo.
      #   * NOT `git rev-parse --show-toplevel`. Run from inside some OTHER git
      #     repo it cheerfully answers with THAT repo's top level. It also needs
      #     git on PATH and a .git directory, so it fails on an export and in
      #     any wrapper whose toolchain omits git.
      #   * NOT an inherited $REPO_ROOT from the environment. The dev shell
      #     EXPORTS this variable, so honouring it would mean that running
      #     `nix run /path/to/B#fmt` from inside repo A's dev shell points B's
      #     formatter at A. An explicit path argument is how a caller overrides
      #     a verb's target; an ambient variable is how they do it by accident.
      #
      # Instead: walk up from $PWD and take the first ancestor that IS this
      # repo, proved by carrying a byte-identical flake.nix. A single tracked
      # filename, a marker directory, or a set of them is not proof -- sibling
      # repos in a fleet share those, and a decoy can be built to carry any list
      # of names you care to publish. The whole flake.nix is what distinguishes
      # repos, because description, toolchain and command map all differ, so the
      # whole flake.nix is what gets compared. Compared with bash's own
      # `$(<file)` rather than cmp or sha256sum, so the check depends on no
      # package at all -- pure builtins, correct even in a wrapper whose PATH
      # carries nothing but the repo's own toolchain.
      #
      # Consequence worth knowing: edit flake.nix and the dev-* wrappers in an
      # already-open `nix develop` stop recognising the tree, because they were
      # built from the previous flake.nix. That is a stale shell telling you so
      # -- re-enter it. `nix run` re-evaluates every time and never sees this.
      rootPreamble = ''
        SRC_ROOT=${lib.escapeShellArg "${self}"}
        export SRC_ROOT

        _dev_find_root() {
          local dir ref
          ref=$(<"$SRC_ROOT/flake.nix") || return 1
          dir=$(
            unset CDPATH
            cd -P -- "''${1:-.}" 2>/dev/null && pwd
          ) || return 1
          while [ -n "$dir" ]; do
            if [ -f "$dir/flake.nix" ] && [ "$(<"$dir/flake.nix")" = "$ref" ]; then
              printf '%s\n' "$dir"
              return 0
            fi
            dir=''${dir%/*}
          done
          return 1
        }

        REPO_ROOT="$(_dev_find_root "$PWD" || printf '%s\n' "$SRC_ROOT")"
        export REPO_ROOT
      '';

      # Wrappers only, not the shellHook -- an interactive shell has no business
      # carrying this function around. Any command text that writes files calls
      # it first, and it is the reason a mutating verb can fail loudly instead
      # of falling back to "well, the cwd then".
      #
      # The test is $REPO_ROOT != $SRC_ROOT, i.e. "rootPreamble found a real
      # checkout", not a permission or a store-path-prefix test. Both of those
      # answer a narrower question: a checkout may be read-only for unrelated
      # reasons, and a store path is not the only tree we must refuse to write.
      guardPreamble = ''
        need_writable_checkout() {
          if [ "$REPO_ROOT" != "$SRC_ROOT" ]; then
            return 0
          fi
          echo "''${0##*/}: this command rewrites files, so it needs a writable" >&2
          echo "checkout of this repo -- and standing in $PWD there is none: no" >&2
          echo "parent directory carries this flake's flake.nix. The only tree in" >&2
          echo "reach is the read-only store snapshot $SRC_ROOT, and rewriting" >&2
          echo "$PWD instead is exactly the bug this guard exists to prevent." >&2
          echo "cd into the repo (or \`nix develop\` it), or pass an explicit path." >&2
          exit 1
        }
      '';

      # One derivation per command, reused by both `apps` and the dev shell, so
      # the two can never diverge. `dev-` prefixed because a bare `test` binary
      # earlier on PATH would shadow the POSIX shell builtin and quietly break
      # every script in the repo that uses it.
      #
      # writeShellApplication, not writeShellScriptBin: it runs shellcheck at
      # BUILD time and sets `set -euo pipefail`, so an unquoted $@ or a silently
      # ignored failure is a `nix flake check` failure rather than a surprise in
      # front of an agent.
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

      # `dev-help` is generated from the same attrset as everything else, so it
      # cannot describe a verb that does not exist or miss one that does. No
      # runtimeInputs: printing the map must work with nothing installed.
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

      # The regression gate for rootPreamble and guardPreamble, which are the
      # two pieces of this flake that can silently damage a tree that is not
      # this repo. It tests the MECHANISM, not any verb, which is precisely what
      # makes it fleet-generic: it needs to know nothing about what this repo
      # does, only that the anchor resolves and the guard refuses.
      #
      # The decoy is a real directory carrying a real flake.nix that differs.
      # Marker-file anchors pass a decoy like this -- that is the whole point of
      # the probe -- and so does any anchor that trusts `pwd`. Probe 2 is the
      # other half, and without it a guard that refused everything would score a
      # perfect pass: a tree that IS byte-identical must still be adopted, or
      # every mutating verb in the repo is dead. Probe 3 pins the subdirectory
      # case, which is the normal one for an agent working inside a repo.
      #
      # A per-repo probe that drives the actual verbs is strictly better and
      # cannot live here -- it has to know which verb writes and which needs a
      # network. INTERFACE.md shows how to add one via `extraChecks`.
      anchorCheck =
        pkgs:
        pkgs.runCommand "anchor-check" { } ''
          set -euo pipefail

          # The two preambles under test, verbatim, in a file the probes source.
          # A quoted heredoc, so every $ below is the bash the wrappers see.
          cat > preamble.sh <<'CANONICAL_PREAMBLE_EOF'
          ${rootPreamble}
          ${guardPreamble}
          CANONICAL_PREAMBLE_EOF

          mkdir decoy
          printf '{\n  description = "a different repo";\n  outputs = _: { };\n}\n' > decoy/flake.nix
          printf 'do not touch me\n' > decoy/victim.txt
          cp -r decoy decoy.orig

          # ---- probe 1: a foreign tree must not be adopted ----
          if ! ( cd decoy && . ../preamble.sh && [ "$REPO_ROOT" = "$SRC_ROOT" ] ); then
            echo "anchor adopted a directory that is not this repo" >&2
            exit 1
          fi
          # In a subshell: need_writable_checkout ends in `exit`, which would
          # otherwise take this whole build down instead of failing a condition.
          if ( cd decoy && . ../preamble.sh && need_writable_checkout ) > guard.log 2>&1; then
            echo "need_writable_checkout accepted a tree that is not this repo" >&2
            exit 1
          fi
          if ! diff -r decoy decoy.orig; then
            echo "the probes modified the foreign tree" >&2
            exit 1
          fi

          # ---- probe 2: a byte-identical checkout must be adopted ----
          cp -r ${lib.escapeShellArg "${self}"} checkout
          chmod -R u+w checkout
          if ! ( cd checkout && . ../preamble.sh &&
                 [ "$REPO_ROOT" = "$(pwd -P)" ] && need_writable_checkout ); then
            echo "anchor refused a byte-identical checkout of this repo" >&2
            exit 1
          fi

          # ---- probe 3: from a subdirectory, still the checkout root ----
          mkdir -p checkout/probe3/deeper
          if ! ( cd checkout/probe3/deeper && . ../../../preamble.sh &&
                 [ "$REPO_ROOT" = "$(cd -P ../.. && pwd)" ] ); then
            echo "anchor did not walk up to the checkout root from a subdirectory" >&2
            exit 1
          fi

          touch "$out"
        '';
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

          # Natively-compiled extension modules are routinely built at -O0,
          # where glibc's _FORTIFY_SOURCE stops being a warning and becomes a
          # hard error.
          hardeningDisable = [ "fortify" ];

          shellHook = ''
            # mkShell inherits SOURCE_DATE_EPOCH=315532800 (1980-01-01) from
            # stdenv, and any wheel or zip built in here then dies with "ZIP does
            # not support timestamps before 1980".
            unset SOURCE_DATE_EPOCH

            # $REPO_ROOT and $SRC_ROOT are exported here as a convenience for
            # the human at the prompt. Every wrapper re-resolves them from
            # scratch and none of them reads these, on purpose: a stale value
            # exported by one repo's shell must never steer another repo's verb.
            ${rootPreamble}
            ${ldPreamble pkgs}

            # Nothing networked, nothing stateful and nothing interactive above
            # this line, and nothing below it either. No environment
            # bootstrapping, no dependency installation, no `read`, no
            # `exec $SHELL`. Bootstrapping in the hook makes a cold
            # `nix develop -c <anything>` start downloading before it runs
            # anything, on EVERY invocation -- the exact failure an unattended
            # agent cannot diagnose. That is what a `setup` verb is for.

            # The banner is interactive-only, and this guard is load-bearing:
            # shellHook output lands on the STDOUT of `nix develop -c <cmd>`, so
            # an unguarded echo corrupts anything parsing it
            # (`nix develop -c cat x.json | jq` fails to parse). $- is the only
            # reliable discriminator here -- it lacks `i` for `nix develop -c`
            # and has it at an interactive prompt. Do not test $PS1 (unset in
            # both) or $IN_NIX_SHELL (set in both). >&2 is the second layer, for
            # the case where a caller runs us on a pty.
            case $- in
              *i*) echo "${repoName} dev shell -- 'dev-help' for the command map" >&2 ;;
            esac
          '';
        };
      });

      # `nix flake check` -- honest by construction, and the only gate this
      # style has. `toolchain` realises the whole toolchain closure (so a typo'd
      # or currently-broken attr fails here, not halfway through a task) and
      # builds every wrapper, which runs shellcheck over every command text.
      # `anchoring` is the regression test described above.
      #
      # Repo-specific checks go in `extraChecks`, never here. They may not
      # shadow either canonical name: silently replacing `anchoring` with
      # something weaker is the exact failure this whole file exists to make
      # impossible, so a collision is an eval error with both names in it.
      #
      # NEVER add a check that always passes. An agent reads "all checks
      # passed!" as a signal, and a fake check makes `nix flake check` a liar.
      checks = forAllSystems (
        pkgs:
        let
          canonical = {
            toolchain =
              pkgs.runCommand "toolchain-check"
                {
                  nativeBuildInputs = toolchain pkgs ++ lib.attrValues (wrappers pkgs) ++ [ (helpFor pkgs) ];
                }
                ''
                  set -euo pipefail
                  dev-help > help.txt

                  # A while-read over a heredoc rather than `for x in <list>`,
                  # which is a bash syntax error when the list is empty -- and a
                  # repo with no verbs yet is a legitimate state.
                  while IFS= read -r verb; do
                    [ -n "$verb" ] || continue
                    command -v "dev-$verb" > /dev/null || {
                      echo "dev-$verb is not on PATH" >&2
                      exit 1
                    }
                    grep -q -- "dev-$verb" help.txt || {
                      echo "dev-$verb is missing from the dev-help map" >&2
                      exit 1
                    }
                  done <<'CANONICAL_VERBS_EOF'
                  ${lib.concatStringsSep "\n" (lib.attrNames (commands pkgs))}
                  CANONICAL_VERBS_EOF

                  touch "$out"
                '';
            anchoring = anchorCheck pkgs;
          };
          extra = extraChecks pkgs;
          clash = lib.intersectLists (lib.attrNames canonical) (lib.attrNames extra);
        in
        if clash != [ ] then
          throw "extraChecks must not redefine canonical checks: ${lib.concatStringsSep ", " clash}"
        else
          canonical // extra
      );

      # `nix fmt` -- formats the *Nix* in this repo; project code gets a `fmt`
      # verb. nixfmt-tree (the treefmt wrapper) rather than bare nixfmt, because
      # bare nixfmt tries to parse every path handed to it and fails on non-Nix
      # files. This file ships already formatted, so `nix fmt` is a no-op rather
      # than a diff across the fleet.
      #
      # This is the one verb here NOT anchored to $REPO_ROOT, and it cannot be:
      # `nix fmt` is nix's own verb, and nix -- not this flake -- decides which
      # paths the formatter receives, passing the cwd when the user names none.
      # A wrapper that overrode them would break `nix fmt path/to/one/file.nix`,
      # and it cannot tell that "." apart from the default. So `nix fmt` formats
      # where you stand, by design; the `fmt` verb is the anchored one.
      formatter = forAllSystems (pkgs: pkgs.nixfmt-tree);
    };
}
# >>>>> END CANONICAL MACHINERY v1 <<<<<
