# One-off: finish the SCIMServer schema on .56 that the wizard couldn't (the
# CreateDatabase.sql TenantId-index bug + the migrate-skip if/else left only the
# Users table). Builds the rest of the baseline + migrations v8-v13 directly.
param(
  [string]$Server = '192.168.1.56',
  [string]$Db     = 'SCIMServer',
  [string]$BaseSql = 'C:\Users\jacob\source\repos\SCIMServer\Database\CreateDatabase.sql'
)
$ErrorActionPreference='Stop'
$cs = "Server=$Server;Database=$Db;User Id=sa;Password=$env:LAB_SQL_PASSWORD;TrustServerCertificate=true;Connect Timeout=15;"
$conn = New-Object System.Data.SqlClient.SqlConnection $cs
$conn.Open()
function Exec($name,$sql){
  $c=$conn.CreateCommand(); $c.CommandTimeout=120; $c.CommandText=$sql
  try { [void]$c.ExecuteNonQuery(); Write-Host "OK   $name" }
  catch { Write-Host "FAIL $name : $($_.Exception.Message)"; throw }
}

# 1) Baseline from the Users indexes onward (skips the Users TABLE, which exists,
#    and the removed TenantId index). Creates the 5 Users indexes + all other
#    baseline tables + the SystemConfiguration seed. One batch (file has no GO).
$base = [System.IO.File]::ReadAllText($BaseSql)
$i = $base.IndexOf('CREATE INDEX [IX_Users_UserName]')
if ($i -lt 0) { throw "anchor 'CREATE INDEX [IX_Users_UserName]' not found in baseline" }
Exec 'baseline (indexes + remaining tables)' $base.Substring($i)

# 2) Migration v8 - Tenants + TenantId on Users/Groups/ApiTokens + Scope
Exec 'v8 Tenants/TenantId' @'
IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'Tenants')
BEGIN
    CREATE TABLE [dbo].[Tenants] (
        [Id]           UNIQUEIDENTIFIER NOT NULL DEFAULT NEWID(),
        [Name]         NVARCHAR(200)    NOT NULL,
        [Slug]         NVARCHAR(100)    NOT NULL,
        [Description]  NVARCHAR(500)    NULL,
        [SystemType]   NVARCHAR(20)     NOT NULL CONSTRAINT [DF_Tenants_SystemType] DEFAULT 'Emulator',
        [Domain]       NVARCHAR(300)    NULL,
        [IsActive]     BIT              NOT NULL CONSTRAINT [DF_Tenants_IsActive] DEFAULT 1,
        [Created]      DATETIME2        NOT NULL CONSTRAINT [DF_Tenants_Created] DEFAULT GETUTCDATE(),
        [LastModified] DATETIME2        NOT NULL CONSTRAINT [DF_Tenants_LastModified] DEFAULT GETUTCDATE(),
        CONSTRAINT [PK_Tenants] PRIMARY KEY CLUSTERED ([Id]),
        CONSTRAINT [UQ_Tenants_Slug] UNIQUE ([Slug])
    );
    CREATE INDEX [IX_Tenants_IsActive] ON [Tenants]([IsActive]);
END
IF NOT EXISTS (SELECT 1 FROM [dbo].[Tenants] WHERE [Id] = '00000000-0000-0000-0000-000000000001')
    INSERT INTO [dbo].[Tenants] ([Id],[Name],[Slug],[Description],[SystemType],[IsActive])
    VALUES ('00000000-0000-0000-0000-000000000001','Default','default','Default Connected System','Emulator',1);
IF NOT EXISTS (SELECT * FROM sys.columns WHERE object_id = OBJECT_ID('dbo.Users') AND name = 'TenantId')
    ALTER TABLE [dbo].[Users] ADD [TenantId] UNIQUEIDENTIFIER NOT NULL CONSTRAINT [DF_Users_TenantId] DEFAULT '00000000-0000-0000-0000-000000000001';
IF NOT EXISTS (SELECT * FROM sys.foreign_keys WHERE name = 'FK_Users_Tenants')
    ALTER TABLE [dbo].[Users] WITH CHECK ADD CONSTRAINT [FK_Users_Tenants] FOREIGN KEY ([TenantId]) REFERENCES [Tenants]([Id]);
IF NOT EXISTS (SELECT * FROM sys.indexes WHERE name = 'IX_Users_TenantId' AND object_id = OBJECT_ID('dbo.Users'))
    CREATE INDEX [IX_Users_TenantId] ON [Users]([TenantId]);
IF NOT EXISTS (SELECT * FROM sys.columns WHERE object_id = OBJECT_ID('dbo.Groups') AND name = 'TenantId')
    ALTER TABLE [dbo].[Groups] ADD [TenantId] UNIQUEIDENTIFIER NOT NULL CONSTRAINT [DF_Groups_TenantId] DEFAULT '00000000-0000-0000-0000-000000000001';
