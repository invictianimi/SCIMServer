# =============================================================================
#  UNITE 2026   |   One Identity UNITE Conference
#  Chicago, USA   |   June 2026   |   Grand Ballroom III
# =============================================================================
#  Script   : UNITE-HRConnect.ps1
#  Purpose  : HR Connect application PROFILE - the role entry points the
#             "UNITE - HR Connect <Role>" workflows call. Boolean-per-role model,
#             identical pattern to HelpDesk: each role is a boolean VA on the user;
#             true grants the matching SCIM entitlement group in HR Connect, false
#             revokes it. The reusable SCIM/role plumbing lives in the shared core
#             (UNITE-HelpDesk.ps1); UNITE-Deploy-HRConnect.ps1 bundles core + this
#             profile into the ARS ScriptModule named "UNITE-HRConnect".
#  Roles    : HR Admin (group "HR Admins"), Recruiter ("Recruiters"),
#             Payroll ("Payroll"  - SoD-controlled vs HelpDesk Administrator).
#  Author   : Jacob Maloney  -  iC Consult, Presales Architect
#  Contact  : sales@ic-consult.com   (We build IAM that doesn't break.)
# =============================================================================
#
# VAs (created in MMC, Boolean, user class):
#   UNITE-HRConnectAdmin       -> SCIM group "HR Admins"
#   UNITE-HRConnectRecruiter   -> SCIM group "Recruiters"
#   UNITE-HRConnectPayroll     -> SCIM group "Payroll"
# AppKey "HRConnect" mapping + OnRemove policy live in UNITE-SCIMMappings.ps1.
# Connection: SCIM-HRConnect-URI / SCIM-HRConnect-Token workflow parameters.
# =============================================================================

# ----------------------------------------------------------------------------
# HR ADMIN  (VA UNITE-HRConnectAdmin -> "HR Admins")
# ----------------------------------------------------------------------------
function Dispatch-HRConnectAdminAccount {
    _EnsureRoleAccount  -RoleVA "UNITE-HRConnectAdmin" -AppKey "HRConnect" -RoleLabel "HR Connect Admin" -Request $Request
}
function Dispatch-HRConnectAdminRole {
    _SyncRoleMembership -RoleVA "UNITE-HRConnectAdmin" -AppKey "HRConnect" -Group "HR Admins" -RoleLabel "HR Connect Admin" -Request $Request
}
function Disable-HRConnectAdminAccount {
    _Disable-OneRoleAccount -RoleVA "UNITE-HRConnectAdmin" -AppKey "HRConnect" -RoleLabel "HR Connect Admin" -Request $Request
}
function Delete-HRConnectAdminAccount {
    _Delete-OneRoleAccount  -RoleVA "UNITE-HRConnectAdmin" -AppKey "HRConnect" -RoleLabel "HR Connect Admin" -Request $Request
}

# ----------------------------------------------------------------------------
# RECRUITER  (VA UNITE-HRConnectRecruiter -> "Recruiters")
# ----------------------------------------------------------------------------
function Dispatch-HRConnectRecruiterAccount {
    _EnsureRoleAccount  -RoleVA "UNITE-HRConnectRecruiter" -AppKey "HRConnect" -RoleLabel "HR Connect Recruiter" -Request $Request
}
function Dispatch-HRConnectRecruiterRole {
    _SyncRoleMembership -RoleVA "UNITE-HRConnectRecruiter" -AppKey "HRConnect" -Group "Recruiters" -RoleLabel "HR Connect Recruiter" -Request $Request
}
function Disable-HRConnectRecruiterAccount {
    _Disable-OneRoleAccount -RoleVA "UNITE-HRConnectRecruiter" -AppKey "HRConnect" -RoleLabel "HR Connect Recruiter" -Request $Request
}
function Delete-HRConnectRecruiterAccount {
    _Delete-OneRoleAccount  -RoleVA "UNITE-HRConnectRecruiter" -AppKey "HRConnect" -RoleLabel "HR Connect Recruiter" -Request $Request
}

# ----------------------------------------------------------------------------
# PAYROLL  (VA UNITE-HRConnectPayroll -> "Payroll")
# Cross-app SoD candidate: Payroll  X  HelpDesk Administrator.
# ----------------------------------------------------------------------------
function Dispatch-HRConnectPayrollAccount {
    _EnsureRoleAccount  -RoleVA "UNITE-HRConnectPayroll" -AppKey "HRConnect" -RoleLabel "HR Connect Payroll" -Request $Request
}
function Dispatch-HRConnectPayrollRole {
    _SyncRoleMembership -RoleVA "UNITE-HRConnectPayroll" -AppKey "HRConnect" -Group "Payroll" -RoleLabel "HR Connect Payroll" -Request $Request
}
function Disable-HRConnectPayrollAccount {
    _Disable-OneRoleAccount -RoleVA "UNITE-HRConnectPayroll" -AppKey "HRConnect" -RoleLabel "HR Connect Payroll" -Request $Request
}
function Delete-HRConnectPayrollAccount {
    _Delete-OneRoleAccount  -RoleVA "UNITE-HRConnectPayroll" -AppKey "HRConnect" -RoleLabel "HR Connect Payroll" -Request $Request
}
