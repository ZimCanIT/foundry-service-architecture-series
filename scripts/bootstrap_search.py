#!/usr/bin/env python3
"""Create a small text index and upload a synthetic grounding fixture."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

API_VERSION = "2025-09-01"
FIXTURE_ID = "series-1-fixture"
FIXTURE_MARKER = "ZIMCANIT-FOUNDRY-SERIES-1-58274"


def get_search_token() -> str:
    result = subprocess.run(
        [
            "az",
            "account",
            "get-access-token",
            "--scope",
            "https://search.azure.com/.default",
            "--query",
            "accessToken",
            "--output",
            "tsv",
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    return result.stdout.strip()


def request_json(url: str, token: str, method: str, payload: dict) -> dict:
    for attempt in range(9):
        request = urllib.request.Request(
            url,
            data=json.dumps(payload).encode("utf-8"),
            headers={
                "Authorization": f"Bearer {token}",
                "Content-Type": "application/json",
            },
            method=method,
        )
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                body = response.read()
                return json.loads(body) if body else {}
        except urllib.error.HTTPError as error:
            detail = error.read().decode("utf-8", errors="replace")
            if error.code not in (401, 403) or attempt == 8:
                raise RuntimeError(
                    f"Azure AI Search returned HTTP {error.code}: {detail}"
                ) from error
            time.sleep(min(2 ** attempt, 30))
            token = get_search_token()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--endpoint", required=True, help="Search service endpoint")
    parser.add_argument("--index", default="foundry-series-1", help="Index name")
    args = parser.parse_args()

    endpoint = args.endpoint.rstrip("/")
    index_name = urllib.parse.quote(args.index, safe="")
    token = get_search_token()
    index_url = f"{endpoint}/indexes('{index_name}')?api-version={API_VERSION}"
    index_definition = {
        "name": args.index,
        "fields": [
            {"name": "id", "type": "Edm.String", "key": True, "filterable": True},
            {
                "name": "title",
                "type": "Edm.String",
                "searchable": True,
                "retrievable": True,
            },
            {
                "name": "content",
                "type": "Edm.String",
                "searchable": True,
                "retrievable": True,
            },
            {"name": "url", "type": "Edm.String", "retrievable": True},
            {
                "name": "contentVector",
                "type": "Collection(Edm.Single)",
                "searchable": True,
                "retrievable": False,
                "dimensions": 3,
                "vectorSearchProfile": "series-1-vector-profile",
            },
        ],
        "vectorSearch": {
            "algorithms": [{"name": "series-1-hnsw", "kind": "hnsw"}],
            "profiles": [
                {"name": "series-1-vector-profile", "algorithm": "series-1-hnsw"}
            ],
        },
    }
    request_json(index_url, token, "PUT", index_definition)
    print(f"Created or updated index {args.index}.")

    documents_url = f"{endpoint}/indexes('{index_name}')/docs/index?api-version={API_VERSION}"
    upload = request_json(
        documents_url,
        token,
        "POST",
        {
            "value": [
                {
                    "@search.action": "mergeOrUpload",
                    "id": FIXTURE_ID,
                    "title": "Series 1 synthetic architecture fixture",
                    "content": (
                        f"This synthetic test record contains marker {FIXTURE_MARKER}. "
                        "It exists only to verify the Foundry chat proof of concept "
                        "can retrieve text from Azure AI Search."
                    ),
                    "url": "https://example.org/series-1-synthetic-fixture",
                }
            ]
        },
    )
    if (
        not upload.get("value")
        or not upload["value"][0].get("status")
        or upload["value"][0].get("errorMessage")
    ):
        raise RuntimeError("Azure AI Search did not confirm the fixture upload.")

    search_url = f"{endpoint}/indexes('{index_name}')/docs/search?api-version={API_VERSION}"
    query = {"search": FIXTURE_MARKER, "select": "id,title,content,url", "top": 1}
    for attempt in range(6):
        result = request_json(search_url, token, "POST", query)
        matches = result.get("value", [])
        if matches and FIXTURE_MARKER in matches[0].get("content", ""):
            print(f"Verified Search fixture {FIXTURE_ID} with marker {FIXTURE_MARKER}.")
            return 0
        if attempt < 5:
            time.sleep(min(2 ** attempt, 15))

    raise RuntimeError("The uploaded Search fixture was not returned by the verification query.")


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, subprocess.CalledProcessError, RuntimeError) as error:
        print(f"Search bootstrap failed: {error}", file=sys.stderr)
        raise SystemExit(1)
