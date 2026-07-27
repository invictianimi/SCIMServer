# =============================================================================
#  UNITE 2026   |   One Identity UNITE Conference
#  Chicago, USA   |   June 2026   |   Grand Ballroom III
# =============================================================================
#  Script   : UNITE-Deploy-RoleWorkflows.ps1
#  Purpose  : Deploys the UNITE script modules + the RBAC / ABAC / SoD workflows
#             into Active Roles (idempotent, re-runnable, direct-SQL).
#  Author   : Jacob Maloney  -  iC Consult, Presales Architect
#  Contact  : sales@ic-consult.com   (We build IAM that doesn't break.)
# =============================================================================
#
# Creates / updates:
#
#   ScriptModules:
#     UNITE-Helpdesk    - mappings + engine + role/ABAC dispatchers (concatenated)
#     UNITE-SoDPolicy   - Separation-of-Duties gate + onPreModify policy handler
#
#   Workflows (all Change Workflows scoped to the UNITE-2026 AD container):
#     UNITE - Add to Role        trigger: modify user UNITE-RequestedRole
#                                SoD gate (abort on conflict) -> grant AD group + REST
#     UNITE - Remove from Role   trigger: modify user UNITE-RemoveRole
#                                revoke AD group + REST entitlement
#     UNITE - ABAC Auto-Assign   trigger: modify user department
#                                department -> role(s) -> grant (SoD policy guards)
#
# MANUAL steps still required (see the banner printed at the end):
#   - Create the virtual attributes UNITE-RequestedRole / UNITE-RemoveRole in MMC
#     and restart the AR Administration Service (new VAs aren't created here -
#     VirtualSchema inserts from scratch aren't proven; renames are).
#   - Create the AD role groups + the SCIM entitlement groups in SCIMServer.
#   - Bind UNITE-SoDPolicy as a Policy Object (Script Execution, onPreModify) on
#     the role-groups' container for the strongest hard-stop.
#   - Add the "Add to Role" / "Remove from Role" Web Interface commands.
#   - Set the SCIM-*-URI / SCIM-*-Token workflow parameters to match your lab.
#
# Brought to you by iC Consult - We build IAM solutions that don't break.
# =============================================================================

param(
    [string]$Server   = "192.168.1.30",
    [string]$Database = "ActiveRoles820",
    [string]$User     = "sa",
    [string]$Password = $env:LAB_SQL_PASSWORD,

    # Config-tree containers (lab GUIDs - same as the Extend Contractor deploy).
    [string]$ScriptModuleParentGuid = "b184d443-23d5-4c99-b0d0-8cdc4ec1da37",  # CN=UNITE-2026,CN=Script Modules
    [string]$WorkflowParentGuid     = "32e903fc-097e-49d3-9a7c-1f3eeedf3e4d",  # CN=UNITE-2026,CN=Workflow,CN=Policies
    [string]$AdScopeContainerGuid   = "80a8172f-2d21-4035-b5d0-2675f24b66a1",  # AD OU the workflows apply to

    # Demo SCIM endpoints + tokens (override to match your lab). These become the
    # default values of the workflow parameters the engine reads via $Workflow.Parameter.
    [string]$FinanceUri   = "http://localhost:5000/scim/v2/t/finance-suite",
    [string]$FinanceToken = "demo-finance-2024",
    [string]$HelpdeskUri  = "http://localhost:5000/scim/v2/t/it-helpdesk-portal",
    [string]$HelpdeskToken= "demo-it-2024"
)

$ErrorActionPreference = "Stop"
$cs = "Server=$Server;Database=$Database;User Id=$User;Password=$Password;TrustServerCertificate=true;"

# -----------------------------------------------------------------------------
# Read + parse-check source. UNITE-SCIMRest module = mappings on top, engine below.
# -----------------------------------------------------------------------------
function Read-PsFile {
    param([string]$Path)
    if (-not (Test-Path $Path)) { Write-Error "Source not found: $Path"; exit 1 }
    $text = [System.IO.File]::ReadAllText($Path)
    $tokens = $errors = $null
    [System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors.Count -ne 0) {
        $errors | ForEach-Object { Write-Host "PARSE ERR ($Path) line $($_.Extent.StartLineNumber): $($_.Message)" }
        exit 1
    }
    return $text
}

$mappingsText = Read-PsFile (Join-Path $PSScriptRoot "UNITE-SCIMMappings.ps1")
$engineText   = Read-PsFile (Join-Path $PSScriptRoot "UNITE-HelpDesk.ps1")
$sodText      = Read-PsFile (Join-Path $PSScriptRoot "UNITE-SoDPolicy.ps1")

