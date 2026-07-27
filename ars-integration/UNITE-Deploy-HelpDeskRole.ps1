# =============================================================================
#  UNITE 2026   |   One Identity UNITE Conference
#  Chicago, USA   |   June 2026   |   Grand Ballroom III
# =============================================================================
#  Script   : UNITE-Deploy-HelpDeskRole.ps1
#  Purpose  : Generalized clone of UNITE-Deploy-HelpDeskAuditor.ps1. Deploys ONE
#             HelpDesk role workflow into Active Roles 8.3 (direct-SQL, idempotent)
#             for whichever role you pass in -RoleKey (Auditor | Operator |
#             Administrator). Triggered on the UNITE-HelpDesk<Role> boolean: true
#             grants the <Role>s entitlement in HelpDesk, false revokes it.
#             Same 7-step flow as the Auditor template (verify/provision/re-enable
#             -> add/remove role -> optional disable -> complete -> optional delete).
#  Author   : Jacob Maloney  -  iC Consult, Presales Architect
#  Contact  : sales@ic-consult.com   (We build IAM that doesn't break.)
#
#  Run (per role):
#    .\UNITE-Deploy-HelpDeskRole.ps1 -RoleKey Operator      -HelpDeskUri 'http://localhost:8080/scim/v2/t/helpdesk' -HelpDeskToken 'scim_helpdesk-2026'
#    .\UNITE-Deploy-HelpDeskRole.ps1 -RoleKey Administrator  -HelpDeskUri 'http://localhost:8080/scim/v2/t/helpdesk' -HelpDeskToken 'scim_helpdesk-2026'
#  After EACH deploy, in MMC: Disable -> Enable the new workflow once to register
#  its operation trigger (direct-SQL workflows don't register until MMC touches them).
# =============================================================================

param(
    [ValidateSet("Auditor","Operator","Administrator")]
    [string]$RoleKey  = "Operator",

    [string]$Server   = "192.168.1.56",
    [string]$Database = "ActiveRoles830",
    [string]$User     = "sa",
    [string]$Password = $env:LAB_SQL_PASSWORD,

    # Discovered on .56 (2026-05-31):
    [string]$ScriptModuleParentGuid = "019f78e8-7f74-4ff6-b662-63c83deb8261",  # CN=Script Modules
    [string]$WorkflowParentGuid     = "f63607f2-4b78-43e5-8812-619c0781b5c6",  # CN=UNITE-2026,CN=Workflow,CN=Policies
    [string]$AdScopeContainerGuid   = "16289041-4cfe-4b48-8a3b-c2c9867cafdc",  # OU=UNITE-2026,DC=Domain,DC=Local
    [string]$AssemblyVersion        = "8.3.0.0",                               # ARS 8.3 workflow activities assembly

    # Optional overrides (defaults derived from -RoleKey):
    [string]$Group        = "",   # SCIM entitlement group; default "<RoleKey>s"
    [string]$TriggerAttr  = "",   # default "UNITE-HelpDesk<RoleKey>"
    [string]$WorkflowName = "",   # default "UNITE - HelpDesk <RoleKey>"

    # Connection parameters baked onto the workflow (engine reads SCIM-<App>-URI/-Token).
    [string]$HelpDeskUri   = "http://localhost:8080/scim/v2/t/helpdesk",
    [string]$HelpDeskToken = ""
)

$ErrorActionPreference = "Stop"

# --- derive role-specific names ----------------------------------------------
if (-not $Group)        { $Group        = "${RoleKey}s" }                       # Auditors / Operators / Administrators
if (-not $TriggerAttr)  { $TriggerAttr  = "UNITE-HelpDesk$RoleKey" }
if (-not $WorkflowName) { $WorkflowName  = "UNITE - HelpDesk $RoleKey" }
$RoleLabel   = "HelpDesk $RoleKey"
$fnAccount   = "Dispatch-HelpDesk${RoleKey}Account"
$fnRole      = "Dispatch-HelpDesk${RoleKey}Role"
$fnDisable   = "Disable-HelpDesk${RoleKey}Account"
$fnDelete    = "Delete-HelpDesk${RoleKey}Account"

$cs = "Server=$Server;Database=$Database;User Id=$User;Password=$Password;TrustServerCertificate=true;"

# NOTE: SCIM-<App>-Token is managed by hand in MMC as a SecureString; the engine
# decrypts via $Security.Cryptography.DecryptFromString. Re-set it after redeploy.

