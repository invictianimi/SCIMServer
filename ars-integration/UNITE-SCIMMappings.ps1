# =============================================================================
#  UNITE 2026   |   One Identity UNITE Conference
#  Chicago, USA   |   June 2026   |   Grand Ballroom III
# =============================================================================
#  Script   : UNITE-SCIMMappings.ps1
#  Purpose  : The maps the UNITE-SCIMRest engine reads at runtime - the ONLY
#             file you edit to add a target, a role, or an auto-assign rule:
#               $script:SCIMMappings    AD attributes -> SCIM user payload
#               $script:SCIMRoles       AD role group -> SCIM entitlement group(s)
#               $script:ABACDeptRoles   department    -> role(s) to auto-assign
#  Author   : Jacob Maloney  -  iC Consult, Presales Architect
#  Contact  : sales@ic-consult.com   (We build IAM that doesn't break.)
# =============================================================================

# ---- Mapping value types ---------------------------------------------------
#  "sAMAccountName"            Plain string  -> read the named AD attribute
#  "=work"                     '=' prefix    -> emit this literal value
#  { (Get-QADUser $u.Manager).mail }   ScriptBlock -> compute at runtime;
#                                                     $u = AD user object
#
# ---- Path syntax (left-hand side) ------------------------------------------
#  userName                            top-level scalar
#  displayName                         top-level scalar
#  active                              top-level scalar (boolean)
#  name.givenName                      nested object property
#  name.familyName                     nested object property
#  emails[0].value                     first element of multi-valued array
#  emails[0].type                      "
#  emails[0].primary                   "
#  phoneNumbers[0].value               "
#  phoneNumbers[0].type                "
#  enterprise.department               enterprise schema extension
#  enterprise.employeeNumber           "
#  enterprise.costCenter               "
#  enterprise.division                 "
#  enterprise.organization             "
#  enterprise.manager.value            manager reference (string id)
# ============================================================================

$script:SCIMMappings = @{

    # ------------------------------------------------------------------------
    # HelpDesk - the focus app. Baseline account (everyone submits tickets);
    # the Auditor / Operator / Administrator roles are SCIM Group entitlements
    # layered on top. Keys on sAMAccountName.
    # ------------------------------------------------------------------------
    "HelpDesk" = @{
        "userName"          = "sAMAccountName"
        "name.givenName"    = "givenName"
        "name.familyName"   = "sn"
        "displayName"       = "displayName"
        "emails[0].value"   = "mail"
        "emails[0].type"    = "=work"
        "emails[0].primary" = "=true"
        "active"            = "=true"
    }

    # ------------------------------------------------------------------------
    # HR Connect - minimal core schema, just identity + email
    # ------------------------------------------------------------------------
    "HRConnect" = @{
        "userName"          = "sAMAccountName"
        "name.givenName"    = "givenName"
        "name.familyName"   = "sn"
        "displayName"       = "displayName"
        "emails[0].value"   = "mail"
        "emails[0].type"    = "=work"
        "emails[0].primary" = "=true"
        "active"            = "=true"
    }

    # ------------------------------------------------------------------------
    # IT Helpdesk Portal - adds department + title for ticket routing
    # ------------------------------------------------------------------------
    "ITHelpdeskPortal" = @{
        "userName"                  = "sAMAccountName"
        "name.givenName"            = "givenName"
        "name.familyName"           = "sn"
        "displayName"               = "displayName"
        "emails[0].value"           = "mail"
        "emails[0].type"            = "=work"
        "emails[0].primary"         = "=true"
        "phoneNumbers[0].value"     = "telephoneNumber"
        "phoneNumbers[0].type"      = "=work"
        "enterprise.department"     = "department"
        "enterprise.employeeNumber" = "employeeID"
        "active"                    = "=true"
    }

    # ------------------------------------------------------------------------
    # Finance Suite - keys on email (not sam), needs cost center + manager
    # ------------------------------------------------------------------------
    "FinanceSuite" = @{
        "userName"                = "mail"              # Finance keys on email
        "name.givenName"          = "givenName"
        "name.familyName"         = "sn"
        "displayName"             = "displayName"
        "emails[0].value"         = "mail"
        "emails[0].type"          = "=work"
        "emails[0].primary"       = "=true"
        "enterprise.department"   = "department"
        "enterprise.costCenter"   = "extensionAttribute3"
        "enterprise.organization" = "company"
        # NOTE: enterprise.manager.value in SCIM 2.0 is a REFERENCE to another
        # SCIM user (by their SCIM id, a GUID) - not an email or DN. To wire
        # this correctly, the mapping would need to call SCIMServer first to
        # look up the manager's SCIM id (or accept missing manager linkage on
        # first-time provisioning and reconcile later). For the talk demo we
        # surface the manager's display name instead, which is informational
        # and harmless on the server side.
        "enterprise.manager.displayName" = {
            param($u)
            if ($u.manager) {
                try { (Get-QADUser $u.manager -DontUseDefaultIncludedProperties -IncludedProperties displayName).displayName }
                catch { $null }
            }
        }
        "active" = "=true"
    }

    # ------------------------------------------------------------------------
    # Example: add your next app here. Uncomment + customize.
    # ------------------------------------------------------------------------
    # "JiraCloud" = @{
    #     "userName"        = "mail"
    #     "name.givenName"  = "givenName"
    #     "name.familyName" = "sn"
    #     "displayName"     = "displayName"
    #     "emails[0].value" = "mail"
    #     "emails[0].type"  = "=work"
    #     "active"          = "=true"
    # }
}

