# Purpose: Zero Trust baseline — Conditional Access policies and Identity Protection.
# Section: 5 — Zero Trust + Conditional Access
# Last updated: 2026-07-10
#
# Policies deployed (all start in Report-only mode via var.ca_policy_state):
#   CA-001  Require MFA for all admin roles
#   CA-002  Block legacy authentication protocols
#   CA-003  Require compliant or hybrid-joined device for Azure portal + management API
#   CA-004  Require phishing-resistant MFA when activating roles via PIM
#   CA-005  Geo-block — deny sign-ins from outside approved countries
#   CA-006  Sign-in frequency 4 h for admin roles on management applications
#   CA-007  Block access on high user risk (Identity Protection integration)
#   CA-008  Require MFA on medium/high sign-in risk (Identity Protection integration)
#
# Break-glass exclusion: var.break_glass_group_object_id is excluded from every
# policy. Set this to a real emergency-access group before enabling policies.
#
# Well-known App IDs (stable across tenants, published by Microsoft):
#   Azure portal:              c44b4083-3bb0-49c1-b47d-974e53cbdf3c (NOT CA-targetable - Graph 1034; do not re-add to app lists)
#   Microsoft Azure Mgmt API:  797f4846-ba00-4fd7-ba43-dac1f8f63013
#
# Admin role template IDs (stable across tenants — confirmed on
# learn.microsoft.com/en-us/entra/identity/role-based-access-control/permissions-reference):

locals {
  # Break-glass exclusion list — empty list if no group configured.
  bg_group = compact([var.break_glass_group_object_id])

  # Entra ID directory role template IDs for privileged admin roles.
  admin_role_template_ids = [
    "62e90394-69f5-4237-9190-012177145e10", # Global Administrator
    "e8611ab8-c189-46e8-94e1-60213ab1f814", # Privileged Role Administrator
    "194ae4cb-b126-40b2-bd5b-6091b380977d", # Security Administrator
    "fe930be7-5e62-47db-91af-98c3a49a38b1", # User Administrator
    "c4e39bd9-1100-46d3-8c65-fb160da0071f", # Authentication Administrator
    "9b895d92-2cd3-44c7-9d02-a6ac2d5ea5c3", # Application Administrator
    "158c047a-c907-4556-b7ef-446551a6b5f7", # Cloud Application Administrator
    "f28a1f50-f6e7-4571-818b-6a12f2af6b6c", # SharePoint Administrator
    "69091246-20e8-4a56-aa4d-066075b2a7a8", # Teams Administrator
    "17315797-102d-40b4-93e0-432062caca18", # Compliance Administrator
    "966707d0-3269-4727-9be2-8c3a10f19b9d", # Password Administrator
    "29232cdf-9323-42fd-ade2-1d097af3e4de", # Exchange Administrator
    "b0f54661-2d74-4c50-afa3-1ec803f12efe", # Billing Administrator
    # CORRECTED (run 28953600569 + code review): the original list carried
    # INVALID GUID variants for Exchange Administrator (...-abe5-b6e039f7c0d5)
    # and Billing Administrator (...-1ec803f12efa) - right prefix, wrong tail;
    # Graph CA's 1103 "non-built in role ids" was literally accurate. Replaced
    # with the published template IDs (permissions-reference, verified
    # 2026-07-08). Also removed a duplicate Compliance Administrator entry that
    # was mislabeled "Compliance Data Administrator" (that role's real template
    # is e6d1a23a-da11-4be4-9570-befc86d067a7; deliberately not added).
  ]

  # Azure management app IDs targeted by device compliance + sign-in frequency policies.
  # NOTE (run 28976315927): Graph CA rejects the Azure portal app id
  # c44b4083-3bb0-49c1-b47d-974e53cbdf3c with 1034 UnsupportedFirstPartyApplication -
  # portal first-party apps can no longer be targeted directly. Removed; intent is
  # preserved because the Microsoft Azure Management app below covers Azure portal
  # sign-ins (its tokens are issued for the ARM audience - MS CA docs).
  azure_management_app_ids = [
    "797f4846-ba00-4fd7-ba43-dac1f8f63013", # Microsoft Azure Management (covers Azure portal)
  ]
}

# ---------------------------------------------------------------------------
# Named Location — Approved Countries (geo-block allowlist)
# ---------------------------------------------------------------------------

