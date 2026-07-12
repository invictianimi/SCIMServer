# =============================================================================
#  UNITE 2026   |   One Identity UNITE Conference
#  Chicago, USA   |   June 2026   |   Grand Ballroom III
# =============================================================================
#  Script   : UNITE-Deploy-HRConnect.ps1
#  Purpose  : Deploy the HR Connect application end-to-end into Active Roles 8.3
#             (direct-SQL, idempotent). Bundles the shared SCIM core + the HR
#             profile into ONE ARS ScriptModule named "UNITE-HRConnect", then
#             creates the three role workflows (HR Admin / Recruiter / Payroll),
#             each the same 7-step template as HelpDesk.
#  Author   : Jacob Maloney  -  iC Consult, Presales Architect
#  Contact  : sales@ic-consult.com   (We build IAM that doesn't break.)
#
#  After this runs, in MMC: Disable -> Enable each new workflow once to register
#  its operation trigger (SQL-built workflows don't register until MMC touches
#  them). The UNITE-HRConnectAdmin/Recruiter/Payroll VAs must exist + the AR
#  service restarted so they're in the schema cache.
# =============================================================================

param(
    [string]$Server   = "192.168.1.56",
    [string]$Database = "ActiveRoles830",
    [string]$User     = "sa",
    [string]$Password = "ITsupp0rt!",

    [string]$ScriptModuleParentGuid = "019f78e8-7f74-4ff6-b662-63c83deb8261",  # CN=Script Modules
    [string]$WorkflowParentGuid     = "f63607f2-4b78-43e5-8812-619c0781b5c6",  # CN=UNITE-2026,CN=Workflow,CN=Policies
    [string]$AdScopeContainerGuid   = "16289041-4cfe-4b48-8a3b-c2c9867cafdc",  # OU=UNITE-2026
    [string]$AssemblyVersion        = "8.3.0.0",

    [string]$ModuleName    = "UNITE-HRConnect",
    [string]$HRConnectUri   = "http://localhost:8080/scim/v2/t/hr-connect",
    [string]$HRConnectToken = "scim_hrconnect-2026"
)

$ErrorActionPreference = "Stop"
$cs = "Server=$Server;Database=$Database;User Id=$User;Password=$Password;TrustServerCertificate=true;"

# NOTE: SCIM-HRConnect-Token is managed by hand in MMC as a SecureString; the
# engine decrypts via $Security.Cryptography.DecryptFromString. Re-set after redeploy.

# The three HR Connect roles. Group names are explicit (not <Role>+s).
$roles = @(
    @{ Key="Admin";     VA="UNITE-HRConnectAdmin";     Group="HR Admins";   Label="HR Connect Admin";     Wf="UNITE - HR Connect Admin" }
    @{ Key="Recruiter"; VA="UNITE-HRConnectRecruiter"; Group="Recruiters";  Label="HR Connect Recruiter"; Wf="UNITE - HR Connect Recruiter" }
    @{ Key="Payroll";   VA="UNITE-HRConnectPayroll";   Group="Payroll";     Label="HR Connect Payroll";   Wf="UNITE - HR Connect Payroll" }
)

# --- read + parse-check + bundle (mappings + core + HR profile) ---------------
function Read-PsFile { param([string]$Path)
    if (-not (Test-Path $Path)) { Write-Error "Source not found: $Path"; exit 1 }
    $text = [System.IO.File]::ReadAllText($Path)
    $tok = $err = $null
    [System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$tok, [ref]$err) | Out-Null
    if ($err.Count) { $err | ForEach-Object { Write-Host "PARSE ERR ($Path) L$($_.Extent.StartLineNumber): $($_.Message)" }; exit 1 }
    return $text
}
$moduleText = (Read-PsFile (Join-Path $PSScriptRoot "UNITE-SCIMMappings.ps1")) + "`r`n`r`n" +
              (Read-PsFile (Join-Path $PSScriptRoot "UNITE-HelpDesk.ps1"))     + "`r`n`r`n" +
              (Read-PsFile (Join-Path $PSScriptRoot "UNITE-HRConnect.ps1"))

