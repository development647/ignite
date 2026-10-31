#!/usr/bin/env bash
set -euo pipefail

# Build and package the IGNITE desktop application.
#
# Usage:
#   scripts/ci/build.sh <semantic-version>
#
# Example:
#   scripts/ci/build.sh 1.4.2
#   scripts/ci/build.sh 0.0.0-pr.123
#
# The version is written to Source/Application/apps/ignite/version.txt before
# configuration, compiled into the binary via IGNITE_VERSION_STRING, and copied
# into BUILD_INFO.txt in the artifact.

VERSION="${1:-}"
if [[ -z "${VERSION}" ]]; then
  echo "usage: $0 <semantic-version>" >&2
  exit 2
fi

if [[ ! "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$ ]]; then
  echo "error: '${VERSION}' is not a semantic version (expected X.Y.Z or X.Y.Z-suffix)" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${ROOT}"

CORE="${VERSION%%[-+]*}"
IFS='.' read -r MAJOR MINOR PATCH <<< "${CORE}"
if [[ -z "${MAJOR}" || -z "${MINOR}" || -z "${PATCH}" ]]; then
  echo "error: could not parse version '${VERSION}'" >&2
  exit 2
fi

# The app CMake reads this file at configure time.
printf '%s\n' "${VERSION}" > Source/Application/apps/ignite/version.txt

export CPM_SOURCE_CACHE="${CPM_SOURCE_CACHE:-${ROOT}/.cpm-cache}"
mkdir -p "${CPM_SOURCE_CACHE}"

rm -rf build dist
cmake -S Source/Application -B build \
  -DCMAKE_BUILD_TYPE=Release
cmake --build build --config Release -j"${BUILD_JOBS:-$(nproc)}"

OUT="${ROOT}/build/apps/ignite/Ignite_artefacts/Release"
if [[ ! -x "${OUT}/Ignite" ]]; then
  echo "error: expected executable at ${OUT}/Ignite" >&2
  exit 1
fi

# Verify the semantic version is actually embedded in the executable.
if ! grep -aFq -- "${VERSION}" "${OUT}/Ignite"; then
  echo "error: version '${VERSION}' was not found in the executable" >&2
  exit 1
fi

DIST="${ROOT}/dist"
mkdir -p "${DIST}/assets"
cp "${OUT}/Ignite" "${DIST}/Ignite"
cp -R "${OUT}/assets/." "${DIST}/assets/"
cp "${ROOT}/LICENSE" "${DIST}/LICENSE"
cp "${ROOT}/README.md" "${DIST}/README.md"

SOUNDFONT_INCLUDED="false"
if [[ -f "${ROOT}/Source/Application/sf/Ignite.sf2" ]]; then
  cp "${ROOT}/Source/Application/sf/Ignite.sf2" "${DIST}/Ignite.sf2"
  SOUNDFONT_INCLUDED="true"
fi

cat > "${DIST}/BUILD_INFO.txt" <<INFO
version=${VERSION}
commit=$(git -C "${ROOT}" rev-parse HEAD 2>/dev/null || echo unknown)
branch=$(git -C "${ROOT}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)
build_date=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
soundfont_included=${SOUNDFONT_INCLUDED}
INFO

ZIP="${ROOT}/.build_cache/Ignite-${VERSION}-linux-x86_64.zip"
mkdir -p "${ROOT}/.build_cache"
rm -f "${ZIP}"

# Use Python's stdlib zip writer so local builds do not require the `zip`
# binary; CI installs zip as well, but this keeps the script portable.
python3 - "${DIST}" "${ZIP}" <<'PY_ZIP'
import os
import sys
import zipfile

src, out = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as archive:
    for root, _dirs, files in os.walk(src):
        for name in files:
            path = os.path.join(root, name)
            archive.write(path, os.path.relpath(path, src))
PY_ZIP

# Generate a checksum next to the artifact.
(cd "${ROOT}/.build_cache" && sha256sum "$(basename "${ZIP}")" > "$(basename "${ZIP}").sha256")

mv "${ZIP}" "${DIST}/"
mv "${ROOT}/.build_cache/$(basename "${ZIP}").sha256" "${DIST}/"

echo "Built: ${DIST}/$(basename "${ZIP}")"
echo "Version embedded: ${VERSION}"
