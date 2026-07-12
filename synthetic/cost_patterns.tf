# Purpose: Cost-generating patterns - five deliberate FinOps anti-patterns
#          that drive Azure Advisor + Cost Management recommendations and
#          §6 Defender for Cloud "right-size" signals.
# Section: 13.4 - Cost-Generating Patterns
# Last updated: 2026-06-05
#
# Anti-patterns shipped:
#   1. Oversized idle VM (var.cost_pattern_vm_size, default Standard_D4s_v5)
#      tagged Optimization=Candidate - drives the Advisor downsize recommendation.
#   2. Unattached 32 GB Premium SSD - drives Advisor delete-unattached-disk.
#   3. Hot-tier storage with stale blobs - drives Advisor lifecycle-policy
#      recommendation once the 7-day no-access window elapses.
#   4. Ungoverned RG with empty tags - Section 7 Modify policy detects the
#      missing FinOps tags and AzureActivity records the remediation.
#   5. RG-scope consumption budget set to var.cost_pattern_budget_amount_usd
#      (default $1) so every month's spend trips the 50/75/100% notifications
#      on day 1 - the demo signal for cost-overrun alerting.
#
# DEVIATIONS vs PROMPT.md:
#   - ADR-003 collapsed the sandbox subscription into the Landing Zones sub.
#     The deliberately-low budget therefore lives at the synthetic
#     cost-pattern RG scope rather than at the sandbox-sub scope. Same demo
#     signal (budget threshold breached), narrower blast radius.
#   - The oversized VM stays running (Advisor needs >=7 days of low CPU to
#     fire the downsize recommendation). Cost-conscious users can override
#     var.cost_pattern_vm_size to Standard_D2s_v5 (~$70/mo instead of ~$140).
#     The kill switch (enable_synthetic_workload=false) tears the entire
#     layer down in <5 min per §13.6.

# ---------------------------------------------------------------------------
# Locals - 13.4 sub-gate + naming
# ---------------------------------------------------------------------------

locals {
  cost_patterns_enabled = local.enabled

  cost_patterns_tags = merge(
    local.common_tags,
    {
      Layer                 = "Synthetic"
      Lifecycle             = "Ephemeral"
      Scenario              = "cost-patterns"
      "Optimization-Source" = "synthetic-13.4"
    },
  )

  oversized_vm_tags = merge(
    local.cost_patterns_tags,
    {
      Optimization = "Candidate"
    },
  )

  cost_patterns_vnet_cidr   = "10.50.0.0/24"
  cost_patterns_subnet_cidr = "10.50.0.0/26"
}

# ---------------------------------------------------------------------------
# Resource groups - governed + intentionally ungoverned
# ---------------------------------------------------------------------------

resource "azurerm_resource_group" "cost_patterns" {
  count    = local.cost_patterns_enabled
  name     = "rg-synthetic-cost-patterns-${var.org_prefix}-${var.environment}"
  location = var.primary_location
  tags     = local.cost_patterns_tags
}

# Anti-pattern #4 - the Section 7 Modify policy at MG scope adds the missing
# FinOps tags shortly after creation; the policy-evaluation entry in
# AzureActivity is the demo signal. Empty tags map is intentional.
resource "azurerm_resource_group" "ungoverned" {
  count    = local.cost_patterns_enabled
  name     = "rg-ungoverned-${var.org_prefix}-${var.environment}"
  location = var.primary_location
  tags     = {}

  lifecycle {
    # The Section 7 Modify policy will mutate tags out-of-band - accept the
    # drift rather than fighting it on every plan.
    ignore_changes = [tags]
  }
}

# ---------------------------------------------------------------------------
# Isolated VNet for the cost-pattern VM - no peering, no firewall UDR, no PE
# ---------------------------------------------------------------------------

resource "azurerm_virtual_network" "cost_patterns" {
  count               = local.cost_patterns_enabled
  name                = "vnet-synthetic-cost-patterns-${var.org_prefix}-${var.environment}"
  resource_group_name = azurerm_resource_group.cost_patterns[0].name
  location            = var.primary_location
  address_space       = [local.cost_patterns_vnet_cidr]
  tags                = local.cost_patterns_tags
}

