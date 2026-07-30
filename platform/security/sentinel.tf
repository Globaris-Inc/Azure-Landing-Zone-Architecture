# Purpose: Section 6 - Microsoft Sentinel data connectors, UEBA, watchlists,
#          analytics rules, automation rules, and workbooks. The Sentinel
#          workspace itself is onboarded in main.tf (Section 8).
# Section: 6 - Defender for Cloud + Sentinel Tuning
# Last updated: 2026-05-29
#
# Apply order: After azurerm_sentinel_log_analytics_workspace_onboarding.this
#              (already enforced by implicit reference via module.security_law).

# ===========================================================================
# 1. Data connectors
# ===========================================================================
#
# DEVIATION: NSG flow logs and Azure Firewall logs are NOT directly ingested
# into Sentinel via a connector. Section 4 sends NSG flow logs to the platform
# LA workspace; the hub Azure Firewall sends its diagnostics there too. The
# corresponding analytics rules below use the cross-workspace `workspace()`
# KQL function to query the platform workspace from the Security workspace -
# preferred for POC since it avoids duplicate log ingestion costs (~$2.3/GB).

resource "azurerm_sentinel_data_connector_azure_active_directory" "this" {
  count = var.enable_aad_connector ? 1 : 0

  name                       = "dc-aad-${var.org_prefix}-${var.environment}"
  log_analytics_workspace_id = module.security_law.resource_id
  tenant_id                  = var.tenant_id

  depends_on = [azurerm_sentinel_log_analytics_workspace_onboarding.this]
}

resource "azurerm_sentinel_data_connector_azure_security_center" "this" {
  name                       = "dc-mdc-${var.org_prefix}-${var.environment}"
  log_analytics_workspace_id = module.security_law.resource_id
  subscription_id            = var.security_subscription_id

  depends_on = [azurerm_sentinel_log_analytics_workspace_onboarding.this]
}

# Microsoft Defender for Endpoint (formerly MDATP). Requires tenant MDE
# subscription + Security Administrator to consent - the connector resource
# itself is just the Sentinel-side enablement.
# GATED OFF: this tenant lacks a Microsoft Defender for Endpoint license, so the
# connector create fails (see docs/preclearance/platform-security.md prereq 2).
# Pre-staged behind enable_mde_connector (default false); flip on after the
# license is in place.
resource "azurerm_sentinel_data_connector_microsoft_defender_advanced_threat_protection" "this" {
  count = var.enable_mde_connector ? 1 : 0

  name                       = "dc-mde-${var.org_prefix}-${var.environment}"
  log_analytics_workspace_id = module.security_law.resource_id
  tenant_id                  = var.tenant_id

  depends_on = [azurerm_sentinel_log_analytics_workspace_onboarding.this]
}

# Microsoft Threat Intelligence connector - feeds ThreatIntelligenceIndicator
# table from the Microsoft TI feed (free tier of MS Threat Intel for Sentinel).
resource "azurerm_sentinel_data_connector_threat_intelligence" "this" {
  count = var.enable_ti_connector ? 1 : 0

  name                       = "dc-ti-${var.org_prefix}-${var.environment}"
  log_analytics_workspace_id = module.security_law.resource_id
  tenant_id                  = var.tenant_id

  depends_on = [azurerm_sentinel_log_analytics_workspace_onboarding.this]
}

# ===========================================================================
# 2. UEBA + Entity Analytics (azapi - no native azurerm resource)
# ===========================================================================
#
# UNVERIFIED 2026-05-29: API version 2024-09-01 is the GA version published
# on docs.microsoft.com at time of writing. Confirm against the latest
# Microsoft.SecurityInsights/settings resource provider versions before apply
# (`az provider show -n Microsoft.SecurityInsights --query resourceTypes`).
# Entity Analytics is a prerequisite for UEBA - the explicit depends_on
# ordering ensures it lands first.

