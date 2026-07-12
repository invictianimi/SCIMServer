# =============================================================================
#  UNITE 2026   |   One Identity UNITE Conference
#  Chicago, USA   |   June 2026   |   Grand Ballroom III
# =============================================================================
#  Script   : UNITE-HelpDesk.ps1
#  Purpose  : HelpDesk app entry points PLUS the shared, universal SCIM 2.0
#             provisioning + RBAC role-entitlement engine for Active Roles
#             workflows. One engine, any number of targets; the attribute /
#             role / ABAC maps live in UNITE-SCIMMappings. Per-app profiles
#             (e.g. UNITE-HRConnect.ps1) reuse the shared helpers here.
#             Deployed to ARS as the ScriptModule named "UNITE-Helpdesk".
#  Author   : Jacob Maloney  -  iC Consult, Presales Architect
#  Contact  : sales@ic-consult.com   (We build IAM that doesn't break.)
# =============================================================================

# Self-signed TLS bypass for the lab. COMMENT OUT IN PRODUCTION.
try {
    Add-Type -Language CSharp -ErrorAction SilentlyContinue @"
        using System.Net;
        using System.Net.Security;
        using System.Security.Cryptography.X509Certificates;
        public class TrustAllCertsPolicy : ICertificatePolicy {
            public bool CheckValidationResult(ServicePoint sp, X509Certificate cert,
                WebRequest req, int problem) { return true; }
        }
"@
    [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]'Tls12,Tls13'
} catch { }


# ============================================================================
# PUBLIC ENTRY POINTS
# ----------------------------------------------------------------------------
# Workflow XAML should call Dispatch-AllSCIM from a SINGLE PowerShellActivity.
# This function loops over every app in the mapping table, checks whether the
# matching SCIM-<App> virtual attribute changed in THIS submit, and routes
# the change to Provision or Remove. Multiple checkboxes toggled in one
# submit all get handled in one workflow run.
#
# Removal policy (Disable vs Delete) is per-app, read from $script:SCIMAppConfig
# in UNITE-SCIMMappings. Defaults to Disable.
# ============================================================================

# ----------------------------------------------------------------------------
# Per-app entry points - workflow XAML wires ONE of these per app, each gated
# by an IfElse that checks whether SCIM-<App> was modified in this submit.
# Each call processes exactly its own app, then throws a one-app summary so
# Change History gets a per-app activity entry with the structured outcome.
# ----------------------------------------------------------------------------

function Dispatch-HRConnect        { _Dispatch-OneApp -AppKey "HRConnect"        -Request $Request }
function Dispatch-ITHelpdeskPortal { _Dispatch-OneApp -AppKey "ITHelpdeskPortal" -Request $Request }
function Dispatch-FinanceSuite     { _Dispatch-OneApp -AppKey "FinanceSuite"     -Request $Request }

function _Dispatch-OneApp {
    param([string]$AppKey, $Request)

    # Fresh buffer per activity so the per-app throw only contains THIS app's lines.
    $script:DispatchResultLines = New-Object System.Collections.ArrayList

    $newValue = "$($Request.Get("SCIM-$AppKey"))"
    if ([string]::IsNullOrEmpty($newValue)) {
        # IfElse upstream should have gated this; defensive no-op.
        return
    }

    $isProvision = ($newValue -ieq "true")
    $isRemove    = ($newValue -ieq "false")
    if (-not ($isProvision -or $isRemove)) {
        throw "[$AppKey] Unexpected SCIM-$AppKey value '$newValue' (expected 'true' or 'false')."
    }

    $appLabel = switch ($AppKey) {
        "HRConnect"         { "HR Connect" }
        "ITHelpdeskPortal"  { "IT Helpdesk Portal" }
        "FinanceSuite"      { "Finance Suite" }
        default             { $AppKey }
    }

    try {
        if ($isProvision) { _Do-Provision -AppKey $AppKey -Request $Request }
        else              { _Do-Remove    -AppKey $AppKey -Request $Request }
    } catch {
        $err = "$($_.Exception.Message)"
        $revertTo = -not $isProvision
        [void]$script:DispatchResultLines.Add("[ERROR] $appLabel - $err")
        try {
            Set-QADObject $Request.DN -ObjectAttributes @{ "SCIM-$AppKey" = $revertTo } | Out-Null
            [void]$script:DispatchResultLines.Add("[INFO]  $appLabel - SCIM-$AppKey auto-reverted to $revertTo; re-toggle to retry")
        } catch {
            [void]$script:DispatchResultLines.Add("[WARN]  $appLabel - could not auto-revert SCIM-$AppKey ($($_.Exception.Message)); uncheck + re-check manually")
        }
    }

    # Throw the per-app summary so it lands in this activity's Change History entry.
    # The activity has SuppressError=True so the throw does not abort the workflow.
    if ($script:DispatchResultLines.Count -gt 0) {
        throw ($script:DispatchResultLines -join "`r`n")
    }
}

# Legacy bulk dispatcher - kept for back-compat, calls all per-app handlers in
# sequence. Not used by the new workflow XAML.
function Dispatch-AllSCIM {
    if (-not $script:SCIMMappings) {
        throw "SCIMMappings not loaded - the mapping table from UNITE-SCIMMappings must be concatenated into this ScriptModule."
    }

    $anyFailure = $false

    foreach ($app in $script:SCIMMappings.Keys) {
        # $Request.Get returns the new value only when the attribute was modified
        # in this submit. Empty/null otherwise - so untouched apps are skipped.
        $newValue = "$($Request.Get("SCIM-$app"))"
        if ([string]::IsNullOrEmpty($newValue)) { continue }

        $isProvision = ($newValue -ieq "true")
        $isRemove    = ($newValue -ieq "false")
        if (-not ($isProvision -or $isRemove)) {
            Write-Output "[$app] Unexpected SCIM-$app value '$newValue' - skipping (expected 'true' or 'false')"
            continue
        }

        # Wrap each per-app dispatch in try/catch so one app's failure
        # does not block the others. On failure, revert the checkbox to its
        # previous value so the user can retry by re-toggling. Natural
        # idempotency in _Do-Provision / _Do-Remove handles the workflow
        # re-trigger that the revert causes (no infinite loop).
        try {
            if ($isProvision) { _Do-Provision -AppKey $app -Request $Request }
            else              { _Do-Remove    -AppKey $app -Request $Request }
        } catch {
            $anyFailure = $true
            $errMsg = "$($_.Exception.Message)"
            $revertTo = -not $isProvision   # if Provision failed, was false before

            # Buffer the failure line through _Report-style accounting so the
            # final summary includes it. The exception object from _ReportError
            # has already been formatted with [App/Action] - keep it whole.
            $appLabel = switch ($app) {
                "HRConnect"         { "HR Connect" }
                "ITHelpdeskPortal"  { "IT Helpdesk Portal" }
                "FinanceSuite"      { "Finance Suite" }
                default             { $app }
            }
            if (-not $script:DispatchResultLines) { $script:DispatchResultLines = New-Object System.Collections.ArrayList }
            [void]$script:DispatchResultLines.Add("[ERROR] $appLabel - $errMsg")

            # Revert the AD attribute so the user can retry by re-toggling.
            try {
                Set-QADObject $Request.DN -ObjectAttributes @{ "SCIM-$app" = $revertTo } | Out-Null
                [void]$script:DispatchResultLines.Add("[INFO]  $appLabel - SCIM-$app auto-reverted to $revertTo; re-toggle to retry")
            } catch {
                [void]$script:DispatchResultLines.Add("[WARN]  $appLabel - could not auto-revert SCIM-$app ($($_.Exception.Message)); uncheck + re-check manually")
            }
        }
    }

    # Compose the human-readable summary.
    $lines = if ($script:DispatchResultLines) { @($script:DispatchResultLines) } else { @() }
    if ($lines.Count -eq 0) {
        # Workflow fired on a non-SCIM property change (e.g. self-modify from
        # the failure auto-revert). Silent no-op.
        return
    }
    $summary = "SCIM Provisioning Hub - per-app outcomes:`r`n" + ($lines -join "`r`n")

    # Reliability matters more than aesthetics here. ARS 8.2 surfaces THREE
    # things from a PowerShellActivity into Change History:
    #   - thrown exceptions (rendered with the activity)
    #   - the script's return value (rendered as the activity's output but
    #     not always expanded by default)
    #   - explicit AddRecordToReport activities (static text only)
    #
    # The most reliable channel for showing the multi-line summary is a
    # final throw. The PowerShellActivity in the workflow is configured with
    # SuppressError="True" so the throw does not abort the workflow - it
    # only attaches the text to the activity entry in Change History.
    Write-Output $summary
    throw $summary
}