$scimModuleText = $mappingsText + "`r`n`r`n" + $engineText

$conn = New-Object System.Data.SqlClient.SqlConnection $cs
$conn.Open()

# -----------------------------------------------------------------------------
# ScriptModule upsert - get-or-create, return GUID. (objectClass=edsScriptModule,
# edsaScriptType=0 for PowerShell - both per the direct-SQL deploy reference.)
# -----------------------------------------------------------------------------
function Upsert-ScriptModule {
    param([System.Data.SqlClient.SqlConnection]$Conn, [string]$Name, [string]$Text, [string]$ParentGuid)

    $g = $Conn.CreateCommand()
    $g.CommandText = "SELECT CAST(objectGUID AS UNIQUEIDENTIFIER) FROM ScriptModules WHERE name = @n"
    [void]$g.Parameters.AddWithValue("@n", $Name)
    $existing = $g.ExecuteScalar()

    if ($existing) {
        $guid = [Guid]$existing
        $u = $Conn.CreateCommand()
        $u.CommandText = "UPDATE ScriptModules SET edsaScriptText = @t, whenChanged = SYSDATETIME() WHERE objectGUID = @g"
        $pt = $u.Parameters.Add("@t", [System.Data.SqlDbType]::NVarChar, -1); $pt.Value = $Text
        [void]$u.Parameters.AddWithValue("@g", $guid)
        $rows = $u.ExecuteNonQuery()
        Write-Host "ScriptModule '$Name' updated (GUID $guid, trigger rows $rows)."
        return $guid
    }

    $guid = [Guid]::NewGuid()
    $dn = "CN=$Name,CN=UNITE-2026,CN=Script Modules,CN=Configuration"
    $i = $Conn.CreateCommand()
    $i.CommandText = @"
INSERT INTO ScriptModules
    (objectGUID, ParentObjectGUID, name, distinguishedName, objectClass,
     edsaScriptText, edsaScriptLanguage, edsaScriptType,
     whenCreated, whenChanged, edsaIsPredefined, edsaSystemObject)
VALUES (@g, @p, @n, @d, 'edsScriptModule', @t, 'PowerShell', 0,
        SYSDATETIME(), SYSDATETIME(), 0, 0);
"@
    [void]$i.Parameters.AddWithValue("@g", $guid)
    [void]$i.Parameters.AddWithValue("@p", [Guid]$ParentGuid)
    [void]$i.Parameters.AddWithValue("@n", $Name)
    [void]$i.Parameters.AddWithValue("@d", $dn)
    $pt = $i.Parameters.Add("@t", [System.Data.SqlDbType]::NVarChar, -1); $pt.Value = $Text
    [void]$i.ExecuteNonQuery()
    Write-Host "ScriptModule '$Name' created (GUID $guid)."
    return $guid
}

$scimGuid = Upsert-ScriptModule -Conn $conn -Name "UNITE-Helpdesk"  -Text $scimModuleText -ParentGuid $ScriptModuleParentGuid
$sodGuid  = Upsert-ScriptModule -Conn $conn -Name "UNITE-SoDPolicy" -Text $sodText        -ParentGuid $ScriptModuleParentGuid