resource "azapi_resource" "entity_analytics" {
  count = var.enable_ueba ? 1 : 0

  type                      = "Microsoft.SecurityInsights/settings@2024-09-01"
  name                      = "EntityAnalytics"
  parent_id                 = module.security_law.resource_id
  schema_validation_enabled = false

  body = {
    kind = "EntityAnalytics"
    properties = {
      entityProviders = ["AzureActiveDirectory"]
    }
  }

  depends_on = [azurerm_sentinel_log_analytics_workspace_onboarding.this]
}

resource "azapi_resource" "ueba" {
  count = var.enable_ueba ? 1 : 0

  type                      = "Microsoft.SecurityInsights/settings@2024-09-01"
  name                      = "Ueba"
  parent_id                 = module.security_law.resource_id
  schema_validation_enabled = false

  body = {
    kind = "Ueba"
    properties = {
      dataSources = ["AuditLogs", "AzureActivity", "SigninLogs"]
    }
  }

  depends_on = [azapi_resource.entity_analytics]
}

# ===========================================================================
# 3. Watchlists - VIPs + High-Value Assets
# ===========================================================================
#
# Watchlists join against detection KQL via the _GetWatchlist() function:
#   SigninLogs
#   | join kind=inner (_GetWatchlist('VIPUsers')) on $left.UserId == $right.UserObjectId
# Population is conditional - empty input lists skip the watchlist entirely.

resource "azurerm_sentinel_watchlist" "vip_users" {
  count = length(var.vip_user_object_ids) > 0 ? 1 : 0

  name = "VIPUsers"
  # azurerm v4: the argument is log_analytics_workspace_id (full LAW resource ID),
  # matching the data-connector resources above and the onboarding input.
  log_analytics_workspace_id = module.security_law.resource_id
  display_name               = "VIP Users"
  description                = "Entra ID user object IDs flagged as VIPs. Used by analytics rules to elevate severity on VIP-targeted activity."
  item_search_key            = "UserObjectId"
  default_duration           = "P1Y"
  labels                     = ["VIP", "Identity"]

  # Preserve apply ordering after Sentinel onboarding (previously implied by the
  # workspace_id attribute reference that was replaced).
  depends_on = [azurerm_sentinel_log_analytics_workspace_onboarding.this]
}

resource "azurerm_sentinel_watchlist_item" "vip_users" {
  for_each = length(var.vip_user_object_ids) > 0 ? toset(var.vip_user_object_ids) : []

  name         = "vip-${substr(replace(each.value, "-", ""), 0, 16)}"
  watchlist_id = azurerm_sentinel_watchlist.vip_users[0].id
  properties = {
    UserObjectId = each.value
  }
}

resource "azurerm_sentinel_watchlist" "high_value_assets" {
  count = length(var.high_value_asset_resource_ids) > 0 ? 1 : 0

  name = "HighValueAssets"
  # azurerm v4: the argument is log_analytics_workspace_id (full LAW resource ID),
  # matching the data-connector resources above and the onboarding input.
  log_analytics_workspace_id = module.security_law.resource_id
  display_name               = "High-Value Assets"
  description                = "Azure resource IDs flagged as high-value (production data plane, prod Key Vault, etc.). Used to scope alert severity uplift."
  item_search_key            = "ResourceId"
  default_duration           = "P1Y"
  labels                     = ["HighValue", "Asset"]

  # Preserve apply ordering after Sentinel onboarding (previously implied by the
  # workspace_id attribute reference that was replaced).
  depends_on = [azurerm_sentinel_log_analytics_workspace_onboarding.this]
}

resource "azurerm_sentinel_watchlist_item" "high_value_assets" {
  for_each = length(var.high_value_asset_resource_ids) > 0 ? toset(var.high_value_asset_resource_ids) : []

  name         = "hva-${substr(sha1(each.value), 0, 16)}"
  watchlist_id = azurerm_sentinel_watchlist.high_value_assets[0].id
  properties = {
    ResourceId = each.value
  }
}

# ===========================================================================
# 4. Analytics rules - 10 scheduled + 1 MS incident creation
# ===========================================================================
#
# Each scheduled rule lives behind a logical key in local.analytics_rules.
# The KQL is hand-rolled to mirror the equivalent Azure/Azure-Sentinel template
# but keeps the rule self-contained so it deploys cleanly in any tenant. Real
# detections need tuning against actual sign-in / activity volume - see
# sentinel/tuning.md for the threshold rationale.