IF NOT EXISTS (SELECT * FROM sys.foreign_keys WHERE name = 'FK_Groups_Tenants')
    ALTER TABLE [dbo].[Groups] WITH CHECK ADD CONSTRAINT [FK_Groups_Tenants] FOREIGN KEY ([TenantId]) REFERENCES [Tenants]([Id]);
IF NOT EXISTS (SELECT * FROM sys.indexes WHERE name = 'IX_Groups_TenantId' AND object_id = OBJECT_ID('dbo.Groups'))
    CREATE INDEX [IX_Groups_TenantId] ON [Groups]([TenantId]);
IF NOT EXISTS (SELECT * FROM sys.columns WHERE object_id = OBJECT_ID('dbo.ApiTokens') AND name = 'TenantId')
    ALTER TABLE [dbo].[ApiTokens] ADD [TenantId] UNIQUEIDENTIFIER NULL;
IF NOT EXISTS (SELECT * FROM sys.foreign_keys WHERE name = 'FK_ApiTokens_Tenants')
    ALTER TABLE [dbo].[ApiTokens] WITH CHECK ADD CONSTRAINT [FK_ApiTokens_Tenants] FOREIGN KEY ([TenantId]) REFERENCES [Tenants]([Id]);
IF NOT EXISTS (SELECT * FROM sys.indexes WHERE name = 'IX_ApiTokens_TenantId' AND object_id = OBJECT_ID('dbo.ApiTokens'))
    CREATE INDEX [IX_ApiTokens_TenantId] ON [ApiTokens]([TenantId]);
IF NOT EXISTS (SELECT * FROM sys.columns WHERE object_id = OBJECT_ID('dbo.ApiTokens') AND name = 'Scope')
    ALTER TABLE [dbo].[ApiTokens] ADD [Scope] NVARCHAR(20) NOT NULL CONSTRAINT [DF_ApiTokens_Scope] DEFAULT 'Tenant';
'@

# 3) v9 - SqlAccounts
Exec 'v9 SqlAccounts' @'
IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'SqlAccounts')
BEGIN
    CREATE TABLE [dbo].[SqlAccounts] (
        [Id]       UNIQUEIDENTIFIER NOT NULL DEFAULT NEWID(),
        [TenantId] UNIQUEIDENTIFIER NOT NULL CONSTRAINT [DF_SqlAccounts_TenantId] DEFAULT '00000000-0000-0000-0000-000000000001',
        [Username] NVARCHAR(128)    NOT NULL,
        [Disabled] BIT              NOT NULL CONSTRAINT [DF_SqlAccounts_Disabled] DEFAULT 0,
        [Created]  DATETIME2        NOT NULL CONSTRAINT [DF_SqlAccounts_Created] DEFAULT GETUTCDATE(),
        CONSTRAINT [PK_SqlAccounts] PRIMARY KEY CLUSTERED ([Id]),
        CONSTRAINT [FK_SqlAccounts_Tenants] FOREIGN KEY ([TenantId]) REFERENCES [Tenants]([Id]),
        CONSTRAINT [UQ_SqlAccounts_TenantUsername] UNIQUE ([TenantId], [Username])
    );
    CREATE INDEX [IX_SqlAccounts_TenantId] ON [SqlAccounts]([TenantId]);
END
'@

# 4) v10 - PortalAdmins (the table the setup gate needs to exist)
Exec 'v10 PortalAdmins' @'
IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'PortalAdmins')
BEGIN
    CREATE TABLE [dbo].[PortalAdmins] (
        [Id]            UNIQUEIDENTIFIER NOT NULL DEFAULT NEWID(),
        [UserName]      NVARCHAR(128)    NOT NULL,
        [DisplayName]   NVARCHAR(256)    NULL,
        [PasswordHash]  NVARCHAR(512)    NOT NULL,
        [PasswordSalt]  NVARCHAR(512)    NOT NULL,
        [Active]        BIT              NOT NULL CONSTRAINT [DF_PortalAdmins_Active] DEFAULT 1,
        [Created]       DATETIME2        NOT NULL CONSTRAINT [DF_PortalAdmins_Created] DEFAULT SYSUTCDATETIME(),
        [LastModified]  DATETIME2        NOT NULL CONSTRAINT [DF_PortalAdmins_LastModified] DEFAULT SYSUTCDATETIME(),
        [LastLoginAt]   DATETIME2        NULL,
        CONSTRAINT [PK_PortalAdmins] PRIMARY KEY CLUSTERED ([Id]),
        CONSTRAINT [UQ_PortalAdmins_UserName] UNIQUE ([UserName])
    );
END;
'@

