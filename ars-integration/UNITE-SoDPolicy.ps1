# =============================================================================
#  UNITE 2026   |   One Identity UNITE Conference
#  Chicago, USA   |   June 2026   |   Grand Ballroom III
# =============================================================================
#  Script   : UNITE-SoDPolicy.ps1
#  Purpose  : Separation-of-Duties for Active Roles. Two layers of enforcement
#             on the boolean role VAs (a user must never hold both sides of a
#             toxic pair):
#               (1) onGetEffectivePolicy - PRIMARY, demo-able. When the user
#                   already holds one role, the conflicting role's checkbox is
#                   forced to FALSE and made READ-ONLY (it can't be ticked), with
#                   a note. This is the "wall right now" the auditor sees.
#               (2) onCheckPropertyValues - the VALIDATION reject. Rejects the save
#                   and flags the field with SetPolicyComplianceInfo (the Attribute
#                   Uniqueness sample pattern). Fires for WI, ADUC, and API.
#  POLICY TYPE: a Script Execution Policy (APE type 0x3) whose parameter 4 points at
#  THIS script module. ARS auto-invokes whichever handlers the module defines for the
#  events in the mask - so defining onGetEffectivePolicy + onCheckPropertyValues is
#  exactly what makes the "i" note and the validation reject appear; no special policy
#  type is required. (Confirmed against the ARS SDK AddEntries.ps1 and the built-in
#  type-0x3 Password Generation policy, which drives WI fields the same way. APE type
#  0x23 is the RULE-based "Property Generation and Validation" type and has NO
#  script-module parameter, so it cannot run this module.) A SQL-built policy object
#  stays inert until it is opened + Saved once in MMC to register.
#  Deploy   : Script Module + a Script Execution Policy Object (parameter 4 = this
#             module) bound to OU=UNITE-2026; open + Save it in MMC to register.
#  Author   : Jacob Maloney  -  iC Consult, Presales Architect
# =============================================================================

# ---- Governed role set -----------------------------------------------------
# Every boolean role VA that participates in ANY toxic pair. Each of these gets a
# PERSISTENT informational "i" note in the Web Interface at all times, telling the
# requester the field is under SoD governance - independent of whether a conflict
# is currently active. This list is maintained explicitly (NOT derived); it must
# contain the distinct set of VAs across all toxic pairs below. Operator was added
# per Jacob's decision when the Operator/Auditor pair was introduced so the Operator
# checkbox also carries the persistent governance note.
$script:SoDGovernedVAs = @(
    "UNITE-HelpDeskAuditor"
    "UNITE-HelpDeskAdministrator"
    "UNITE-HelpDeskOperator"
    "UNITE-HRConnectPayroll"
)

# Generic, always-on governance note shown on every governed role checkbox.
$script:SoDGovernanceNote = "This role is governed by a Separation of Duties policy. Some role combinations cannot be held by the same person."

# ---- Toxic pairs ----------------------------------------------------------
$script:SoDBoolConflicts = @(
    @{
        Name   = "Helpdesk Auditor / Administrator separation"
        VaA    = "UNITE-HelpDeskAuditor";        LabelA = "Helpdesk Auditor"
        VaB    = "UNITE-HelpDeskAdministrator";  LabelB = "Helpdesk Administrator"
        Reason = "An auditor independently reviews the actions of administrators; one person holding both could make a change and sign off on it."
    }
    @{
        Name   = "Helpdesk Administrator / HR Payroll separation (cross-system)"
        VaA    = "UNITE-HelpDeskAdministrator"; LabelA = "Helpdesk Administrator"
        VaB    = "UNITE-HRConnectPayroll";      LabelB = "HR Connect Payroll"
        Reason = "Administering the helpdesk while also running payroll lets one person grant access in one system and pay it out unseen in another."
    }
    @{
        Name   = "Helpdesk Operator / Auditor separation"
        VaA    = "UNITE-HelpDeskOperator";  LabelA = "Helpdesk Operator"
        VaB    = "UNITE-HelpDeskAuditor";    LabelB = "Helpdesk Auditor"
        Reason = "An auditor independently reviews operators' day-to-day actions; one person holding both could perform the work and sign off on it."
    }
)

# ============================================================================
# (1) EFFECTIVE POLICY - PRIMARY: lock the conflicting checkbox to FALSE
# ----------------------------------------------------------------------------
# Pattern from Jacob's BSAM policy: SetEffectivePolicyInfo with GENERATED_VALUE +
# AUTO_GENERATED forces a field and makes it read-only; RELOAD_EPI_BY_RULE
# re-evaluates the instant the driver attribute changes.
# ============================================================================
function onGetEffectivePolicy($Request)
{
    if ("$($Request.Class)" -ne "user") { return }

    # ----- PASS 1: persistent governance note on EVERY governed role -----------
    # Always-on "i" note so the auditor sees SoD coverage at all times, not just
    # when a conflict is live. Set FIRST so the conflict-specific note in PASS 2
    # can overwrite it on the one field that gets locked (last write wins).
    foreach ($va in $script:SoDGovernedVAs) {
        $Request.SetEffectivePolicyInfo($va, $Constants.EDS_EPI_UI_DISPLAY_NOTE, $script:SoDGovernanceNote)
    }

    # ----- PASS 2: live conflict locking ---------------------------------------
    foreach ($pair in $script:SoDBoolConflicts) {
        # Re-evaluate live the moment either side toggles.
        $Request.SetEffectivePolicyInfo($pair.VaA, $Constants.EDS_EPI_UI_RELOAD_EPI_BY_RULE, $pair.VaB)
        $Request.SetEffectivePolicyInfo($pair.VaB, $Constants.EDS_EPI_UI_RELOAD_EPI_BY_RULE, $pair.VaA)

        $aHeld = _HeldTrue -Request $Request -Va $pair.VaA
        $bHeld = _HeldTrue -Request $Request -Va $pair.VaB

        # If one side is held and the other isn't, LOCK the other OFF. _LockOff sets
        # the specific conflict note LAST, so it takes precedence over the generic
        # governance note on THAT field (the locked one). All other governed fields
        # keep the generic note from PASS 1.
        if ($aHeld -and -not $bHeld) { _LockOff -Request $Request -Va $pair.VaB -Because $pair.LabelA -Reason $pair.Reason }
        if ($bHeld -and -not $aHeld) { _LockOff -Request $Request -Va $pair.VaA -Because $pair.LabelB -Reason $pair.Reason }
    }
}

