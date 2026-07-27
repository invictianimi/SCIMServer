# =============================================================================
#  UNITE 2026   |   One Identity UNITE Conference
#  Chicago, USA   |   June 2026   |   Grand Ballroom III
# =============================================================================
#  Script   : UNITE-Deploy-SoDPolicy.ps1
#  Purpose  : Push UNITE-SoDPolicy.ps1 into Active Roles 8.3 as a Script Module
#             (direct-SQL, idempotent). The module holds the onPreModify SoD
#             handler. After this runs, create the Policy Object in MMC (steps at
#             the bottom) - that binding is the ARS-native part.
#  Author   : Jacob Maloney  -  iC Consult, Presales Architect
# =============================================================================

param(
    [string]$Server   = "192.168.1.56",
    [string]$Database = "ActiveRoles830",
    [string]$User     = "sa",
    [string]$Password = $env:LAB_SQL_PASSWORD,
    [string]$ScriptModuleParentGuid = "019f78e8-7f74-4ff6-b662-63c83deb8261",  # CN=Script Modules
    [string]$ModuleName = "UNITE-SoDPolicy",

    # Policy Object + link (discovered on .56 2026-06-01 by cloning the built-in
    # 'Application Policy' = a Script Execution policy, APE type 0x3, param 4 = script module GUID):
    [string]$PolicyName        = "UNITE - HelpDesk Separation of Duties",
    [string]$AdminContainerGuid = "053DC4C4-DAA2-47F9-A135-49C1D4C52A9B",       # CN=Administration,CN=Policies (custom policies)
    [string]$ApLinksContainerGuid = "D0400A25-E383-4CD0-B82C-5E1F753911D2",     # CN=AP Links,CN=Configuration
    [string]$ScopeOuGuid       = "16289041-4cfe-4b48-8a3b-c2c9867cafdc"         # OU=UNITE-2026 (demo users)
)

$ErrorActionPreference = "Stop"
$cs = "Server=$Server;Database=$Database;User Id=$User;Password=$Password;TrustServerCertificate=true;"

function Read-PsFile { param([string]$Path)
    if (-not (Test-Path $Path)) { Write-Error "Source not found: $Path"; exit 1 }
    $text = [System.IO.File]::ReadAllText($Path)
    $tok = $err = $null
    [System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$tok, [ref]$err) | Out-Null
    if ($err.Count) { $err | ForEach-Object { Write-Host "PARSE ERR L$($_.Extent.StartLineNumber): $($_.Message)" }; exit 1 }
    return $text
}
$moduleText = Read-PsFile (Join-Path $PSScriptRoot "UNITE-SoDPolicy.ps1")

$conn = New-Object System.Data.SqlClient.SqlConnection $cs
$conn.Open()

$g=$conn.CreateCommand(); $g.CommandText="SELECT CAST(objectGUID AS UNIQUEIDENTIFIER) FROM ScriptModules WHERE name=@n"
[void]$g.Parameters.AddWithValue("@n",$ModuleName); $existing=$g.ExecuteScalar()
if ($existing) {
    $guid=[Guid]$existing
    $u=$conn.CreateCommand(); $u.CommandText="UPDATE ScriptModules SET edsaScriptText=@t, whenChanged=SYSDATETIME() WHERE objectGUID=@g"
    $pt=$u.Parameters.Add("@t",[System.Data.SqlDbType]::NVarChar,-1); $pt.Value=$moduleText
    [void]$u.Parameters.AddWithValue("@g",$guid); $rows=$u.ExecuteNonQuery()
    Write-Host "ScriptModule '$ModuleName' updated (GUID $guid, trigger rows $rows)."
} else {
    $guid=[Guid]::NewGuid(); $dn="CN=$ModuleName,CN=Script Modules,CN=Configuration"
    $i=$conn.CreateCommand()
    $i.CommandText=@"
INSERT INTO ScriptModules (objectGUID,ParentObjectGUID,name,distinguishedName,objectClass,
  edsaScriptText,edsaScriptLanguage,edsaScriptType,whenCreated,whenChanged,edsaIsPredefined,edsaSystemObject)
VALUES (@g,@p,@n,@d,'edsScriptModule',@t,'PowerShell',0,SYSDATETIME(),SYSDATETIME(),0,0);
"@
    [void]$i.Parameters.AddWithValue("@g",$guid); [void]$i.Parameters.AddWithValue("@p",[Guid]$ScriptModuleParentGuid)
    [void]$i.Parameters.AddWithValue("@n",$ModuleName); [void]$i.Parameters.AddWithValue("@d",$dn)
    $pt=$i.Parameters.Add("@t",[System.Data.SqlDbType]::NVarChar,-1); $pt.Value=$moduleText
    [void]$i.ExecuteNonQuery(); Write-Host "ScriptModule '$ModuleName' created (GUID $guid)."
}
$moduleGuid = $guid

# --- Policy Object (APOs): Script Execution APE (type 0x3, param 4 = module GUID) ---
function New-Guid2 { [Guid]::NewGuid().ToString().ToUpper() }
$apeInstanceGuid = New-Guid2
$apeXml = @"
<APEList Version="1.0">
            <APE type="0x3">
                <parameter id="1">
                    <value>$PolicyName</value>
                </parameter>
                <parameter id="4">
                    <value>$($moduleGuid.ToString().ToUpper())</value>
                </parameter>
                <parameter id="6">
                    <value>0xFFFFFFFF</value>
                </parameter>
                <parameter id="57">
                    <value>Real-time separation-of-duties hard stop: denies a grant that would let a user hold both Helpdesk Auditor and Helpdesk Administrator.</value>
                </parameter>
                <parameter id="59">
                    <value>$apeInstanceGuid</value>
                </parameter>
                <parameter id="72">
                    <value>1</value>
                </parameter>
            </APE>
        </APEList>
