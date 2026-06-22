# Voice + Conversational Agent Plan

A plan for natural-language interaction with the homelab — both ambient voice
control ("turn off the office lights") and a richer self-hosted chat assistant
that can reason over and act on the running services.

## Goals

- Talk or type to control homelab services (lights, media, DNS, cluster status, etc.)
- Keep inference off the Pi cluster (it is too weak for local LLMs) by deferring to **OpenRouter**
- Build one reusable **MCP server** that exposes all homelab tools, not just Home Assistant
- Fit the existing GitOps model: new Helm charts, sealed secrets, nginx ingress, Authentik auth

## Hardware constraint

The Pi4/Pi5 cluster cannot run a useful local LLM (a Pi 5 manages ~2–4 tok/s on a
3B model). The design works around this by running only lightweight pieces locally
(chat UI, STT/TTS, MCP server) and renting the reasoning per-token from OpenRouter.
A local LLM (Ollama) stays an optional future add-on if a GPU box is added.

## Two complementary surfaces

These are not competing — many setups run both and share the same Whisper/Piper containers.

### 1. Ambient voice control — Home Assistant Assist
Hands-free, across-the-room device control. Reuses the existing Home Assistant
instance on `pi4-02`.

| Stage | Component |
|-------|-----------|
| Wake word | openWakeWord |
| Speech-to-text | faster-whisper (Wyoming) |
| Intent / brains | HA built-in intents (instant, local) → optional LLM for fuzzy commands |
| Text-to-speech | Piper (Wyoming) |
| Glue | Wyoming protocol |
| Hardware | HA Voice Preview Edition satellite (~$60) |

Start with HA built-in intents (no LLM, runs fine on existing nodes). They handle
~90% of "turn off the lights" cases instantly and locally.

### 2. Conversational assistant — LibreChat + OpenRouter + custom MCP server
A self-hosted "ChatGPT" you talk or type to, with bigger reasoning, RAG, and the
ability to act on the homelab via tools.

```
  voice/text  ──▶  LibreChat (UI + STT/TTS)  ──▶  OpenRouter (chat model)
                          │
                          └──▶  homelab MCP server  ──▶  HA, Pi-hole, Immich,
                                                          Radarr/Sonarr/Jellyfin,
                                                          Prometheus/Grafana,
                                                          kubectl, backups, ...
```

Split the system by where compute lives:

| Layer | Runs where | Why |
|-------|-----------|-----|
| Chat UI | homelab (container) | Lightweight, no GPU |
| Chat model | **OpenRouter** | Offloaded, pay-per-token |
| STT / TTS | local (NAS) **or** cheap cloud API | OpenRouter does **not** do audio |
| Homelab control | homelab (MCP server) | Local tool execution |

> **Gotcha:** OpenRouter routes text/LLM only. Audio (STT/TTS) is a separate
> decision — local faster-whisper + Piper/Speaches on the NAS, or a cheap cloud
> API (Groq Whisper, OpenAI, ElevenLabs). LibreChat configures chat model, STT,
> and TTS independently in its `speech` block, so the OpenRouter chat path does
> not block voice.

## The centerpiece: a custom homelab MCP server

The MCP server is the valuable, reusable piece. MCP is an open protocol, so the
server is built **once** and any MCP-capable client can drive it — LibreChat,
Open WebUI, Claude Desktop, Claude Code, or a custom agent loop. No need to
hand-roll a chat UI to get a custom server.

- **Language:** Python with the official MCP SDK (FastMCP). TypeScript is an equal alternative.
- **Transport:** Streamable HTTP (networked service in-cluster), not stdio.
- **Tools:** grouped by service; each tool's docstring + type hints are the schema
  the LLM sees — written as "when to call this," not just "what it does."
- **Deployment:** `charts/homelab-mcp` Helm chart in the `default` namespace,
  service tokens as sealed secrets, nginx ingress, behind Authentik (it can do
  destructive actions, so do not expose it unauthenticated).

### Inference wiring options
- **A — LibreChat + OpenRouter (least code, recommended start):** point LibreChat
  at the MCP server and at OpenRouter. No agent-loop code to maintain.
- **B — hand-rolled agent loop:**
  - *Claude (Anthropic API):* native MCP connector — pass the server URL, no manual
    tool bridging. Lowest-friction custom loop.
  - *OpenRouter:* OpenAI-compatible, no MCP connector — run an MCP client in the
    loop and bridge tools to function-calling yourself. Works, just more plumbing.

The MCP server is identical across all of these — that is the payoff.

## Proposed charts

```
charts/wyoming-whisper     # STT (faster-whisper) for HA Assist + LibreChat
charts/wyoming-piper       # TTS (Piper) for HA Assist + LibreChat
charts/homelab-mcp         # the custom MCP server (FastMCP, Streamable HTTP)
charts/librechat           # chat UI + deps; speech block (local Whisper/Piper),
                           #   OPENROUTER_API_KEY (sealed), MCP server wired in
```

STT/TTS containers may instead live on the NAS alongside `docker/` if cluster
headroom is tight.

## Phased rollout

1. **HA Assist, built-in intents** — Whisper + Piper + openWakeWord add-ons, one
   HA Voice satellite. Verify "turn off the lights" end-to-end. No LLM, no cost.
2. **homelab MCP server** — `charts/homelab-mcp` with a first cut of tools
   (Home Assistant + Pi-hole + media stack), sealed secrets, Authentik auth.
3. **LibreChat** — `charts/librechat` with OpenRouter for chat, local Whisper/Piper
   for voice, and the MCP server wired in for tool use.
4. **(Optional) local LLM** — add Ollama (Qwen3 family) only if a GPU box is added,
   for fully-offline reasoning.

## Open decisions

- Which services go in the first MCP cut (suggested: HA + Pi-hole + Radarr/Sonarr/Jellyfin)
- STT/TTS: fully local (NAS) vs cheap cloud API (Groq Whisper) to start
- Whether STT/TTS charts live in-cluster or as NAS `docker/` containers
- Whether to buy an HA Voice Preview Edition satellite or start DIY/ESP32-S3
