# scripts/powershell/day1/02-promote-dc.ps1
#
# Run on DC01 as a local Administrator (RDP in first).
# Promotes DC01 to the forest root domain controller for dbalab.local.
# Reboots automatically on completion — expect the RDP session to drop.

Install-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools

$safeModePw = Read-Host -Prompt "Enter Safe Mode Administrator Password" -AsSecureString

Install-ADDSForest `
  -DomainName "dbalab.local" `
  -DomainNetbiosName "DBALAB" `
  -InstallDns:$true `
  -SafeModeAdministratorPassword $safeModePw `
  -Force:$true

# After reboot, verify with:
#   Get-ADDomain | Select Name, DomainMode, PDCEmulator
# Expected: Name = dbalab
