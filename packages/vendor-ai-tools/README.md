# Vendor AI tools

Finite Python release discovery/orchestration + direct Nix package builds. No
flake, local worktree, daemon, user npm prefix, or vendor installer is involved.
The packaging recipes currently target this host's **x86_64-linux** platform.

## Release sources and trust

- **Claude:** `downloads.claude.ai/claude-code-releases/latest`, then the exact
  version's manifest and `linux-x64/claude` binary. This is the vendor's latest
  public release channel, not its deliberately delayed `stable` channel; numeric
  prerelease versions are rejected.
- **Codex:** latest non-prerelease GitHub release in `openai/codex`, using the
  complete Linux x86_64 musl package (including its companion host/resources).
- **Pi:** latest non-prerelease GitHub release in `earendil-works/pi`, using its
  official installer package.json/package-lock.json. Missing workspace integrity
  fields are filled from the npm registry for the **exact locked version**.
  Nix imports that lock and installs published npm content offline with lifecycle
  scripts disabled. No source build or guessed dependency hash is necessary.
- **T3:** latest non-prerelease GitHub release in `pingdotgg/t3code`, using its
  Linux x64 CLI archive and amd64 desktop deb. The desktop's self-updater is
  disabled, and its setuid sandbox helper is removed (normal user-namespace
  sandboxing remains enabled; the launcher does not pass `--no-sandbox`).

GitHub asset SHA-256 digests and Claude's platform checksum are mandatory.
Separately published SHA256SUMS entries are cross-checked where available; Nix
verifies actual downloads against the recorded hashes. Pi dependencies additionally
require registry integrity hashes. This trusts the official HTTPS release/registry
accounts; it is not an independent publisher-signature/provenance verification
system. Compromise of a vendor account remains a supply-chain risk. Do not
interpret automatically recorded hashes as independent approval of vendor code.

The immutable worker configuration contains the packaging nixpkgs store path,
recipe and deployed Pi extension snapshot. Updating vendor versions needs no OS
rebuild. Updating those packaging inputs or the deployed extensions does require
rebuilding the configuration. Only Pi's build identity includes its extensions.
No secrets or provider requests are needed for release discovery or smoke tests.

## State and activation

`/var/lib/nixos-ai-tools/vendor/<tool>/` contains:

- `status.json`: detected release/version, last successful metadata check,
  attempt/finish timestamps, phase and error.
- `generations/<id>/release.json`: exact requested versions, source URLs and hashes.
- `generations/<id>/build.json`: release/recipe/support-input identity.
- `generations/<id>/profile`: **stationary Nix indirect GC root** for a successful
  build. Smoke checks and Pi compatibility checks are part of that derivation.
- `current`, `previous`: atomically replaced symlinks to those profile roots.
- `hold.json`: explicit pause after rollback; only `resume` removes it.

The package itself embeds its release receipt. Status reads the installed version
from the active package, not optimistic metadata written before activation.
Successful release checks and successful installations are separate facts. A
failed download/build/test never replaces `current`. Root-owned per-tool locks
serialize updates and rollback. New launches follow `current`; existing processes
are neither signalled nor restarted.

Activation retains the previous generation. Other generations and interrupted
candidates are pruned under the tool lock; their store paths are reclaimed by the
normal Nix GC. The old shared `/var/lib/nixos-ai-tools/current` is never modified
or removed by this updater, and remains available as a bootstrap fallback.

`ai-tools rollback TOOL` restores the previous profile and holds that tool, so the
next timer cannot immediately reinstall the rejected release. On the first vendor
installation, rollback can return to the retained legacy/system bootstrap instead.
`ai-tools resume TOOL`, followed by `ai-tools update TOOL`, releases the hold and retries. Automatic
downgrades are refused. No automatic rollback after a later runtime failure is
attempted: launch smoke tests cannot prove every provider or UI feature works.

Detailed state is available through `ai-tools status [--json]`. Shelllist continues
to consume the bounded schema-v1 aggregate records under
`/var/lib/nixos-delayed-updates-v2/jobs/`; boot/PID/start identity is preserved.
A failure in one tool does not prevent any other tool's build/activation.

## Tests and deployment

Fast, offline policy/transaction tests:

```sh
python3 -B -m unittest discover -s packages/vendor-ai-tools/tests -v
```

The same suite, plus a packaged empty-PATH invocation, runs as the host flake's
`vendor-ai-tools` check. It covers failure isolation, unrelated untracked files,
checksum/version rejection, activation, rollback holds, retained roots, stale
checks, no-change builds and process timeout. Host validation still uses the
normal `local-build check /etc/nixos` workflow.

Real vendor builds can be tested **without evaluating the host flake or activating
anything** by discovering a manifest into a temporary directory and invoking:

```sh
nix-build packages/vendor-ai-tools/package.nix \
  --argstr nixpkgs /nix/store/EXISTING-PINNED-NIXPKGS-SOURCE \
  --argstr manifestFile /absolute/path/to/release.json \
  --argstr piExtensions /etc/nixos/config/pi \
  --out-link /tmp/vendor-tool-result
```

Do not invent hashes: manifests must come from `updater.discover(tool)`. For an
end-to-end isolated test, give `updater.py --config CONFIG update TOOL` a test
configuration with temporary `state` and `jobs` directories, immutable `nixpkgs`,
`recipe`, and `extensions` paths, and an absolute `nix_build` executable. Leave
`notify_command` unset. Test one tool first, then the others; inspect the temporary
profiles and status. This uses real downloads/builds without touching live tools.

Deploy with `rebuild`. Start a fresh login session for the new launcher PATH; then
`sudo systemctl start nixos-ai-tools-update.service`. Existing sessions continue
using their original executable. Packaging maintenance should preserve the
per-tool failure boundary, not add host flake/worktree checks back into this path.

### Implementation validation (2026-09-30)

- Offline regression suite and packaged empty-PATH runtime check passed.
- `local-build check /etc/nixos` passed, including host configuration evaluation.
  A final rerun was subsequently blocked by newly untracked
  `acceptance/profile.py` and `acceptance/resource-budgets.json` in the unrelated
  `ts-react-quality-lens` worktree. Those files were left untouched; the final
  isolated updater tests/builds still passed with that worktree present.
- Real vendor discovery, Nix packaging and sandboxed smoke checks passed for
  Claude **2.1.285**, Codex **0.159.2**, Pi **0.99.1** and T3 **0.0.44**.
- Pi **0.99.1** passed the deployed extension typecheck and retention tests.
- Real isolated activation, bootstrap rollback/hold/resume, per-tool launches,
  registered GC roots and no-change checks passed using temporary state paths.
- Packaged release discovery also passed with an empty environment/missing PATH.

No production profile or NixOS generation was activated during these tests.
Provider-authenticated requests and a full interactive T3 desktop session were
not exercised; smoke tests are intentionally not an end-to-end product guarantee.