# --- read + parse-check + concatenate the engine module (mappings on top) ----
function Read-PsFile { param([string]$Path)
    if (-not (Test-Path $Path)) { Write-Error "Source not found: $Path"; exit 1 }
    $text = [System.IO.File]::ReadAllText($Path)
    $tok = $err = $null
    [System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$tok, [ref]$err) | Out-Null
    if ($err.Count) { $err | ForEach-Object { Write-Host "PARSE ERR ($Path) L$($_.Extent.StartLineNumber): $($_.Message)" }; exit 1 }
    return $text
}
$scimModuleText = (Read-PsFile (Join-Path $PSScriptRoot "UNITE-SCIMMappings.ps1")) + "`r`n`r`n" +
                  (Read-PsFile (Join-Path $PSScriptRoot "UNITE-HelpDesk.ps1"))

$conn = New-Object System.Data.SqlClient.SqlConnection $cs
$conn.Open()

# --- ScriptModule upsert (objectClass=edsScriptModule, edsaScriptType=0) ------
function Upsert-ScriptModule { param($Conn,$Name,$Text,$ParentGuid)
    $g=$Conn.CreateCommand(); $g.CommandText="SELECT CAST(objectGUID AS UNIQUEIDENTIFIER) FROM ScriptModules WHERE name=@n"
    [void]$g.Parameters.AddWithValue("@n",$Name); $existing=$g.ExecuteScalar()
    if ($existing) {
        $guid=[Guid]$existing
        $u=$Conn.CreateCommand(); $u.CommandText="UPDATE ScriptModules SET edsaScriptText=@t, whenChanged=SYSDATETIME() WHERE objectGUID=@g"
        $pt=$u.Parameters.Add("@t",[System.Data.SqlDbType]::NVarChar,-1); $pt.Value=$Text
        [void]$u.Parameters.AddWithValue("@g",$guid); $rows=$u.ExecuteNonQuery()
        Write-Host "ScriptModule '$Name' updated (GUID $guid, trigger rows $rows)."; return $guid
    }
    $guid=[Guid]::NewGuid(); $dn="CN=$Name,CN=Script Modules,CN=Configuration"
    $i=$Conn.CreateCommand()
    $i.CommandText=@"
INSERT INTO ScriptModules (objectGUID,ParentObjectGUID,name,distinguishedName,objectClass,
  edsaScriptText,edsaScriptLanguage,edsaScriptType,whenCreated,whenChanged,edsaIsPredefined,edsaSystemObject)
VALUES (@g,@p,@n,@d,'edsScriptModule',@t,'PowerShell',0,SYSDATETIME(),SYSDATETIME(),0,0);
"@
    [void]$i.Parameters.AddWithValue("@g",$guid); [void]$i.Parameters.AddWithValue("@p",[Guid]$ParentGuid)
    [void]$i.Parameters.AddWithValue("@n",$Name); [void]$i.Parameters.AddWithValue("@d",$dn)
    $pt=$i.Parameters.Add("@t",[System.Data.SqlDbType]::NVarChar,-1); $pt.Value=$Text
    [void]$i.ExecuteNonQuery(); Write-Host "ScriptModule '$Name' created (GUID $guid)."; return $guid
}
$scimGuid = Upsert-ScriptModule -Conn $conn -Name "UNITE-Helpdesk" -Text $scimModuleText -ParentGuid $ScriptModuleParentGuid