$conn = New-Object System.Data.SqlClient.SqlConnection $cs
$conn.Open()

# --- ScriptModule upsert ------------------------------------------------------
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
$scimGuid = Upsert-ScriptModule -Conn $conn -Name $ModuleName -Text $moduleText -ParentGuid $ScriptModuleParentGuid

# --- XAML builders ------------------------------------------------------------
function Add-Report { param($Header,$Message,$ActivityName,$XName)
    $def="&lt;?xml version=&quot;1.0&quot; encoding=&quot;utf-16&quot;?&gt;&lt;AddRecordToReportActivityDefinition xmlns:xsd=&quot;http://www.w3.org/2001/XMLSchema&quot; xmlns:xsi=&quot;http://www.w3.org/2001/XMLSchema-instance&quot; IsErrorType=&quot;false&quot; xmlns=&quot;urn:schemas-quest-com:ActiveRolesServer&quot;&gt;&lt;Header&gt;&lt;ArsToken xsi:type=&quot;TextToken&quot; TextTokenType=&quot;Default&quot;&gt;&lt;Text&gt;$Header&lt;/Text&gt;&lt;/ArsToken&gt;&lt;/Header&gt;&lt;Message&gt;&lt;ArsToken xsi:type=&quot;TextToken&quot; TextTokenType=&quot;Default&quot;&gt;&lt;Text&gt;$Message&lt;/Text&gt;&lt;/ArsToken&gt;&lt;/Message&gt;&lt;/AddRecordToReportActivityDefinition&gt;"
    return "<ns0:AddRecordToReportActivity SuppressError=`"False`" ActivityDefinitionXML=`"$def`" ActivityName=`"$ActivityName`" x:Name=`"$XName`" />"
}
function PS-Activity { param($FunctionToRun,$ActivityName,$XName,$Guid,[bool]$Suppress=$true)
    $params="&lt;?xml version=&quot;1.0&quot; encoding=&quot;utf-16&quot;?&gt;&lt;CustomActivityParameter xmlns:xsd=&quot;http://www.w3.org/2001/XMLSchema&quot; xmlns:xsi=&quot;http://www.w3.org/2001/XMLSchema-instance&quot; xmlns=&quot;urn:schemas-quest-com:ActiveRolesServer&quot; /&gt;"
    $sup=if($Suppress){"True"}else{"False"}
    return "<ns0:PowerShellActivity SuppressError=`"$sup`" PolicyTypeID=`"{x:Null}`" NotificationConfigurationXml=`"{x:Null}`" ScriptModuleGuid=`"$Guid`" Parameters=`"$params`" FunctionToRun=`"$FunctionToRun`" ActivityName=`"$ActivityName`" FunctionToDeclareParameters=`"{x:Null}`" x:Name=`"$XName`" />"
}
function Param-Def { param($Name,$Display,$Default)
    $d=[System.Security.SecurityElement]::Escape($Default)
    return "<ParameterDefinition name=`"$Name`" syntax=`"String`" multiValued=`"false`" required=`"false`" runtime=`"false`"><DisplayName>$Display</DisplayName><DefaultValue isScript=`"false`"><ScriptGuid xsi:nil=`"true`" /><Values><Value isEncrypted=`"false`"><RawValue>$d</RawValue></Value></Values></DefaultValue><PossibleValues isScript=`"false`"><ScriptGuid xsi:nil=`"true`" /><Values /></PossibleValues></ParameterDefinition>"
}
$paramsXml = "<ParameterDefinitions xmlns:xsd=`"http://www.w3.org/2001/XMLSchema`" xmlns:xsi=`"http://www.w3.org/2001/XMLSchema-instance`" xmlns=`"urn:schemas-quest-com:ActiveRolesServer:WorkflowParameters`">" +
    (Param-Def -Name "SCIM-HRConnect-URI"   -Display "HR Connect - SCIM base URI" -Default $HRConnectUri) +
    (Param-Def -Name "SCIM-HRConnect-Token" -Display "HR Connect - bearer token"  -Default $HRConnectToken) +
    "</ParameterDefinitions>"

