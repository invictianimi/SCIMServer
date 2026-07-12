# =============================================================================
#  UNITE 2026   |   One Identity UNITE Conference
#  Chicago, USA   |   June 2026   |   Grand Ballroom III
# =============================================================================
#  Script   : UNITE-Deploy-ADRoleGroups.ps1
#  Purpose  : Creates the AD role groups for the RBAC / SoD demo THROUGH Active
#             Roles (so ARS policy / workflow / audit fire on the creation).
#  Author   : Jacob Maloney  -  iC Consult, Presales Architect
#  Contact  : sales@ic-consult.com   (We build IAM that doesn't break.)
# =============================================================================
#
# Group names must match the role-map keys in UNITE-SCIMMappings.ps1
# ($script:SCIMRoles) - the workflow's RoleName is the group name, resolved by
# _AddToADGroup via Get-QADGroup.
#
# Needs a DOMAIN credential for Connect-QADService (SQL 'sa' does NOT apply - AD
# objects live in the directory, not the ARS config DB). Credentials are never
# stored: pass them, or you'll be prompted. Run it with the session '!' prefix
# so the password stays on your box:
#
#   ! powershell -ExecutionPolicy Bypass -File "C:\Users\jacob\source\repos\SCIMServer\ars-integration\UNITE-Deploy-ADRoleGroups.ps1" -ConnectionAccount "Domain\Administrator"
#
# (secure password prompt). Or pass -ConnectionPassword and -OUDN for a fully
# non-interactive run.
# =============================================================================

param(
    [string]$Service = "192.168.1.30",
    [string]$ConnectionAccount,                # e.g. "LAB\Administrator"; blank -> Get-Credential
    [string]$ConnectionPassword,               # blank -> prompt (kept off disk)
    [string]$OUDN,                             # target OU DN; blank -> auto-discover UNITE-2026, else CN=Users
    [string[]]$Groups = @("Finance Clerk","Accounts Payable","Accounts Receivable","IT Support")
)

$ErrorActionPreference = "Stop"
$mod = 'C:\Program Files\One Identity\Active Roles\8.2\Shell\ActiveRolesManagementShell\ActiveRolesManagementShell.psd1'
Import-Module $mod -WarningAction SilentlyContinue

# --- Connect through the AR Admin Service ------------------------------------
if ($ConnectionAccount -and $ConnectionPassword) {
    $sp = ConvertTo-SecureString $ConnectionPassword -AsPlainText -Force
    Connect-QADService -Service $Service -ConnectionAccount $ConnectionAccount -ConnectionPassword $sp | Out-Null
} elseif ($ConnectionAccount) {
    $cred = Get-Credential -UserName $ConnectionAccount -Message "Password for $ConnectionAccount (ARS connection)"
    Connect-QADService -Service $Service -Credential $cred | Out-Null
} else {
    $cred = Get-Credential -Message "ARS domain account (DOMAIN\user)"
    Connect-QADService -Service $Service -Credential $cred | Out-Null
}
Write-Host "Connected to AR Admin Service on $Service."

# --- Resolve the target OU --------------------------------------------------
if (-not $OUDN) {
    $ou = Get-QADObject -Type organizationalUnit -Name 'UNITE-2026' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($ou) {
        $OUDN = $ou.DN
    } else {
        $nc = (Get-QADRootDSE).defaultNamingContext
        $OUDN = "CN=Users,$nc"
        Write-Warning "No 'UNITE-2026' OU found - defaulting to $OUDN. Pass -OUDN to override."
    }
}
Write-Host "Creating role groups in: $OUDN`n"

# --- Create groups (idempotent) ---------------------------------------------
foreach ($g in $Groups) {
    $existing = Get-QADGroup -Name $g -ErrorAction SilentlyContinue
    if ($existing) { Write-Host "SKIP (exists): $g  [$($existing.DN)]"; continue }
    $sam = ($g -replace '\s','')   # "Accounts Payable" -> "AccountsPayable"
    $new = New-QADGroup -Name $g -ParentContainer $OUDN -GroupScope 'Global' -GroupType 'Security' -SamAccountName $sam
    Write-Host "CREATED: $g  [$($new.DN)]"
}

# --- Verify -----------------------------------------------------------------
Write-Host "`n=== Verify ==="
foreach ($g in $Groups) {
    $x = Get-QADGroup -Name $g -ErrorAction SilentlyContinue
    Write-Host ("  {0,-22} {1}" -f $g, $(if ($x) { $x.DN } else { 'NOT FOUND' }))
}

Disconnect-QADService | Out-Null
Write-Host "`nDone. These group names match the role map - the Add-to-Role workflow will find them."