# --- XAML activity builders (L1-encoded attr values; real tags) ---------------
function Add-Report { param($Header,$Message,$ActivityName,$XName)
    $def="&lt;?xml version=&quot;1.0&quot; encoding=&quot;utf-16&quot;?&gt;&lt;AddRecordToReportActivityDefinition xmlns:xsd=&quot;http://www.w3.org/2001/XMLSchema&quot; xmlns:xsi=&quot;http://www.w3.org/2001/XMLSchema-instance&quot; IsErrorType=&quot;false&quot; xmlns=&quot;urn:schemas-quest-com:ActiveRolesServer&quot;&gt;&lt;Header&gt;&lt;ArsToken xsi:type=&quot;TextToken&quot; TextTokenType=&quot;Default&quot;&gt;&lt;Text&gt;$Header&lt;/Text&gt;&lt;/ArsToken&gt;&lt;/Header&gt;&lt;Message&gt;&lt;ArsToken xsi:type=&quot;TextToken&quot; TextTokenType=&quot;Default&quot;&gt;&lt;Text&gt;$Message&lt;/Text&gt;&lt;/ArsToken&gt;&lt;/Message&gt;&lt;/AddRecordToReportActivityDefinition&gt;"
    return "<ns0:AddRecordToReportActivity SuppressError=`"False`" ActivityDefinitionXML=`"$def`" ActivityName=`"$ActivityName`" x:Name=`"$XName`" />"
}
function PS-Activity { param($FunctionToRun,$ActivityName,$XName,$Guid,[bool]$Suppress=$true)
    $params="&lt;?xml version=&quot;1.0&quot; encoding=&quot;utf-16&quot;?&gt;&lt;CustomActivityParameter xmlns:xsd=&quot;http://www.w3.org/2001/XMLSchema&quot; xmlns:xsi=&quot;http://www.w3.org/2001/XMLSchema-instance&quot; xmlns=&quot;urn:schemas-quest-com:ActiveRolesServer&quot; /&gt;"
    $sup=if($Suppress){"True"}else{"False"}
    return "<ns0:PowerShellActivity SuppressError=`"$sup`" PolicyTypeID=`"{x:Null}`" NotificationConfigurationXml=`"{x:Null}`" ScriptModuleGuid=`"$Guid`" Parameters=`"$params`" FunctionToRun=`"$FunctionToRun`" ActivityName=`"$ActivityName`" FunctionToDeclareParameters=`"{x:Null}`" x:Name=`"$XName`" />"
}

# Nice, numbered, self-describing 7-step flow (same as the Auditor template).
# Steps 5 (disable) and 7 (delete) are optional - enable at most one in MMC.
$rptStart  = Add-Report  -Header "1. $RoleLabel - request received" -Message "A request to modify the $RoleLabel entitlement has been received. The following steps verify the account in the Helpdesk application, provision it if it does not yet exist, grant or remove the $RoleKey role, and - optionally - deactivate the account when the role is removed." -ActivityName "1. Request received" -XName "rptStart"
$psAccount = PS-Activity -FunctionToRun $fnAccount -ActivityName "2. Verify account: provision if missing, re-enable if disabled" -XName "psAccount" -Guid $scimGuid.ToString() -Suppress $true
$psRole    = PS-Activity -FunctionToRun $fnRole    -ActivityName "3. Add or remove the $Group role"      -XName "psRole"    -Guid $scimGuid.ToString() -Suppress $true
$rptMid    = Add-Report  -Header "4. Account lifecycle" -Message "When the role is removed, choose how the account is handled: enable step 5 to deactivate (suspend) the account, or enable step 7 to permanently delete it. Leave both disabled to drop the role only and keep the account active. Enable at most one of step 5 or step 7." -ActivityName "4. Account lifecycle" -XName "rptMid"
$psDisable = PS-Activity -FunctionToRun $fnDisable -ActivityName "5. Deactivate Helpdesk account on removal (optional)" -XName "psDisable" -Guid $scimGuid.ToString() -Suppress $true
$rptDone   = Add-Report  -Header "6. $RoleLabel - complete" -Message "The $RoleLabel entitlement is now synchronized with the requested state. Expand any step above to review the actions performed in the Helpdesk application." -ActivityName "6. Complete" -XName "rptDone"
$psDelete  = PS-Activity -FunctionToRun $fnDelete  -ActivityName "7. Delete Helpdesk account on removal (optional)" -XName "psDelete" -Guid $scimGuid.ToString() -Suppress $true

$activities = @($rptStart,$psAccount,$psRole,$rptMid,$psDisable,$rptDone,$psDelete) -join "`r`n"

# --- full <ArsWorkflow> def (8.3 assembly version) ----------------------------
$xamlInner = @"
<?xml version="1.0" encoding="utf-16"?><ns0:ARSWorkflowActivity SuppressError="False" Description="ActiveRoles Workflow Activity" ExecutionContext="{p1:Null}" ActivityName="{p1:Null}" x:Name="Activity" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" xmlns:p1="http://schemas.microsoft.com/winfx/2006/xaml" xmlns:ns0="clr-namespace:ActiveRoles.Workflow.Activities;Assembly=ActiveRoles.Workflow.Activities, Version=$AssemblyVersion, Culture=neutral, PublicKeyToken=37ba620bec38a887">
<ns0:ServiceExecutionActivity SuppressError="False" x:Name="serviceExecutionActivity1" ActivityName="{x:Null}" />
$activities
</ns0:ARSWorkflowActivity>
"@
# Outer escape: & < > but NOT " (quotes stay literal in <Xaml> text content).
$xamlEsc = $xamlInner.Replace("&","&amp;").Replace("<","&lt;").Replace(">","&gt;")
$wfGuid = [Guid]::NewGuid()
$workflowDef = @"
<ArsWorkflow xmlns:xsd="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" guid="$wfGuid">
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

# --- workflow parameters (SCIM-HelpDesk-URI / -Token) -------------------------
function Param-Def { param($Name,$Display,$Default)
    $d=[System.Security.SecurityElement]::Escape($Default)
    return "<ParameterDefinition name=`"$Name`" syntax=`"String`" multiValued=`"false`" required=`"false`" runtime=`"false`"><DisplayName>$Display</DisplayName><DefaultValue isScript=`"false`"><ScriptGuid xsi:nil=`"true`" /><Values><Value isEncrypted=`"false`"><RawValue>$d</RawValue></Value></Values></DefaultValue><PossibleValues isScript=`"false`"><ScriptGuid xsi:nil=`"true`" /><Values /></PossibleValues></ParameterDefinition>"
}
$paramsXml = "<ParameterDefinitions xmlns:xsd=`"http://www.w3.org/2001/XMLSchema`" xmlns:xsi=`"http://www.w3.org/2001/XMLSchema-instance`" xmlns=`"urn:schemas-quest-com:ActiveRolesServer:WorkflowParameters`">" +
    (Param-Def -Name "SCIM-HelpDesk-URI"   -Display "HelpDesk - SCIM base URI" -Default $HelpDeskUri) +
    (Param-Def -Name "SCIM-HelpDesk-Token" -Display "HelpDesk - bearer token"  -Default $HelpDeskToken) +
    "</ParameterDefinitions>"