# --- per-role workflow upsert -------------------------------------------------
function Upsert-Workflow { param($Conn,$Role,$Guid,$ParamsXml)
    $g=$Role.Group; $va=$Role.VA; $label=$Role.Label; $wf=$Role.Wf

    $rptStart  = Add-Report  -Header "1. $label - request received" -Message "A request to modify the $label entitlement has been received. The following steps verify the account in HR Connect, provision it if it does not yet exist, grant or remove the $($Role.Key) role, and - optionally - deactivate the account when the role is removed." -ActivityName "1. Request received" -XName "rptStart"
    $psAccount = PS-Activity -FunctionToRun "Dispatch-HRConnect$($Role.Key)Account" -ActivityName "2. Verify account: provision if missing, re-enable if disabled" -XName "psAccount" -Guid $Guid -Suppress $true
    $psRole    = PS-Activity -FunctionToRun "Dispatch-HRConnect$($Role.Key)Role"    -ActivityName "3. Add or remove the $g role" -XName "psRole" -Guid $Guid -Suppress $true
    $rptMid    = Add-Report  -Header "4. Account lifecycle" -Message "When the role is removed, choose how the account is handled: enable step 5 to deactivate (suspend) the account, or enable step 7 to permanently delete it. Leave both disabled to drop the role only and keep the account active. Enable at most one of step 5 or step 7." -ActivityName "4. Account lifecycle" -XName "rptMid"
    $psDisable = PS-Activity -FunctionToRun "Disable-HRConnect$($Role.Key)Account" -ActivityName "5. Deactivate HR Connect account on removal (optional)" -XName "psDisable" -Guid $Guid -Suppress $true
    $rptDone   = Add-Report  -Header "6. $label - complete" -Message "The $label entitlement is now synchronized with the requested state. Expand any step above to review the actions performed in HR Connect." -ActivityName "6. Complete" -XName "rptDone"
    $psDelete  = PS-Activity -FunctionToRun "Delete-HRConnect$($Role.Key)Account" -ActivityName "7. Delete HR Connect account on removal (optional)" -XName "psDelete" -Guid $Guid -Suppress $true

    $activities = @($rptStart,$psAccount,$psRole,$rptMid,$psDisable,$rptDone,$psDelete) -join "`r`n"
    $xamlInner = @"
<?xml version="1.0" encoding="utf-16"?><ns0:ARSWorkflowActivity SuppressError="False" Description="ActiveRoles Workflow Activity" ExecutionContext="{p1:Null}" ActivityName="{p1:Null}" x:Name="Activity" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" xmlns:p1="http://schemas.microsoft.com/winfx/2006/xaml" xmlns:ns0="clr-namespace:ActiveRoles.Workflow.Activities;Assembly=ActiveRoles.Workflow.Activities, Version=$AssemblyVersion, Culture=neutral, PublicKeyToken=37ba620bec38a887">
<ns0:ServiceExecutionActivity SuppressError="False" x:Name="serviceExecutionActivity1" ActivityName="{x:Null}" />
$activities
</ns0:ARSWorkflowActivity>
"@
    $xamlEsc = $xamlInner.Replace("&","&amp;").Replace("<","&lt;").Replace(">","&gt;")
    $wfGuid = [Guid]::NewGuid()
    $workflowDef = @"
<ArsWorkflow xmlns:xsd="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" guid="$wfGuid">
  <Xaml>$xamlEsc</Xaml>
  <InitializationScript />
  <Conditions>
    <Operation xsi:type="ModifyObject" policyCheckEnabled="false" objectClass="user">
      <AttributeNames>
        <string>$va</string>
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
    $sel=$Conn.CreateCommand(); $sel.CommandText="SELECT CAST(objectGUID AS UNIQUEIDENTIFIER) FROM Workflows WHERE name=@n"
    [void]$sel.Parameters.AddWithValue("@n",$wf); $existing=$sel.ExecuteScalar()
    if ($existing) {
        $u=$Conn.CreateCommand()
        $u.CommandText="UPDATE Workflows SET edsaWorkflowDefinition=@d, edsaWorkflowParameters=@pp, displayName=@dn, objectClass='edsWorkflowDefinition', whenChanged=SYSDATETIME() WHERE objectGUID=@g"
        $pd=$u.Parameters.Add("@d",[System.Data.SqlDbType]::NVarChar,-1); $pd.Value=$workflowDef
        $pp=$u.Parameters.Add("@pp",[System.Data.SqlDbType]::NVarChar,-1); $pp.Value=$ParamsXml
        [void]$u.Parameters.AddWithValue("@dn",$wf); [void]$u.Parameters.AddWithValue("@g",$existing)
        [void]$u.ExecuteNonQuery(); Write-Host "Workflow '$wf' updated (trigger $va -> group '$g')."
    } else {
        $wfg=[Guid]::NewGuid(); $dn="CN=$wf,CN=UNITE-2026,CN=Workflow,CN=Policies,CN=Configuration"
        $i=$Conn.CreateCommand()
        $i.CommandText=@"
INSERT INTO Workflows (objectGUID,ParentObjectGUID,name,displayName,distinguishedName,objectClass,
  edsaWorkflowDefinition,edsaWorkflowParameters,whenCreated,whenChanged,edsaIsPredefined,edsaSystemObject,edsaWorkflowIsDisabled)
VALUES (@g,@p,@n,@dn,@d,'edsWorkflowDefinition',@def,@pp,SYSDATETIME(),SYSDATETIME(),0,0,0);
"@
        [void]$i.Parameters.AddWithValue("@g",$wfg); [void]$i.Parameters.AddWithValue("@p",[Guid]$WorkflowParentGuid)
        [void]$i.Parameters.AddWithValue("@n",$wf); [void]$i.Parameters.AddWithValue("@dn",$wf)
        [void]$i.Parameters.AddWithValue("@d",$dn)
        $pdef=$i.Parameters.Add("@def",[System.Data.SqlDbType]::NVarChar,-1); $pdef.Value=$workflowDef
        $pp=$i.Parameters.Add("@pp",[System.Data.SqlDbType]::NVarChar,-1); $pp.Value=$ParamsXml
        [void]$i.ExecuteNonQuery(); Write-Host "Workflow '$wf' created (trigger $va -> group '$g')."
    }
}

foreach ($role in $roles) { Upsert-Workflow -Conn $conn -Role $role -Guid $scimGuid.ToString() -ParamsXml $paramsXml }
$conn.Close()

Write-Host ""
Write-Host "=== Done (HR Connect) ==="
Write-Host "ScriptModule: $ModuleName ($scimGuid)  [core + HR profile bundled]"
Write-Host "Workflows:    UNITE - HR Connect Admin / Recruiter / Payroll  (scope OU $AdScopeContainerGuid)"
Write-Host "Params:       SCIM-HRConnect-URI=$HRConnectUri ; SCIM-HRConnect-Token=$(if($HRConnectToken){'(set)'}else{'(blank)'})"
Write-Host ""
Write-Host "NEXT: (1) VAs UNITE-HRConnectAdmin/Recruiter/Payroll exist + AR service restarted;"
Write-Host "      (2) in MMC, Disable -> Enable each of the 3 workflows once to register triggers;"
Write-Host "      (3) HR Connect SCIM tenant + groups (HR Admins/Recruiters/Payroll) seeded in SCIMServer."
