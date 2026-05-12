# AzureLIT SearXNG Configuration
# Rendered by Terraform; do not edit manually.
#
# DESIGN DECISIONS:
# - JSON-only mode (no HTML): designed for API consumption by AI agents
# - Bot detection disabled: server.limiter=false; all requests come from
#   LiteLLM inside the same pod, so bot detection would falsely block us.
# - Favicon fetching disabled: saves bandwidth and CPU for headless API usage
# - Static dummy secret_key: not used for sessions in JSON-only mode;
#   SearXNG requires the key to exist but we don't use cookie-based sessions.
# - Explicit engine whitelist: only engines known to work from Azure
#   datacenter IPs; Google/Startpage/Bing/Yandex are blacklisted due to
#   aggressive CAPTCHA blocking of cloud IP ranges.

general:
  debug: false
  instance_name: "AzureLIT-SearXNG"

use_default_settings: true

search:
  favicon_resolver: ""
  formats:
    - json

server:
  bind_address: "0.0.0.0"
  port: 8080
  limiter: false
  public_instance: false
  secret_key: "azure-lit-dummy-not-used-for-sessions"

# ---------------------------------------------------------------------------
# ENGINE CURATION
# ---------------------------------------------------------------------------
# Strategy: explicit opt-in. Do NOT use use_default_settings:true which
# auto-enables ~125 engines including Google/Bing.
#
# BLOCKED (aggressive CAPTCHA from Azure/cloud IPs):
#   google, startpage, bing, yandex
#
# ENABLED (own index or API-based, cloud-friendly):
#   brave, mojeek, mwmbl, wiby, yep
#
# FALLBACK (moderate block risk, monitor):
#   duckduckgo
#
# SUB-ENGINES (reliable but narrow scope):
#   qwant news/images/videos, wikipedia, wikidata,
#   arxiv, github, stackoverflow, pypi, docker hub
# ---------------------------------------------------------------------------

engines:
  # -- PRIMARY GENERAL-WEB (own index, cloud-safe) --
  - name: brave
    disabled: false
  - name: mojeek
    disabled: false
  - name: mwmbl
    disabled: false
  - name: wiby
    disabled: false
  - name: yep
    disabled: false

  # -- FALLBACK --
  - name: duckduckgo
    disabled: false

  # -- QWANT SUB-ENGINES (EU-friendly; main qwant web disabled upstream) --
  - name: qwant news
    disabled: false
  - name: qwant images
    disabled: false
  - name: qwant videos
    disabled: false

  # -- KNOWLEDGE / DEVELOPER (API-based, never blocks) --
  - name: wikipedia
    disabled: false
  - name: wikidata
    disabled: false
  - name: arxiv
    disabled: false
  - name: github
    disabled: false
  - name: stackoverflow
    disabled: false
  - name: pypi
    disabled: false
  - name: docker hub
    disabled: false

  # -- EXPLICITLY DISABLED (high CAPTCHA risk from cloud IPs) --
  - name: google
    disabled: true
  - name: google images
    disabled: true
  - name: google news
    disabled: true
  - name: google videos
    disabled: true
  - name: google scholar
    disabled: true
  - name: startpage
    disabled: true
  - name: startpage news
    disabled: true
  - name: startpage images
    disabled: true
  - name: bing
    disabled: true
  - name: bing images
    disabled: true
  - name: bing news
    disabled: true
  - name: bing videos
    disabled: true
  - name: yandex
    disabled: true
  - name: yandex images
    disabled: true