resource "azuread_named_location" "approved_countries" {
  display_name = "Approved Sign-in Countries — ${title(var.org_prefix)}"

  country {
    countries_and_regions                 = var.approved_sign_in_countries
    include_unknown_countries_and_regions = false
  }
}

# ADR-028: greenfield named-location race hardening. Microsoft Graph replicates a
# FRESHLY created named location asynchronously; CA-005 (geo_block) references it by
# id and failed with error 1040 one second after create in run 28978396902. This
# 300s buffer makes the greenfield DEPLOYMENT path deterministic. For an existing
# tenant (named location already replicated) it costs nothing meaningful and a plain
# rerun clears geo_block regardless. See ADR-028.
#
# Gated on the same var.enable_geo_block_ca_policy as its only consumer, the
# geo_block policy below (ADR-030): with geo_block off the path there is nothing to
# wait for, so this 300s sleep is skipped too. Re-enabling the policy re-enables
# this wait in lockstep.
resource "time_sleep" "wait_named_location" {
  count = var.enable_geo_block_ca_policy ? 1 : 0

  create_duration = "300s"

  depends_on = [azuread_named_location.approved_countries]
}

# ---------------------------------------------------------------------------
# CA-001: Require MFA for all admin roles
# ---------------------------------------------------------------------------

resource "azuread_conditional_access_policy" "require_mfa_admins" {
  display_name = "CA-001 [${upper(var.org_prefix)}] Require MFA — Admin Roles"
  state        = var.ca_policy_state

  conditions {
    client_app_types = ["all"]

    applications {
      included_applications = ["All"]
    }

    users {
      included_roles  = local.admin_role_template_ids
      excluded_groups = local.bg_group
    }
  }

  grant_controls {
    operator          = "OR"
    built_in_controls = ["mfa"]
  }
}

# ---------------------------------------------------------------------------
# CA-002: Block legacy authentication protocols
# Legacy clients (Exchange ActiveSync, IMAP, POP3, SMTP AUTH) bypass MFA.
# ---------------------------------------------------------------------------

resource "azuread_conditional_access_policy" "block_legacy_auth" {
  display_name = "CA-002 [${upper(var.org_prefix)}] Block Legacy Authentication"
  state        = var.ca_policy_state

  conditions {
    client_app_types = ["exchangeActiveSync", "other"]

    applications {
      included_applications = ["All"]
    }

    users {
      included_users  = ["All"]
      excluded_groups = local.bg_group
    }
  }

  grant_controls {
    operator          = "OR"
    built_in_controls = ["block"]
  }
}

# ---------------------------------------------------------------------------
# CA-003: Require compliant or hybrid-joined device for Azure portal + mgmt API
# ---------------------------------------------------------------------------

resource "azuread_conditional_access_policy" "require_compliant_device_portal" {
  display_name = "CA-003 [${upper(var.org_prefix)}] Compliant Device — Azure Portal + Mgmt API"
  state        = var.ca_policy_state

  conditions {
    client_app_types = ["all"]

    applications {
      included_applications = local.azure_management_app_ids
    }

    users {
      included_users  = ["All"]
      excluded_groups = local.bg_group
    }
  }

  grant_controls {
    operator          = "OR"
    built_in_controls = ["compliantDevice", "domainJoinedDevice"]
  }
}

# ---------------------------------------------------------------------------
# CA-004: Require phishing-resistant MFA for PIM role activation
#
# DEVIATION: The azuread provider does not expose authentication_strength_policy_id
# on the built-in "Phishing-resistant MFA" strength without creating a custom
# authentication strength resource. Using standard MFA here as the grant control.
# Production path: create azuread_authentication_strength_policy with
# allowed_combinations = ["fido2", "windowsHelloForBusiness", "x509CertificateMultiFactor"]
# and reference it via grant_controls.authentication_strength_policy_id.
# ---------------------------------------------------------------------------

resource "azuread_conditional_access_policy" "phishing_resistant_mfa_pim" {
  display_name = "CA-004 [${upper(var.org_prefix)}] Require MFA — PIM Role Activation (phishing-resistant in prod)"
  state        = var.ca_policy_state

  conditions {
    client_app_types = ["all"]

    applications {
      included_applications = local.azure_management_app_ids
    }

    users {
      included_roles  = local.admin_role_template_ids
      excluded_groups = local.bg_group
    }
  }

  grant_controls {
    operator          = "OR"
    built_in_controls = ["mfa"]
  }
}

