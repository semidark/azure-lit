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
  printf "Quota (limit / used / available) is fetched from the subscription and\n"
  printf "matched per (model, SKU).\n"
  printf "\n"
  printf "Options:\n"
  printf "  -g, --resource-group <name>   Resource group (default: %s)\n" "$RESOURCE_GROUP"
  printf "  -n, --account-name <name>     Cognitive account name (default: %s)\n" "$ACCOUNT_NAME"
  printf "      --name <substring>        Filter by model name substring (case-insensitive)\n"
  printf "      --sku <sku>               Filter by supported SKU (case-insensitive)\n"
  printf "      --capability <name>       Filter by capability flag set to true (e.g. responses, chatCompletion, embeddings)\n"
  printf "      --format <name>           Filter by model format (e.g. OpenAI, OpenAI-OSS)\n"
  printf "      --default-only            Show only default versions\n"
  printf "      --json                    Output JSON (one record per model + SKU)\n"
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

# ============================================================================
# 1. Fetch model catalog from the account
# ============================================================================

MODEL_JSON="$(az cognitiveservices account list-models \
  --name "$ACCOUNT_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  -o json)"

LOCATION="$(az cognitiveservices account show \
  --name "$ACCOUNT_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query "location" -o tsv)"

# ============================================================================
# 2. Fetch subscription quota for the location
# ============================================================================

QUOTA_JSON="$(az cognitiveservices usage list \
  --location "$LOCATION" \
  -o json 2>/dev/null || echo "[]")"

# ============================================================================
# 3. Build a lookup map: normalized_quota_key -> {limit, used, available}
#
#    Azure quota names often drop dots/hyphens: "gpt-4.1" -> "gpt4.1"
#    We keep the original keys AND normalized keys for matching.
# ============================================================================

