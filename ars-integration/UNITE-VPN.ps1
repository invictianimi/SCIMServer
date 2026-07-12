# =============================================================================
#  UNITE 2026   |   One Identity UNITE Conference
#  Chicago, USA   |   June 2026   |   Grand Ballroom III
# =============================================================================
#  Script   : UNITE-VPN.ps1   (intentionally empty - no script)
#  Purpose  : VPN / Remote Access needs NO PowerShell. Add/remove of the VPN AD
#             security groups is done the native ARS way: each "UNITE - VPN
#             <Role>" workflow uses an If-Else on the UNITE-VPN<Role> boolean VA
#             (TRUE -> built-in "Add to group" activity, FALSE -> built-in
#             "Remove from group" activity). Native Object-management activities
#             are the supported, audited, no-code path for AD group membership.
#
#             The earlier script functions (_SyncVPNRole / _AddVPNRole /
#             _RemoveVPNRole / Dispatch-VPN* / Add-VPN* / Remove-VPN*) were
#             REMOVED on 2026-06-01 once the workflows were rebuilt natively.
#             The role VAs (UNITE-VPNStandard/Privileged/Admin) and the AD groups
#             (VPN Standard/Privileged/Admin) remain - only the script was dropped.
#  Author   : Jacob Maloney  -  iC Consult, Presales Architect
# =============================================================================

# No functions. VPN role grant/revoke is handled by native ARS workflow activities.