# ============================================================================
# Per-app behavior config. Separate from the mapping table because this is
# about LIFECYCLE policy, not field shape.
#
# Recognized keys:
#   OnRemove = "Disable" (default) | "Delete"
#     What to do when the SCIM-<App> virtual attribute flips to false.
#     "Disable" -> PATCH active=false (row stays, marked inactive)
#     "Delete"  -> HTTP DELETE on the SCIM user (row removed)
#
# Defaults: any app not listed here gets OnRemove="Disable".
# ============================================================================

$script:SCIMAppConfig = @{
    "HRConnect"        = @{ OnRemove = "Disable" }
    "ITHelpdeskPortal" = @{ OnRemove = "Disable" }
    "FinanceSuite"     = @{ OnRemove = "Delete"  }   # per-seat pricing - actually remove on offboard
}

# Convenience accessors for the engine.
function Get-SCIMMapping {
    param([Parameter(Mandatory=$true)][string]$AppKey)
    if (-not $script:SCIMMappings.ContainsKey($AppKey)) {
        throw "No SCIM mapping defined for AppKey '$AppKey'. Add an entry to `$script:SCIMMappings in UNITE-SCIMMappings."
    }
    return $script:SCIMMappings[$AppKey]
}

function Get-SCIMAppConfig {
    param([Parameter(Mandatory=$true)][string]$AppKey)
    if ($script:SCIMAppConfig -and $script:SCIMAppConfig.ContainsKey($AppKey)) {
        return $script:SCIMAppConfig[$AppKey]
    }
    return @{}   # empty -> all defaults apply
}

# ============================================================================
# ROLE MAP (RBAC)  - AD role group -> SCIM entitlement(s) in target system(s)
# ----------------------------------------------------------------------------
# The "add to role" workflow reads this. A role is an AD security group; the
# entries say which SCIM Group it grants, in which target app. Add a role by
# adding one key. A role may grant entitlements in MULTIPLE apps - list them all.
#
#   Key    = the AD role group's name (matches what the workflow passes as RoleName)
#   Value  = array of @{ AppKey = "<app in $script:SCIMMappings>"; Group = "<SCIM group displayName>" }
#
# NOTE: each entitlement's AppKey must ALSO have a user mapping above (so the
# engine can find-or-provision the account before adding it to the group).
#
# This is the RBAC half of the talk. The SoD toxic-pair table lives separately
# in UNITE-SoDPolicy.ps1 (it's an ARS Policy object, not part of this engine).
# ============================================================================

$script:SCIMRoles = @{

    # Finance roles -> entitlements in Finance Suite
    "Finance Clerk"       = @( @{ AppKey = "FinanceSuite";     Group = "Finance Clerks" } )
    "Accounts Payable"    = @( @{ AppKey = "FinanceSuite";     Group = "Accounts Payable" } )
    "Accounts Receivable" = @( @{ AppKey = "FinanceSuite";     Group = "Accounts Receivable" } )

    # IT role -> entitlement in the Helpdesk portal
    "IT Support"          = @( @{ AppKey = "ITHelpdeskPortal"; Group = "Helpdesk Agents" } )

    # Example of a role that fans out to TWO targets at once:
    # "Finance Admin"     = @(
    #     @{ AppKey = "FinanceSuite";     Group = "Finance Admins" }
    #     @{ AppKey = "ITHelpdeskPortal"; Group = "App Admins" }
    # )
}

function Get-SCIMRole {
    param([Parameter(Mandatory=$true)][string]$RoleName)
    if ($script:SCIMRoles -and $script:SCIMRoles.ContainsKey($RoleName)) {
        return $script:SCIMRoles[$RoleName]
    }
    return $null   # unmapped role -> AD-only, engine no-ops on the REST side
}

# ============================================================================
# ABAC MAP  - attribute value (department) -> role(s) to auto-assign
# ----------------------------------------------------------------------------
# The ABAC auto-assign workflow reads this on a department change. Each
# department maps to one or more roles (keys of $script:SCIMRoles). The engine
# adds the user to each role; the SoD policy refuses any toxic auto-grant.
# This is the ABAC half of the talk - access that follows the attribute, no ticket.
# ============================================================================
$script:ABACDeptRoles = @{
    "Finance"  = @("Finance Clerk")
    "IT"       = @("IT Support")
    # A department can drive several roles:
    # "Treasury" = @("Finance Clerk", "Accounts Payable")
}

function Get-ABACRolesForDept {
    param([Parameter(Mandatory=$true)][string]$Dept)
    if ($script:ABACDeptRoles -and $script:ABACDeptRoles.ContainsKey($Dept)) {
        return $script:ABACDeptRoles[$Dept]
    }
    return @()
}

# ============================================================================
# BEARER-TOKEN PROTECTION
# ----------------------------------------------------------------------------
# Token secrecy is now handled the ARS-NATIVE way: the SCIM-<App>-Token workflow
# parameter is a SecureString (ARS encrypts it with its service key on save), and
# the engine decrypts it at runtime via $Security.Cryptography.DecryptFromString
# in _Get-SCIMContext. No key lives in this module. (The earlier AES-key helper
# pair was removed in favor of this.)
# ============================================================================
