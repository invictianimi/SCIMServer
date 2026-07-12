# =============================================================================
#  UNITE 2026   |   One Identity UNITE Conference
#  Chicago, USA   |   June 2026   |   Grand Ballroom III
# =============================================================================
#  Script   : UNITE-Deploy-VPN.ps1
#  Purpose  : Deploy the VPN / Remote Access app end-to-end into Active Roles 8.3.
#             AD-GROUP based: roles grant AD security group membership (no SCIM).
#             Two parts:
#               (A) config DB via SQL  - the UNITE-VPN ScriptModule + 3 workflows
#                                          (always runs; uses SQL 'sa').
#               (B) AD groups via ARS  - New-QADGroup for VPN Standard/Privileged/
#                                          Admin (runs ONLY when -ConnectionAccount
#                                          is supplied; needs a DOMAIN credential).
#  Author   : Jacob Maloney  -  iC Consult, Presales Architect
#  Contact  : sales@ic-consult.com   (We build IAM that doesn't break.)
#
#  Run (config only, headless):  .\UNITE-Deploy-VPN.ps1
#  Run (also create AD groups):  ! powershell -ExecutionPolicy Bypass -File ".\UNITE-Deploy-VPN.ps1" -ConnectionAccount "DOMAIN\Administrator"
#  After: VAs UNITE-VPNStandard/Privileged/Admin exist + AR service restarted;
#         in MMC Disable->Enable each of the 3 VPN workflows to register triggers.
# =============================================================================

param(
    [string]$Server   = "192.168.1.56",
    [string]$Database = "ActiveRoles830",
    [string]$User     = "sa",
    [string]$Password = "ITsupp0rt!",
    [string]$ScriptModuleParentGuid = "019f78e8-7f74-4ff6-b662-63c83deb8261",
    [string]$WorkflowParentGuid     = "f63607f2-4b78-43e5-8812-619c0781b5c6",
    [string]$AdScopeContainerGuid   = "16289041-4cfe-4b48-8a3b-c2c9867cafdc",
    [string]$AssemblyVersion        = "8.3.0.0",
    [string]$ModuleName             = "UNITE-VPN",

    # Supply to also create the AD groups via ARS (Part B). Blank -> skip Part B.
    [string]$ConnectionAccount,
    [string]$ConnectionPassword,
    [string]$GroupsOUDN                       # blank -> auto-discover OU=UNITE-2026, else CN=Users
)

$ErrorActionPreference = "Stop"
$cs = "Server=$Server;Database=$Database;User Id=$User;Password=$Password;TrustServerCertificate=true;"

$roles = @(
    @{ Key="Standard";   VA="UNITE-VPNStandard";   Group="VPN Standard";   Label="VPN Standard";   Wf="UNITE - VPN Standard" }
    @{ Key="Privileged"; VA="UNITE-VPNPrivileged"; Group="VPN Privileged"; Label="VPN Privileged"; Wf="UNITE - VPN Privileged" }
    @{ Key="Admin";      VA="UNITE-VPNAdmin";      Group="VPN Admin";      Label="VPN Admin";      Wf="UNITE - VPN Admin" }
)

# ====================== PART A : config DB (SQL) =============================
function Read-PsFile { param([string]$Path)
    if (-not (Test-Path $Path)) { Write-Error "Source not found: $Path"; exit 1 }
    $text = [System.IO.File]::ReadAllText($Path)
    $tok = $err = $null
    [System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$tok, [ref]$err) | Out-Null
    if ($err.Count) { $err | ForEach-Object { Write-Host "PARSE ERR L$($_.Extent.StartLineNumber): $($_.Message)" }; exit 1 }
    return $text
}
$moduleText = Read-PsFile (Join-Path $PSScriptRoot "UNITE-VPN.ps1")

$conn = New-Object System.Data.SqlClient.SqlConnection $cs
$conn.Open()

