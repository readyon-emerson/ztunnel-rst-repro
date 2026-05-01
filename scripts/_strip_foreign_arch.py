#!/usr/bin/env python3
# Rewrite an OCI image tarball (output of `docker save`) so its manifest
# list contains only the local-platform manifest. Without this step,
# `kind load image-archive` fails with "content digest ... not found" on
# Docker Desktop because the saved tarball includes manifest-list entries
# for both linux/amd64 and linux/arm64 but only ships the local platform's
# layers. ctr's `--all-platforms --digests` import then trips on the
# foreign-platform manifest digest that isn't in the tarball.
#
# Usage: scripts/_strip_foreign_arch.py [tarball ...]
import json, tarfile, hashlib, os, tempfile, platform, sys


ARCH = "arm64" if platform.machine() in ("arm64", "aarch64") else "amd64"


def rewrite(tarball: str) -> None:
    with tempfile.TemporaryDirectory() as tmp:
        with tarfile.open(tarball) as tar:
            tar.extractall(tmp)

        idx_path = os.path.join(tmp, "index.json")
        with open(idx_path) as f:
            index = json.load(f)

        for entry in index["manifests"]:
            digest = entry["digest"].split(":")[1]
            list_path = os.path.join(tmp, "blobs/sha256", digest)
            with open(list_path) as f:
                ml = json.load(f)
            if ml.get("mediaType") not in (
                "application/vnd.docker.distribution.manifest.list.v2+json",
                "application/vnd.oci.image.index.v1+json",
            ):
                continue
            ml["manifests"] = [
                m for m in ml["manifests"]
                if m.get("platform", {}).get("architecture") == ARCH
            ]
            data = json.dumps(ml, separators=(",", ":")).encode()
            new_digest = hashlib.sha256(data).hexdigest()
            new_path = os.path.join(tmp, "blobs/sha256", new_digest)
            with open(new_path, "wb") as f:
                f.write(data)
            os.remove(list_path)
            entry["digest"] = f"sha256:{new_digest}"
            entry["size"] = len(data)

        with open(idx_path, "w") as f:
            json.dump(index, f)

        with tarfile.open(tarball, "w") as tar:
            for name in sorted(os.listdir(tmp)):
                tar.add(os.path.join(tmp, name), arcname=name)


for path in sys.argv[1:]:
    rewrite(path)