"@

$g=$conn.CreateCommand(); $g.CommandText="SELECT CAST(objectGUID AS UNIQUEIDENTIFIER) FROM APOs WHERE name=@n"
[void]$g.Parameters.AddWithValue("@n",$PolicyName); $apoExisting=$g.ExecuteScalar()
if ($apoExisting) {
    $apoGuid=[Guid]$apoExisting
    $u=$conn.CreateCommand(); $u.CommandText="UPDATE APOs SET edsaAPEListXML=@x, edsaPolicyDisabled=0, whenChanged=SYSDATETIME() WHERE objectGUID=@g"
    $px=$u.Parameters.Add("@x",[System.Data.SqlDbType]::NVarChar,-1); $px.Value=$apeXml
    [void]$u.Parameters.AddWithValue("@g",$apoGuid); [void]$u.ExecuteNonQuery()
    Write-Host "Policy Object '$PolicyName' updated (GUID $apoGuid)."
} else {
    $apoGuid=[Guid]::NewGuid(); $dn="CN=$PolicyName,CN=Administration,CN=Policies,CN=Configuration"
    $i=$conn.CreateCommand()
    $i.CommandText=@"
INSERT INTO APOs (objectGUID,ParentObjectGUID,name,distinguishedName,description,objectClass,
  edsaIsPredefined,edsaSystemObject,showInAdvancedViewOnly,edsaShowInRawViewOnly,
  edsaAPEListXML,whenCreated,whenChanged,sign,edsaPolicyDisabled)
VALUES (@g,@p,@n,@d,@desc,'edsPolicyObject',0,0,0,0,@x,SYSDATETIME(),SYSDATETIME(),0,0);
"@
    [void]$i.Parameters.AddWithValue("@g",$apoGuid); [void]$i.Parameters.AddWithValue("@p",[Guid]$AdminContainerGuid)
    [void]$i.Parameters.AddWithValue("@n",$PolicyName); [void]$i.Parameters.AddWithValue("@d",$dn)
    [void]$i.Parameters.AddWithValue("@desc","UNITE 2026 - real-time SoD hard stop (Helpdesk Auditor vs Administrator).")
    $px=$i.Parameters.Add("@x",[System.Data.SqlDbType]::NVarChar,-1); $px.Value=$apeXml
    [void]$i.ExecuteNonQuery(); Write-Host "Policy Object '$PolicyName' created (GUID $apoGuid)."
}

# --- Policy link (APOLinks): scope the policy to OU=UNITE-2026 ---
$lk=$conn.CreateCommand()
$lk.CommandText="SELECT COUNT(*) FROM APOLinks WHERE edsaAPOGUID=@a AND edsaSecObjectGUID=@s"
[void]$lk.Parameters.AddWithValue("@a",$apoGuid); [void]$lk.Parameters.AddWithValue("@s",[Guid]$ScopeOuGuid)
if ([int]$lk.ExecuteScalar() -gt 0) {
    Write-Host "Policy link to OU already present - skipped."
} else {
    $linkGuid=[Guid]::NewGuid()
    $linkName="Link to '$PolicyName' (UNITE-2026)"
    $linkDn="CN=$linkName,CN=AP Links,CN=Configuration"
    $li=$conn.CreateCommand()
    $li.CommandText=@"
INSERT INTO APOLinks (objectGUID,ParentObjectGUID,name,distinguishedName,objectClass,
  edsaIsPredefined,edsaSystemObject,edsaAPOGUID,edsaSecObjectGUID,
  edsaLinkFlags,edsaLinkDisabled,isDeleted,whenCreated,whenChanged,sign)
VALUES (@g,@p,@n,@d,'edsPolicyObjectLink',0,0,@a,@s,2,0,0,SYSDATETIME(),SYSDATETIME(),0);
"@
    [void]$li.Parameters.AddWithValue("@g",$linkGuid); [void]$li.Parameters.AddWithValue("@p",[Guid]$ApLinksContainerGuid)
    [void]$li.Parameters.AddWithValue("@n",$linkName); [void]$li.Parameters.AddWithValue("@d",$linkDn)
    [void]$li.Parameters.AddWithValue("@a",$apoGuid); [void]$li.Parameters.AddWithValue("@s",[Guid]$ScopeOuGuid)
    [void]$li.ExecuteNonQuery(); Write-Host "Policy link created -> OU=UNITE-2026 ($ScopeOuGuid)."
}

$conn.Close()

Write-Host ""
Write-Host "=== Done ==="
Write-Host "ScriptModule:  $ModuleName ($moduleGuid)"
Write-Host "Policy Object: $PolicyName ($apoGuid)  [Script Execution -> module, onPreModify]"
Write-Host "Linked to:     OU=UNITE-2026 ($ScopeOuGuid)"
Write-Host ""
Write-Host "NEXT: restart the AR Administration Service so the policy engine loads the new"
Write-Host "policy + link, then test: grant Helpdesk Administrator to a user who already holds"
Write-Host "Helpdesk Auditor -> the operation must be DENIED with the SoD reason."
