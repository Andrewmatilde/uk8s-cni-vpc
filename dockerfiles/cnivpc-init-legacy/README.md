# Historical CNI with the current init installer

This image retains the released `cni-vpc-init` installer and replaces only
`/app/cnivpc` with `/usr/local/bin/cnivpc` from a released `cni-vpc-node` image.
Historical Go source is never recompiled. The historical node entrypoint and
its log-tailing process are not included in the final image.

## Build and publish

First inspect the existing tags in `uk8s/cni-vpc-init` and
`andrew/cni-vpc-init` outside the script. Make an explicit list of missing
CNI versions and pass only those versions to the script:

```sh
scripts/build-legacy-cnivpc-init-images.sh VERSION [VERSION ...]
```

The script loops over that list and builds and pushes each image. It uses
`uk8s/cni-vpc-init:2.0.6` for the installer and `uk8s/cni-vpc-node:VERSION`
for the historical binary. Output is `uk8s/cni-vpc-init:VERSION`, targeting
`linux/amd64`. It requires Docker buildx and registry credentials.

There is no registry lookup, default version list, or mode selection in the
script. Running it without versions prints usage and exits without building.

## Published images

[images.json](images.json) records the 14 images published and verified on
2026-09-15, including their `linux/amd64` manifest digests and source images.
Each image passed real-container checks for version output, initial installation,
same-version skip, preserving an existing version by default, and explicit
overwrite. The installer SHA-256 matched the released `2.0.6` installer.
Remote filesystem layers and runtime configuration matched the local images.
The existing `2.0.0-alpha.5` image digest was confirmed unchanged.

These checks validate packaging and installation, not cluster networking.

## Use for version-switch testing

Replace the image of the existing CNI init container with the desired output
image. Keep its `/opt/cni/bin` hostPath mount. For deliberate upgrades or
downgrades, set:

```yaml
image: uhub.service.ucloud.cn/uk8s/cni-vpc-init:1.3.4
env:
  - name: CNI_INIT_OVERWRITE
    value: "true"
```

The init installer runs once and exits. By default it installs only when the
target binary is absent; `CNI_INIT_OVERWRITE=true` replaces a different version.
Identical `--version` output skips the copy. Both source and existing target
must support successful `--version` execution; a broken existing target can
cause the installer to exit before replacement.

These images replace only the CNI executable. They do not change the CNI
configuration, IPAMD, or controllers. Select those versions separately when
the test requires a complete historical deployment. Avoid another container
concurrently overwriting the same host CNI executable.
