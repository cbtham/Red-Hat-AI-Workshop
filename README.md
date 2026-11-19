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
| `ENVIRONMENT-SETUP.md` | Instructor guide: order the RHDP cluster, size it for your number of attendees, run the setup script, dry run, clean up |
| `manifests/open-webui.yaml` | Open WebUI v0.9.0, deployed by participants in Part 7 |
| `samples/acme-handbook.txt` | Sample document for the RAG exercises |
| `show-urls.sh` | Prints the Open WebUI URL, MaaS base URL and model ID for your project |
| `manifests/instructor/setup-workshop.sh` | One-command cluster setup for any number of attendees, plus `--check` (read-only status and attendee handout) and `--cleanup` |
| `manifests/instructor/` | The pieces the setup script applies (inference gateway, Web Terminal operator and per-attendee terminals, shared OpenShift MCP Server, premium subscription placeholder, Open WebUI dashboard tiles, model image pre-pull) |
| `manifests/mcp-server.yaml` | Per-project MCP server (reference only, not used in the current flow) |
| `manifests/llamastack.yaml` | LlamaStack deployment (reference only, not used in the current flow) |
| `images/` | Screenshots for the guide (`images/maas/` for the current flow) |

## Workshop Flow

1. **Access** OpenShift AI and **create** your project `userN`
2. **Deploy** gemma-4-E4B-it from your project's Deployments tab (LLM inference service, single node, `gpu-profile`, AI asset endpoint)
3. **Playground:** chat, MCP tool calling with the OpenShift MCP Server, and RAG
4. **Publish as MaaS:** edit the deployment to turn on MaaS, then create `basic subscription userN` (10,000 tokens per minute) for your model
5. **API keys and the Playground:** create an `sk-oai-` API key and reconnect the Playground through MaaS
6. **Open WebUI:** connect to the MaaS endpoint with your API key, chat and RAG
7. **Observability** (optional instructor demo)

## Tech Stack

- OpenShift 4.20+ and RHOAI 3.5.x with Models-as-a-Service (validated on OCP 4.22 and RHOAI 3.5.3)
- gemma-4-E4B-it (`registry.redhat.io/rhai/modelcar-redhatai-gemma-4-e4b-it:3.0`) on vLLM with tool calling (`gemma4` parser)
- LLM inference service (LLMInferenceService), one GPU per participant
- Open WebUI v0.9.0
- OpenShift MCP Server (shared, set up by the instructor)

## Instructor Setup

Follow **[ENVIRONMENT-SETUP.md](ENVIRONMENT-SETUP.md)**. Order the cluster on the Red Hat Demo Platform, then run one script from your laptop:

```bash
bash manifests/instructor/setup-workshop.sh --check        # read-only: what's ready, what's missing
bash manifests/instructor/setup-workshop.sh --users 20     # set up for user1..user20
```

It works for any number of attendees, as long as the cluster can get one GPU node per attendee. It reuses the platform scripts from [rhoai-field-source-setup-guide](https://github.com/jingggg-wenn/rhoai-field-source-setup-guide), pinned and checksum-verified. **Appendix A** of the workshop guide explains each piece and how to do it by hand.