resource "azurerm_subnet" "cost_patterns" {
  count                = local.cost_patterns_enabled
  name                 = "snet-cost-patterns"
  resource_group_name  = azurerm_resource_group.cost_patterns[0].name
  virtual_network_name = azurerm_virtual_network.cost_patterns[0].name
  address_prefixes     = [local.cost_patterns_subnet_cidr]
}

# NSG for the isolated cost-pattern subnet. The landingzones-MG
# Deny-Subnet-Without-Nsg policy denies any subnet create with no NSG attached
# (pre-clearance row 5, same policy that denied corp snet-integration), so this
# subnet needs one. The subnet is isolated (no peering, no public IP on the VM
# NIC; break-glass is via Bastion / Serial Console), so the single explicit
# deny documents intent on top of the platform default DenyAllInBound.
resource "azurerm_network_security_group" "cost_patterns" {
  count               = local.cost_patterns_enabled
  name                = "nsg-synthetic-cost-patterns-${var.org_prefix}-${var.environment}"
  resource_group_name = azurerm_resource_group.cost_patterns[0].name
  location            = var.primary_location

  security_rule {
    name                       = "Deny-Internet-Inbound"
    priority                   = 4000
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "Internet"
    destination_address_prefix = "VirtualNetwork"
    description                = "Isolated cost-pattern subnet needs no internet inbound; access is via Bastion / Serial Console."
  }

  tags = local.cost_patterns_tags
}

resource "azurerm_subnet_network_security_group_association" "cost_patterns" {
  count                     = local.cost_patterns_enabled
  subnet_id                 = azurerm_subnet.cost_patterns[0].id
  network_security_group_id = azurerm_network_security_group.cost_patterns[0].id
}

resource "azurerm_network_interface" "oversized_vm" {
  count               = local.cost_patterns_enabled
  name                = "nic-oversized-${var.org_prefix}-${var.environment}"
  resource_group_name = azurerm_resource_group.cost_patterns[0].name
  location            = var.primary_location

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = azurerm_subnet.cost_patterns[0].id
    private_ip_address_allocation = "Dynamic"
  }

  tags = local.cost_patterns_tags
}

# ---------------------------------------------------------------------------
# Ephemeral SSH keypair - public key on the VM, private key as sensitive output
# ---------------------------------------------------------------------------

resource "tls_private_key" "oversized_vm" {
  count     = local.cost_patterns_enabled
  algorithm = "RSA"
  rsa_bits  = 4096
}

# ---------------------------------------------------------------------------
# Anti-pattern #1 - oversized idle VM (Standard_D4s_v5 by default)
# ---------------------------------------------------------------------------

