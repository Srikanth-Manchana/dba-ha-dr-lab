# scripts/powershell/day1/03-join-domain.ps1
#
# Run on SQL01, SQL02, and JUMP01 individually (one at a time, confirm each
# before moving to the next). RDP in as the LOCAL labadmin account first.
#
# IMPORTANT LESSON (see docs/day1-notes.md, issue #4): after joining the
# domain, always reconnect RDP using "DBALAB\labadmin" explicitly in the
# username field — RDP clients can silently default back to the local
# account otherwise, which causes confusing "login failed" errors on
# anything domain-related later.

# DC01's private IP — confirm with:
#   az vm list-ip-addresses -g dba-lab-rg -n DC01 --output table
$dcPrivateIp = "10.10.1.4"

$adapter = Get-DnsClient | Where-Object {$_.InterfaceAlias -like "Ethernet*"}
Set-DnsClientServerAddress -InterfaceIndex $adapter.InterfaceIndex -ServerAddresses $dcPrivateIp

Add-Computer -DomainName "dbalab.local" -Credential (Get-Credential) -Restart
# When prompted: username = DBALAB\labadmin, password = same as local labadmin

# After reboot, reconnect RDP as DBALAB\labadmin (not just labadmin), then verify:
#   (Get-WmiObject Win32_ComputerSystem).Domain
# Expected: dbalab.local
