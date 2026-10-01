#!/usr/bin/env python3
"""Checks a model catalog (models.json) against its servers, and optionally local copies.

For each file: the URL answers at the pinned revision, and for Hugging Face
the announced size (x-linked-size) and SHA-256 (x-linked-etag) match the
catalog. With --local DIR, files found in DIR are hashed and compared too.
The catalog format itself is validated by the Swift tests (DownloadTests).

    bindings/apple/Catalog/verify-catalog.py [--local DIR] [catalog.json]
"""
import argparse, hashlib, json, os, subprocess, sys


def head(url):
    """Status and headers of the first response (no redirect), with curl."""
    output = subprocess.run(["curl", "-sSI", "--max-time", "30", url], check=True,
                            capture_output=True, text=True).stdout
    lines = output.replace("\r", "").split("\n")
    responses = [i for i, line in enumerate(lines) if line.startswith("HTTP/") and " 200 Connection" not in line]
    first = responses[0]
    status = int(lines[first].split()[1])
    headers = {}
    for line in lines[first + 1:]:
        if not line:
            break
        name, _, value = line.partition(":")
        headers[name.strip().lower()] = value.strip()
    return status, headers


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(8 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("catalog", nargs="?", default=os.path.join(os.path.dirname(__file__), "models.json"))
    parser.add_argument("--local", help="directory holding copies of the files")
    args = parser.parse_args()
    catalog = json.load(open(args.catalog))
    failures = 0
    for model in catalog["models"]:
        files = model["weights"] + ([model["projector"]] if model.get("projector") else [])
        for file in files:
            status, headers = head(file["url"])
            problems = []
            if status not in (200, 302, 307):
                problems.append(f"HTTP {status}")
            if "x-repo-commit" in headers and headers["x-repo-commit"] != model["source"]["revision"]:
                problems.append(f"revision {headers['x-repo-commit']}")
            if "x-linked-size" in headers and int(headers["x-linked-size"]) != file["size"]:
                problems.append(f"size {headers['x-linked-size']}")
            if "x-linked-etag" in headers and headers["x-linked-etag"].strip('"') != file["sha256"]:
                problems.append(f"sha256 {headers['x-linked-etag']}")
            if args.local:
                path = os.path.join(args.local, file["name"])
                if os.path.exists(path):
                    if os.path.getsize(path) != file["size"]:
                        problems.append("local size")
                    elif sha256(path) != file["sha256"]:
                        problems.append("local sha256")
                    else:
                        print(f"  local copy of {file['name']} matches")
            verdict = "OK" if not problems else "FAIL " + ", ".join(problems)
            print(f"{model['id']} {file['name']}: {verdict}")
            failures += bool(problems)
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