resource "azurerm_linux_virtual_machine" "oversized_idle" {
  count               = local.cost_patterns_enabled
  name                = "vm-oversized-${var.org_prefix}-${var.environment}"
  resource_group_name = azurerm_resource_group.cost_patterns[0].name
  location            = var.primary_location
  size                = var.cost_pattern_vm_size

  admin_username                  = var.cost_pattern_vm_admin_username
  disable_password_authentication = true

  network_interface_ids = [
    azurerm_network_interface.oversized_vm[0].id,
  ]

  admin_ssh_key {
    username   = var.cost_pattern_vm_admin_username
    public_key = tls_private_key.oversized_vm[0].public_key_openssh
  }

  os_disk {
    name                 = "osdisk-oversized-${var.org_prefix}-${var.environment}"
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  tags = local.oversized_vm_tags
}

# ---------------------------------------------------------------------------
# Anti-pattern #2 - unattached 32 GB Premium SSD
# ---------------------------------------------------------------------------

resource "azurerm_managed_disk" "unattached" {
  count                = local.cost_patterns_enabled
  name                 = "disk-unattached-${var.org_prefix}-${var.environment}"
  resource_group_name  = azurerm_resource_group.cost_patterns[0].name
  location             = var.primary_location
  storage_account_type = "Premium_LRS"
  create_option        = "Empty"
  disk_size_gb         = 32

  tags = merge(
    local.cost_patterns_tags,
    {
      Optimization = "Candidate"
      AntiPattern  = "unattached-disk"
    },
  )
}

# ---------------------------------------------------------------------------
# Anti-pattern #3 - Hot-tier storage with stale blobs
# ---------------------------------------------------------------------------

resource "azurerm_storage_account" "cost_pattern_hot" {
  count = local.cost_patterns_enabled
  # Role token kept to 2 chars ("ch" = cost-hot) so the rendered name stays
  # within the 24-char storage limit: stsyn(5) + ch(2) + globaris(8) + poc(3) +
  # 6-char suffix = 24. Matches the corp_a1 "a1" token convention.
  name                     = "stsynch${var.org_prefix}${var.environment}${random_string.sa_suffix[0].result}"
  resource_group_name      = azurerm_resource_group.cost_patterns[0].name
  location                 = var.primary_location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  account_kind             = "StorageV2"
  access_tier              = "Hot"
  min_tls_version          = "TLS1_2"

  public_network_access_enabled   = true
  allow_nested_items_to_be_public = false
  shared_access_key_enabled       = true

  tags = merge(
    local.cost_patterns_tags,
    {
      AntiPattern = "hot-tier-stale"
    },
  )

  # Wait for the OQ-029 Waiver exemption to propagate before creating this public
  # SA, else the Deny-Public-Endpoints PUT races propagation and is denied
  # (ADR-028 race). No-op ordering when the exemptions are disabled.
  depends_on = [time_sleep.wait_synthetic_policy_exemptions]
}

resource "azurerm_storage_container" "stale" {
  count                 = local.cost_patterns_enabled
  name                  = "stale"
  storage_account_id    = azurerm_storage_account.cost_pattern_hot[0].id
  container_access_type = "private"
}

# Five 4 KB sentinel blobs - uploaded once and intentionally never read again.
# After 7 days, the storage account's "last access tracking" surfaces them in
# the Storage Insights "infrequently accessed blobs" recommendation.
resource "azurerm_storage_blob" "stale" {
  for_each = local.cost_patterns_enabled == 1 ? toset([
    "snapshot-archive-2023.bin",
    "ml-training-dump.bin",
    "legacy-export.bin",
    "audit-archive.bin",
    "tmp-batch-output.bin",
  ]) : []

  name                   = each.value
  storage_account_name   = azurerm_storage_account.cost_pattern_hot[0].name
  storage_container_name = azurerm_storage_container.stale[0].name
  type                   = "Block"
  access_tier            = "Hot"
  source_content         = "synthetic stale payload - section 13.4 anti-pattern - ${each.value} - do not access"
}

# ---------------------------------------------------------------------------
# Anti-pattern #5 - deliberately-low budget at RG scope ($1/mo by default)
# ---------------------------------------------------------------------------

resource "azurerm_consumption_budget_resource_group" "sandbox_overrun" {
  count             = local.cost_patterns_enabled == 1 && length(var.cost_pattern_budget_alert_emails) > 0 ? 1 : 0
  name              = "bdgt-synthetic-overrun-${var.org_prefix}-${var.environment}"
  resource_group_id = azurerm_resource_group.cost_patterns[0].id
  amount            = var.cost_pattern_budget_amount_usd
  time_grain        = "Monthly"

  time_period {
    # Budgets require a first-of-month start_date. Pin to a known-past month so
    # the resource is idempotent across re-applies; the actual spend window
    # rolls forward monthly inside Azure.
    start_date = "2026-06-01T00:00:00Z"
    end_date   = "2030-12-01T00:00:00Z"
  }

  dynamic "notification" {
    for_each = toset([50, 75, 100])
    content {
      enabled        = true
      threshold      = notification.value
      operator       = "GreaterThan"
      threshold_type = "Actual"
      contact_emails = var.cost_pattern_budget_alert_emails
    }
  }
}