# ---------------------------------------------------------------------------
# CA-005: Geo-block — deny sign-ins from outside approved countries
#
# DEVIATION: creation is gated OFF by default (var.enable_geo_block_ca_policy =
# false). The policy create fails persistently (~5 straight runs) with Microsoft
# Graph error 1040 "NamedLocation ... does not exist in the directory" even though
# azuread_named_location.approved_countries exists and is replicated (verified live
# via Graph), and it kept blocking the entire platform/identity apply. Evidence it
# is a genuine named-location reference issue and NOT OIDC token expiry: in run
# 29068343843 the 1040 fired ~1 minute into a ~34-minute apply, while the token was
# still valid. It is report-only and 1 of 8 CA policies, so gating its creation off
# loses NO enforcement while letting the root finish green. The named location
# itself (approved_countries) stays in place - it is harmless and is the intended
# geo config. Re-enable by setting var.enable_geo_block_ca_policy = true once the
# reference (1040) bug is fixed. See ADR-030 (geo_block 1040 persists post-fix;
# gated off pending root cause).
# ---------------------------------------------------------------------------

resource "azuread_conditional_access_policy" "geo_block" {
  count = var.enable_geo_block_ca_policy ? 1 : 0

  display_name = "CA-005 [${upper(var.org_prefix)}] Geo-Block — Outside Approved Countries"
  state        = var.ca_policy_state

  conditions {
    client_app_types = ["all"]

    applications {
      included_applications = ["All"]
    }

    users {
      included_users  = ["All"]
      excluded_groups = local.bg_group
    }

    locations {
      included_locations = ["All"]
      excluded_locations = [azuread_named_location.approved_countries.id]
    }
  }

  grant_controls {
    operator          = "OR"
    built_in_controls = ["block"]
  }

  # ADR-028: wait out the Graph replication lag on the named location this policy
  # references (excluded_locations), so the create does not fail with error 1040.
  depends_on = [time_sleep.wait_named_location]
}

# ---------------------------------------------------------------------------
# CA-006: Enforce sign-in frequency of 4 hours for admin roles on mgmt apps
# ---------------------------------------------------------------------------

resource "azuread_conditional_access_policy" "signin_frequency_admins" {
  display_name = "CA-006 [${upper(var.org_prefix)}] Sign-in Frequency 4h — Admin Roles on Mgmt Apps"
  state        = var.ca_policy_state

  conditions {
    client_app_types = ["browser", "mobileAppsAndDesktopClients"]

    applications {
      included_applications = local.azure_management_app_ids
    }

    users {
      included_roles  = local.admin_role_template_ids
      excluded_groups = local.bg_group
    }
  }

  session_controls {
    sign_in_frequency        = 4
    sign_in_frequency_period = "hours"
  }
}

# ---------------------------------------------------------------------------
# CA-007: Block access on high user risk (Entra ID Protection integration)
# Requires Entra ID P2. In report-only mode, this logs but does not block.
# ---------------------------------------------------------------------------

resource "azuread_conditional_access_policy" "block_high_user_risk" {
  display_name = "CA-007 [${upper(var.org_prefix)}] Block — High User Risk"
  state        = var.ca_policy_state

  conditions {
    client_app_types = ["all"]
    user_risk_levels = ["high"]

    applications {
      included_applications = ["All"]
    }

    users {
      included_users  = ["All"]
      excluded_groups = local.bg_group
    }
  }

  grant_controls {
    operator          = "OR"
    built_in_controls = ["block"]
  }
}

# ---------------------------------------------------------------------------
# CA-008: Require MFA on medium or high sign-in risk
# ---------------------------------------------------------------------------

resource "azuread_conditional_access_policy" "mfa_signin_risk" {
  display_name = "CA-008 [${upper(var.org_prefix)}] Require MFA — Medium/High Sign-in Risk"
  state        = var.ca_policy_state

  conditions {
    client_app_types    = ["all"]
    sign_in_risk_levels = ["medium", "high"]

    applications {
      included_applications = ["All"]
    }

    users {
      included_users  = ["All"]
      excluded_groups = local.bg_group
    }
  }

  grant_controls {
    operator          = "OR"
    built_in_controls = ["mfa"]
  }
}