function Upsert-ScriptModule { param($Conn,$Name,$Text,$ParentGuid)
    $g=$Conn.CreateCommand(); $g.CommandText="SELECT CAST(objectGUID AS UNIQUEIDENTIFIER) FROM ScriptModules WHERE name=@n"
    [void]$g.Parameters.AddWithValue("@n",$Name); $existing=$g.ExecuteScalar()
    if ($existing) {
        $guid=[Guid]$existing
        $u=$Conn.CreateCommand(); $u.CommandText="UPDATE ScriptModules SET edsaScriptText=@t, whenChanged=SYSDATETIME() WHERE objectGUID=@g"
        $pt=$u.Parameters.Add("@t",[System.Data.SqlDbType]::NVarChar,-1); $pt.Value=$Text
        [void]$u.Parameters.AddWithValue("@g",$guid); [void]$u.ExecuteNonQuery()
        Write-Host "ScriptModule '$Name' updated (GUID $guid)."; return $guid
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
$modGuid = Upsert-ScriptModule -Conn $conn -Name $ModuleName -Text $moduleText -ParentGuid $ScriptModuleParentGuid

function Add-Report { param($Header,$Message,$ActivityName,$XName)
    $def="&lt;?xml version=&quot;1.0&quot; encoding=&quot;utf-16&quot;?&gt;&lt;AddRecordToReportActivityDefinition xmlns:xsd=&quot;http://www.w3.org/2001/XMLSchema&quot; xmlns:xsi=&quot;http://www.w3.org/2001/XMLSchema-instance&quot; IsErrorType=&quot;false&quot; xmlns=&quot;urn:schemas-quest-com:ActiveRolesServer&quot;&gt;&lt;Header&gt;&lt;ArsToken xsi:type=&quot;TextToken&quot; TextTokenType=&quot;Default&quot;&gt;&lt;Text&gt;$Header&lt;/Text&gt;&lt;/ArsToken&gt;&lt;/Header&gt;&lt;Message&gt;&lt;ArsToken xsi:type=&quot;TextToken&quot; TextTokenType=&quot;Default&quot;&gt;&lt;Text&gt;$Message&lt;/Text&gt;&lt;/ArsToken&gt;&lt;/Message&gt;&lt;/AddRecordToReportActivityDefinition&gt;"
    return "<ns0:AddRecordToReportActivity SuppressError=`"False`" ActivityDefinitionXML=`"$def`" ActivityName=`"$ActivityName`" x:Name=`"$XName`" />"
}
function PS-Activity { param($FunctionToRun,$ActivityName,$XName,$Guid,[bool]$Suppress=$true)
    $params="&lt;?xml version=&quot;1.0&quot; encoding=&quot;utf-16&quot;?&gt;&lt;CustomActivityParameter xmlns:xsd=&quot;http://www.w3.org/2001/XMLSchema&quot; xmlns:xsi=&quot;http://www.w3.org/2001/XMLSchema-instance&quot; xmlns=&quot;urn:schemas-quest-com:ActiveRolesServer&quot; /&gt;"
    $sup=if($Suppress){"True"}else{"False"}
    return "<ns0:PowerShellActivity SuppressError=`"$sup`" PolicyTypeID=`"{x:Null}`" NotificationConfigurationXml=`"{x:Null}`" ScriptModuleGuid=`"$Guid`" Parameters=`"$params`" FunctionToRun=`"$FunctionToRun`" ActivityName=`"$ActivityName`" FunctionToDeclareParameters=`"{x:Null}`" x:Name=`"$XName`" />"
}
$emptyParams = "<ParameterDefinitions xmlns:xsd=`"http://www.w3.org/2001/XMLSchema`" xmlns:xsi=`"http://www.w3.org/2001/XMLSchema-instance`" xmlns=`"urn:schemas-quest-com:ActiveRolesServer:WorkflowParameters`" />"

# IfElse branch condition: workflow-target property (the role VA) == a literal.
# Operator "==" confirmed from built-in conditions. Returns L1-encoded XML (the
# outer xaml escape later turns &lt; into &amp;lt; etc., matching the engine).
function Condition-TargetEqualsText { param([string]$AttrName, [string]$Value)
    return "&lt;AdvancedConditionOperationFilter xmlns:xsd=&quot;http://www.w3.org/2001/XMLSchema&quot; xmlns:xsi=&quot;http://www.w3.org/2001/XMLSchema-instance&quot; policyCheckEnabled=&quot;false&quot;&gt;&lt;And&gt;&lt;TokenCondition operator=&quot;==&quot;&gt;&lt;LeftOperand&gt;&lt;ArsToken xmlns:q1=&quot;urn:schemas-quest-com:ActiveRolesServer&quot; xsi:type=&quot;q1:WorkflowTargetToken&quot; isObject=&quot;false&quot;&gt;&lt;q1:Property name=&quot;$AttrName&quot; charNumber=&quot;0&quot; limitValueString=&quot;false&quot; limitValueCount=&quot;0&quot; adjustCase=&quot;false&quot; makeCaseLower=&quot;false&quot; excludeCharacters=&quot;false&quot; excludeSpace=&quot;false&quot; /&gt;&lt;/ArsToken&gt;&lt;/LeftOperand&gt;&lt;RightOperand&gt;&lt;ArsToken xmlns:q2=&quot;urn:schemas-quest-com:ActiveRolesServer&quot; xsi:type=&quot;q2:TextToken&quot; TextTokenType=&quot;Default&quot;&gt;&lt;q2:Text&gt;$Value&lt;/q2:Text&gt;&lt;/ArsToken&gt;&lt;/RightOperand&gt;&lt;/TokenCondition&gt;&lt;/And&gt;&lt;/AdvancedConditionOperationFilter&gt;"
}

function Upsert-Workflow { param($Conn,$Role,$Guid)
    $rptStart = Add-Report  -Header "1. $($Role.Label) - request received" -Message "A request to modify the $($Role.Label) entitlement has been received. Step 2 branches: if the role was granted it ADDS the user to the AD security group '$($Role.Group)'; if revoked it REMOVES them." -ActivityName "1. Request received" -XName "rptStart"
    $psAdd    = PS-Activity -FunctionToRun "Add-VPN$($Role.Key)"    -ActivityName "Add to '$($Role.Group)' AD group" -XName "psAdd" -Guid $Guid -Suppress $true
    $psRemove = PS-Activity -FunctionToRun "Remove-VPN$($Role.Key)" -ActivityName "Remove from '$($Role.Group)' AD group" -XName "psRemove" -Guid $Guid -Suppress $true
    $condGrant  = Condition-TargetEqualsText -AttrName $Role.VA -Value "TRUE"
    $condRevoke = Condition-TargetEqualsText -AttrName $Role.VA -Value "FALSE"
    $ifElse = @"
<ns0:IfElseActivity SuppressError="False" ExecutionContext="{x:Null}" ActivityName="2. Add or remove ($($Role.VA))" x:Name="ifVPN">
  <ns0:IfElseBranchActivity SuppressError="False" ExecutionContext="{x:Null}" ConditionXml="$condGrant" ActivityName="Grant - $($Role.VA) is TRUE" x:Name="brGrant">
    $psAdd
  </ns0:IfElseBranchActivity>
  <ns0:IfElseBranchActivity SuppressError="False" ExecutionContext="{x:Null}" ConditionXml="$condRevoke" ActivityName="Revoke - $($Role.VA) is FALSE" x:Name="brRevoke">
    $psRemove
  </ns0:IfElseBranchActivity>
</ns0:IfElseActivity>
"@
    $rptDone  = Add-Report  -Header "3. $($Role.Label) - complete" -Message "The $($Role.Label) entitlement is now synchronized with the requested state. Expand the branch above to review the AD group change." -ActivityName "3. Complete" -XName "rptDone"
    $activities = @($rptStart,$ifElse,$rptDone) -join "`r`n"
    $xamlInner = @"
<?xml version="1.0" encoding="utf-16"?><ns0:ARSWorkflowActivity SuppressError="False" Description="ActiveRoles Workflow Activity" ExecutionContext="{p1:Null}" ActivityName="{p1:Null}" x:Name="Activity" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" xmlns:p1="http://schemas.microsoft.com/winfx/2006/xaml" xmlns:ns0="clr-namespace:ActiveRoles.Workflow.Activities;Assembly=ActiveRoles.Workflow.Activities, Version=$AssemblyVersion, Culture=neutral, PublicKeyToken=37ba620bec38a887">
<ns0:ServiceExecutionActivity SuppressError="False" x:Name="serviceExecutionActivity1" ActivityName="{x:Null}" />
$activities
</ns0:ARSWorkflowActivity>
"@
    $xamlEsc = $xamlInner.Replace("&","&amp;").Replace("<","&lt;").Replace(">","&gt;")
    $wfGuid=[Guid]::NewGuid()
    $workflowDef = @"
<ArsWorkflow xmlns:xsd="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" guid="$wfGuid">
  <Xaml>$xamlEsc</Xaml>
  <InitializationScript />
  <Conditions>
    <Operation xsi:type="ModifyObject" policyCheckEnabled="false" objectClass="user">
      <AttributeNames><string>$($Role.VA)</string></AttributeNames>
    </Operation>
    <InitiatorsAndScopes>
      <InitiatorAndScopeFilter>
        <Initiator xsi:type="SecurityIdentifierInitiatorFilter" sid="S-1-1-0" />
        <Scope xsi:type="IncludeContainer"><Container guid="$AdScopeContainerGuid" /></Scope>
      </InitiatorAndScopeFilter>
    </InitiatorsAndScopes>
    <AdvancedConditions policyCheckEnabled="false"><And /></AdvancedConditions>
  </Conditions>
  <Settings><AccountType>ServiceAccount</AccountType><EnforceApproval>false</EnforceApproval></Settings>
</ArsWorkflow>
"@
    $sel=$Conn.CreateCommand(); $sel.CommandText="SELECT CAST(objectGUID AS UNIQUEIDENTIFIER) FROM Workflows WHERE name=@n"
    [void]$sel.Parameters.AddWithValue("@n",$Role.Wf); $existing=$sel.ExecuteScalar()
    if ($existing) {
        $u=$Conn.CreateCommand()
        $u.CommandText="UPDATE Workflows SET edsaWorkflowDefinition=@d, edsaWorkflowParameters=@pp, displayName=@dn, objectClass='edsWorkflowDefinition', whenChanged=SYSDATETIME() WHERE objectGUID=@g"
        $pd=$u.Parameters.Add("@d",[System.Data.SqlDbType]::NVarChar,-1); $pd.Value=$workflowDef
        $pp=$u.Parameters.Add("@pp",[System.Data.SqlDbType]::NVarChar,-1); $pp.Value=$emptyParams
        [void]$u.Parameters.AddWithValue("@dn",$Role.Wf); [void]$u.Parameters.AddWithValue("@g",$existing)
        [void]$u.ExecuteNonQuery(); Write-Host "Workflow '$($Role.Wf)' updated (trigger $($Role.VA) -> AD group '$($Role.Group)')."
    } else {
        $wfg=[Guid]::NewGuid(); $dn="CN=$($Role.Wf),CN=UNITE-2026,CN=Workflow,CN=Policies,CN=Configuration"
        $i=$Conn.CreateCommand()
        $i.CommandText=@"
INSERT INTO Workflows (objectGUID,ParentObjectGUID,name,displayName,distinguishedName,objectClass,
  edsaWorkflowDefinition,edsaWorkflowParameters,whenCreated,whenChanged,edsaIsPredefined,edsaSystemObject,edsaWorkflowIsDisabled)
VALUES (@g,@p,@n,@dn,@d,'edsWorkflowDefinition',@def,@pp,SYSDATETIME(),SYSDATETIME(),0,0,0);
"@
        [void]$i.Parameters.AddWithValue("@g",$wfg); [void]$i.Parameters.AddWithValue("@p",[Guid]$WorkflowParentGuid)
        [void]$i.Parameters.AddWithValue("@n",$Role.Wf); [void]$i.Parameters.AddWithValue("@dn",$Role.Wf)
        [void]$i.Parameters.AddWithValue("@d",$dn)
        $pdef=$i.Parameters.Add("@def",[System.Data.SqlDbType]::NVarChar,-1); $pdef.Value=$workflowDef
        $pp=$i.Parameters.Add("@pp",[System.Data.SqlDbType]::NVarChar,-1); $pp.Value=$emptyParams
        [void]$i.ExecuteNonQuery(); Write-Host "Workflow '$($Role.Wf)' created (trigger $($Role.VA) -> AD group '$($Role.Group)')."
    }
}
foreach ($role in $roles) { Upsert-Workflow -Conn $conn -Role $role -Guid $modGuid.ToString() }
$conn.Close()
Write-Host "Part A done: module + 3 workflows."

# ====================== PART B : AD groups via ARS ==========================
if ($ConnectionAccount) {
    $shell = @(
        'C:\Program Files\One Identity\Active Roles\8.3\Shell\ActiveRolesManagementShell\ActiveRolesManagementShell.psd1',
        'C:\Program Files\One Identity\Active Roles\8.2\Shell\ActiveRolesManagementShell\ActiveRolesManagementShell.psd1'
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $shell) { throw "AR Management Shell not found - run Part B on the ARS server, or install the shell here." }
    Import-Module $shell -WarningAction SilentlyContinue
    if ($ConnectionPassword) {
        $sp = ConvertTo-SecureString $ConnectionPassword -AsPlainText -Force
        Connect-QADService -Service $Server -ConnectionAccount $ConnectionAccount -ConnectionPassword $sp | Out-Null
    } else {
        $cred = Get-Credential -UserName $ConnectionAccount -Message "Domain password for $ConnectionAccount (ARS connection)"
        Connect-QADService -Service $Server -Credential $cred | Out-Null
    }
    if (-not $GroupsOUDN) {
        $ou = Get-QADObject -Type organizationalUnit -Name 'UNITE-2026' -ErrorAction SilentlyContinue | Select-Object -First 1
        $GroupsOUDN = if ($ou) { $ou.DN } else { "CN=Users," + (Get-QADRootDSE).defaultNamingContext }
    }
    Write-Host "Creating VPN AD groups in: $GroupsOUDN"
    foreach ($role in $roles) {
        $existing = Get-QADGroup -Name $role.Group -ErrorAction SilentlyContinue
        if ($existing) { Write-Host "  SKIP (exists): $($role.Group)  [$($existing.DN)]"; continue }
        $sam = ($role.Group -replace '\s','')
        $new = New-QADGroup -Name $role.Group -ParentContainer $GroupsOUDN -GroupScope 'Global' -GroupType 'Security' -SamAccountName $sam -Description "UNITE 2026 - VPN / Remote Access entitlement group ($($role.Label))."
        Write-Host "  CREATED: $($role.Group)  [$($new.DN)]"
    }
    Disconnect-QADService | Out-Null
    Write-Host "Part B done: AD groups created via ARS."
} else {
    Write-Host ""
    Write-Host "Part B SKIPPED (no -ConnectionAccount). To create the AD groups via ARS, re-run with a DOMAIN credential:"
    Write-Host "  ! powershell -ExecutionPolicy Bypass -File `"$PSCommandPath`" -ConnectionAccount `"DOMAIN\Administrator`""
}

Write-Host ""
Write-Host "=== Done (VPN) ==="
Write-Host "ScriptModule: $ModuleName ($modGuid)"
Write-Host "Workflows:    UNITE - VPN Standard / Privileged / Admin  (scope OU $AdScopeContainerGuid)"
Write-Host "NEXT: VAs UNITE-VPNStandard/Privileged/Admin + AR service restart; create AD groups (Part B);"
Write-Host "      in MMC Disable->Enable the 3 VPN workflows to register triggers."