# --- upsert the workflow ------------------------------------------------------
$g=$conn.CreateCommand(); $g.CommandText="SELECT CAST(objectGUID AS UNIQUEIDENTIFIER) FROM Workflows WHERE name=@n"
[void]$g.Parameters.AddWithValue("@n",$WorkflowName); $existing=$g.ExecuteScalar()
if ($existing) {
    $u=$conn.CreateCommand()
    $u.CommandText="UPDATE Workflows SET edsaWorkflowDefinition=@d, edsaWorkflowParameters=@pp, displayName=@dn, objectClass='edsWorkflowDefinition', whenChanged=SYSDATETIME() WHERE objectGUID=@g"
    $pd=$u.Parameters.Add("@d",[System.Data.SqlDbType]::NVarChar,-1); $pd.Value=$workflowDef
    $pp=$u.Parameters.Add("@pp",[System.Data.SqlDbType]::NVarChar,-1); $pp.Value=$paramsXml
    [void]$u.Parameters.AddWithValue("@dn",$WorkflowName); [void]$u.Parameters.AddWithValue("@g",$existing)
    $rows=$u.ExecuteNonQuery(); Write-Host "Workflow '$WorkflowName' updated (GUID $existing, trigger rows $rows)."
} else {
    $wf=[Guid]::NewGuid(); $dn="CN=$WorkflowName,CN=UNITE-2026,CN=Workflow,CN=Policies,CN=Configuration"
    $i=$conn.CreateCommand()
    $i.CommandText=@"
INSERT INTO Workflows (objectGUID,ParentObjectGUID,name,displayName,distinguishedName,objectClass,
  edsaWorkflowDefinition,edsaWorkflowParameters,whenCreated,whenChanged,edsaIsPredefined,edsaSystemObject,edsaWorkflowIsDisabled)
VALUES (@g,@p,@n,@dn,@d,'edsWorkflowDefinition',@def,@pp,SYSDATETIME(),SYSDATETIME(),0,0,0);
"@
    [void]$i.Parameters.AddWithValue("@g",$wf); [void]$i.Parameters.AddWithValue("@p",[Guid]$WorkflowParentGuid)
    [void]$i.Parameters.AddWithValue("@n",$WorkflowName); [void]$i.Parameters.AddWithValue("@dn",$WorkflowName)
    [void]$i.Parameters.AddWithValue("@d",$dn)
    $pdef=$i.Parameters.Add("@def",[System.Data.SqlDbType]::NVarChar,-1); $pdef.Value=$workflowDef
    $pp=$i.Parameters.Add("@pp",[System.Data.SqlDbType]::NVarChar,-1); $pp.Value=$paramsXml
    [void]$i.ExecuteNonQuery(); Write-Host "Workflow '$WorkflowName' created (GUID $wf)."
}
$conn.Close()
Write-Host ""
Write-Host "=== Done ($RoleKey) ==="
Write-Host "ScriptModule: UNITE-Helpdesk ($scimGuid)"
Write-Host "Workflow:     $WorkflowName  (trigger: modify user $TriggerAttr; scope OU $AdScopeContainerGuid)"
Write-Host "Entitlement:  SCIM group '$Group'  via $fnRole"
Write-Host "Parameters:   SCIM-HelpDesk-URI=$HelpDeskUri ; SCIM-HelpDesk-Token=$(if($HelpDeskToken){'(set)'}else{'(blank - set when minted)'})"
Write-Host "NEXT: in MMC, Disable -> Enable '$WorkflowName' once to register its trigger."