locals {
  # Hub firewall logs land in the platform LA workspace (Section 8 hub_and_spoke
  # module), not the Security workspace. Cross-workspace queries are used to
  # surface them in Sentinel without duplicating ingestion.
  platform_law_workspace_function = "workspace('law-platform-${var.org_prefix}-${var.environment}')"

  analytics_rules = {

    brute_force_entra = {
      display_name        = "Multiple failed Entra ID sign-ins from a single user (brute force)"
      description         = "Detects ≥10 failed interactive sign-ins for the same UserPrincipalName within 5 minutes - typical of password spray or credential stuffing."
      severity            = "Medium"
      query_frequency     = "PT5M"
      query_period        = "PT5M"
      trigger_operator    = "GreaterThan"
      trigger_threshold   = 0
      tactics             = ["CredentialAccess", "InitialAccess"]
      techniques          = ["T1110"]
      query               = <<-KQL
        SigninLogs
        | where ResultType !in ("0", "50125", "50140")
        | summarize FailedAttempts = count(), DistinctIPs = dcount(IPAddress)
            by UserPrincipalName, bin(TimeGenerated, 5m)
        | where FailedAttempts >= 10
      KQL
      entity_account_path = "UserPrincipalName"
    }

    blocked_country_signin = {
      display_name        = "Successful sign-in from outside approved countries"
      description         = "Successful sign-in originating from a country not on the approved list - bypass attempt of CA-005 (Geo-block named location) or an emergency-access account in transit."
      severity            = "High"
      query_frequency     = "PT15M"
      query_period        = "PT15M"
      trigger_operator    = "GreaterThan"
      trigger_threshold   = 0
      tactics             = ["InitialAccess"]
      techniques          = ["T1078"]
      query               = <<-KQL
        let approved = dynamic(${jsonencode([for c in ["US", "CA", "GB"] : c])});
        SigninLogs
        | where ResultType == "0"
        | extend Country = tostring(LocationDetails.countryOrRegion)
        | where Country !in (approved) and isnotempty(Country)
        | project TimeGenerated, UserPrincipalName, IPAddress, Country, AppDisplayName, ClientAppUsed
      KQL
      entity_account_path = "UserPrincipalName"
    }

    legacy_auth_attempt = {
      display_name        = "Legacy authentication attempt"
      description         = "Sign-in attempt using a legacy authentication protocol (POP/IMAP/SMTP basic, Other clients). CA-002 should be blocking these - alert if any slip through."
      severity            = "Medium"
      query_frequency     = "PT30M"
      query_period        = "PT30M"
      trigger_operator    = "GreaterThan"
      trigger_threshold   = 0
      tactics             = ["DefenseEvasion", "InitialAccess"]
      techniques          = ["T1078"]
      query               = <<-KQL
        SigninLogs
        | where ClientAppUsed in (
            "Other clients", "IMAP4", "POP3", "MAPI Over HTTP", "SMTP", "Authenticated SMTP",
            "Exchange ActiveSync", "Exchange Web Services", "Exchange Online PowerShell"
          )
        | project TimeGenerated, UserPrincipalName, IPAddress, ClientAppUsed, AppDisplayName, ResultType
      KQL
      entity_account_path = "UserPrincipalName"
    }

    kv_bulk_secret_access = {
      display_name        = "Bulk Key Vault secret access by a single caller"
      description         = "A single caller pulls ≥50 distinct secrets from a Key Vault within 10 minutes. Typical of an attacker harvesting credentials after compromise."
      severity            = "High"
      query_frequency     = "PT10M"
      query_period        = "PT10M"
      trigger_operator    = "GreaterThan"
      trigger_threshold   = 0
      tactics             = ["CredentialAccess", "Collection"]
      techniques          = ["T1555"]
      query               = <<-KQL
        AzureDiagnostics
        | where ResourceProvider == "MICROSOFT.KEYVAULT"
        | where OperationName == "SecretGet"
        | where ResultType == "Success"
        | summarize DistinctSecrets = dcount(id_s), Count = count()
            by identity_claim_appid_g, CallerIPAddress, Resource, bin(TimeGenerated, 10m)
        | where DistinctSecrets >= 50
      KQL
      entity_account_path = "identity_claim_appid_g"
    }

    pim_after_hours_activation = {
      display_name        = "Privileged role activation outside business hours"
      description         = "A PIM-eligible role was activated between 22:00 and 06:00 UTC. Cross-reference with the operator's normal working hours."
      severity            = "Medium"
      query_frequency     = "PT15M"
      query_period        = "PT15M"
      trigger_operator    = "GreaterThan"
      trigger_threshold   = 0
      tactics             = ["PrivilegeEscalation"]
      techniques          = ["T1078"]
      query               = <<-KQL
        AuditLogs
        | where Category == "RoleManagement"
        | where ActivityDisplayName has "Add member to role completed (PIM activation)"
        | extend HourUtc = hourofday(TimeGenerated)
        | where HourUtc >= 22 or HourUtc < 6
        | project TimeGenerated, InitiatedBy.user.userPrincipalName, ActivityDisplayName, TargetResources
      KQL
      entity_account_path = "InitiatedBy_user_userPrincipalName"
    }

    mass_resource_deletion = {
      display_name        = "Mass resource deletion by a single principal"
      description         = "A single principal issues ≥10 delete operations across resources within 5 minutes. Possible attacker covering tracks or insider sabotage."
      severity            = "High"
      query_frequency     = "PT5M"
      query_period        = "PT5M"
      trigger_operator    = "GreaterThan"
      trigger_threshold   = 0
      tactics             = ["Impact"]
      techniques          = ["T1485"]
      query               = <<-KQL
        AzureActivity
        | where OperationNameValue endswith "/delete"
        | where ActivityStatusValue == "Success"
        | summarize DeleteCount = count(), Resources = make_set(_ResourceId, 25)
            by Caller, CallerIpAddress, bin(TimeGenerated, 5m)
        | where DeleteCount >= 10
      KQL
      entity_account_path = "Caller"
    }

    anonymous_storage_access = {
      display_name        = "Anonymous public access to a storage blob"
      description         = "A blob in a managed storage account was retrieved with AuthenticationType=Anonymous. Indicates a misconfigured container or a deliberate exfiltration path."
      severity            = "High"
      query_frequency     = "PT15M"
      query_period        = "PT15M"
      trigger_operator    = "GreaterThan"
      trigger_threshold   = 0
      tactics             = ["Exfiltration", "Collection"]
      techniques          = ["T1530"]
      query               = <<-KQL
        StorageBlobLogs
        | where AuthenticationType == "Anonymous"
        | where OperationName in ("GetBlob", "ListBlobs")
        | project TimeGenerated, AccountName, Uri, CallerIpAddress, OperationName, StatusCode
      KQL
      entity_account_path = "CallerIpAddress"
    }

    new_global_admin = {
      display_name        = "New member added to a privileged directory role"
      description         = "A user or service principal was added to Global Administrator, Privileged Role Administrator, or User Access Administrator. PIM bypass or persistence."
      severity            = "High"
      query_frequency     = "PT15M"
      query_period        = "PT15M"
      trigger_operator    = "GreaterThan"
      trigger_threshold   = 0
      tactics             = ["Persistence", "PrivilegeEscalation"]
      techniques          = ["T1098"]
      query               = <<-KQL
        AuditLogs
        | where Category == "RoleManagement"
        | where ActivityDisplayName == "Add member to role"
        | mv-expand TargetResources
        | extend RoleName = tostring(TargetResources.modifiedProperties[1].newValue)
        | where RoleName has_any ("Global Administrator", "Privileged Role Administrator", "User Access Administrator")
        | project TimeGenerated, InitiatedBy_user_userPrincipalName = tostring(InitiatedBy.user.userPrincipalName), RoleName, TargetResources
      KQL
      entity_account_path = "InitiatedBy_user_userPrincipalName"
    }

    firewall_threat_intel_hit = {
      display_name        = "Azure Firewall threat-intel block (cross-workspace)"
      description         = "The hub Azure Firewall blocked a connection because the destination matched its threat-intelligence feed. Cross-workspace query reads the platform LA workspace where firewall diagnostics land."
      severity            = "Medium"
      query_frequency     = "PT15M"
      query_period        = "PT15M"
      trigger_operator    = "GreaterThan"
      trigger_threshold   = 0
      tactics             = ["CommandAndControl"]
      techniques          = ["T1071"]
      query               = <<-KQL
        ${local.platform_law_workspace_function}.AzureDiagnostics
        | where Category in ("AzureFirewallNetworkRule", "AzureFirewallApplicationRule", "AzureFirewallThreatIntelLog")
        | where msg_s has "ThreatIntel:" or msg_s has "ThreatIntelMode"
        | project TimeGenerated, Resource, msg_s
      KQL
      entity_account_path = "" # no account entity for firewall traffic
    }

    mfa_disabled_for_admin = {
      display_name        = "MFA disabled or weakened for a privileged user"
      description         = "An admin account had a strong authentication method removed, or per-user MFA was disabled. Strong precursor to credential abuse."
      severity            = "High"
      query_frequency     = "PT15M"
      query_period        = "PT15M"
      trigger_operator    = "GreaterThan"
      trigger_threshold   = 0
      tactics             = ["DefenseEvasion", "PrivilegeEscalation"]
      techniques          = ["T1556"]
      query               = <<-KQL
        AuditLogs
        | where Category in ("UserManagement", "AuthenticationMethod")
        | where ActivityDisplayName has_any (
            "Delete authentication method",
            "Disable Strong Authentication",
            "Update user",
            "Reset password (by admin)"
          )
        | mv-expand TargetResources
        | extend TargetUpn = tostring(TargetResources.userPrincipalName)
        | project TimeGenerated, InitiatedBy_user_userPrincipalName = tostring(InitiatedBy.user.userPrincipalName), ActivityDisplayName, TargetUpn
      KQL
      entity_account_path = "TargetUpn"
    }
  }
}