# Build associative array in bash from JSON using process substitution
# Format per line: <original_key> TAB <normalized_key> TAB <limit> TAB <used> TAB <available>
QUOTA_MAP_TSV="$(printf '%s' "$QUOTA_JSON" | jq -r '
  .[] | {
    name: .name.value,
    limit: (.limit // 0),
    used: (.currentValue // 0),
    avail: ((.limit // 0) - (.currentValue // 0))
  } | [.name, (.name | ascii_downcase), .limit, .used, .avail] | @tsv
')"

declare -A QUOTA_MAP
while IFS=$'\t' read -r orig_key norm_key limit used avail; do
  QUOTA_MAP["$orig_key"]="$limit"$'\t'"$used"$'\t'"$avail"
  QUOTA_MAP["$norm_key"]="$limit"$'\t'"$used"$'\t'"$avail"
done <<< "$QUOTA_MAP_TSV"

# ============================================================================
# 4. Normalization helpers
# ============================================================================

# Strip dots and hyphens, lowercase -> "gpt41", "kimik26"
normalize_all() {
  printf '%s' "$1" | tr -d '.-' | tr '[:upper:]' '[:lower:]'
}

# Strip hyphens only, keep dots, lowercase -> "gpt4.1"
normalize_hyphens() {
  printf '%s' "$1" | tr -d '-' | tr '[:upper:]' '[:lower:]'
}

# Strip dots only, keep hyphens, lowercase -> "gpt-41"
normalize_dots() {
  printf '%s' "$1" | tr -d '.' | tr '[:upper:]' '[:lower:]'
}

# Common Azure prefix normalization: "gpt-4.1" -> "gpt4.1", "o3-mini" -> "o3-mini"
normalize_prefix() {
  printf '%s' "$1" | sed 's/^gpt-/gpt/; s/^o-/o/' | tr '[:upper:]' '[:lower:]'
}

# Build likely quota key patterns from model name + sku
# Try exact and several normalized variants because Azure naming is inconsistent.
find_quota() {
  local model="$1"
  local sku="$2"
  local provider="${3:-OpenAI}"

  local exact_key="${provider}.${sku}.${model}"
  local norm_all="${provider}.${sku}.$(normalize_all "$model")"
  local norm_hyphens="${provider}.${sku}.$(normalize_hyphens "$model")"
  local norm_dots="${provider}.${sku}.$(normalize_dots "$model")"
  local norm_prefix="${provider}.${sku}.$(normalize_prefix "$model")"

  # Try exact first
  if [[ -n "${QUOTA_MAP[$exact_key]+x}" ]]; then
    printf '%s' "${QUOTA_MAP[$exact_key]}"
    return
  fi

  # Try normalized variants (exact key match)
  for key in "$norm_all" "$norm_hyphens" "$norm_dots" "$norm_prefix"; do
    if [[ -n "${QUOTA_MAP[$key]+x}" ]]; then
      printf '%s' "${QUOTA_MAP[$key]}"
      return
    fi
  done

  # Try lowercase exact
  local lc_key="${exact_key,,}"
  if [[ -n "${QUOTA_MAP[$lc_key]+x}" ]]; then
    printf '%s' "${QUOTA_MAP[$lc_key]}"
    return
  fi

  # Fallback: fuzzy contains search with all variants
  local sku_lc="${sku,,}"
  local model_all="$(normalize_all "$model")"
  local model_hyphens="$(normalize_hyphens "$model")"
  local model_dots="$(normalize_dots "$model")"
  local model_prefix="$(normalize_prefix "$model")"

  for k in "${!QUOTA_MAP[@]}"; do
    local match_key="${k,,}"
    if [[ "$match_key" == *"${sku_lc}"* ]]; then
      if [[ "$match_key" == *"$model_all"* ]] || \
         [[ "$match_key" == *"$model_hyphens"* ]] || \
         [[ "$match_key" == *"$model_dots"* ]] || \
         [[ "$match_key" == *"$model_prefix"* ]] || \
         [[ "$match_key" == *"${model,,}"* ]]; then
        printf '%s' "${QUOTA_MAP[$k]}"
        return
      fi
    fi
  done

  # Not found
  printf '%s' ""
}

# ============================================================================
# 5. Flatten JSON: one record per (model, SKU)
# ============================================================================

FILTERED_JSON="$(printf '%s' "$MODEL_JSON" | jq \
  --arg name_filter "$NAME_FILTER" \
  --arg sku_filter "$SKU_FILTER" \
  --arg capability_filter "$CAPABILITY_FILTER" \
  --arg format_filter "$FORMAT_FILTER" \
  --argjson default_only "$DEFAULT_ONLY" \
  '
  # First, filter models
  [
    .[] | {
      name: .name,
      version: .version,
      format: .format,
      default: (.isDefaultVersion // false),
      skus: ((.skus // []) | map(.name) | unique),
      capabilities: (.capabilities // {})
    }
    | select(
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
      )
  ]
  # Then flatten by SKU
  | map(
      . as $m
      | $m.skus[]
      | select(
          $sku_filter == "" or (. | ascii_downcase) == ($sku_filter | ascii_downcase)
        )
      | {
          name: $m.name,
          version: $m.version,
          format: $m.format,
          default: $m.default,
          sku: .,
          capabilities: $m.capabilities
        }
    )
  | sort_by(.name, .version, .sku)
  ')"

# ============================================================================
# 6. JSON output
# ============================================================================

if [[ "$JSON_OUTPUT" == "true" ]]; then
  ROW_COUNT="$(printf '%s' "$FILTERED_JSON" | jq 'length')"
  if [[ "$ROW_COUNT" -eq 0 ]]; then
    printf "[]\n"
    exit 0
  fi

  # Build JSON incrementally with a temp array
  RESULT="["
  for ((i=0; i<ROW_COUNT; i++)); do
    ROW="$(printf '%s' "$FILTERED_JSON" | jq ".[$i]")"
    MODEL_NAME="$(printf '%s' "$ROW" | jq -r '.name')"
    SKU="$(printf '%s' "$ROW" | jq -r '.sku')"
    PROVIDER="$(printf '%s' "$ROW" | jq -r '.format')"
    # Determine provider prefix for quota key
    case "$PROVIDER" in
      OpenAI-OSS) PROVIDER="AIServices" ;;
      MoonshotAI) PROVIDER="AIServices" ;;
      xAI)        PROVIDER="AIServices" ;;
      *)          PROVIDER="OpenAI" ;;
    esac

    QUOTA_STR="$(find_quota "$MODEL_NAME" "$SKU" "$PROVIDER")"
    IFS=$'\t' read -r limit used avail <<< "$QUOTA_STR"

    # Build quota object with nulls for missing values
    if [[ -n "$limit" ]]; then
      QUOTA_JSON_OBJ="{\"limit\":$limit,\"used\":$used,\"available\":$avail}"
    else
      QUOTA_JSON_OBJ="{\"limit\":null,\"used\":null,\"available\":null}"
    fi

    MERGED="$(printf '%s' "$ROW" | jq \
      --argjson quota "$(printf '%s' "$QUOTA_JSON_OBJ")" \
      '. + {quota: $quota}')"

    [[ "$i" -gt 0 ]] && RESULT+=","
    RESULT+="$MERGED"
  done
  RESULT+="]"

  printf '%s\n' "$RESULT" | jq '.'
  exit 0
fi

# ============================================================================
# 7. Table output
# ============================================================================

COUNT="$(printf '%s' "$FILTERED_JSON" | jq 'length')"
if [[ "$COUNT" -eq 0 ]]; then
  printf "No models matched the current filters.\n"
  exit 0
fi

# Build rows into a temp file to avoid subshell variable scope issues
TMPFILE="$(mktemp)"
trap "rm -f '$TMPFILE'" EXIT

printf '%s' "$FILTERED_JSON" | jq -r '.[] | @base64' | while IFS= read -r row64; do
  ROW="$(printf '%s' "$row64" | base64 -d)"
  MODEL_NAME="$(printf '%s' "$ROW" | jq -r '.name')"
  VERSION="$(printf '%s' "$ROW" | jq -r '.version')"
  FORMAT="$(printf '%s' "$ROW" | jq -r '.format')"
  DEFAULT="$(printf '%s' "$ROW" | jq -r '.default')"
  SKU="$(printf '%s' "$ROW" | jq -r '.sku')"
  AREA="$(printf '%s' "$ROW" | jq -r '.capabilities.area // ""')"
  CAPS="$(printf '%s' "$ROW" | jq -r '
    (.capabilities // {})
    | to_entries
    | map(select((.value | tostring | ascii_downcase) == "true"))
    | map(.key)
    | sort
    | join(",")
  ')"

  # Determine provider prefix
  PROVIDER="OpenAI"
  case "$FORMAT" in
    OpenAI-OSS) PROVIDER="AIServices" ;;
    MoonshotAI) PROVIDER="AIServices" ;;
    xAI)        PROVIDER="AIServices" ;;
  esac

  QUOTA_STR="$(find_quota "$MODEL_NAME" "$SKU" "$PROVIDER")"
  IFS=$'\t' read -r limit used avail <<< "$QUOTA_STR"

  # Format missing quota as dashes
  LIMIT_DISP="${limit:-—}"
  USED_DISP="${used:-—}"
  AVAIL_DISP="${avail:-—}"

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$MODEL_NAME" "$VERSION" "$FORMAT" "$DEFAULT" "$SKU" \
    "$AREA" "$CAPS" "$LIMIT_DISP" "$USED_DISP" "$AVAIL_DISP" >> "$TMPFILE"
done

# Prepend headers and print
{ 
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    MODEL VERSION FORMAT DEFAULT SKU AREA CAPABILITIES_TRUE QUOTA_LIMIT QUOTA_USED QUOTA_AVAIL
  cat "$TMPFILE"
} | column -t -s $'\t'
