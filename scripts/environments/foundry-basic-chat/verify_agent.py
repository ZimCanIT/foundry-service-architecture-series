#!/usr/bin/env python3
"""Verify the named Foundry agent's Search and Bing grounding through Responses."""

from __future__ import annotations

import argparse
import subprocess
import sys
from urllib.parse import urlparse

from azure.ai.projects import AIProjectClient
from azure.identity import AzureCliCredential

FIXTURE_MARKER = "ZIMCANIT-FOUNDRY-SERIES-1-58274"
FIXTURE_HOST = "example.org"
FIXTURE_PATH = "/series-1-synthetic-fixture"


def terraform_output(name: str) -> str:
    result = subprocess.run(
        ["terraform", "output", "-raw", name],
        check=True,
        capture_output=True,
        text=True,
    )
    return result.stdout.strip()


def response_citations(response: object) -> list[str]:
    citations: list[str] = []
    for item in getattr(response, "output", []):
        if getattr(item, "type", None) != "message":
            continue
        for content in getattr(item, "content", []):
            if getattr(content, "type", None) != "output_text":
                continue
            for annotation in getattr(content, "annotations", []) or []:
                if getattr(annotation, "type", None) == "url_citation":
                    url = getattr(annotation, "url", None)
                    if url:
                        citations.append(url)
    return citations


def response_conversation_id(response: object) -> str | None:
    conversation = getattr(response, "conversation", None)
    if isinstance(conversation, str):
        return conversation
    return getattr(conversation, "id", None)


def require_conversation(response: object, expected_id: str, label: str) -> None:
    actual_id = response_conversation_id(response)
    if actual_id != expected_id:
        raise RuntimeError(
            f"{label} response did not retain the requested conversation ID."
        )


def require_completed(response: object, label: str) -> None:
    status = getattr(response, "status", None)
    if status != "completed":
        raise RuntimeError(f"{label} response did not complete (status: {status}).")


def is_fixture_citation(url: str) -> bool:
    parsed = urlparse(url)
    return (
        parsed.scheme == "https"
        and parsed.hostname == FIXTURE_HOST
        and parsed.path.rstrip("/") == FIXTURE_PATH
    )


def is_external_https_citation(url: str) -> bool:
    parsed = urlparse(url)
    return parsed.scheme == "https" and bool(parsed.hostname) and not is_fixture_citation(url)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--endpoint", help="Foundry project endpoint (defaults to Terraform output)"
    )
    parser.add_argument(
        "--agent-name", help="Agent name (defaults to Terraform output)"
    )
    parser.add_argument(
        "--agent-version", help="Exact agent version (defaults to Terraform output)"
    )
    args = parser.parse_args()

    endpoint = args.endpoint or terraform_output("foundry_project_endpoint")
    agent_name = args.agent_name or terraform_output("agent_name")
    agent_version = args.agent_version or terraform_output("agent_version")
    if not agent_name or not agent_version or agent_version == "pending":
        raise RuntimeError(
            "Terraform must reference the exact created agent name and version before verification."
        )

    credential = AzureCliCredential()
    project = AIProjectClient(endpoint=endpoint, credential=credential)
    openai = project.get_openai_client()
    conversation = openai.conversations.create()
    agent_reference = {
        "name": agent_name,
        "version": agent_version,
        "type": "agent_reference",
    }

    search_response = openai.responses.create(
        conversation=conversation.id,
        input=(
            "From the Azure AI Search reference material, what exact marker is in the "
            "Series 1 synthetic fixture? Return the marker verbatim and cite the source."
        ),
        tool_choice="required",
        extra_body={"agent_reference": agent_reference},
    )
    require_completed(search_response, "Search")
    require_conversation(search_response, conversation.id, "Search")
    search_answer = search_response.output_text or ""
    search_citations = response_citations(search_response)
    if FIXTURE_MARKER not in search_answer:
        raise RuntimeError("The Search-grounded response omitted the unique fixture marker.")
    if not any(is_fixture_citation(url) for url in search_citations):
        raise RuntimeError(
            "The Search-grounded response did not cite the synthetic fixture URL."
        )

    print(
        f"Search verified: response {search_response.id}, "
        f"conversation {conversation.id}."
    )
    print(f"Search citation: {next(url for url in search_citations if is_fixture_citation(url))}")

    bing_response = openai.responses.create(
        conversation=conversation.id,
        input=(
            "Use current public web search to find today's weather forecast for Stockholm, "
            "Sweden. Summarise it briefly and cite at least one source URL. Do not use the "
            "synthetic Azure AI Search fixture for this question."
        ),
        tool_choice="required",
        extra_body={"agent_reference": agent_reference},
    )
    require_completed(bing_response, "Bing")
    require_conversation(bing_response, conversation.id, "Bing")
    bing_citations = response_citations(bing_response)
    external_citations = [url for url in bing_citations if is_external_https_citation(url)]
    if not external_citations:
        raise RuntimeError(
            "The Bing-grounded response did not include an external source citation."
        )

    print(
        f"Bing verified: response {bing_response.id}, "
        f"conversation {conversation.id}."
    )
    for url in external_citations:
        print(f"Bing citation: {url}")
    print(f"Verified exact agent reference: {agent_name}, version {agent_version}.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, subprocess.CalledProcessError, RuntimeError) as error:
        print(f"Agent verification failed: {error}", file=sys.stderr)
        raise SystemExit(1)