resource "azurerm_sentinel_alert_rule_scheduled" "this" {
  for_each = {
    for k, v in local.analytics_rules : k => v
    if k != "firewall_threat_intel_hit" || var.enable_firewall_ti_rule
  }

  name                       = "ar-${each.key}-${var.org_prefix}-${var.environment}"
  log_analytics_workspace_id = module.security_law.resource_id
  display_name               = each.value.display_name
  description                = each.value.description
  severity                   = each.value.severity

  query             = each.value.query
  query_frequency   = each.value.query_frequency
  query_period      = each.value.query_period
  trigger_operator  = each.value.trigger_operator
  trigger_threshold = each.value.trigger_threshold

  tactics    = each.value.tactics
  techniques = each.value.techniques

  enabled             = true
  suppression_enabled = false

  incident {
    create_incident_enabled = true
    grouping {
      enabled                 = true
      lookback_duration       = "PT5H"
      reopen_closed_incidents = false
      entity_matching_method  = "AllEntities"
    }
  }

  dynamic "entity_mapping" {
    for_each = each.value.entity_account_path != "" ? [each.value.entity_account_path] : []
    content {
      entity_type = "Account"
      field_mapping {
        identifier  = "FullName"
        column_name = entity_mapping.value
      }
    }
  }

  depends_on = [azurerm_sentinel_log_analytics_workspace_onboarding.this]
}

