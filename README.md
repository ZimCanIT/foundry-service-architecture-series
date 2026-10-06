# Foundry Service Architecture Series

## Introduction

This repository contains environment-based reference deployments for the ZimCanIT YouTube series on Microsoft Foundry as a service in Azure. It begins with the basic chat proof of concept and progresses through Foundry Agent Service, hosted agents and further production architecture topics.

## Local MCP tools

The workspace MCP configuration connects to Microsoft Learn's hosted documentation server and a local HashiCorp Terraform MCP server. Start the Terraform server from the repository root with Docker Compose. These examples use `sudo` for hosts where the current user does not have direct access to the Docker daemon; omit it if your account has that access.

```bash
sudo docker compose -f compose.mcp.yaml up -d
```

Expected output:

```text
[+] Running 2/2
 ✔ Network foundry-service-architecture-series_default  Created      0.0s
 ✔ Container terraform-mcp-server                       Started      0.2s
```

Check that the container is running:

```bash
sudo docker compose -f compose.mcp.yaml ps
```

Expected output:

```text
NAME                   IMAGE                                  COMMAND                  SERVICE         CREATED         STATUS         PORTS
terraform-mcp-server   hashicorp/terraform-mcp-server:1.3.0   "/bin/terraform-mcp-…"   terraform-mcp   7 seconds ago   Up 6 seconds   127.0.0.1:8080->8080/tcp
```

Check the HTTP health endpoint:

```bash
curl -fsS http://127.0.0.1:8080/health
```

Expected output:

```json
{"status":"ok","service":"terraform-mcp-server","transport":"streamable-http","endpoint":"/mcp","version":"1.3.0"}
```

The MCP endpoint is bound to loopback at `http://127.0.0.1:8080/mcp`. Stop the server with:

```bash
sudo docker compose -f compose.mcp.yaml down
```