# -----------------------------------------------------------------------------
# XAML activity builders (L1-encoded attribute values; real tags). Copied from
# the proven Extend Contractor deploy so the encoding matches byte-for-byte.
# -----------------------------------------------------------------------------
function Add-Report {
    param([string]$Header, [string]$Message, [string]$ActivityName, [string]$XName)
    $defL1 = "&lt;?xml version=&quot;1.0&quot; encoding=&quot;utf-16&quot;?&gt;&lt;AddRecordToReportActivityDefinition xmlns:xsd=&quot;http://www.w3.org/2001/XMLSchema&quot; xmlns:xsi=&quot;http://www.w3.org/2001/XMLSchema-instance&quot; IsErrorType=&quot;false&quot; xmlns=&quot;urn:schemas-quest-com:ActiveRolesServer&quot;&gt;&lt;Header&gt;&lt;ArsToken xsi:type=&quot;TextToken&quot; TextTokenType=&quot;Default&quot;&gt;&lt;Text&gt;$Header&lt;/Text&gt;&lt;/ArsToken&gt;&lt;/Header&gt;&lt;Message&gt;&lt;ArsToken xsi:type=&quot;TextToken&quot; TextTokenType=&quot;Default&quot;&gt;&lt;Text&gt;$Message&lt;/Text&gt;&lt;/ArsToken&gt;&lt;/Message&gt;&lt;/AddRecordToReportActivityDefinition&gt;"
    return "<ns0:AddRecordToReportActivity SuppressError=`"False`" ActivityDefinitionXML=`"$defL1`" ActivityName=`"$ActivityName`" x:Name=`"$XName`" />"
}

function PS-Activity {
    param([string]$FunctionToRun, [string]$ActivityName, [string]$XName, [string]$Guid, [bool]$Suppress = $true)
    $paramsL1 = "&lt;?xml version=&quot;1.0&quot; encoding=&quot;utf-16&quot;?&gt;&lt;CustomActivityParameter xmlns:xsd=&quot;http://www.w3.org/2001/XMLSchema&quot; xmlns:xsi=&quot;http://www.w3.org/2001/XMLSchema-instance&quot; xmlns=&quot;urn:schemas-quest-com:ActiveRolesServer&quot; /&gt;"
    $suppressStr = if ($Suppress) { "True" } else { "False" }
    return "<ns0:PowerShellActivity SuppressError=`"$suppressStr`" PolicyTypeID=`"{x:Null}`" NotificationConfigurationXml=`"{x:Null}`" ScriptModuleGuid=`"$Guid`" Parameters=`"$paramsL1`" FunctionToRun=`"$FunctionToRun`" ActivityName=`"$ActivityName`" FunctionToDeclareParameters=`"{x:Null}`" x:Name=`"$XName`" />"
}

# Wrap an inner activity list into the full <ArsWorkflow> definition with a
# ModifyObject(user, <TriggerAttr>) trigger scoped to the UNITE-2026 container.
function Build-WorkflowDef {
    param([string]$ActivitiesXaml, [string]$TriggerAttr)

    $xamlInner = @"
<?xml version="1.0" encoding="utf-16"?><ns0:ARSWorkflowActivity SuppressError="False" Description="ActiveRoles Workflow Activity" ExecutionContext="{p1:Null}" ActivityName="{p1:Null}" x:Name="Activity" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" xmlns:p1="http://schemas.microsoft.com/winfx/2006/xaml" xmlns:ns0="clr-namespace:ActiveRoles.Workflow.Activities;Assembly=ActiveRoles.Workflow.Activities, Version=8.2.1.0, Culture=neutral, PublicKeyToken=37ba620bec38a887">
<ns0:ServiceExecutionActivity SuppressError="False" x:Name="serviceExecutionActivity1" ActivityName="{x:Null}" />
$ActivitiesXaml
</ns0:ARSWorkflowActivity>
"@
    # Outer escape: & < >  but NOT "  (gotcha #1 - quotes stay literal in <Xaml> text).
    $xamlEsc = $xamlInner.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;")

    $guid = [Guid]::NewGuid()
    return @"
<ArsWorkflow xmlns:xsd="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" guid="$guid">
  <Xaml>$xamlEsc</Xaml>
  <InitializationScript />
  <Conditions>
    <Operation xsi:type="ModifyObject" policyCheckEnabled="false" objectClass="user">
      <AttributeNames>
        <string>$TriggerAttr</string>
      </AttributeNames>
    </Operation>
    <InitiatorsAndScopes>
      <InitiatorAndScopeFilter>
        <Initiator xsi:type="SecurityIdentifierInitiatorFilter" sid="S-1-1-0" />
        <Scope xsi:type="IncludeContainer">
          <Container guid="$AdScopeContainerGuid" />
        </Scope>
      </InitiatorAndScopeFilter>
    </InitiatorsAndScopes>
    <AdvancedConditions policyCheckEnabled="false">
      <And />
    </AdvancedConditions>
  </Conditions>
  <Settings>
    <AccountType>ServiceAccount</AccountType>
    <EnforceApproval>false</EnforceApproval>
  </Settings>
</ArsWorkflow>
"@
}

# One <ParameterDefinition> with a default string value.
function Param-Def {
    param([string]$Name, [string]$Display, [string]$Default)
    $d = [System.Security.SecurityElement]::Escape($Default)
    return "<ParameterDefinition name=`"$Name`" syntax=`"String`" multiValued=`"false`" required=`"false`" runtime=`"false`"><DisplayName>$Display</DisplayName><DefaultValue isScript=`"false`"><ScriptGuid xsi:nil=`"true`" /><Values><Value isEncrypted=`"false`"><RawValue>$d</RawValue></Value></Values></DefaultValue><PossibleValues isScript=`"false`"><ScriptGuid xsi:nil=`"true`" /><Values /></PossibleValues></ParameterDefinition>"
}