# Microsoft Defender for Cloud high-severity alerts → Sentinel incidents
resource "azurerm_sentinel_alert_rule_ms_security_incident" "mdc_high" {
  name                       = "ar-mdc-high-${var.org_prefix}-${var.environment}"
  log_analytics_workspace_id = module.security_law.resource_id
  display_name               = "Microsoft Defender for Cloud - high-severity alert"
  product_filter             = "Azure Security Center"
  severity_filter            = ["High"]

  enabled = true

  depends_on = [azurerm_sentinel_data_connector_azure_security_center.this]
}

# ===========================================================================
# 5. Automation rules - auto-assign + TI enrichment tag
# ===========================================================================
#
# Production playbooks (Logic Apps that quarantine MDE devices, enrich with
# Recorded Future, etc.) are out of scope for this section - they require app
# registrations + MDE API permissions tracked under Section 13 (synthetic
# workload + signal generation).

resource "azurerm_sentinel_automation_rule" "auto_assign" {
  count = var.sentinel_owner_group_object_id != "" ? 1 : 0

  name                       = "12345678-1111-1111-1111-000000000001"
  log_analytics_workspace_id = module.security_law.resource_id
  display_name               = "Auto-assign new incidents to security ops"
  order                      = 1
  enabled                    = true

  triggers_on   = "Incidents"
  triggers_when = "Created"

  action_incident {
    order = 1
    # UNVERIFIED 2026-05-29: azurerm 4.71 action_incident.owner_id assignment
    # path - confirm against provider docs before apply; some 4.x releases
    # require nesting under a separate owner{} sub-block.
    owner_id = var.sentinel_owner_group_object_id
    labels   = ["auto-assigned"]
  }

  depends_on = [azurerm_sentinel_log_analytics_workspace_onboarding.this]
}

