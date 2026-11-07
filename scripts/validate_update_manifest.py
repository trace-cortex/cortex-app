from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
from urllib.parse import urlparse, unquote


REQUIRED_TOP_LEVEL = {
    "app",
    "bundle_id",
    "channel",
    "version",
    "build",
    "minimum_macos",
    "released_at",
    "mandatory",
    "release_notes",
    "artifacts",
}
REQUIRED_ARTIFACT = {"kind", "filename", "url", "size_bytes", "sha256"}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def artifact_path(root: Path, filename: str, url: str) -> Path:
    parsed = urlparse(url)
    if parsed.scheme == "file":
        return Path(unquote(parsed.path))
    return root / filename


def checksums_from_file(path: Path) -> dict[str, str]:
    """Parse a `shasum -a 256` style file into {filename: sha256}."""
    entries: dict[str, str] = {}
    if not path.exists():
        return entries
    for line in path.read_text(encoding="utf-8").splitlines():
        parts = line.strip().split()
        if len(parts) >= 2 and len(parts[0]) == 64:
            entries[parts[-1].lstrip("*")] = parts[0].lower()
    return entries


def validate(manifest_path: Path, *, allow_remote_artifacts: bool = False) -> dict:
    payload = json.loads(manifest_path.read_text(encoding="utf-8"))
    missing = sorted(REQUIRED_TOP_LEVEL - set(payload))
    if missing:
        raise ValueError(f"manifest missing top-level keys: {', '.join(missing)}")
    if payload["app"] != "Cortex":
        raise ValueError("manifest app must be Cortex")
    if payload["bundle_id"] != "com.cortex.doppl":
        raise ValueError("manifest bundle_id must be com.cortex.doppl")
    if not isinstance(payload["release_notes"], list):
        raise ValueError("release_notes must be a list")
    artifacts = payload["artifacts"]
    if not isinstance(artifacts, list) or not artifacts:
        raise ValueError("artifacts must be a non-empty list")

    root = manifest_path.parent
    seen_kinds: set[str] = set()
    remote_artifacts = 0
    published_checksums = checksums_from_file(root / f"{payload['app']}-{payload['version']}-{payload['build']}.checksums.txt")
    for artifact in artifacts:
        missing_artifact = sorted(REQUIRED_ARTIFACT - set(artifact))
        if missing_artifact:
            raise ValueError(f"artifact missing keys: {', '.join(missing_artifact)}")
        kind = str(artifact["kind"])
        if kind not in {"dmg", "zip", "obsidian-plugin"}:
            raise ValueError(f"unsupported artifact kind: {kind}")
        seen_kinds.add(kind)
        path = artifact_path(root, str(artifact["filename"]), str(artifact["url"]))
        if not path.exists():
            if not allow_remote_artifacts:
                raise FileNotFoundError(f"artifact not found: {path}")
            # The published site feed points at release binaries hosted elsewhere (GitHub
            # Releases); the repo keeps only latest.json + the checksums file. Validate what can
            # be validated without the binary: an https URL and agreement with the published
            # checksums file when it is present.
            parsed = urlparse(str(artifact["url"]))
            if parsed.scheme != "https":
                raise ValueError(f"remote artifact {artifact['filename']} must use an https URL, got {artifact['url']!r}")
            expected = published_checksums.get(str(artifact["filename"]))
            if expected is not None and expected != str(artifact["sha256"]).lower():
                raise ValueError(
                    f"sha256 mismatch for {artifact['filename']}: manifest={artifact['sha256']} checksums-file={expected}"
                )
            remote_artifacts += 1
            continue
        size = path.stat().st_size
        if size != int(artifact["size_bytes"]):
            raise ValueError(f"size mismatch for {path.name}: manifest={artifact['size_bytes']} actual={size}")
        digest = sha256(path)
        if digest != str(artifact["sha256"]).lower():
            raise ValueError(f"sha256 mismatch for {path.name}: manifest={artifact['sha256']} actual={digest}")

    if "dmg" not in seen_kinds:
        raise ValueError("manifest must include a dmg artifact")
    payload["_remote_artifacts"] = remote_artifacts
    return payload


def main() -> None:
    parser = argparse.ArgumentParser(description="Validate a Cortex update manifest against local release artifacts.")
    parser.add_argument("manifest", type=Path)
    parser.add_argument(
        "--allow-remote-artifacts",
        action="store_true",
        help=(
            "Accept artifacts that are not on disk next to the manifest when they point at an https URL "
            "(the published site feed). Their sha256 is cross-checked against the release checksums file "
            "when present. Release-directory validation must NOT use this flag."
        ),
    )
    args = parser.parse_args()
    payload = validate(args.manifest, allow_remote_artifacts=args.allow_remote_artifacts)
    print(
        json.dumps(
            {
                "status": "ok",
                "version": payload["version"],
                "build": payload["build"],
                "artifacts": len(payload["artifacts"]),
                "remote_artifacts": payload.get("_remote_artifacts", 0),
            },
            indent=2,
        )
    )


if __name__ == "__main__":
    main()
