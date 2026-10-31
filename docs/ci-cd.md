# CI/CD and release process

This document describes the GitHub Actions pipeline added for the IGNITE application.

## Flow at a glance

```text
feature branch
  -> PR to main/master
     -> PR title check (Conventional Commit style)
     -> Linux CI build
     -> downloadable PR artifact
  -> merge PR
     -> Release Please opens/updates a release PR
        -> release PR runs the same CI checks
     -> merge release PR
        -> Release Please creates tag vX.Y.Z and GitHub Release
        -> release-build job builds the final artifact
        -> artifact + SHA-256 are uploaded to the GitHub Release
```

There are no direct commits to the protected branch from the release automation. Version bumps and
changelog updates are made through the Release Please pull request.

## Current branch

The repository currently uses `main` as the default branch. All workflows also support `master`, so
you can rename the default branch without changing the pipeline. PRs should target whichever branch
is the protected/default branch.

If you want the strict `master` flow, rename the default branch to `master` in **Settings → Branches**
(or via the GitHub API) and keep the protection rules on that branch.

## Workflows

| File | Trigger | Purpose |
|---|---|---|
| `.github/workflows/ci.yml` | PR to `main`/`master`, manual | Build Linux app, verify embedded version, upload artifact |
| `.github/workflows/pr-title.yml` | PR opened/edited/reopened/synchronized | Enforce Conventional Commit PR titles |
| `.github/workflows/release-please.yml` | Push to `main`/`master` | Open/update release PR, then build/upload release artifacts after release creation |
| `.github/workflows/release.yml` | — | Removed; release builds happen in `release-please.yml` after Release Please creates the tag |

## Semantic versioning

The project uses [Semantic Versioning](https://semver.org/):

```text
MAJOR.MINOR.PATCH
```

Release Please derives the next version from Conventional Commit messages:

| Commit / PR type | Version effect |
|---|---|
| `fix:` | patch |
| `feat:` | minor |
| `feat!:` or `BREAKING CHANGE:` | major |
| `perf:` | patch |
| `refactor:`, `docs:`, `test:`, `build:`, `ci:`, `chore:` | no release on their own |

Examples:

```text
feat(sequencer): add per-step probability      -> minor
fix(midi): correct clock divider                -> patch
feat(api)!: replace the legacy parameter API    -> major
```

Use **Squash and merge** or make sure the merge commit/PR title is the Conventional Commit you want
release-please to read. The `PR title` workflow rejects non-conventional titles.

## Version source and embedding

The canonical version file is:

```text
Source/Application/apps/ignite/version.txt
```

It contains a plain semantic version, for example:

```text
1.4.2
```

Release Please updates this file in the release PR. The application reads it at CMake configure time
(`Source/Application/apps/ignite/CMakeLists.txt`) and injects:

```text
IGNITE_VERSION_STRING
```

`Main.cpp` returns that value from `getApplicationVersion()`. The build script also verifies that the
version string is present in the final executable before packaging.

Each artifact contains `BUILD_INFO.txt` with:

```text
version=1.4.2
commit=<git sha>
branch=<git branch>
build_date=<UTC timestamp>
soundfont_included=<true|false>
```

## Artifacts

The release and CI jobs produce:

```text
dist/Ignite-<version>-linux-x86_64.zip
dist/Ignite-<version>-linux-x86_64.zip.sha256
```

The ZIP contains:

```text
Ignite
assets/
LICENSE
README.md
BUILD_INFO.txt
Ignite.sf2          # only when Source/Application/sf/Ignite.sf2 exists
```

The SoundFont is not committed to the repository. If it is present in the build workspace it is
included in the artifact; otherwise the app still needs `/app/Ignite.sf2` at runtime.

**Not included:** device images, Buildroot output, MCU firmware, NXP/Marvell Wi-Fi firmware, and
`pcmode`. Those require proprietary or non-redistributable artifacts and are not built by this CI.
Add a separate device-image job only after those inputs are available.

## Required repository settings

1. Enable GitHub Actions for the repository.
2. Set the default branch to `main` or `master`.
3. Protect the default branch:
   - require pull requests before merging;
   - require status checks:
     - `CI build / Linux build`
     - `PR title / Conventional PR title`
   - optionally require conversation resolution.
4. Disable direct pushes to the protected branch.
5. Enable **Squash and merge** and use the PR title as the squash commit title.

### Release Please token

Release Please works with the default `GITHUB_TOKEN`, but GitHub does not start new workflow runs
from events created by `GITHUB_TOKEN`. That means a release PR created with `GITHUB_TOKEN` will not
trigger the CI checks automatically.

For a fully automatic release flow, create a fine-grained token or classic PAT with:

- contents: read/write
- pull requests: read/write

Add it as repository secret:

```text
RELEASE_PLEASE_TOKEN
```

The workflow uses:

```yaml
token: ${{ secrets.RELEASE_PLEASE_TOKEN || secrets.GITHUB_TOKEN }}
```

Without the secret, release creation still works, but release PR checks may need to be run manually.

## Local build and packaging

The same script used by CI can be run locally:

```sh
bash scripts/ci/install-linux-deps.sh   # Ubuntu 24.04 only
bash scripts/ci/build.sh 1.4.2
```

The version must be semantic:

```sh
bash scripts/ci/build.sh 0.4.0
bash scripts/ci/build.sh 0.4.0-rc.1
```

The script writes the version to `Source/Application/apps/ignite/version.txt`, configures and builds
the app, verifies the version is embedded, and creates the ZIP plus SHA-256 in `dist/`.

## Manual testing of a release

To rebuild an exact version locally:

```sh
git checkout v1.4.2
bash scripts/ci/build.sh 1.4.2
```

To verify the embedded version in the binary:

```sh
strings dist/Ignite | grep -F '1.4.2'
```

or simply inspect `dist/BUILD_INFO.txt`.

## Files added for CI/CD

```text
.github/workflows/ci.yml
.github/workflows/pr-title.yml
.github/workflows/release-please.yml
release-please-config.json
.release-please-manifest.json
CHANGELOG.md
scripts/ci/install-linux-deps.sh
scripts/ci/build.sh
```

`release-please-config.json` uses the `simple` strategy so it updates
`Source/Application/apps/ignite/version.txt`. `.release-please-manifest.json` starts at `0.3.3`, the
current application version. `bootstrap-sha` is set to the current base commit so the first release
PR does not parse unrelated early history.

## Failure behaviour

- A failed PR build blocks merge if branch protection is configured.
- A failed release build leaves the tag/release in place; re-run the `Release Please` workflow or
  build locally, then upload the artifact with `gh release upload`.
- A tag whose `version.txt` does not match the tag fails verification before build.
- PR builds are intentionally versioned `0.0.0-pr.<number>` and are not published as releases.

## Next steps

- Add Windows/macOS build jobs if those desktop artifacts are required.
- Add a separate Buildroot/device-image workflow once the NXP, MCU, and USB-service inputs are
  available.
- Add automated tests before treating CI as a release-quality gate; the current pipeline verifies
  build and embedded version only.