resource "azurerm_sentinel_automation_rule" "ti_enrichment_tag" {
  name                       = "12345678-1111-1111-1111-000000000002"
  log_analytics_workspace_id = module.security_law.resource_id
  display_name               = "Tag high-severity incidents for TI enrichment"
  order                      = 2
  enabled                    = true

  triggers_on   = "Incidents"
  triggers_when = "Created"

  condition_json = jsonencode([
    {
      conditionType = "Property"
      conditionProperties = {
        propertyName   = "IncidentSeverity"
        operator       = "Equals"
        propertyValues = ["High"]
      }
    }
  ])

  action_incident {
    order  = 1
    labels = ["TI-enrichment-needed"]
  }

  depends_on = [azurerm_sentinel_log_analytics_workspace_onboarding.this]
}

# ===========================================================================
# 6. Workbooks - Azure Activity, Identity & Access, Azure Firewall, Investigation
# ===========================================================================
#
# DEVIATION: The four built-in Sentinel workbooks live in the Sentinel Content
# Hub gallery and are normally deployed as ARM templates referencing the
# gallery content_id GUIDs. azurerm exposes them as azurerm_application_insights_workbook
# resources with a serialised data_json payload. We deploy empty workbook
# shells here so the resources exist and are inventoried by Terraform; the
# actual workbook JSON should be sourced from
# https://github.com/Azure/Azure-Sentinel/tree/master/Workbooks before demo and
# pasted into the data_json field (Section 6 sentinel/tuning.md tracks the
# mapping).

locals {
  workbook_placeholder_json = jsonencode({
    version = "Notebook/1.0"
    items = [
      {
        type = 1
        content = {
          json = "## Workbook stub\n\nReplace the data_json field on this resource with the JSON from the matching Sentinel gallery workbook before the demo. See sentinel/tuning.md."
        }
      }
    ]
    fallbackResourceIds = [module.security_law.resource_id]
    fromTemplateId      = "sentinel-UserWorkbook"
  })

  sentinel_workbooks = {
    azure_activity    = "Azure Activity"
    identity_access   = "Identity & Access"
    azure_firewall    = "Azure Firewall"
    investigation_ins = "Investigation Insights"
  }
}

resource "random_uuid" "workbooks" {
  for_each = local.sentinel_workbooks
}

resource "azurerm_application_insights_workbook" "sentinel" {
  for_each = local.sentinel_workbooks

  name                = random_uuid.workbooks[each.key].result
  resource_group_name = azurerm_resource_group.security.name
  location            = var.primary_location
  display_name        = "Sentinel - ${each.value}"
  source_id           = lower(module.security_law.resource_id)
  category            = "sentinel"
  data_json           = local.workbook_placeholder_json

  tags = local.common_tags
}
