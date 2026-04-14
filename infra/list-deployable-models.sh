#!/usr/bin/env bash
set -euo pipefail

RESOURCE_GROUP="${AZURELIT_RESOURCE_GROUP:-AzureLIT-POC}"
ACCOUNT_NAME="${AZURELIT_ACCOUNT_NAME:-azurelit-openai}"
NAME_FILTER=""
SKU_FILTER=""
CAPABILITY_FILTER=""
FORMAT_FILTER=""
DEFAULT_ONLY="false"
JSON_OUTPUT="false"

usage() {
  printf "Usage: %s [options]\n" "$(basename "$0")"
  printf "\n"
  printf "List deployable models for an Azure AI account, with practical filters.\n"
  printf "\n"
  printf "Options:\n"
  printf "  -g, --resource-group <name>   Resource group (default: %s)\n" "$RESOURCE_GROUP"
  printf "  -n, --account-name <name>     Cognitive account name (default: %s)\n" "$ACCOUNT_NAME"
  printf "      --name <substring>        Filter by model name substring (case-insensitive)\n"
  printf "      --sku <sku>               Filter by supported SKU (case-insensitive)\n"
  printf "      --capability <name>       Filter by capability flag set to true (e.g. responses, chatCompletion, embeddings)\n"
  printf "      --format <name>           Filter by model format (e.g. OpenAI, OpenAI-OSS)\n"
  printf "      --default-only            Show only default versions\n"
  printf "      --json                    Output filtered JSON\n"
  printf "  -h, --help                    Show this help\n"
  printf "\n"
  printf "Examples:\n"
  printf "  %s --name codex\n" "$(basename "$0")"
  printf "  %s --capability responses --name gpt-5.1\n" "$(basename "$0")"
  printf "  %s --sku DataZoneStandard\n" "$(basename "$0")"
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf "Error: required command not found: %s\n" "$1" >&2
    exit 1
  fi
}

while (($# > 0)); do
  case "$1" in
    -g|--resource-group)
      RESOURCE_GROUP="$2"
      shift 2
      ;;
    -n|--account-name)
      ACCOUNT_NAME="$2"
      shift 2
      ;;
    --name)
      NAME_FILTER="$2"
      shift 2
      ;;
    --sku)
      SKU_FILTER="$2"
      shift 2
      ;;
    --capability)
      CAPABILITY_FILTER="$2"
      shift 2
      ;;
    --format)
      FORMAT_FILTER="$2"
      shift 2
      ;;
    --default-only)
      DEFAULT_ONLY="true"
      shift
      ;;
    --json)
      JSON_OUTPUT="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf "Error: unknown option: %s\n\n" "$1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

require_cmd az
require_cmd jq

FILTERED_JSON="$({
  az cognitiveservices account list-models \
    --name "$ACCOUNT_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    -o json
} | jq \
  --arg name_filter "$NAME_FILTER" \
  --arg sku_filter "$SKU_FILTER" \
  --arg capability_filter "$CAPABILITY_FILTER" \
  --arg format_filter "$FORMAT_FILTER" \
  --argjson default_only "$DEFAULT_ONLY" \
  '
  map({
    name: .name,
    version: .version,
    format: .format,
    default: (.isDefaultVersion // false),
    skus: ((.skus // []) | map(.name) | unique),
    capabilities: (.capabilities // {})
  })
  | map(select(
      ($name_filter == "" or ((.name // "") | ascii_downcase | contains($name_filter | ascii_downcase)))
      and ($format_filter == "" or (.format == $format_filter))
      and ($default_only | not or .default == true)
      and (
        $sku_filter == ""
        or (((.skus // []) | map(ascii_downcase)) | index($sku_filter | ascii_downcase) != null)
      )
      and (
        $capability_filter == ""
        or (((.capabilities[$capability_filter] // "false") | tostring | ascii_downcase) == "true")
      )
    ))
  | sort_by(.name, .version)
  '
)"

if [[ "$JSON_OUTPUT" == "true" ]]; then
  printf "%s\n" "$FILTERED_JSON"
  exit 0
fi

COUNT="$(printf "%s" "$FILTERED_JSON" | jq 'length')"
if [[ "$COUNT" -eq 0 ]]; then
  printf "No models matched the current filters.\n"
  exit 0
fi

TABLE="$(printf "%s" "$FILTERED_JSON" | jq -r '
  ["MODEL","VERSION","FORMAT","DEFAULT","SKUS","AREA","CAPABILITIES_TRUE"],
  (
    .[]
    | [
        .name,
        .version,
        .format,
        (.default | tostring),
        ((.skus // []) | join(",")),
        ((.capabilities.area // "") | tostring),
        (
          (.capabilities // {})
          | to_entries
          | map(select((.value | tostring | ascii_downcase) == "true"))
          | map(.key)
          | sort
          | join(",")
        )
      ]
  )
  | @tsv
')"

if command -v column >/dev/null 2>&1; then
  printf "%s\n" "$TABLE" | column -t -s $'\t'
else
  printf "%s\n" "$TABLE"
fi
