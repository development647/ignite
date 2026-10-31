The General MIDI SoundFont used by IGNITE (`Ignite.sf2`) is not part of this open-source release.
Put a `.sf2` file you have the rights to here as `Ignite.sf2`; the build copies it next to the
application, and the device image installs it as `/app/Ignite.sf2`.

## Tested replacement: FluidR3_GM

The Buildroot tree already contains a package for the MIT-licensed **FluidR3_GM** SoundFont, but it is
disabled in the Ignite defconfigs. The same file can be fetched directly from Debian:

```sh
cd /tmp
curl -fL -o fluid-soundfont_3.1.orig.tar.gz \
  https://deb.debian.org/debian/pool/main/f/fluid-soundfont/fluid-soundfont_3.1.orig.tar.gz

# Expected SHA256:
# 2621acaa1c78e4abdb24bdd163230cc577e61276936d6aa6e3180582142f0343
sha256sum fluid-soundfont_3.1.orig.tar.gz

tar -xzf fluid-soundfont_3.1.orig.tar.gz
```

The archive contains:

- `FluidR3_GM.sf2` — 142 MB, General MIDI, the file used for the tested build
- `FluidR3_GS.sf2` — 3.1 MB, GS variant
- `COPYING` — MIT license
- `README` — provenance and credits

Copy the GM file into this directory if you want the CMake build to copy it next to the executable:

```sh
cp /tmp/fluid-soundfont-3.1/FluidR3_GM.sf2 Source/Application/sf/Ignite.sf2
```

On Linux the runtime still expects `/app/Ignite.sf2`, so also install it there:

```sh
sudo mkdir -p /app
sudo cp Source/Application/sf/Ignite.sf2 /app/Ignite.sf2
```

`*.sf2` is ignored by git here. Do not commit the 142 MB file: GitHub rejects files over 100 MB, and
the repository is meant to stay source-only. For a device image, either enable
`BR2_PACKAGE_FLUID_SOUNDFONT` and arrange for `/app/Ignite.sf2` to point at
`/usr/share/soundfonts/FluidR3_GM.sf2`, or provide the file through your release packaging.

The FluidR3 license is MIT:

```text
Copyright (c) 2000-2002, 2008 Frank Wen <getfrank@gmail.com>
```

See the `COPYING` file in the downloaded archive for the full text.
