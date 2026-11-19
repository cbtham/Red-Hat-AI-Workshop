# Red Hat OpenShift AI: Model Deployment and Models-as-a-Service Workshop

A hands-on workshop (about 2 hours) on Red Hat OpenShift AI (RHOAI) 3.5. Participants create their own project, deploy gemma-4-E4B-it in it, try it in the AI Playground (chat, MCP tool calling, RAG), publish it as Models-as-a-Service (MaaS) with a subscription and an API key, and then connect Open WebUI to the MaaS endpoint.

## Quick Start

Participants follow the guide in the OpenShift AI dashboard first. In Part 7 they clone this repo in the OpenShift Web Terminal:

```bash
git clone -b rhoai-3.5-maas-workshop https://github.com/cbtham/Red-Hat-AI-Workshop.git
cd Red-Hat-AI-Workshop
```

See [RHOAI-MODEL-DEPLOYMENT-WORKSHOP.md](RHOAI-MODEL-DEPLOYMENT-WORKSHOP.md) for the full workshop guide.

## What's in This Repo

| File | Purpose |
|------|---------|
| `RHOAI-MODEL-DEPLOYMENT-WORKSHOP.md` | Workshop guide (8 parts + instructor checklist in Appendix A) |
| `manifests/open-webui.yaml` | Open WebUI v0.9.0, deployed by participants in Part 7 |
| `samples/acme-handbook.txt` | Sample document for the RAG exercises |
| `show-urls.sh` | Prints the Open WebUI URL, MaaS base URL and model ID for your project |
| `manifests/instructor/` | Cluster setup used by the instructor (inference gateway, Web Terminal operator and per-attendee terminals, shared OpenShift MCP Server, premium subscription placeholder, Open WebUI dashboard tiles) |
| `manifests/mcp-server.yaml` | Per-project MCP server (reference only, not used in the current flow) |
| `manifests/llamastack.yaml` | LlamaStack deployment (reference only, not used in the current flow) |
| `images/` | Screenshots for the guide (`images/maas/` for the current flow) |

## Workshop Flow

1. **Access** OpenShift AI and **create** your project `userN`
2. **Deploy** gemma-4-E4B-it from your project's Deployments tab (LLM inference service, single node, `gpu-profile`, AI asset endpoint)
3. **Playground:** chat, MCP tool calling with the OpenShift MCP Server, and RAG
4. **Publish as MaaS:** edit the deployment and turn on MaaS
5. **Subscriptions and API keys:** create `basic subscription userN` (10,000 tokens per minute) and an `sk-oai-` API key
6. **Open WebUI:** connect to the MaaS endpoint with your API key, chat and RAG
7. **Observability** (optional instructor demo)

## Tech Stack

- OpenShift 4.20+ and RHOAI 3.5.x with Models-as-a-Service (validated on OCP 4.22 and RHOAI 3.5.3)
- gemma-4-E4B-it (`registry.redhat.io/rhai/modelcar-redhatai-gemma-4-e4b-it:3.0`) on vLLM with tool calling (`gemma4` parser)
- LLM inference service (LLMInferenceService), one GPU per participant
- Open WebUI v0.9.0
- OpenShift MCP Server (shared, set up by the instructor)

## Instructor Setup

Follow **Appendix A: Instructor Setup Checklist** in the workshop guide. The [RHOAI Toolkit](https://github.com/gymnatics/RHOAI-Toolkit) can install the cluster; install it with RHCL and MaaS enabled.