# Legacy per-app entry points kept for back-compat with workflow XAML that
# still wires individual Provision-/Disable- branches. New deployments should
# use the single Dispatch-AllSCIM activity above.
function Provision-HRConnect        { _Do-Provision -AppKey "HRConnect"        -Request $Request }
function Disable-HRConnect          { _Do-Remove    -AppKey "HRConnect"        -Request $Request }
function Provision-ITHelpdeskPortal { _Do-Provision -AppKey "ITHelpdeskPortal" -Request $Request }
function Disable-ITHelpdeskPortal   { _Do-Remove    -AppKey "ITHelpdeskPortal" -Request $Request }
function Provision-FinanceSuite     { _Do-Provision -AppKey "FinanceSuite"     -Request $Request }
function Disable-FinanceSuite       { _Do-Remove    -AppKey "FinanceSuite"     -Request $Request }


# ============================================================================
# CORE DISPATCH
# ============================================================================

function _Do-Provision {
    param([string]$AppKey, $Request)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $ctx  = _Get-SCIMContext -AppKey $AppKey
        $user = _Get-UserAttributes -Request $Request
        if (-not $user.sAMAccountName) {
            _ReportError -AppKey $AppKey -Action "Provision" -Message "Could not read sAMAccountName from $($Request.DN)"
            return
        }

        $sam = "$($user.sAMAccountName)"
        $appUserName = _Get-AppUserName -AppKey $AppKey -User $user
        if (-not $appUserName) {
            $src = _Describe-UserNameSource -AppKey $AppKey
            _ReportError -AppKey $AppKey -Action "Provision" -Message "Cannot determine SCIM userName for $sam - source $src is empty in AD. Populate it and re-toggle."
            return
        }
        $existing = _Find-SCIMUser -Ctx $ctx -UserName $appUserName
        if ($existing) {
            # 'active' missing OR true == already-active. Only explicit false
            # means the record exists but disabled, in which case we reactivate.
            if ($existing.active -ne $false) {
                $sw.Stop()
                _Report -AppKey $AppKey -Action "Provision" -Verb "AlreadyActive" -UserName $appUserName -ScimId $existing.id -ElapsedMs $sw.ElapsedMilliseconds
                return
            }
            $body = _Build-PatchActive -Active $true
            $resp = _Invoke-SCIM -Method "PATCH" -Url ("{0}/{1}" -f $ctx.Uri, $existing.id) -Token $ctx.Token -Body $body
            $sw.Stop()
            _Report -AppKey $AppKey -Action "Provision" -Verb "Reactivated" -UserName $appUserName -ScimId $existing.id -ElapsedMs $sw.ElapsedMilliseconds
        } else {
            $body = _Build-CreateUser -AppKey $AppKey -User $user
            try {
                $resp = _Invoke-SCIM -Method "POST" -Url $ctx.Uri -Token $ctx.Token -Body $body
                $sw.Stop()
                _Report -AppKey $AppKey -Action "Provision" -Verb "Created" -UserName $appUserName -ScimId $resp.id -ElapsedMs $sw.ElapsedMilliseconds
            } catch {
                # 409 Conflict on POST means the server says the user already
                # exists - our initial Find missed it (case sensitivity, soft-
                # delete, partial index, race). Re-find by userName and treat
                # as the AlreadyActive / Reactivated outcome instead of bouncing
                # back through the failure path.
                $isConflict = $false
                $r = $_.Exception.Response
                if ($r -and [int]$r.StatusCode -eq 409) { $isConflict = $true }
                if (-not $isConflict) { throw }

                $retry = _Find-SCIMUser -Ctx $ctx -UserName $appUserName
                if (-not $retry) {
                    # Server says 409 but we still can't find it - genuinely confused.
                    _ReportError -AppKey $AppKey -Action "Provision" -Message "Server reported 409 Conflict but a follow-up Find returned no user. Manual cleanup may be needed."
                    return
                }
                # Treat "active missing or true" as active. Some SCIM servers
                # omit the 'active' property when it equals the default (true).
                # Only an explicit false means we need to reactivate via PATCH.
                if ($retry.active -ne $false) {
                    $sw.Stop()
                    _Report -AppKey $AppKey -Action "Provision" -Verb "AlreadyActive" -UserName $appUserName -ScimId $retry.id -ElapsedMs $sw.ElapsedMilliseconds
                } else {
                    $patchBody = _Build-PatchActive -Active $true
                    [void](_Invoke-SCIM -Method "PATCH" -Url ("{0}/{1}" -f $ctx.Uri, $retry.id) -Token $ctx.Token -Body $patchBody)
                    $sw.Stop()
                    _Report -AppKey $AppKey -Action "Provision" -Verb "Reactivated" -UserName $appUserName -ScimId $retry.id -ElapsedMs $sw.ElapsedMilliseconds
                }
            }
        }
    } catch {
        $sw.Stop()
        _ReportError -AppKey $AppKey -Action "Provision" -Message (_Classify-NoResponse $_)
    }
}

# Dispatch helper: read the per-app OnRemove policy and route to Disable or Delete.
function _Do-Remove {
    param([string]$AppKey, $Request)
    $cfg = Get-SCIMAppConfig -AppKey $AppKey
    $policy = if ($cfg -and $cfg.OnRemove) { $cfg.OnRemove } else { "Disable" }
    if ($policy -ieq "Delete") {
        _Do-Delete  -AppKey $AppKey -Request $Request
    } else {
        _Do-Disable -AppKey $AppKey -Request $Request
    }
}

function _Do-Disable {
    param([string]$AppKey, $Request)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $ctx  = _Get-SCIMContext -AppKey $AppKey
        $user = _Get-UserAttributes -Request $Request
        if (-not $user.sAMAccountName) {
            _ReportError -AppKey $AppKey -Action "Disable" -Message "Could not read sAMAccountName from $($Request.DN)"
            return
        }

        $sam = "$($user.sAMAccountName)"
        $appUserName = _Get-AppUserName -AppKey $AppKey -User $user
        if (-not $appUserName) {
            $src = _Describe-UserNameSource -AppKey $AppKey
            _ReportError -AppKey $AppKey -Action "Disable" -Message "Cannot determine SCIM userName for $sam - source $src is empty in AD."
            return
        }
        $existing = _Find-SCIMUser -Ctx $ctx -UserName $appUserName
        if (-not $existing) {
            $sw.Stop()
            _Report -AppKey $AppKey -Action "Disable" -Verb "SkippedNotPresent" -UserName $appUserName -ElapsedMs $sw.ElapsedMilliseconds
            return
        }
        if ($existing.active -eq $false) {
            $sw.Stop()
            _Report -AppKey $AppKey -Action "Disable" -Verb "AlreadyInactive" -UserName $appUserName -ScimId $existing.id -ElapsedMs $sw.ElapsedMilliseconds
            return
        }

        $body = _Build-PatchActive -Active $false
        $resp = _Invoke-SCIM -Method "PATCH" -Url ("{0}/{1}" -f $ctx.Uri, $existing.id) -Token $ctx.Token -Body $body
        $sw.Stop()
        _Report -AppKey $AppKey -Action "Disable" -Verb "Disabled" -UserName $appUserName -ScimId $existing.id -ElapsedMs $sw.ElapsedMilliseconds
    } catch {
        $sw.Stop()
        _ReportError -AppKey $AppKey -Action "Disable" -Message (_Classify-NoResponse $_)
    }
}

function _Do-Delete {
    param([string]$AppKey, $Request)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $ctx  = _Get-SCIMContext -AppKey $AppKey
        $user = _Get-UserAttributes -Request $Request
        if (-not $user.sAMAccountName) {
            _ReportError -AppKey $AppKey -Action "Delete" -Message "Could not read sAMAccountName from $($Request.DN)"
            return
        }

        $sam = "$($user.sAMAccountName)"
        $appUserName = _Get-AppUserName -AppKey $AppKey -User $user
        if (-not $appUserName) {
            $src = _Describe-UserNameSource -AppKey $AppKey
            _ReportError -AppKey $AppKey -Action "Delete" -Message "Cannot determine SCIM userName for $sam - source $src is empty in AD."
            return
        }
        $existing = _Find-SCIMUser -Ctx $ctx -UserName $appUserName
        if (-not $existing) {
            $sw.Stop()
            _Report -AppKey $AppKey -Action "Delete" -Verb "SkippedNotPresent" -UserName $appUserName -ElapsedMs $sw.ElapsedMilliseconds
            return
        }

        $resp = _Invoke-SCIM -Method "DELETE" -Url ("{0}/{1}" -f $ctx.Uri, $existing.id) -Token $ctx.Token -Body $null
        $sw.Stop()
        _Report -AppKey $AppKey -Action "Delete" -Verb "Deleted" -UserName $appUserName -ScimId $existing.id -ElapsedMs $sw.ElapsedMilliseconds
    } catch {
        $sw.Stop()
        _ReportError -AppKey $AppKey -Action "Delete" -Message (_Classify-NoResponse $_)
    }
}