# Force a role attribute to FALSE + read-only, with the SoD reason as the note.
function _LockOff {
    param($Request, [string]$Va, [string]$Because, [string]$Reason)
    $Request.SetEffectivePolicyInfo($Va, $Constants.EDS_EPI_UI_GENERATED_VALUE, "FALSE")
    $Request.SetEffectivePolicyInfo($Va, $Constants.EDS_EPI_UI_AUTO_GENERATED, $Va)
    $Request.SetEffectivePolicyInfo($Va, $Constants.EDS_EPI_UI_DISPLAY_NOTE, "Separation of duties: cannot be granted while the user holds $Because. $Reason")
}

# ============================================================================
# (2) onCheckPropertyValues - the VALIDATION reject (rejects the save AND shows
# the error on the field). This is the Property-Generation-and-Validation handler
# ARS uses to refuse a value - the SAME pattern as the Active Roles "Attribute
# Uniqueness Validation" sample: $Request.SetPolicyComplianceInfo(attr,
# EDS_POLICY_COMPLIANCE_ERROR, message, $false). Fires for the WI, ADUC, and API.
# ============================================================================
function onCheckPropertyValues($Request)
{
    if ("$($Request.Class)" -ne "user") { return }

    foreach ($pair in $script:SoDBoolConflicts) {
        $aSet = _ModSetsTrue -Request $Request -Va $pair.VaA   # is THIS change granting A?
        $bSet = _ModSetsTrue -Request $Request -Va $pair.VaB   # is THIS change granting B?
        if (-not ($aSet -or $bSet)) { continue }

        $aEff = if ($aSet) { $true } else { _HeldTrue -Request $Request -Va $pair.VaA }
        $bEff = if ($bSet) { $true } else { _HeldTrue -Request $Request -Va $pair.VaB }

        if ($aEff -and $bEff) {
            # Put the compliance error on the attribute being granted, so the WI
            # flags THAT field and rejects the save.
            if ($aSet -and $bSet) {
                $attr = $pair.VaB
                $msg  = "Separation of duties: '$($pair.LabelA)' and '$($pair.LabelB)' cannot be granted together. $($pair.Reason)"
            }
            elseif ($aSet) {
                $attr = $pair.VaA
                $msg  = "Separation of duties: cannot grant '$($pair.LabelA)' - the user already holds '$($pair.LabelB)'. $($pair.Reason)"
            }
            else {
                $attr = $pair.VaB
                $msg  = "Separation of duties: cannot grant '$($pair.LabelB)' - the user already holds '$($pair.LabelA)'. $($pair.Reason)"
            }
            $Request.SetPolicyComplianceInfo($attr, $Constants.EDS_POLICY_COMPLIANCE_ERROR, $msg, $false)
        }
    }
}

# ============================================================================
# HELPERS
# ============================================================================
# Is THIS modify setting $Va to TRUE? (the role being granted IS in the request)
function _ModSetsTrue {
    param($Request, [string]$Va)
    $mod = $null
    try { $mod = [bool]$Request.IsAttributeModified($Va) } catch { $mod = $null }
    if ($null -eq $mod) { try { $v = $Request.Get($Va); $mod = ($null -ne $v -and "$v" -ne "") } catch { $mod = $false } }
    if (-not $mod) { return $false }
    $val = $null; try { $val = $Request.Get($Va) } catch { }
    return ("$val" -ieq "true")
}

# Does the user CURRENTLY hold $Va? Read the controlled object ($DirObj) - ARS
# populates it with merged VA values in-service, so this returns a VA's current
# value even when the op is NOT modifying it. ($Request.Get only has modified
# attrs; external Get-QADUser doesn't surface VAs.) $DirObj is an ARS global.
function _HeldTrue {
    param($Request, [string]$Va)
    $v = $null
    try { $v = $DirObj.Get($Va) } catch { }
    if ($null -eq $v -or "$v" -eq "") { try { $v = $Request.Get($Va) } catch { } }
    return ("$v" -ieq "true")
}

function _LeafName {
    param([string]$DN)
    if ([string]::IsNullOrWhiteSpace($DN)) { return $DN }
    $first = $DN.Split(',')[0]; $eq = $first.IndexOf('=')
    if ($eq -ge 0) { return $first.Substring($eq + 1) }
    return $first
}

function _SamFromDN {
    param([string]$DN)
    try {
        $u = Get-QADUser $DN -DontUseDefaultIncludedProperties -IncludedProperties sAMAccountName -ErrorAction SilentlyContinue
        if ($u -and $u.sAMAccountName) { return "$($u.sAMAccountName)" }
    } catch { }
    return (_LeafName $DN)
}
