# =============================================================================
# AZURE CONSUMPTION BUDGET
# =============================================================================
# Monitors Azure OpenAI/Cognitive Services spending and sends email alerts
# when budget thresholds are reached.
#
# Configuration via environment variables:
#   TF_VAR_budget_monthly_amount  - Monthly limit in EUR (default: 100)
#   TF_VAR_budget_alert_emails    - Comma-separated list of alert recipients
#
# Alerts are triggered at:
#   - 50%  (warning)
#   - 80%  (elevated)
#   - 100% (critical - budget exhausted)
# =============================================================================

resource "azurerm_consumption_budget_subscription" "openai_budget" {
  name            = "azurelit-openai-monthly-budget"
  subscription_id = "/subscriptions/${var.subscription_id}"
  amount          = var.budget_monthly_amount
  time_grain      = "Monthly"

  time_period {
    start_date = formatdate("YYYY-MM-01'T'00:00:00Z", timestamp())
    # end_date is optional - budget recurs monthly indefinitely
  }

  # Filter to track only Cognitive Services / Azure OpenAI related costs
  filter {
    dimension {
      name     = "ResourceGroupName"
      operator = "In"
      values   = [azurerm_resource_group.rg.name]
    }
  }

  # Alert at 50% of budget
  notification {
    enabled        = true
    threshold      = 50
    threshold_type = "Actual"
    operator       = "GreaterThan"

    contact_emails = var.budget_alert_emails

    contact_roles = [
      "Owner",
      "Contributor",
    ]
  }

  # Alert at 80% of budget
  notification {
    enabled        = true
    threshold      = 80
    threshold_type = "Actual"
    operator       = "GreaterThan"

    contact_emails = var.budget_alert_emails

    contact_roles = [
      "Owner",
      "Contributor",
    ]
  }

  # Alert at 100% of budget (budget exhausted)
  notification {
    enabled        = true
    threshold      = 100
    threshold_type = "Actual"
    operator       = "GreaterThan"

    contact_emails = var.budget_alert_emails

    contact_roles = [
      "Owner",
      "Contributor",
    ]
  }

  # Prevent time_period changes from forcing replacement
  lifecycle {
    ignore_changes = [
      time_period[0].start_date,
    ]
  }
}

# =============================================================================
# BUDGET OUTPUTS
# =============================================================================

output "budget_name" {
  description = "Name of the created Azure Consumption Budget"
  value       = azurerm_consumption_budget_subscription.openai_budget.name
}

output "budget_amount" {
  description = "Monthly budget amount in EUR"
  value       = azurerm_consumption_budget_subscription.openai_budget.amount
}

output "budget_alert_emails" {
  description = "Email addresses configured for budget alerts"
  value       = var.budget_alert_emails
}
