# scripts/powershell/day1/05-install-sql.ps1
#
# Run on SQL01, then SQL02 (as DBALAB\labadmin for Day 1's domain-joined
# nodes; local labadmin is fine for Day 2's standalone VM).
#
# LESSON (see docs/day1-notes.md): the SSEI bootstrapper's /MEDIATYPE only
# accepts ISO or CAB, NOT "Core" or "Advanced" despite some older docs/blog
# posts suggesting otherwise. Check with `.\SQL2022-SSEI-Dev.exe /?` if in
# doubt for whatever version you're using.

# 1. Download the bootstrapper (stable Microsoft fwlink for SQL Server 2022
#    Developer Edition — Developer is free, full-featured, legal for lab/dev use)
Invoke-WebRequest -Uri "https://go.microsoft.com/fwlink/?linkid=2215158" -OutFile "C:\SQL2022-SSEI-Dev.exe"

# 2. Download the install media as an ISO
C:\SQL2022-SSEI-Dev.exe /ACTION=Download /MEDIAPATH=C:\SQLInstall /MEDIATYPE=ISO /QUIET

# 3. Mount it and find the drive letter
#    NOTE: the actual downloaded filename includes "-Dev" (Developer Edition),
#    e.g. SQLServer2022-x64-ENU-Dev.iso — check what actually landed:
Get-ChildItem C:\SQLInstall
Mount-DiskImage -ImagePath "C:\SQLInstall\SQLServer2022-x64-ENU-Dev.iso"
Get-Volume | Where-Object {$_.DriveType -eq 'CD-ROM'}

# 4. Run the unattended install (swap D: for whatever drive letter step 3 showed)
#    Domain-joined node (Day 1, SQL01/SQL02):
$sysadmin = "DBALAB\labadmin"
#    Standalone node (Day 2, single VM, no domain):
#    $sysadmin = "labadmin"

$saPassword = Read-Host -Prompt "Enter SA password" -AsSecureString
$saPasswordPlain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($saPassword))

D:\SETUP.EXE /Q /ACTION=Install /FEATURES=SQLENGINE /INSTANCENAME=MSSQLSERVER `
  /SQLSYSADMINACCOUNTS="$sysadmin" /TCPENABLED=1 `
  /SECURITYMODE=SQL /SAPWD="$saPasswordPlain" /IACCEPTSQLSERVERLICENSETERMS

# 5. Verify the service
Get-Service MSSQLSERVER

# 6. Open the Windows Firewall for SQL Server — the Azure NSG rule (added in
#    01-provision-vms.sh) is a SEPARATE layer and does not substitute for this.
#    Missing this step causes "Access is denied" / Named Pipes errors in SSMS.
New-NetFirewallRule -DisplayName "SQL Server (TCP-In)" -Direction Inbound -Protocol TCP -LocalPort 1433 -Action Allow
New-NetFirewallRule -DisplayName "SQL Server HADR (TCP-In)" -Direction Inbound -Protocol TCP -LocalPort 5022 -Action Allow

# 7. If you plan to use the SqlServer PowerShell module (needed for AG cmdlets
#    in 06-create-ag.ps1), install it now — it does NOT come with a
#    /FEATURES=SQLENGINE-only install:
Install-Module -Name SqlServer -Force -AllowClobber -Scope CurrentUser