# ============================================================================
# ROLE / ENTITLEMENT ENGINE  (RBAC fan-out to REST targets)
# ----------------------------------------------------------------------------
# A "role" is an AD security group. The role-map ($script:SCIMRoles in
# UNITE-SCIMMappings) says which SCIM Group entitlement that role grants in
# which target app. Adding a user to the AD role group -> Grant-RoleEntitlements
# fans the membership out to every mapped REST target. Removing it ->
# Revoke-RoleEntitlements. The user account is created on demand if it doesn't
# exist yet (granting a role makes the account that holds it).
#
# TRIGGER OPTIONS (wire ONE in the workflow; the core below is trigger-agnostic):
#   A) User-targeted  - workflow target is the USER, role supplied via workflow
#      parameter "RoleName" or the UNITE-RequestedRole VA. Cleanest $Request.
#      Entry points: Dispatch-RoleGrant / Dispatch-RoleRevoke (below).
#   B) Group-targeted - workflow target is the role GROUP, members extracted
#      from the member delta. Stronger governance claim (catches ADUC adds too)
#      but the member-delta read is ARS-build-specific - confirm in lab before
#      wiring, then call Grant-RoleEntitlements -RoleName <group cn> -UserDN <dn>
#      per added member.
# ============================================================================

# Resolve a SCIM Group by displayName. Tries the server-side filter first;
# falls back to listing + client-side match so the demo survives a target whose
# /Groups filter doesn't index displayName.
function _Find-SCIMGroup {
    param($Ctx, [string]$DisplayName)
    if ($Ctx.DryRun) { return $null }

    $escaped = $DisplayName -replace '\\','\\' -replace '"','\"'
    $filter  = [System.Web.HttpUtility]::UrlEncode(("displayName eq `"{0}`"" -f $escaped))
    $url     = "$($Ctx.BaseUri)/Groups?filter=$filter"
    try {
        $resp = _Invoke-SCIM -Method "GET" -Url $url -Token $Ctx.Token -Body $null
        if ($resp.Resources -and $resp.Resources.Count -gt 0) { return $resp.Resources[0] }
    } catch {
        # fall through to the unfiltered listing
    }

    # Fallback: list and match case-insensitively on displayName.
    $listUrl = "$($Ctx.BaseUri)/Groups?count=1000"
    $all = _Invoke-SCIM -Method "GET" -Url $listUrl -Token $Ctx.Token -Body $null
    if ($all.Resources) {
        foreach ($g in $all.Resources) {
            if ("$($g.displayName)" -ieq $DisplayName) { return $g }
        }
    }
    return $null
}

# PATCH op=add path=members. The SCIMServer GroupsController dedupes by value,
# so this is idempotent - a re-run won't double-add.
function _Add-SCIMGroupMember {
    param($Ctx, [string]$GroupId, [string]$UserScimId, [string]$Display)
    $body = [ordered]@{
        schemas    = @("urn:ietf:params:scim:api:messages:2.0:PatchOp")
        Operations = @(
            [ordered]@{
                op    = "add"
                path  = "members"
                value = @( [ordered]@{ value = $UserScimId; type = "User"; display = $Display } )
            }
        )
    }
    return _Invoke-SCIM -Method "PATCH" -Url ("{0}/Groups/{1}" -f $Ctx.BaseUri, $GroupId) -Token $Ctx.Token -Body $body
}

# PATCH op=remove path=members[value eq "<id>"] - the standard Okta/Azure
# SCIM client shape, matched by GroupsController.ApplyGroupPatchOperation.
function _Remove-SCIMGroupMember {
    param($Ctx, [string]$GroupId, [string]$UserScimId)
    $body = [ordered]@{
        schemas    = @("urn:ietf:params:scim:api:messages:2.0:PatchOp")
        Operations = @(
            [ordered]@{ op = "remove"; path = ("members[value eq `"{0}`"]" -f $UserScimId) }
        )
    }
    return _Invoke-SCIM -Method "PATCH" -Url ("{0}/Groups/{1}" -f $Ctx.BaseUri, $GroupId) -Token $Ctx.Token -Body $body
}

