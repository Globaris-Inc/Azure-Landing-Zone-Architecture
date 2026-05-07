# Purpose: Input variables for Management Group hierarchy root module.
# Section: 2 — Management Group Hierarchy
# Last updated: 2026-05-06

variable "connectivity_subscription_id" {
  description = "Subscription ID for sub-connectivity-poc-01 — placed under the Connectivity management group."
  type        = string
}

variable "management_subscription_id" {
  description = "Subscription ID for sub-management-poc-01 — placed under the Management management group."
  type        = string
}

variable "identity_subscription_id" {
  description = "Subscription ID for sub-identity-poc-01 — placed under the Identity management group."
  type        = string
}

variable "security_subscription_id" {
  description = "Subscription ID for sub-security-poc-01 — placed under the Security management group."
  type        = string
}

variable "landingzones_subscription_id" {
  description = "Subscription ID for sub-landingzones-poc-01 — placed under the Corp management group."
  type        = string
}

variable "primary_location" {
  description = "Primary Azure region for resources that require a location (e.g. policy assignments with remediation)."
  type        = string
  default     = "eastus2"
}

variable "tags" {
  description = "Additional tags to merge into all resources managed by this module."
  type        = map(string)
  default     = {}
}
