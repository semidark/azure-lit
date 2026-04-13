# =============================================================================
# CUSTOM RAI (Responsible AI) CONTENT FILTER POLICY
# =============================================================================
# AzureLIT-Permissive: less strict than Microsoft.DefaultV2.
#
# Changes vs DefaultV2:
#   - Harm categories (Hate/Sexual/Violence/Selfharm): Medium → High threshold
#     (minimum without a Microsoft use-case exemption)
#   - Jailbreak detection: disabled
#   - Protected Material Text/Code: disabled
#
# Known provider quirk: azurerm returns PascalCase filter names from API, which
# may cause perpetual plan drift. If that happens, switch to azapi_resource.
# See: https://github.com/hashicorp/terraform-provider-azurerm/issues/31632
#
# severity_threshold is required by the provider even for filters that don't
# use it (Jailbreak, Protected Material). Value is ignored for those filters.
# See: https://github.com/hashicorp/terraform-provider-azurerm/issues/28653
# =============================================================================

# --- Primary account policy ---

resource "azurerm_cognitive_account_rai_policy" "permissive" {
  name                 = "AzureLIT-Permissive"
  cognitive_account_id = azurerm_cognitive_account.openai.id
  base_policy_name     = "Microsoft.DefaultV2"
  mode                 = "Blocking"

  # Harm categories: High threshold (blocks only clearly harmful content)
  content_filter {
    name               = "Hate"
    source             = "Prompt"
    severity_threshold = "High"
    filter_enabled     = true
    block_enabled      = true
  }
  content_filter {
    name               = "Hate"
    source             = "Completion"
    severity_threshold = "High"
    filter_enabled     = true
    block_enabled      = true
  }
  content_filter {
    name               = "Sexual"
    source             = "Prompt"
    severity_threshold = "High"
    filter_enabled     = true
    block_enabled      = true
  }
  content_filter {
    name               = "Sexual"
    source             = "Completion"
    severity_threshold = "High"
    filter_enabled     = true
    block_enabled      = true
  }
  content_filter {
    name               = "Violence"
    source             = "Prompt"
    severity_threshold = "High"
    filter_enabled     = true
    block_enabled      = true
  }
  content_filter {
    name               = "Violence"
    source             = "Completion"
    severity_threshold = "High"
    filter_enabled     = true
    block_enabled      = true
  }
  content_filter {
    name               = "Selfharm"
    source             = "Prompt"
    severity_threshold = "High"
    filter_enabled     = true
    block_enabled      = true
  }
  content_filter {
    name               = "Selfharm"
    source             = "Completion"
    severity_threshold = "High"
    filter_enabled     = true
    block_enabled      = true
  }

  # Jailbreak + Protected Material: fully disabled
  # severity_threshold required by provider but ignored for these filter types
  content_filter {
    name               = "Jailbreak"
    source             = "Prompt"
    severity_threshold = "High"
    filter_enabled     = false
    block_enabled      = false
  }
  content_filter {
    name               = "Protected Material Text"
    source             = "Completion"
    severity_threshold = "High"
    filter_enabled     = false
    block_enabled      = false
  }
  content_filter {
    name               = "Protected Material Code"
    source             = "Completion"
    severity_threshold = "High"
    filter_enabled     = false
    block_enabled      = false
  }
}

# --- Regional account policies (identical to primary) ---

resource "azurerm_cognitive_account_rai_policy" "permissive_regional" {
  for_each = local.remote_regions

  name                 = "AzureLIT-Permissive"
  cognitive_account_id = azurerm_cognitive_account.regional[each.key].id
  base_policy_name     = "Microsoft.DefaultV2"
  mode                 = "Blocking"

  content_filter {
    name               = "Hate"
    source             = "Prompt"
    severity_threshold = "High"
    filter_enabled     = true
    block_enabled      = true
  }
  content_filter {
    name               = "Hate"
    source             = "Completion"
    severity_threshold = "High"
    filter_enabled     = true
    block_enabled      = true
  }
  content_filter {
    name               = "Sexual"
    source             = "Prompt"
    severity_threshold = "High"
    filter_enabled     = true
    block_enabled      = true
  }
  content_filter {
    name               = "Sexual"
    source             = "Completion"
    severity_threshold = "High"
    filter_enabled     = true
    block_enabled      = true
  }
  content_filter {
    name               = "Violence"
    source             = "Prompt"
    severity_threshold = "High"
    filter_enabled     = true
    block_enabled      = true
  }
  content_filter {
    name               = "Violence"
    source             = "Completion"
    severity_threshold = "High"
    filter_enabled     = true
    block_enabled      = true
  }
  content_filter {
    name               = "Selfharm"
    source             = "Prompt"
    severity_threshold = "High"
    filter_enabled     = true
    block_enabled      = true
  }
  content_filter {
    name               = "Selfharm"
    source             = "Completion"
    severity_threshold = "High"
    filter_enabled     = true
    block_enabled      = true
  }

  content_filter {
    name               = "Jailbreak"
    source             = "Prompt"
    severity_threshold = "High"
    filter_enabled     = false
    block_enabled      = false
  }
  content_filter {
    name               = "Protected Material Text"
    source             = "Completion"
    severity_threshold = "High"
    filter_enabled     = false
    block_enabled      = false
  }
  content_filter {
    name               = "Protected Material Code"
    source             = "Completion"
    severity_threshold = "High"
    filter_enabled     = false
    block_enabled      = false
  }
}