# Find the SCIM user for this app; create on demand if missing; reactivate if
# disabled. Returns the SCIM user object (with .id). Requires the app to also
# have a user mapping in $script:SCIMMappings (used for create + userName key).
function _Ensure-SCIMUser {
    param($Ctx, [string]$AppKey, $User)
    $appUserName = _Get-AppUserName -AppKey $AppKey -User $User
    if (-not $appUserName) {
        $src = _Describe-UserNameSource -AppKey $AppKey
        throw "cannot determine SCIM userName ($src empty in AD) - populate it, then re-grant."
    }
    $existing = _Find-SCIMUser -Ctx $Ctx -UserName $appUserName
    if ($existing) {
        if ($existing.active -eq $false) {
            [void](_Invoke-SCIM -Method "PATCH" -Url ("{0}/{1}" -f $Ctx.Uri, $existing.id) `
                    -Token $Ctx.Token -Body (_Build-PatchActive -Active $true))
        }
        return $existing
    }
    # Provision on demand - granting a role creates the account that holds it.
    $body = _Build-CreateUser -AppKey $AppKey -User $User
    [void](_Invoke-SCIM -Method "POST" -Url $Ctx.Uri -Token $Ctx.Token -Body $body)
    $created = _Find-SCIMUser -Ctx $Ctx -UserName $appUserName
    if (-not $created) { throw "provisioned $appUserName but a follow-up Find returned nothing." }
    return $created
}

# Core grant: fan a role's entitlements out to every mapped REST target.
# Trigger-agnostic - call with the role name and the user's DN.
function Grant-RoleEntitlements {
    param(
        [Parameter(Mandatory=$true)][string]$RoleName,
        [Parameter(Mandatory=$true)][string]$UserDN
    )
    $entitlements = Get-SCIMRole -RoleName $RoleName
    if (-not $entitlements -or $entitlements.Count -eq 0) {
        Write-Output "[INFO] Role '$RoleName' grants no REST entitlements (AD-only role) - nothing to fan out."
        return
    }

    $user = Get-QADUser $UserDN -DontUseDefaultIncludedProperties `
        -IncludedProperties sAMAccountName,givenName,sn,mail,displayName,department,title,employeeID,
                             telephoneNumber,mobile,company,manager
    if (-not $user) { throw "Grant-RoleEntitlements: Get-QADUser returned nothing for $UserDN" }

    $lines = New-Object System.Collections.ArrayList
    $hadError = $false

    foreach ($ent in $entitlements) {
        $appKey    = "$($ent.AppKey)"
        $groupName = "$($ent.Group)"
        try {
            $ctx      = _Get-SCIMContext -AppKey $appKey
            $scimUser = _Ensure-SCIMUser -Ctx $ctx -AppKey $appKey -User $user
            $group    = _Find-SCIMGroup -Ctx $ctx -DisplayName $groupName
            if (-not $group) {
                throw "entitlement group '$groupName' not found in $appKey - create it (POST /Groups) or fix the role map."
            }

            $already = $false
            if ($group.members) {
                foreach ($m in $group.members) { if ("$($m.value)" -eq "$($scimUser.id)") { $already = $true; break } }
            }
            if ($already) {
                [void]$lines.Add("[INFO]  $appKey / $groupName - $($user.sAMAccountName) already a member, no change")
            } else {
                [void](_Add-SCIMGroupMember -Ctx $ctx -GroupId $group.id -UserScimId $scimUser.id -Display "$($user.displayName)")
                [void]$lines.Add("[OK]    $appKey / $groupName - entitlement granted to $($user.sAMAccountName) (scimId=$($scimUser.id))")
            }
        } catch {
            $hadError = $true
            [void]$lines.Add("[ERROR] $appKey / $groupName - $($_.Exception.Message)")
        }
    }

    $summary = "Role grant '$RoleName' -> $($user.sAMAccountName):`r`n" + ($lines -join "`r`n")
    Write-Output $summary
    # Errors surface in Change History via throw; PowerShellActivity is
    # SuppressError=True so the workflow continues.
    if ($hadError) { throw $summary }
}

# Core revoke: remove the role's entitlements. Does NOT deprovision the account
# (losing a role != losing the user) - it only drops the group memberships.
function Revoke-RoleEntitlements {
    param(
        [Parameter(Mandatory=$true)][string]$RoleName,
        [Parameter(Mandatory=$true)][string]$UserDN
    )
    $entitlements = Get-SCIMRole -RoleName $RoleName
    if (-not $entitlements -or $entitlements.Count -eq 0) {
        Write-Output "[INFO] Role '$RoleName' grants no REST entitlements (AD-only role) - nothing to revoke."
        return
    }

    $user = Get-QADUser $UserDN -DontUseDefaultIncludedProperties `
        -IncludedProperties sAMAccountName,givenName,sn,mail,displayName,department,title,employeeID,
                             telephoneNumber,mobile,company,manager
    if (-not $user) { throw "Revoke-RoleEntitlements: Get-QADUser returned nothing for $UserDN" }

    $lines = New-Object System.Collections.ArrayList
    $hadError = $false

    foreach ($ent in $entitlements) {
        $appKey    = "$($ent.AppKey)"
        $groupName = "$($ent.Group)"
        try {
            $ctx = _Get-SCIMContext -AppKey $appKey
            $appUserName = _Get-AppUserName -AppKey $appKey -User $user
            if (-not $appUserName) {
                [void]$lines.Add("[INFO]  $appKey / $groupName - no resolvable userName for $($user.sAMAccountName), nothing to revoke")
                continue
            }
            $scimUser = _Find-SCIMUser -Ctx $ctx -UserName $appUserName
            if (-not $scimUser) {
                [void]$lines.Add("[INFO]  $appKey / $groupName - no account for $appUserName, nothing to revoke")
                continue
            }
            $group = _Find-SCIMGroup -Ctx $ctx -DisplayName $groupName
            if (-not $group) {
                [void]$lines.Add("[INFO]  $appKey / $groupName - entitlement group not found, nothing to revoke")
                continue
            }
            $isMember = $false
            if ($group.members) {
                foreach ($m in $group.members) { if ("$($m.value)" -eq "$($scimUser.id)") { $isMember = $true; break } }
            }
            if (-not $isMember) {
                [void]$lines.Add("[INFO]  $appKey / $groupName - $($user.sAMAccountName) not a member, nothing to revoke")
            } else {
                [void](_Remove-SCIMGroupMember -Ctx $ctx -GroupId $group.id -UserScimId $scimUser.id)
                [void]$lines.Add("[OK]    $appKey / $groupName - entitlement revoked from $($user.sAMAccountName)")
            }
        } catch {
            $hadError = $true
            [void]$lines.Add("[ERROR] $appKey / $groupName - $($_.Exception.Message)")
        }
    }

    $summary = "Role revoke '$RoleName' -> $($user.sAMAccountName):`r`n" + ($lines -join "`r`n")
    Write-Output $summary
    if ($hadError) { throw $summary }
}

# ----------------------------------------------------------------------------
# AD-side role membership helpers. The "role" is an AD security group; adding a
# user to it is the AD half of the grant (the REST half is Grant-RoleEntitlements).
# Tolerant of already-member / already-absent so the workflow is idempotent.
# ----------------------------------------------------------------------------
function _AddToADGroup {
    param([string]$GroupName, [string]$UserDN)
    $grp = Get-QADGroup $GroupName -ErrorAction SilentlyContinue
    if (-not $grp) { return "[AD] role group '$GroupName' not found - REST entitlement still granted, but the AD role membership was skipped." }
    try {
        Add-QADGroupMember $grp.DN -Member $UserDN -ErrorAction Stop | Out-Null
        return "[AD] added to role group '$GroupName'."
    } catch {
        $m = "$($_.Exception.Message)"
        if ($m -match "already a member|already exists") { return "[AD] already in role group '$GroupName' - no change." }
        # A Separation-of-Duties POLICY on the group will surface here as a thrown
        # error - re-throw so the caller reports the denial honestly.
        throw "[AD] add to role group '$GroupName' refused: $m"
    }
}

function _RemoveFromADGroup {
    param([string]$GroupName, [string]$UserDN)
    $grp = Get-QADGroup $GroupName -ErrorAction SilentlyContinue
    if (-not $grp) { return "[AD] role group '$GroupName' not found - nothing to remove on the AD side." }
    try {
        Remove-QADGroupMember $grp.DN -Member $UserDN -ErrorAction Stop | Out-Null
        return "[AD] removed from role group '$GroupName'."
    } catch {
        $m = "$($_.Exception.Message)"
        if ($m -match "not a member|cannot find") { return "[AD] not in role group '$GroupName' - no change." }
        return "[AD] remove from role group '$GroupName' note: $m"
    }
}

# ----------------------------------------------------------------------------
# Entry points (Trigger A - user-targeted). Workflow target is the USER.
# "Add to Role" / "Remove from Role" web-interface commands write the role name
# into UNITE-RequestedRole / UNITE-RemoveRole; the workflow triggers on that.
# Each grant does BOTH halves: AD role-group membership + REST entitlement fan-out.
# ----------------------------------------------------------------------------
function Dispatch-RoleGrant {
    $roleName = "$($Request.Get('UNITE-RequestedRole'))".Trim()
    if (-not $roleName) { $roleName = "$($Workflow.Parameter('RoleName'))".Trim() }
    if (-not $roleName) { Write-Output "[INFO] Dispatch-RoleGrant: no role requested - no-op."; return }

    $adNote = _AddToADGroup -GroupName $roleName -UserDN $Request.DN
    Write-Output $adNote
    Grant-RoleEntitlements -RoleName $roleName -UserDN $Request.DN

    # Clear the request marker so the command can be used again. Setting it to the
    # same empty value twice is not a change, so this does not loop.
    try { Set-QADObject $Request.DN -ObjectAttributes @{ 'UNITE-RequestedRole' = '' } | Out-Null } catch { }
}

function Dispatch-RoleRevoke {
    $roleName = "$($Request.Get('UNITE-RemoveRole'))".Trim()
    if (-not $roleName) { $roleName = "$($Workflow.Parameter('RoleName'))".Trim() }
    if (-not $roleName) { Write-Output "[INFO] Dispatch-RoleRevoke: no role requested - no-op."; return }

    $adNote = _RemoveFromADGroup -GroupName $roleName -UserDN $Request.DN
    Write-Output $adNote
    Revoke-RoleEntitlements -RoleName $roleName -UserDN $Request.DN

    try { Set-QADObject $Request.DN -ObjectAttributes @{ 'UNITE-RemoveRole' = '' } | Out-Null } catch { }
}

# ----------------------------------------------------------------------------
# Entry point (ABAC) - attribute-driven auto-assignment. Workflow target is the
# USER; trigger on the department change. Department -> role(s) via the ABAC map.
# SoD is enforced by the group-level onPreModify policy: a toxic auto-grant is
# refused at _AddToADGroup, logged, and the loop continues with other roles so
# one conflict doesn't sink the whole HR-driven assignment.
# ----------------------------------------------------------------------------
function Dispatch-ABACAutoAssign {
    $dept = "$($Request.Get('department'))".Trim()
    if (-not $dept) { Write-Output "[ABAC] no department on the change - no-op."; return }

    $roles = Get-ABACRolesForDept -Dept $dept
    if (-not $roles -or $roles.Count -eq 0) {
        Write-Output "[ABAC] department '$dept' maps to no roles - no-op."
        return
    }

    $lines = New-Object System.Collections.ArrayList
    foreach ($roleName in $roles) {
        try {
            $adNote = _AddToADGroup -GroupName $roleName -UserDN $Request.DN
            [void]$lines.Add("[ABAC] $dept -> $roleName : $adNote")
            Grant-RoleEntitlements -RoleName $roleName -UserDN $Request.DN
            [void]$lines.Add("[ABAC] $dept -> $roleName : REST entitlements fanned out.")
        } catch {
            # Most likely a SoD denial from the group policy - record and move on.
            [void]$lines.Add("[ABAC] $dept -> $roleName : SKIPPED - $($_.Exception.Message)")
        }
    }
    $summary = "ABAC auto-assign for department '$dept':`r`n" + ($lines -join "`r`n")
    Write-Output $summary
    throw $summary   # lands the per-role outcomes on the activity row; SuppressError=True keeps the workflow alive
}

# ============================================================================
# HELPDESK ROLES (boolean-per-role)  - the "start simple, build up" model
# ----------------------------------------------------------------------------
# Each HelpDesk role is a boolean virtual attribute on the user. Flipping it
# true grants the matching SCIM entitlement group in the HelpDesk target;
# false revokes it. One generic dispatcher; one thin entry point per role that
# the workflow's PowerShellActivity calls. Add Operator / Administrator later
# by adding two more entry points - same pattern, no new plumbing.
#
# Connection comes from the workflow parameters the engine already reads:
#   SCIM-HelpDesk-URI    e.g. http://localhost:5000/scim/v2/t/helpdesk
#   SCIM-HelpDesk-Token  the HelpDesk Connected System bearer token
#
# On any failure the role checkbox auto-reverts so the operator can re-toggle
# to retry (same reliability pattern as the Provisioning Hub).
# ============================================================================
function _Dispatch-OneRoleBool {
    param([string]$RoleVA, [string]$AppKey, [string]$Group, [string]$RoleLabel, $Request)

    # $Request.Get returns the new value only when this attribute changed in
    # THIS submit; empty/null otherwise - so an unrelated change is a no-op.
    $newValue = "$($Request.Get($RoleVA))"
    if ([string]::IsNullOrEmpty($newValue)) { return }

    $grant  = ($newValue -ieq "true")
    $revoke = ($newValue -ieq "false")
    if (-not ($grant -or $revoke)) { throw "[$RoleLabel] unexpected $RoleVA value '$newValue' (expected true/false)." }

    # Each decision is reported as its own line (Write-Output -> the activity's
    # detail in Change History) so the operator sees the story: did the user
    # exist, was it created, was it already in the role, was a removal skipped.
    try {
        $ctx     = _Get-SCIMContext -AppKey $AppKey
        $user    = _Get-UserAttributes -Request $Request
        $sam     = "$($user.sAMAccountName)"
        $appUser = _Get-AppUserName -AppKey $AppKey -User $user
        if (-not $appUser) { throw "cannot resolve the SCIM userName for $sam ($(_Describe-UserNameSource -AppKey $AppKey) is empty in AD)." }
        $scimUser = _Find-SCIMUser -Ctx $ctx -UserName $appUser

        if ($grant) {
            # STEP 1 - does the user exist in the target? provision if not.
            if (-not $scimUser) {
                Write-Output "[$RoleLabel] CHECK   : '$sam' not found in $AppKey -> provisioning a new account."
                [void](_Invoke-SCIM -Method "POST" -Url $ctx.Uri -Token $ctx.Token -Body (_Build-CreateUser -AppKey $AppKey -User $user))
                $scimUser = _Find-SCIMUser -Ctx $ctx -UserName $appUser
                if (-not $scimUser) { throw "provisioned $appUser but a follow-up lookup returned nothing." }
                Write-Output "[$RoleLabel] PROVISION: created '$sam' in $AppKey (scimId=$($scimUser.id))."
            } else {
                Write-Output "[$RoleLabel] CHECK   : '$sam' already exists in $AppKey (scimId=$($scimUser.id)) - no provisioning needed."
            }
            # STEP 2 - is the user already in the role? add if not.
            $g = _Find-SCIMGroup -Ctx $ctx -DisplayName $Group
            if (-not $g) { throw "entitlement group '$Group' not found in $AppKey - create it in SCIMServer." }
            $isMember = $false
            if ($g.members) { foreach ($m in $g.members) { if ("$($m.value)" -eq "$($scimUser.id)") { $isMember = $true; break } } }
            if ($isMember) { Write-Output "[$RoleLabel] ROLE    : '$sam' already holds '$Group' - no change." }
            else {
                [void](_Add-SCIMGroupMember -Ctx $ctx -GroupId $g.id -UserScimId $scimUser.id -Display "$($user.displayName)")
                Write-Output "[$RoleLabel] ROLE    : '$sam' was not in '$Group' -> added to role."
            }
        }
        else {
            # STEP 1 - does the user even exist in the target?
            if (-not $scimUser) {
                Write-Output "[$RoleLabel] CHECK   : '$sam' does not exist in $AppKey - entitlement removal skipped (nothing to remove)."
                return
            }
            Write-Output "[$RoleLabel] CHECK   : '$sam' exists in $AppKey (scimId=$($scimUser.id))."
            # STEP 2 - is the user actually in the role? remove if so.
            $g = _Find-SCIMGroup -Ctx $ctx -DisplayName $Group
            $isMember = $false
            if ($g -and $g.members) { foreach ($m in $g.members) { if ("$($m.value)" -eq "$($scimUser.id)") { $isMember = $true; break } } }
            if (-not $g) { Write-Output "[$RoleLabel] ROLE    : '$Group' not found in $AppKey - removal skipped." }
            elseif ($isMember) {
                [void](_Remove-SCIMGroupMember -Ctx $ctx -GroupId $g.id -UserScimId $scimUser.id)
                Write-Output "[$RoleLabel] ROLE    : removed '$Group' entitlement from '$sam'."
            }
            else { Write-Output "[$RoleLabel] ROLE    : entitlement removal skipped - '$sam' was not a member of '$Group'." }
        }
    }
    catch {
        # Report-only on failure (no checkbox auto-revert: it would re-trigger this
        # workflow and ping-pong when the target is unreachable). Surface the reason.
        $err = _Classify-NoResponse $_
        throw "[$RoleLabel] $err"
    }
}

# Combined entry point (check/provision + add/remove in one activity). Kept for
# back-compat; the split entry points below are what the 6-step workflow uses.
function Dispatch-HelpDeskAuditor {
    _Dispatch-OneRoleBool -RoleVA "UNITE-HelpDeskAuditor" -AppKey "HelpDesk" -Group "Auditors" -RoleLabel "HelpDesk Auditor" -Request $Request
}

# ----------------------------------------------------------------------------
# Split entry points - one ARS activity each, so the workflow reads as discrete
# steps: (2) verify/provision the account, then (3) add or remove the role.
#   Dispatch-HelpDeskAuditorAccount -> STEP 2 (ensure the account exists)
#   Dispatch-HelpDeskAuditorRole    -> STEP 3 (add on grant / remove on revoke)
# Both are self-contained (each re-resolves the SCIM user) so they work as
# independent activities, and each narrates its own decision to Change History.
# ----------------------------------------------------------------------------
function Dispatch-HelpDeskAuditorAccount {
    _EnsureRoleAccount  -RoleVA "UNITE-HelpDeskAuditor" -AppKey "HelpDesk" -RoleLabel "HelpDesk Auditor" -Request $Request
}
function Dispatch-HelpDeskAuditorRole {
    _SyncRoleMembership -RoleVA "UNITE-HelpDeskAuditor" -AppKey "HelpDesk" -Group "Auditors" -RoleLabel "HelpDesk Auditor" -Request $Request
}

# STEP 2 - ensure the target account exists. On grant: provision if missing.
# On revoke: just confirm existence (the role/disable steps handle the rest).
function _EnsureRoleAccount {
    param([string]$RoleVA, [string]$AppKey, [string]$RoleLabel, $Request)
    $newValue = "$($Request.Get($RoleVA))"
    if ([string]::IsNullOrEmpty($newValue)) { return }
    $grant = ($newValue -ieq "true")
    try {
        $ctx     = _Get-SCIMContext -AppKey $AppKey
        $user    = _Get-UserAttributes -Request $Request
        $sam     = "$($user.sAMAccountName)"
        $appUser = _Get-AppUserName -AppKey $AppKey -User $user
        if (-not $appUser) { throw "cannot resolve the SCIM userName for $sam ($(_Describe-UserNameSource -AppKey $AppKey) is empty in AD)." }
        $scimUser = _Find-SCIMUser -Ctx $ctx -UserName $appUser

        if ($grant) {
            if (-not $scimUser) {
                Write-Output "[$RoleLabel] CHECK    : '$sam' not found in $AppKey -> provisioning a new account."
                [void](_Invoke-SCIM -Method "POST" -Url $ctx.Uri -Token $ctx.Token -Body (_Build-CreateUser -AppKey $AppKey -User $user))
                Write-Output "[$RoleLabel] PROVISION: created '$sam' in $AppKey."
            }
            elseif ($scimUser.active -eq $false) {
                # Account exists but was disabled/suspended (e.g. a prior revoke).
                # Re-enable it BEFORE the role is applied so we never grant access
                # to a suspended account.
                Write-Output "[$RoleLabel] CHECK    : '$sam' exists in $AppKey but is DISABLED -> re-enabling before the role is applied."
                [void](_Invoke-SCIM -Method "PATCH" -Url ("{0}/{1}" -f $ctx.Uri, $scimUser.id) -Token $ctx.Token -Body (_Build-PatchActive -Active $true))
                Write-Output "[$RoleLabel] ENABLE   : reactivated '$sam' in $AppKey (active=true)."
            }
            else {
                Write-Output "[$RoleLabel] CHECK    : '$sam' already exists and is active in $AppKey - no change needed."
            }
        } else {
            if ($scimUser) { Write-Output "[$RoleLabel] CHECK    : '$sam' exists in $AppKey." }
            else           { Write-Output "[$RoleLabel] CHECK    : '$sam' does not exist in $AppKey - nothing to remove or disable." }
        }
    }
    catch { throw "[$RoleLabel] account step: $(_Classify-NoResponse $_)" }
}

# STEP 3 - add the role on grant, remove it on revoke. No-op (reported) if the
# account doesn't exist or the user isn't a member.
function _SyncRoleMembership {
    param([string]$RoleVA, [string]$AppKey, [string]$Group, [string]$RoleLabel, $Request)
    $newValue = "$($Request.Get($RoleVA))"
    if ([string]::IsNullOrEmpty($newValue)) { return }
    $grant = ($newValue -ieq "true")
    try {
        $ctx     = _Get-SCIMContext -AppKey $AppKey
        $user    = _Get-UserAttributes -Request $Request
        $sam     = "$($user.sAMAccountName)"
        $appUser = _Get-AppUserName -AppKey $AppKey -User $user
        $scimUser = if ($appUser) { _Find-SCIMUser -Ctx $ctx -UserName $appUser } else { $null }
        if (-not $scimUser) { Write-Output "[$RoleLabel] ROLE     : '$sam' has no $AppKey account - role step skipped."; return }

        $g = _Find-SCIMGroup -Ctx $ctx -DisplayName $Group
        if (-not $g) {
            if ($grant) { throw "entitlement group '$Group' not found in $AppKey - create it in SCIMServer." }
            Write-Output "[$RoleLabel] ROLE     : '$Group' not found in $AppKey - removal skipped."; return
        }
        $isMember = $false
        if ($g.members) { foreach ($m in $g.members) { if ("$($m.value)" -eq "$($scimUser.id)") { $isMember = $true; break } } }

        if ($grant) {
            if ($isMember) { Write-Output "[$RoleLabel] ROLE     : '$sam' already holds '$Group' - no change." }
            else {
                [void](_Add-SCIMGroupMember -Ctx $ctx -GroupId $g.id -UserScimId $scimUser.id -Display "$($user.displayName)")
                Write-Output "[$RoleLabel] ROLE     : added '$sam' to '$Group'."
            }
        } else {
            if ($isMember) {
                [void](_Remove-SCIMGroupMember -Ctx $ctx -GroupId $g.id -UserScimId $scimUser.id)
                Write-Output "[$RoleLabel] ROLE     : removed '$Group' entitlement from '$sam'."
            }
            else { Write-Output "[$RoleLabel] ROLE     : '$sam' was not a member of '$Group' - removal skipped." }
        }
    }
    catch { throw "[$RoleLabel] role step: $(_Classify-NoResponse $_)" }
}

# ----------------------------------------------------------------------------
# OPTIONAL revoke-side step: disable the target account after a role is removed.
# Wire this as a SEPARATE PowerShellActivity placed AFTER the role activity. If
# you want "uncheck = drop membership but keep the account active", simply
# DISABLE this activity in MMC - no code change needed. It only acts on a
# REVOKE (the role VA flipped to false); on a grant it is a no-op.
# ----------------------------------------------------------------------------
function Disable-HelpDeskAccount {
    _Disable-OneRoleAccount -RoleVA "UNITE-HelpDeskAuditor" -AppKey "HelpDesk" -RoleLabel "HelpDesk Auditor" -Request $Request
}

function _Disable-OneRoleAccount {
    param([string]$RoleVA, [string]$AppKey, [string]$RoleLabel, $Request)

    $newValue = "$($Request.Get($RoleVA))"
    if ([string]::IsNullOrEmpty($newValue)) { return }                       # attribute didn't change this submit
    if ($newValue -ieq "true") {                                            # this is a grant - never disable
        Write-Output "[$RoleLabel] DISABLE : grant in progress - account stays active, step skipped."
        return
    }

    try {
        $ctx     = _Get-SCIMContext -AppKey $AppKey
        $user    = _Get-UserAttributes -Request $Request
        $sam     = "$($user.sAMAccountName)"
        $appUser = _Get-AppUserName -AppKey $AppKey -User $user
        $scimUser = if ($appUser) { _Find-SCIMUser -Ctx $ctx -UserName $appUser } else { $null }

        if (-not $scimUser) {
            Write-Output "[$RoleLabel] DISABLE : '$sam' has no $AppKey account - nothing to disable."
            return
        }
        if ($scimUser.active -eq $false) {
            Write-Output "[$RoleLabel] DISABLE : '$sam' account already disabled - no change."
            return
        }
        [void](_Invoke-SCIM -Method "PATCH" -Url ("{0}/{1}" -f $ctx.Uri, $scimUser.id) -Token $ctx.Token -Body (_Build-PatchActive -Active $false))
        Write-Output "[$RoleLabel] DISABLE : deactivated '$sam' account in $AppKey (active=false)."
    }
    catch {
        throw "[$RoleLabel] disable failed: $(_Classify-NoResponse $_)"
    }
}

# ----------------------------------------------------------------------------
# OPTIONAL revoke-side step: PERMANENTLY DELETE the target account. This is the
# hard-deprovision alternative to Disable-HelpDeskAccount - wire it as a
# SEPARATE activity and enable EITHER disable OR delete (not both). Only acts on
# a REVOKE; on a grant it is a no-op. Leaving both this and the disable activity
# disabled means removal drops the role only and keeps the account active.
# ----------------------------------------------------------------------------
function Delete-HelpDeskAccount {
    _Delete-OneRoleAccount -RoleVA "UNITE-HelpDeskAuditor" -AppKey "HelpDesk" -RoleLabel "HelpDesk Auditor" -Request $Request
}

function _Delete-OneRoleAccount {
    param([string]$RoleVA, [string]$AppKey, [string]$RoleLabel, $Request)

    $newValue = "$($Request.Get($RoleVA))"
    if ([string]::IsNullOrEmpty($newValue)) { return }
    if ($newValue -ieq "true") {                                            # grant - never delete
        Write-Output "[$RoleLabel] DELETE  : grant in progress - account retained, step skipped."
        return
    }

    try {
        $ctx     = _Get-SCIMContext -AppKey $AppKey
        $user    = _Get-UserAttributes -Request $Request
        $sam     = "$($user.sAMAccountName)"
        $appUser = _Get-AppUserName -AppKey $AppKey -User $user
        $scimUser = if ($appUser) { _Find-SCIMUser -Ctx $ctx -UserName $appUser } else { $null }

        if (-not $scimUser) {
            Write-Output "[$RoleLabel] DELETE  : '$sam' has no $AppKey account - nothing to delete."
            return
        }
        [void](_Invoke-SCIM -Method "DELETE" -Url ("{0}/{1}" -f $ctx.Uri, $scimUser.id) -Token $ctx.Token -Body $null)
        Write-Output "[$RoleLabel] DELETE  : permanently deleted '$sam' from $AppKey (record removed)."
    }
    catch {
        throw "[$RoleLabel] delete failed: $(_Classify-NoResponse $_)"
    }
}

# Role-named aliases for the Auditor disable/delete (match the Operator/Admin
# convention below, so all three roles share the identical *-HelpDesk<Role>Account
# naming). The original Disable-HelpDeskAccount / Delete-HelpDeskAccount are kept
# for the already-deployed Auditor workflow.
function Disable-HelpDeskAuditorAccount {
    _Disable-OneRoleAccount -RoleVA "UNITE-HelpDeskAuditor" -AppKey "HelpDesk" -RoleLabel "HelpDesk Auditor" -Request $Request
}
function Delete-HelpDeskAuditorAccount {
    _Delete-OneRoleAccount  -RoleVA "UNITE-HelpDeskAuditor" -AppKey "HelpDesk" -RoleLabel "HelpDesk Auditor" -Request $Request
}

# ============================================================================
# OPERATOR role - clone of the Auditor entry points (same parameterized helpers,
# different VA / entitlement group / label). VA: UNITE-HelpDeskOperator;
# SCIM group: "Operators".
# ============================================================================
function Dispatch-HelpDeskOperatorAccount {
    _EnsureRoleAccount  -RoleVA "UNITE-HelpDeskOperator" -AppKey "HelpDesk" -RoleLabel "HelpDesk Operator" -Request $Request
}
function Dispatch-HelpDeskOperatorRole {
    _SyncRoleMembership -RoleVA "UNITE-HelpDeskOperator" -AppKey "HelpDesk" -Group "Operators" -RoleLabel "HelpDesk Operator" -Request $Request
}
function Disable-HelpDeskOperatorAccount {
    _Disable-OneRoleAccount -RoleVA "UNITE-HelpDeskOperator" -AppKey "HelpDesk" -RoleLabel "HelpDesk Operator" -Request $Request
}
function Delete-HelpDeskOperatorAccount {
    _Delete-OneRoleAccount -RoleVA "UNITE-HelpDeskOperator" -AppKey "HelpDesk" -RoleLabel "HelpDesk Operator" -Request $Request
}

# ============================================================================
# ADMINISTRATOR role - clone of the Auditor entry points. VA:
# UNITE-HelpDeskAdministrator; SCIM group: "Administrators".
# ============================================================================
function Dispatch-HelpDeskAdministratorAccount {
    _EnsureRoleAccount  -RoleVA "UNITE-HelpDeskAdministrator" -AppKey "HelpDesk" -RoleLabel "HelpDesk Administrator" -Request $Request
}
function Dispatch-HelpDeskAdministratorRole {
    _SyncRoleMembership -RoleVA "UNITE-HelpDeskAdministrator" -AppKey "HelpDesk" -Group "Administrators" -RoleLabel "HelpDesk Administrator" -Request $Request
}
function Disable-HelpDeskAdministratorAccount {
    _Disable-OneRoleAccount -RoleVA "UNITE-HelpDeskAdministrator" -AppKey "HelpDesk" -RoleLabel "HelpDesk Administrator" -Request $Request
}
function Delete-HelpDeskAdministratorAccount {
    _Delete-OneRoleAccount -RoleVA "UNITE-HelpDeskAdministrator" -AppKey "HelpDesk" -RoleLabel "HelpDesk Administrator" -Request $Request
}


# ============================================================================
# MAPPING ENGINE - reads $script:SCIMMappings from UNITE-SCIMMappings
# ============================================================================

# Resolves the SCIM userName for this app by running the mapping's "userName"
# entry through _Resolve-MappingValue. Returns $null if the source AD attribute
# is empty - which is a hard-stop for both Find (no key to search on) and
# Provision (server will 400 with "userName is required").
function _Get-AppUserName {
    param([string]$AppKey, $User)
    $mapping = Get-SCIMMapping -AppKey $AppKey
    if (-not $mapping.ContainsKey("userName")) { return $null }
    $val = _Resolve-MappingValue -Source $mapping["userName"] -User $User
    if ($null -eq $val -or $val -eq "") { return $null }
    return "$val"
}

# Human-readable description of where the app's userName comes from, for error
# messages. "=literal" -> the literal; "{ ... }" scriptblock -> "<computed>";
# plain string -> the AD attribute name.
function _Describe-UserNameSource {
    param([string]$AppKey)
    $mapping = Get-SCIMMapping -AppKey $AppKey
    if (-not $mapping.ContainsKey("userName")) { return "<unmapped>" }
    $src = $mapping["userName"]
    if ($src -is [scriptblock]) { return "<computed>" }
    if ($src -is [string]) {
        if ($src.StartsWith("=")) { return "literal '$($src.Substring(1))'" }
        return "AD attribute '$src'"
    }
    return "$src"
}

function _Build-CreateUser {
    param([string]$AppKey, $User)

    $mapping = Get-SCIMMapping -AppKey $AppKey
    $payload = [ordered]@{
        schemas = @("urn:ietf:params:scim:schemas:core:2.0:User")
    }
    $hasEnterprise = $false

    foreach ($scimPath in $mapping.Keys) {
        $source = $mapping[$scimPath]
        $value  = _Resolve-MappingValue -Source $source -User $User
        if ($null -eq $value -or $value -eq "") { continue }

        # Normalize booleans coming through as strings (e.g. "=true")
        if ($value -is [string] -and ($value -eq "true" -or $value -eq "false")) {
            $value = [bool]::Parse($value)
        }

        if ($scimPath -like "enterprise.*") { $hasEnterprise = $true }
        _Set-SCIMPath -Payload $payload -Path $scimPath -Value $value
    }

    if ($hasEnterprise) {
        $payload.schemas += "urn:ietf:params:scim:schemas:extension:enterprise:2.0:User"
    }
    return $payload
}

function _Resolve-MappingValue {
    param($Source, $User)

    $raw = $null
    if ($Source -is [scriptblock]) {
        try { $raw = (& $Source $User) } catch {
            # Don't swallow silently - a future scriptblock for a required
            # field (e.g. userName) failing this way would surface only as
            # "source <computed> is empty in AD" with no hint of the real
            # error. Write to the script trace so the operator can see it
            # without breaking the dispatch.
            Write-Output "[WARN] scriptblock mapping threw: $($_.Exception.Message)"
            return $null
        }
    }
    elseif ($Source -is [string]) {
        if ($Source.StartsWith("=")) { return $Source.Substring(1) }
        $raw = $User.$Source
    }
    else { $raw = $Source }

    # Quest AD cmdlets return ETS-decorated objects (e.g. ResultPropertyValueCollection)
    # rather than plain strings. ConvertTo-Json serializes those as nested objects
    # ({"Length":5,"name":"Jacob"}) which the SCIM server rejects with a 500.
    # Coerce to a clean string here so downstream JSON is always primitive-shaped.
    if ($null -eq $raw) { return $null }
    if ($raw -is [string]) { return $raw }
    if ($raw -is [bool])   { return $raw }
    if ($raw -is [System.Collections.IEnumerable] -and -not ($raw -is [string])) {
        # Multi-valued AD attr - take the first element and string-coerce.
        foreach ($v in $raw) { return "$v" }
        return $null
    }
    return "$raw"
}

# Walks a path like "name.givenName", "emails[0].value", or "enterprise.department"
# and writes the value into the payload hashtable, creating intermediate
# nodes as needed.
function _Set-SCIMPath {
    param($Payload, [string]$Path, $Value)

    $enterpriseUrn = "urn:ietf:params:scim:schemas:extension:enterprise:2.0:User"

    # Re-key "enterprise.*" to the urn-prefixed extension key.
    if ($Path -like "enterprise.*") {
        $rest = $Path.Substring("enterprise.".Length)
        if (-not $Payload.Contains($enterpriseUrn)) {
            $Payload[$enterpriseUrn] = [ordered]@{}
        }
        _Set-NestedPath -Node $Payload[$enterpriseUrn] -Segments (_Tokenize-Path $rest) -Value $Value
        return
    }

    _Set-NestedPath -Node $Payload -Segments (_Tokenize-Path $Path) -Value $Value
}

# Tokenize "emails[0].value" -> @("emails", "[0]", "value")
function _Tokenize-Path {
    param([string]$Path)
    $tokens = @()
    foreach ($part in $Path.Split('.')) {
        $m = [regex]::Match($part, '^([^\[]+)(\[(\d+)\])?$')
        if ($m.Success) {
            $tokens += $m.Groups[1].Value
            if ($m.Groups[2].Success) { $tokens += "[$($m.Groups[3].Value)]" }
        } else {
            $tokens += $part
        }
    }
    return $tokens
}

function _Set-NestedPath {
    param($Node, [object[]]$Segments, $Value)

    for ($i = 0; $i -lt $Segments.Count; $i++) {
        $seg     = $Segments[$i]
        $isLast  = ($i -eq $Segments.Count - 1)
        $isIndex = $seg -match '^\[(\d+)\]$'

        if ($isIndex) {
            $idx = [int]$Matches[1]
            # $Node is expected to be a System.Collections.ArrayList from previous step
            while ($Node.Count -le $idx) { [void]$Node.Add([ordered]@{}) }
            if ($isLast) { $Node[$idx] = $Value } else { $Node = $Node[$idx] }
            continue
        }

        # Look ahead: is the next segment an array index?
        $nextIsIndex = (-not $isLast) -and ($Segments[$i+1] -match '^\[\d+\]$')

        if ($isLast) {
            $Node[$seg] = $Value
        } else {
            if (-not $Node.Contains($seg)) {
                if ($nextIsIndex) {
                    $Node[$seg] = New-Object System.Collections.ArrayList
                } else {
                    $Node[$seg] = [ordered]@{}
                }
            }
            $Node = $Node[$seg]
        }
    }
}

function _Build-PatchActive {
    param([bool]$Active)
    return [ordered]@{
        schemas    = @("urn:ietf:params:scim:api:messages:2.0:PatchOp")
        Operations = @(
            [ordered]@{ op = "replace"; path = "active"; value = $Active }
        )
    }
}


# ============================================================================
# AD READ + WORKFLOW CONFIG
# ============================================================================

function _Get-UserAttributes {
    param($Request)
    $u = Get-QADUser $Request.DN -DontUseDefaultIncludedProperties `
        -IncludedProperties sAMAccountName,givenName,sn,mail,displayName,department,title,employeeID,
                             telephoneNumber,mobile,company,manager,extensionAttribute1,extensionAttribute2,
                             extensionAttribute3,extensionAttribute4,extensionAttribute5
    if (-not $u) { throw "Get-QADUser returned nothing for $($Request.DN)" }
    return $u
}

function _Get-SCIMContext {
    param([string]$AppKey)

    $uriParam   = "SCIM-$AppKey-URI"
    $tokenParam = "SCIM-$AppKey-Token"

    $uri   = $Workflow.Parameter($uriParam)
    $token = $Workflow.Parameter($tokenParam)

    # Trim BOTH ends - MMC sometimes saves values with a leading space.
    if ($uri)   { $uri   = $uri.Trim() }
    if ($token) { $token = $token.Trim() }

    # The token parameter is a SecureString - ARS encrypted it with its service
    # key when it was saved. Decrypt it with the ARS-native cryptography helper:
    # the same $Security.Cryptography.DecryptFromString pattern One Identity uses
    # for stored credentials. A plain-text value (legacy String param) falls
    # through the catch unchanged, so nothing breaks during the switch-over.
    if ($token) {
        try   { $token = "$($Security.Cryptography.DecryptFromString($token))".Trim() }
        catch { }   # not ARS-encrypted -> already plain text, use as-is
    }

    if (-not $uri)   { throw "Workflow parameter '$uriParam' is empty. Open the workflow's Parameters dialog in MMC and set it." }
    if (-not $token) { throw "Workflow parameter '$tokenParam' is empty. Open the workflow's Parameters dialog in MMC, click in the value field, paste the FULL bearer token (exactly as your SCIM provider gave you - SCIMServer mints with a 'scim_' prefix, Okta/Auth0/etc. don't), and OK. If you see ******** but get this error, the previous save did not persist - re-enter it." }

    # NOTE: the engine deliberately does NOT munge the token. Whatever the
    # admin pasted is what gets sent verbatim after 'Bearer '. SCIMServer
    # happens to mint tokens with a 'scim_' prefix; other SCIM providers
    # don't. The token format is the SCIM provider's contract, not ours.

    # Tolerate trailing /Users - script appends it itself.
    $uri = $uri.TrimEnd('/')
    if ($uri.EndsWith("/Users")) { $uri = $uri.Substring(0, $uri.Length - "/Users".Length) }

    # Warn (don't block) when the URI is plain HTTP. The cert-trust callback
    # at the top of this script makes http silently work, which is convenient
    # for the lab but dangerous in production - tokens travel in cleartext.
    if ($uri -notmatch '^https://') {
        Write-Output "[WARN] $AppKey URI is not HTTPS ('$uri') - bearer token will travel in cleartext. Use only for lab/demo."
    }

    return @{
        AppKey  = $AppKey
        BaseUri = $uri            # tenant root, e.g. .../scim/v2/t/finance-suite
        Uri     = "$uri/Users"    # back-compat: existing /Users dispatch uses this
        Token   = $token
        DryRun  = ($Workflow.Parameter("SCIM-DryRun") -eq "true")
    }
}


# ============================================================================
# SCIM HTTP
# ============================================================================

function _Find-SCIMUser {
    param($Ctx, [string]$UserName)
    if ($Ctx.DryRun) { return $null }

    # SCIM filter strings escape backslash and double-quote per RFC 7644 sec 3.4.2.2.
    # Without this, a userName containing " or \ produces a syntactically invalid
    # filter (e.g. `userName eq "foo"bar"`) - URL-encoding can't fix bad SCIM syntax.
    # NB: in PowerShell -replace, the replacement string is .NET regex
    # replacement syntax where backslash is NOT special; only '$' is. So we
    # write '\\' (2 chars) to emit two backslashes, and '\"' (2 chars) to emit
    # backslash + quote.
    $escaped = $UserName -replace '\\','\\' -replace '"','\"'
    $filter  = [System.Web.HttpUtility]::UrlEncode(("userName eq `"{0}`"" -f $escaped))
    $url     = "$($Ctx.Uri)?filter=$filter"
    $resp   = _Invoke-SCIM -Method "GET" -Url $url -Token $Ctx.Token -Body $null
    if ($resp.Resources -and $resp.Resources.Count -gt 0) { return $resp.Resources[0] }
    return $null
}

function _Invoke-SCIM {
    param([string]$Method, [string]$Url, [string]$Token, $Body)

    $headers = @{
        "Authorization" = "Bearer $Token"
        "Accept"        = "application/scim+json"
    }
    $params = @{
        Method  = $Method
        Uri     = $Url
        Headers = $headers
        UseBasicParsing = $true
        ErrorAction = "Stop"
        TimeoutSec = 10          # never let an unreachable target hang the operation (~100s default)
    }
    if ($Body) {
        $params["ContentType"] = "application/scim+json"
        $params["Body"]        = ($Body | ConvertTo-Json -Depth 10 -Compress)
    }

    $raw = Invoke-WebRequest @params

    # In PowerShell 5.1 (ARS host), Invoke-WebRequest returns $raw.Content as
    # byte[] for any Content-Type that is not "text/*". SCIM 2.0 mandates
    # "application/scim+json", which means Content arrives as bytes and piping
    # it into ConvertFrom-Json silently fails (no exception, no warning - you
    # just get $null back). That is the root cause of Find-misses on records
    # that DO exist server-side. Decode bytes -> UTF-8 string explicitly so
    # parsing is reliable across PS 5.1, PS 7, and every SCIM 2.0 vendor.
    $body = $raw.Content
    if ($body -is [byte[]]) {
        if ($body.Length -eq 0) { return $null }
        $body = [System.Text.Encoding]::UTF8.GetString($body)
    }
    if ([string]::IsNullOrWhiteSpace($body)) { return $null }
    return ($body | ConvertFrom-Json)
}


# ============================================================================
# REPORTING / ERROR CLASSIFICATION
# ============================================================================

function _Report {
    param(
        [string]$AppKey,
        [string]$Action,
        [string]$Verb,           # Created, Reactivated, AlreadyActive, Disabled, AlreadyInactive, Deleted, SkippedNotPresent
        [string]$UserName,
        [string]$ScimId = $null,
        [string]$Note   = $null,
        [long]  $ElapsedMs = 0
    )
    $appLabel = switch ($AppKey) {
        "HRConnect"         { "HR Connect" }
        "ITHelpdeskPortal"  { "IT Helpdesk Portal" }
        "FinanceSuite"      { "Finance Suite" }
        default             { $AppKey }
    }
    # Consistent shape: "[ICON]  AppLabel - action for user, context"
    $line = switch ($Verb) {
        "Created"           { "[OK]    $appLabel - new account provisioned for $UserName, AD identity linked" }
        "Reactivated"       { "[OK]    $appLabel - existing account reactivated for $UserName, was disabled" }
        "AlreadyActive"     { "[INFO]  $appLabel - account already exists for $UserName, linked to AD identity - no change needed" }
        "Disabled"          { "[OK]    $appLabel - account disabled for $UserName, assignment removed (record retained)" }
        "AlreadyInactive"   { "[INFO]  $appLabel - account already disabled for $UserName - no change needed" }
        "Deleted"           { "[OK]    $appLabel - account deleted for $UserName per tenant policy" }
        "SkippedNotPresent" { "[INFO]  $appLabel - no account found for $UserName, nothing to disable - assignment marker cleared" }
        default             { "[OK]    $appLabel - $Verb for $UserName" }
    }
    if ($ScimId)          { $line += "  (scimId=$ScimId)" }
    if ($Note)            { $line += "  ($Note)" }
    if ($ElapsedMs -gt 0) { $line += "  [${ElapsedMs}ms]" }

    # Successes and idempotent no-ops (AlreadyActive / SkippedNotPresent /
    # AlreadyInactive) go to the script trace - visible when you click into
    # the activity in Change History, but NOT thrown. ARS only renders thrown
    # text in the main Change History row, so throwing here would mark every
    # happy-path dispatch as "Activity encountered an error". Only genuine
    # failures (network/auth/5xx) should land in $script:DispatchResultLines
    # and produce a throw - that work happens in _ReportError + the catch
    # block in _Dispatch-OneApp.
    Write-Output $line
}

function _ReportError {
    param([string]$AppKey, [string]$Action, [string]$Message)
    $appLabel = switch ($AppKey) {
        "HRConnect"         { "HR Connect" }
        "ITHelpdeskPortal"  { "IT Helpdesk Portal" }
        "FinanceSuite"      { "Finance Suite" }
        default             { $AppKey }
    }
    # throw is the ONLY thing ARS surfaces as an error in Change History.
    throw "[$appLabel/$Action] $Message"
}

function _Classify-NoResponse {
    param($Err)
    $msg = if ($Err.Exception.Message) { $Err.Exception.Message } else { "$Err" }
    $resp = $Err.Exception.Response

    # Capture the SCIM error response body when there is one - its 'detail'
    # field names the real failure (e.g. "NullReferenceException: ...").
    $body = ""
    if ($resp) {
        try {
            $sr = New-Object System.IO.StreamReader($resp.GetResponseStream())
            $body = $sr.ReadToEnd(); $sr.Close()
            if ($body.Length -gt 400) { $body = $body.Substring(0, 400) + "..." }
        } catch { }
    }
    $bodyTail = if ($body) { " - server said: $body" } else { "" }

    if ($resp) {
        switch ([int]$resp.StatusCode) {
            401 { return "401 Unauthorized - token rejected. Paste the FULL 'scim_<value>' mint string into the workflow token parameter.$bodyTail" }
            403 { return "403 Forbidden - token is valid but scoped to a different Connected System.$bodyTail" }
            404 { return "404 Not Found - the URI's tenant slug does not match any Connected System.$bodyTail" }
            409 { return "409 Conflict - user already exists; benign race between Find and Create.$bodyTail" }
            429 { return "429 Rate limited - back off and retry.$bodyTail" }
            default {
                $code = [int]$resp.StatusCode
                if ($code -ge 500) { return "$code Server error.$bodyTail" }
                return "$code $msg.$bodyTail"
            }
        }
    }
    if ($msg -match "actively refused|No connection could be made") { return "Connection refused - is SCIMServer running on the configured host:port?" }
    if ($msg -match "remote name could not be resolved")             { return "DNS failure - check the host in the URI" }
    if ($msg -match "timed out")                                     { return "Timeout - SCIMServer did not respond" }
    if ($msg -match "SSL|TLS|certificate")                           { return "TLS error - self-signed cert; enable the TrustAllCertsPolicy block at top of script for lab use" }
    return $msg
}