# 5) v11 - LoginAttempts + LoginLockouts (the throttle pruner needs these)
Exec 'v11 Login throttle tables' @'
IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'LoginAttempts')
BEGIN
    CREATE TABLE [dbo].[LoginAttempts] (
        [Id]            UNIQUEIDENTIFIER NOT NULL DEFAULT NEWID(),
        [UsernameLower] NVARCHAR(256)    NOT NULL,
        [IpAddress]     NVARCHAR(64)     NOT NULL,
        [AttemptedAt]   DATETIME2        NOT NULL CONSTRAINT [DF_LoginAttempts_AttemptedAt] DEFAULT SYSUTCDATETIME(),
        [Success]       BIT              NOT NULL,
        CONSTRAINT [PK_LoginAttempts] PRIMARY KEY CLUSTERED ([Id])
    );
    CREATE INDEX [IX_LoginAttempts_UserIpTime] ON [LoginAttempts]([UsernameLower],[IpAddress],[AttemptedAt] DESC) INCLUDE ([Success]);
    CREATE INDEX [IX_LoginAttempts_AttemptedAt] ON [LoginAttempts]([AttemptedAt]);
END;
IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'LoginLockouts')
BEGIN
    CREATE TABLE [dbo].[LoginLockouts] (
        [UsernameLower] NVARCHAR(256)    NOT NULL,
        [IpAddress]     NVARCHAR(64)     NOT NULL,
        [LockedUntil]   DATETIME2        NOT NULL,
        [LockedAt]      DATETIME2        NOT NULL CONSTRAINT [DF_LoginLockouts_LockedAt] DEFAULT SYSUTCDATETIME(),
        [FailureCount]  INT              NOT NULL CONSTRAINT [DF_LoginLockouts_FailureCount] DEFAULT 0,
        CONSTRAINT [PK_LoginLockouts] PRIMARY KEY CLUSTERED ([UsernameLower],[IpAddress])
    );
    CREATE INDEX [IX_LoginLockouts_LockedUntil] ON [LoginLockouts]([LockedUntil]);
END;
'@

# 6) v12 - Tenants.LegalHold
Exec 'v12 LegalHold' @'
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.Tenants') AND name = 'LegalHold')
    ALTER TABLE [dbo].[Tenants] ADD [LegalHold] BIT NOT NULL CONSTRAINT [DF_Tenants_LegalHold] DEFAULT 0;
'@

# 7) v13 - tenant-scoped uniqueness (this creates UQ_Users_TenantId_UserName now that TenantId exists)
Exec 'v13 tenant-scoped uniqueness' @'
IF EXISTS (SELECT 1 FROM sys.key_constraints WHERE name = 'UQ_Users_UserName' AND parent_object_id = OBJECT_ID('dbo.Users'))
    ALTER TABLE [dbo].[Users] DROP CONSTRAINT [UQ_Users_UserName];
ELSE IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UQ_Users_UserName' AND object_id = OBJECT_ID('dbo.Users'))
    DROP INDEX [UQ_Users_UserName] ON [dbo].[Users];
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UQ_Users_TenantId_UserName' AND object_id = OBJECT_ID('dbo.Users'))
    CREATE UNIQUE NONCLUSTERED INDEX [UQ_Users_TenantId_UserName] ON [dbo].[Users]([TenantId],[UserName]);
IF EXISTS (SELECT 1 FROM sys.key_constraints WHERE name = 'UQ_Groups_DisplayName' AND parent_object_id = OBJECT_ID('dbo.Groups'))
    ALTER TABLE [dbo].[Groups] DROP CONSTRAINT [UQ_Groups_DisplayName];
ELSE IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UQ_Groups_DisplayName' AND object_id = OBJECT_ID('dbo.Groups'))
    DROP INDEX [UQ_Groups_DisplayName] ON [dbo].[Groups];
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UQ_Groups_TenantId_DisplayName' AND object_id = OBJECT_ID('dbo.Groups'))
    CREATE UNIQUE NONCLUSTERED INDEX [UQ_Groups_TenantId_DisplayName] ON [dbo].[Groups]([TenantId],[DisplayName]);
'@

# 8) Record SchemaVersion 2-13 so the app's AutoMigrate is a no-op on restart
Exec 'SchemaVersion 2-13' @'
;WITH v(n,d) AS (VALUES
 (2,'Fix GroupMembers'),(3,'Add Owner to Groups'),(4,'Add Type to Groups'),(5,'Add Manager to Users'),
 (6,'Fix ApiTokens'),(7,'Add IsAdmin'),(8,'Multi-tenant baseline'),(9,'SqlAccounts'),
 (10,'PortalAdmins separation'),(11,'Login throttle'),(12,'Tenants.LegalHold'),(13,'Tenant-scoped uniqueness'))
INSERT INTO [SchemaVersion]([Version],[Description])
SELECT n,d FROM v WHERE n NOT IN (SELECT [Version] FROM [SchemaVersion]);
'@

Write-Host "`n=== Final tables ==="
$c=$conn.CreateCommand(); $c.CommandText="SELECT name FROM sys.tables ORDER BY name"
$r=$c.ExecuteReader(); while($r.Read()){ Write-Host "  $($r['name'])" }; $r.Close()
$c=$conn.CreateCommand(); $c.CommandText="SELECT MAX([Version]) FROM SchemaVersion"
Write-Host "SchemaVersion max = $($c.ExecuteScalar())"
$conn.Close()
