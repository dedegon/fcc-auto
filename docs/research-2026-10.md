# Research Report: NVIDIA NIM, OpenRouter, FCC Uninstall, Agnes AI

**Date:** 2026-10-31  
**Project:** claude-auto (fcc-auto-1.0.3)  
**Scope:** Research only — no code changes, no installations, no API calls with keys

---

## 1. NVIDIA NIM Free Tier Models

### Summary from Official & Aggregated Sources

| Model (Display) | Model ID (API) | Context Window | Rate Limit (Free Tier) | Source |
|-----------------|----------------|----------------|------------------------|--------|
| DeepSeek-V4-Pro | `deepseek/deepseek-v4-pro` | 1,000,000 tokens | ~40 RPM (request increase to 200 RPM via support) | [klymentiev.com](https://klymentiev.com/blog/nvidia-nim-free-credits) |
| DeepSeek-V4-Flash | `deepseek/deepseek-v4-flash` | 1,000,000 tokens | ~40 RPM | [klymentiev.com](https://klymentiev.com/blog/nvidia-nim-free-credits) |
| Nemotron 3 Ultra | `nvidia/nemotron-3-ultra-550b-a55b` | 1,000,000 tokens | ~40 RPM | [klymentiev.com](https://klymentiev.com/blog/nvidia-nim-free-credits) |
| GLM-5 / GLM-5.1 | `glm-5` / `zai/glm-5.1` | Model-dependent (not specified) | ~40 RPM | [freeinference.dev](https://freeinference.dev/providers/nvidia-nim--build-nvidia-com/) |
| Kimi K2.5 | `kimi-2.5` / `moonshot/kimi-k2.5` | Model-dependent (not specified) | ~40 RPM | [freeinference.dev](https://freeinference.dev/providers/nvidia-nim--build-nvidia-com/) |
| Llama 3.3 70B Instruct | `meta/llama-3.3-70b-instruct` | Not found in sources | ~40 RPM | [klymentiev.com](https://klymentiev.com/blog/nvidia-nim-free-credits) |
| Qwen 3.5 variants | Various `qwen/*` | Not found in sources | ~40 RPM | [klymentiev.com](https://klymentiev.com/blog/nvidia-nim-free-credits) |
| Mistral variants | Various `mistral/*` | Not found in sources | ~40 RPM | [klymentiev.com](https://klymentiev.com/blog/nvidia-nim-free-credits) |
| Microsoft Phi variants | Various `microsoft/*` | Not found in sources | ~40 RPM | [klymentiev.com](https://klymentiev.com/blog/nvidia-nim-free-credits) |

### Key Details

- **API Endpoint:** `https://integrate.api.nvidia.com/v1` (OpenAI-compatible)
- **Credit System:** ~1,000 trial credits at signup (up to ~5,000); 1 credit ≈ 1 API call on standard request
- **Rate Limit:** ~40 RPM on free tier; can request increase to 200 RPM via support ticket (no self-service toggle)
- **Models Listed on build.nvidia.com:** 3 primary free models (GLM-5, Kimi-2.5, NIM-packaged open models) per freeinference.dev, but klymentiev.com lists many more

### `/v1/models` Endpoint — `context_length` Field

**Not documented in official NVIDIA API reference.**  
- The [NVIDIA NIM LLM API Reference](https://docs.nvidia.com/nim/large-language-models/latest/reference/api-reference.html) describes `/v1/models` as "List models currently loaded and available for inference" but does **not** specify the response schema or field structure.  
- It directs users to "the interactive OpenAPI explorer at `/docs` on the running container" for "full request/response schemas."  
- The [LLM APIs reference](https://docs.api.nvidia.com/nim/reference/llm-apis) documents only `POST /v1/chat/completions` and individual model endpoints, not `/v1/models`.

**Conclusion:** No official documentation confirms a `context_length` field in `/v1/models` response. Field existence is **not confirmed**.

---

## 2. OpenRouter Free Models & API

### `/api/v1/models` Response Fields (from [OpenRouter API Reference](https://openrouter.ai/docs/api/api-reference/models/list-all-models-and-their-properties))

| Field | Type | Description |
|-------|------|-------------|
| `context_length` | integer (nullable) | Maximum context length in tokens (e.g., `8192`) |
| `pricing` | PublicPricing object | Required: `prompt`, `completion` (USD per token). Additional: `request`, `image`, `image_output`, `audio`, `audio_output`, `image_token`, `input_cache_read`, `input_cache_write`, `input_cache_write_1h`, `input_audio_cache`, `internal_reasoning`, `web_search`, `discount`, `overrides` |
| `supported_parameters` | array of enum | Includes: `temperature`, `top_p`, `top_k`, `min_p`, `top_a`, `frequency_penalty`, `presence_penalty`, `repetition_penalty`, `max_tokens`, `max_completion_tokens`, `logit_bias`, `logprobs`, `top_logprobs`, `prediction`, `seed`, `response_format`, `structured_outputs`, `stop`, **`tools`**, **`tool_choice`**, **`parallel_tool_calls`**, `include_reasoning`, `reasoning`, `reasoning_effort`, `web_search_options`, `verbosity` |

### Tool / Function Calling Support

**Indicators in `supported_parameters`:**
- Presence of `tools`, `tool_choice`, `parallel_tool_calls` → model supports function calling
- Query parameters `min_tool_success_rate` / `max_tool_success_rate` filter by "tool-calling success rate, as a fraction in [0, 1] (e.g. 0.9 = 90% of requests finishing with a tool_calls finish reason)"

### Free Models (`:free` suffix) — from [costgoat.com](https://costgoat.com/pricing/openrouter-free-models)

| Model ID | Context | Features |
|----------|---------|----------|
| `google/gemma-4-26b-a4b-it:free` | 262K | vision + tools |
| `google/gemma-4-31b-it:free` | 262K | vision + tools |
| `nvidia/nemotron-3.5-super-vl:free` | 1.0M | vision + tools |
| `thinkingmachines/inkling-small:free` | 1.0M | vision + tools + reasoning |
| `nvidia/nemotron-3.5-lightning:free` | 1.0M | tools |
| `thinkingmachines/inkling:free` | 1.0M | vision + tools + reasoning |
| `nvidia/nemotron-3-ultra-550b-a55b:free` | 1.0M | tools |
| +10 more (Cohere, LiquidAI, dots-studio, recursive, xingchen-agi, poolside, OpenRouter) | various | various |

### Rate Limits for Free Models

- **20 Requests / minute** (per model)
- **200 Requests / day** (per model)
- **$0 — No credit card needed**
- Limits apply **per-model**

### Lifting Daily Limits

> "If you hit rate limits, you can add credits to your OpenRouter account for higher throughput with paid model variants"  
> "For higher throughput, you can add credits to your account or use paid model variants"  
> Free models "may be removed or have limits adjusted without notice"  
> — [costgoat.com](https://costgoat.com/pricing/openrouter-free-models)

**No documented automatic limit increase based on account balance alone** — adding credits enables paid model variants with higher limits, but free model limits remain as stated.

---

## 3. FCC (Free Claude Code) Official Uninstallation

### Sources
- [uninstall.sh](https://raw.githubusercontent.com/Alishahryar1/free-claude-code/main/scripts/uninstall.sh) (Linux/macOS)
- [uninstall.ps1](https://raw.githubusercontent.com/Alishahryar1/free-claude-code/main/scripts/uninstall.ps1) (Windows)
- [Issue #755](https://github.com/Alishahryar1/free-claude-code/issues/755) / [Issue #2103](https://github.com/Alishahryar1/free-claude-code/issues/2103)

### Numbered Uninstallation Steps

1. **Run integration disconnect**  
   `fcc-doctor --disconnect-integrations` (unless `-KeepIntegrations` specified) — removes editor/app integrations

2. **Remove uv tool package**  
   `uv tool uninstall free-claude-code`

3. **Delete FCC binaries from uv tool bin directory**  
   The following entry points are removed (extensions: `.exe`, `.cmd`, `.bat`, `.ps1` on Windows):
   - `fcc-desktop`
   - `fcc-server`
   - `fcc-claude`
   - `fcc-codex`
   - `fcc-pi`
   - `fcc-opencode`
   - `fcc-cline`
   - `fcc-hermes`
   - `fcc-dsh`
   - `fcc-grok`
   - `fcc-muse`
   - `fcc-aider`
   - `fcc-agy`
   - `fcc-doctor`
   - `fcc-update`
   - `fcc-init`
   - `free-claude-code`
   - `fcc-update.cmd` (Windows)

4. **Purge configuration folder**  
   - Linux/macOS: `~/.fcc` (`$HOME/$FCC_HOME_DIRNAME`)
   - Windows: `%USERPROFILE%\.fcc` (`$env:USERPROFILE\.fcc`)
   - Removed with `Remove-Item -Recurse -Force` / `rm -rf`

5. **Remove shortcuts (Windows)**  
   - `%USERPROFILE%\Desktop\Free Claude Code.lnk`
   - `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Free Claude Code.lnk`
   - Only removed if they target FCC binaries

6. **Remove macOS app bundles (macOS only)**  
   - `~/Applications/Free Claude Code.app`
   - `~/Desktop/Free Claude Code.app` (symlink)

### What is **NOT** Removed (Explicitly Preserved)

- `uv` itself
- Claude Code, Codex, Pi, OpenCode, Cline, Hermes Agent, DeepSeek Harness, Grok Build, Muse Code, Aider, Antigravity CLI
- uv-managed Python runtime
- Shared PATH entries (script *adds* known uv paths to locate `uv` but does **not** remove any PATH entries)

---

## 4. Agnes AI API

### Official Documentation Sources
- [Overview](https://wiki.agnes-ai.com/en/docs/overview)
- [Quickstart](https://wiki.agnes-ai.com/en/docs/quickstart)
- [GitHub: AgnesAI-Labs/AgnesAI-Models](https://github.com/AgnesAI-Labs/AgnesAI-Models)
- [models.dev provider page](https://models.dev/providers/agnes/)

### API Configuration

| Property | Value |
|----------|-------|
| **Base URL** | `https://apihub.agnes-ai.com/v1` |
| **Authentication** | `Authorization: Bearer YOUR_API_KEY` (Bearer token in header) |
| **Chat Completions** | `POST /v1/chat/completions` |
| **Model Listing** | **Not documented** in official docs; models listed in `MODEL_CATALOG.md` (GitHub) |

### Known Models (from models.dev & GitHub)

| Model ID | Pricing (Input/Output) | Notes |
|----------|------------------------|-------|
| `agnes-2.0-flash` | $0.00 / $0.00 | Free tier |
| `agnes-2.5-flash` | $0.00 / $0.00 | Free tier |
| `agnes-3.0-flash` | $0.00 / $0.00 | Free tier |
| `agnes-2.5-pro-alpha` | $0.45 / $0.90 | Paid |

### Free Tier Limits (from GitHub)

| Category | Limit |
|----------|-------|
| Text models | 20 actual RPM |
| Image models | Resolution-specific RPM limits |
| Video models | 1 actual RPM |
| Quotas published | Base Token Plan: 2026-06-22; Video RPM updated: 2026-06-28 |

**Note:** No explicit "daily limit" documented; limits expressed as RPM (requests per minute).

---

## 5. Not Confirmed & Contradictions

| Topic | Status | Details |
|-------|--------|---------|
| NVIDIA `/v1/models` includes `context_length` | **Not confirmed** | Official API reference does not document response schema; directs to container's `/docs` OpenAPI explorer |
| NVIDIA free tier model list (exact count) | **Contradiction** | freeinference.dev: "3 models" (GLM-5, Kimi-2.5, NIM-packaged open models); klymentiev.com: 10+ models including DeepSeek-V4, Nemotron 3, Llama 3.3, Qwen 3.5, Mistral, Phi |
| NVIDIA context window for GLM-5 / Kimi-2.5 | **Not found** | Sources say "model-dependent" but give no numbers |
| OpenRouter `:free` model limit lifting via balance | **Not confirmed** | Docs only mention "add credits for paid variants" — no automatic free-tier limit increase |
| Agnes AI `/v1/models` endpoint | **Not documented** | No official docs mention a model listing endpoint; only chat completions documented |
| Agnes AI free tier daily/monthly quota | **Not found** | Only RPM limits documented |

---

## 6. What Needs User Action (Data Unavailable Without)

| Data Needed | Requires |
|-------------|----------|
| Exact NVIDIA `/v1/models` response schema (incl. `context_length` field) | Running a NVIDIA NIM container locally and checking `/docs` OpenAPI explorer, OR making an API call with a valid key |
| Complete list of NVIDIA free-tier model IDs with verified context windows | API call to `https://integrate.api.nvidia.com/v1/models` with valid key |
| Agnes AI model listing endpoint existence & response format | API call to `https://apihub.agnes-ai.com/v1/models` with valid key, OR finding undocumented endpoint |
| OpenRouter free model `:free` suffix behavior in API (pricing = "0" vs separate field) | API call to `https://openrouter.ai/api/v1/models` with valid key |
| Real-time rate limit headers (x-ratelimit-*) from any provider | Live API calls with keys |

---

## Source Index

1. **NVIDIA NIM Free Tier** — [klymentiev.com/blog/nvidia-nim-free-credits](https://klymentiev.com/blog/nvidia-nim-free-credits)
2. **NVIDIA NIM Free Tier (alt)** — [freeinference.dev/providers/nvidia-nim--build-nvidia-com/](https://freeinference.dev/providers/nvidia-nim--build-nvidia-com/)
3. **NVIDIA NIM API Reference** — [docs.nvidia.com/nim/large-language-models/latest/reference/api-reference.html](https://docs.nvidia.com/nim/large-language-models/latest/reference/api-reference.html)
4. **NVIDIA LLM APIs** — [docs.api.nvidia.com/nim/reference/llm-apis](https://docs.api.nvidia.com/nim/reference/llm-apis)
5. **OpenRouter Models API** — [openrouter.ai/docs/api/api-reference/models/list-all-models-and-their-properties](https://openrouter.ai/docs/api/api-reference/models/list-all-models-and-their-properties)
6. **OpenRouter Free Models** — [costgoat.com/pricing/openrouter-free-models](https://costgoat.com/pricing/openrouter-free-models)
7. **FCC uninstall.sh** — [raw.githubusercontent.com/Alishahryar1/free-claude-code/main/scripts/uninstall.sh](https://raw.githubusercontent.com/Alishahryar1/free-claude-code/main/scripts/uninstall.sh)
8. **FCC uninstall.ps1** — [raw.githubusercontent.com/Alishahryar1/free-claude-code/main/scripts/uninstall.ps1](https://raw.githubusercontent.com/Alishahryar1/free-claude-code/main/scripts/uninstall.ps1)
9. **FCC Issue #755** — [github.com/Alishahryar1/free-claude-code/issues/755](https://github.com/Alishahryar1/free-claude-code/issues/755)
10. **Agnes AI Overview** — [wiki.agnes-ai.com/en/docs/overview](https://wiki.agnes-ai.com/en/docs/overview)
11. **Agnes AI Quickstart** — [wiki.agnes-ai.com/en/docs/quickstart](https://wiki.agnes-ai.com/en/docs/quickstart)
12. **Agnes AI GitHub** — [github.com/AgnesAI-Labs/AgnesAI-Models](https://github.com/AgnesAI-Labs/AgnesAI-Models)
13. **Agnes AI models.dev** — [models.dev/providers/agnes/](https://models.dev/providers/agnes/)