# Engine reads SCIM-<AppKey>-URI / -Token via $Workflow.Parameter, so every
# workflow that grants/revokes needs these defined.
$scimParams =
    (Param-Def -Name "SCIM-FinanceSuite-URI"      -Display "Finance Suite - SCIM base URI"   -Default $FinanceUri) +
    (Param-Def -Name "SCIM-FinanceSuite-Token"    -Display "Finance Suite - bearer token"    -Default $FinanceToken) +
    (Param-Def -Name "SCIM-ITHelpdeskPortal-URI"  -Display "IT Helpdesk Portal - SCIM URI"   -Default $HelpdeskUri) +
    (Param-Def -Name "SCIM-ITHelpdeskPortal-Token"-Display "IT Helpdesk Portal - token"      -Default $HelpdeskToken)

$paramsXml = "<ParameterDefinitions xmlns:xsd=`"http://www.w3.org/2001/XMLSchema`" xmlns:xsi=`"http://www.w3.org/2001/XMLSchema-instance`" xmlns=`"urn:schemas-quest-com:ActiveRolesServer:WorkflowParameters`">$scimParams</ParameterDefinitions>"

# -----------------------------------------------------------------------------
# Workflow upsert.
# -----------------------------------------------------------------------------
function Upsert-Workflow {
    param([System.Data.SqlClient.SqlConnection]$Conn, [string]$Name, [string]$Def, [string]$Params, [string]$ParentGuid)

    $g = $Conn.CreateCommand()
    $g.CommandText = "SELECT CAST(objectGUID AS UNIQUEIDENTIFIER) FROM Workflows WHERE name = @n"
    [void]$g.Parameters.AddWithValue("@n", $Name)
    $existing = $g.ExecuteScalar()

    if ($existing) {
        $u = $Conn.CreateCommand()
        $u.CommandText = @"
UPDATE Workflows
SET edsaWorkflowDefinition = @d, edsaWorkflowParameters = @pp, displayName = @dn,
    objectClass = 'edsWorkflowDefinition', whenChanged = SYSDATETIME()
WHERE objectGUID = @g
"@
        $pd  = $u.Parameters.Add("@d",  [System.Data.SqlDbType]::NVarChar, -1); $pd.Value  = $Def
        $ppp = $u.Parameters.Add("@pp", [System.Data.SqlDbType]::NVarChar, -1); $ppp.Value = $Params
        [void]$u.Parameters.AddWithValue("@dn", $Name)
        [void]$u.Parameters.AddWithValue("@g",  $existing)
        $rows = $u.ExecuteNonQuery()
        Write-Host "Workflow '$Name' updated (GUID $existing, trigger rows $rows)."
        return
    }

    $guid = [Guid]::NewGuid()
    $dn = "CN=$Name,CN=UNITE-2026,CN=Workflow,CN=Policies,CN=Configuration"
    $i = $Conn.CreateCommand()
    $i.CommandText = @"
INSERT INTO Workflows
    (objectGUID, ParentObjectGUID, name, displayName, distinguishedName, objectClass,
     edsaWorkflowDefinition, edsaWorkflowParameters,
     whenCreated, whenChanged, edsaIsPredefined, edsaSystemObject, edsaWorkflowIsDisabled)
VALUES (@g, @p, @n, @dn, @d, 'edsWorkflowDefinition', @def, @pp,
        SYSDATETIME(), SYSDATETIME(), 0, 0, 0);
"@
    [void]$i.Parameters.AddWithValue("@g",  $guid)
    [void]$i.Parameters.AddWithValue("@p",  [Guid]$ParentGuid)
    [void]$i.Parameters.AddWithValue("@n",  $Name)
    [void]$i.Parameters.AddWithValue("@dn", $Name)
    [void]$i.Parameters.AddWithValue("@d",  $dn)
    $pdef = $i.Parameters.Add("@def", [System.Data.SqlDbType]::NVarChar, -1); $pdef.Value = $Def
    $ppp  = $i.Parameters.Add("@pp",  [System.Data.SqlDbType]::NVarChar, -1); $ppp.Value  = $Params
    [void]$i.ExecuteNonQuery()
    Write-Host "Workflow '$Name' created (GUID $guid)."
}

