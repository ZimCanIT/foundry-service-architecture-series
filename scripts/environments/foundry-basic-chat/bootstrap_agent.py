#!/usr/bin/env python3
"""Create a named prompt agent and save its returned version for Terraform."""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import subprocess
import sys

from azure.ai.projects import AIProjectClient
from azure.ai.projects.models import (
    AISearchIndexResource,
    AzureAISearchQueryType,
    AzureAISearchTool,
    AzureAISearchToolResource,
    BingGroundingSearchConfiguration,
    BingGroundingSearchToolParameters,
    BingGroundingTool,
    PromptAgentDefinition,
)
from azure.identity import AzureCliCredential


def terraform_output(name: str) -> str:
    result = subprocess.run(
        ["terraform", "output", "-raw", name],
        check=True,
        capture_output=True,
        text=True,
    )
    return result.stdout.strip()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--endpoint", help="Foundry project endpoint (defaults to Terraform output)")
    parser.add_argument("--search-connection", default="azure-ai-search")
    parser.add_argument("--bing-connection", default="bing-grounding")
    parser.add_argument("--search-index", default="foundry-series-1")
    parser.add_argument("--agent-name", default="baseline-chatbot-agent")
    parser.add_argument("--model", default="agent-model")
    parser.add_argument(
        "--tfvars-output",
        default="agent.auto.tfvars.json",
        help="Ignored Terraform variable file written with the returned agent version",
    )
    args = parser.parse_args()

    endpoint = args.endpoint or terraform_output("foundry_project_endpoint")
    client = AIProjectClient(endpoint=endpoint, credential=AzureCliCredential())
    search_connection = client.connections.get(args.search_connection)
    bing_connection = client.connections.get(args.bing_connection)

    search_tool = AzureAISearchTool(
        azure_ai_search=AzureAISearchToolResource(
            indexes=[
                AISearchIndexResource(
                    project_connection_id=search_connection.id,
                    index_name=args.search_index,
                    query_type=AzureAISearchQueryType.SIMPLE,
                )
            ]
        )
    )
    bing_tool = BingGroundingTool(
        bing_grounding=BingGroundingSearchToolParameters(
            search_configurations=[
                BingGroundingSearchConfiguration(project_connection_id=bing_connection.id)
            ]
        )
    )
    agent = client.agents.create_version(
        agent_name=args.agent_name,
        definition=PromptAgentDefinition(
            model=args.model,
            instructions=(
                "Answer clearly and distinguish retrieved evidence from general knowledge. "
                "Use Azure AI Search for questions about the supplied reference material and "
                "cite its sources. Use Bing grounding for current public information. "
                "If the Search fixture is relevant, preserve its exact marker in your answer."
            ),
            tools=[search_tool, bing_tool],
        ),
        description="Series 1 basic Microsoft Foundry chat proof of concept.",
    )

    if not agent.name or not agent.version:
        raise RuntimeError("Foundry did not return both the agent name and version.")

    output_path = pathlib.Path(args.tfvars_output)
    output_path.write_text(
        json.dumps({"agent_name": agent.name, "agent_version": str(agent.version)}, indent=2)
        + "\n",
        encoding="utf-8",
    )
    os.chmod(output_path, 0o600)
    print(f"Created agent {agent.name}, version {agent.version}.")
    print(f"Saved its exact returned version to {output_path}.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, subprocess.CalledProcessError, RuntimeError) as error:
        print(f"Agent bootstrap failed: {error}", file=sys.stderr)
        raise SystemExit(1)