# --- Workflow 1: Add to Role ------------------------------------------------
# rptStart -> SoD gate (UNITE-SoDPolicy, SuppressError=False so a denial ABORTS)
#          -> grant (UNITE-SCIMRest, AD group + REST) -> rptDone
$addActivities = @(
    (Add-Report  -Header "Add to Role - request received" -Message "Granting the role in UNITE-RequestedRole: SoD is checked first, then AD group membership and the REST entitlement are granted together." -ActivityName "Add to Role: start" -XName "rptAddStart"),
    (PS-Activity -FunctionToRun "Dispatch-AssertSoD" -ActivityName "SoD gate: block toxic combinations" -XName "psSoDGate" -Guid $sodGuid.ToString() -Suppress $false),
    (PS-Activity -FunctionToRun "Dispatch-RoleGrant" -ActivityName "Grant: AD role group + REST entitlement" -XName "psGrant" -Guid $scimGuid.ToString() -Suppress $true),
    (Add-Report  -Header "Add to Role - complete" -Message "If you see this with no SoD denial above, the role was granted in AD and fanned out to every mapped REST target." -ActivityName "Add to Role: complete" -XName "rptAddDone")
) -join "`r`n"

# --- Workflow 2: Remove from Role -------------------------------------------
$removeActivities = @(
    (Add-Report  -Header "Remove from Role - request received" -Message "Revoking the role in UNITE-RemoveRole from AD group membership and every mapped REST target." -ActivityName "Remove from Role: start" -XName "rptRemStart"),
    (PS-Activity -FunctionToRun "Dispatch-RoleRevoke" -ActivityName "Revoke: AD role group + REST entitlement" -XName "psRevoke" -Guid $scimGuid.ToString() -Suppress $true),
    (Add-Report  -Header "Remove from Role - complete" -Message "Role membership and entitlements removed. The user account itself is retained." -ActivityName "Remove from Role: complete" -XName "rptRemDone")
) -join "`r`n"

# --- Workflow 3: ABAC Auto-Assign by Department -----------------------------
$abacActivities = @(
    (Add-Report  -Header "ABAC Auto-Assign - department changed" -Message "Mapping the new department to its role(s) and granting each. The SoD policy refuses any toxic auto-grant; other roles still apply." -ActivityName "ABAC: start" -XName "rptAbacStart"),
    (PS-Activity -FunctionToRun "Dispatch-ABACAutoAssign" -ActivityName "ABAC: department -> role(s) -> grant" -XName "psAbac" -Guid $scimGuid.ToString() -Suppress $true),
    (Add-Report  -Header "ABAC Auto-Assign - complete" -Message "Per-role outcomes are on the ABAC activity row above." -ActivityName "ABAC: complete" -XName "rptAbacDone")
) -join "`r`n"

Upsert-Workflow -Conn $conn -Name "UNITE - Add to Role"      -Def (Build-WorkflowDef -ActivitiesXaml $addActivities    -TriggerAttr "UNITE-RequestedRole") -Params $paramsXml -ParentGuid $WorkflowParentGuid
Upsert-Workflow -Conn $conn -Name "UNITE - Remove from Role" -Def (Build-WorkflowDef -ActivitiesXaml $removeActivities -TriggerAttr "UNITE-RemoveRole")    -Params $paramsXml -ParentGuid $WorkflowParentGuid
Upsert-Workflow -Conn $conn -Name "UNITE - ABAC Auto-Assign by Department" -Def (Build-WorkflowDef -ActivitiesXaml $abacActivities -TriggerAttr "department") -Params $paramsXml -ParentGuid $WorkflowParentGuid

$conn.Close()

Write-Host ""
Write-Host "=== Done ==="
Write-Host "ScriptModules: UNITE-Helpdesk ($scimGuid), UNITE-SoDPolicy ($sodGuid)"
Write-Host "Workflows:     UNITE - Add to Role | UNITE - Remove from Role | UNITE - ABAC Auto-Assign by Department"
Write-Host ""
Write-Host "MANUAL steps remaining:"
Write-Host "  1. MMC: create virtual attributes 'UNITE-RequestedRole' and 'UNITE-RemoveRole'"
Write-Host "     (Unicode String) on the user class, then restart the AR Administration Service."
Write-Host "  2. Create the AD role groups (Accounts Payable / Accounts Receivable / Finance"
Write-Host "     Clerk / IT Support) and, in SCIMServer, the matching SCIM entitlement groups."
Write-Host "  3. SoD hard-stop: bind UNITE-SoDPolicy as a Policy Object (Script Execution,"
Write-Host "     handler onPreModify) on the role-groups' container."
Write-Host "  4. Web Interface: add 'Add to Role' (sets UNITE-RequestedRole) and 'Remove from"
Write-Host "     Role' (sets UNITE-RemoveRole) commands on the user page; iisreset."
Write-Host "  5. Confirm SCIM-*-URI / SCIM-*-Token parameters on each workflow match your lab."
Write-Host "  6. Test (manual): Set-QADUser <user> -ObjectAttributes @{ 'UNITE-RequestedRole' = 'Accounts Payable' }"
