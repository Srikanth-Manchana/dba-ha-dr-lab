# scripts/powershell/day1/06-create-ag.ps1
#
# The full Always-On AG build, incorporating every real fix hit along the way.
# See docs/day1-notes.md for the full story behind each numbered fix below.
# Run the numbered sections on the node indicated — this is NOT one script to
# run top-to-bottom on a single machine; it's a sequenced runbook.

# ============================================================
# SECTION A — Enable Always On (run on SQL01, then SQL02)
# ============================================================
# LESSON: Enable-SqlAlwaysOn's automatic service restart can fail with
# "StopService failed for Service 'MSSQLSERVER'". If it does, skip the
# cmdlet's restart and do it via SQL Server Configuration Manager instead:
#   SQLServerManager16.msc -> SQL Server Services -> SQL Server (MSSQLSERVER)
#   -> Properties -> Always On High Availability tab -> check the box -> OK
#   -> right-click -> Restart
# The cmdlet version, if it works cleanly for you:

Import-Module SqlServer
Enable-SqlAlwaysOn -ServerInstance SQL01 -Force   # repeat on SQL02

# Verify (authoritative check — the SQLSERVER:\ PowerShell provider can show
# stale cached state; T-SQL is the source of truth):
#   sqlcmd -S SQL01 -E -Q "SELECT SERVERPROPERTY('IsHadrEnabled') AS IsHadrEnabled"

# ============================================================
# SECTION B — Create + back up the test database (run on SQL01, via SSMS)
# ============================================================
# CREATE DATABASE DBALAB_OrdersDB;
# ALTER DATABASE DBALAB_OrdersDB SET RECOVERY FULL;
# (then, in PowerShell on SQL01:)
#   New-Item -Path C:\Backup -ItemType Directory -Force
# (back in SSMS:)
# BACKUP DATABASE DBALAB_OrdersDB TO DISK = 'C:\Backup\DBALAB_OrdersDB.bak';

# ============================================================
# SECTION C — Create endpoints, AG, listener (run on SQL01)
# ============================================================
Import-Module SqlServer

$primary = "SQL01"; $secondary = "SQL02"
$ep = New-SqlHADREndpoint -Path "SQLSERVER:\SQL\$primary\DEFAULT" -Port 5022 -Name "Hadr_endpoint"
$ep2 = New-SqlHADREndpoint -Path "SQLSERVER:\SQL\$secondary\DEFAULT" -Port 5022 -Name "Hadr_endpoint"

$primaryReplica = New-SqlAvailabilityReplica -Name $primary -EndpointUrl "TCP://SQL01.dbalab.local:5022" `
  -AvailabilityMode "SynchronousCommit" -FailoverMode "Automatic" -Version 12 -AsTemplate
$secondaryReplica = New-SqlAvailabilityReplica -Name $secondary -EndpointUrl "TCP://SQL02.dbalab.local:5022" `
  -AvailabilityMode "SynchronousCommit" -FailoverMode "Automatic" -Version 12 -AsTemplate

New-SqlAvailabilityGroup -Name "DBALAB-AG01" -Path "SQLSERVER:\SQL\$primary\DEFAULT" `
  -AvailabilityReplica @($primaryReplica, $secondaryReplica) `
  -Database "DBALAB_OrdersDB"

Join-SqlAvailabilityGroup -Path "SQLSERVER:\SQL\$secondary\DEFAULT" -Name "DBALAB-AG01"

# ============================================================
# SECTION D — Fix endpoint connectivity BEFORE attempting the database join
# ============================================================
# LESSON: "The connection to the primary replica is not active" can have
# THREE independent causes, layered. Check all three, don't assume fixing
# one means the others are fine:
#
#   D1. Azure NSG — already handled in 01-provision-vms.sh, but if you skipped
#       it or it's a fresh environment, each VM's own NSG needs port 5022
#       open (not just the OS firewall — this is a separate layer):
#         az network nsg rule create -g dba-lab-rg --nsg-name SQL01NSG \
#           --name Allow-SQL-HADR --priority 200 --direction Inbound \
#           --access Allow --protocol Tcp --destination-port-ranges 5022 \
#           --source-address-prefixes VirtualNetwork --destination-address-prefixes VirtualNetwork
#         (repeat for SQL02NSG)
#
#   D2. HADR endpoint registered but not actually STARTED. Check on BOTH nodes:
#         SELECT name, state_desc, port FROM sys.tcp_endpoints
#         WHERE type_desc = 'DATABASE_MIRRORING';
#       If state_desc is not STARTED, fix per-node:
#         ALTER ENDPOINT Hadr_endpoint STATE = STARTED;
#
#   D3. Missing SQL Server login for the peer's AD computer account. The SQL
#       Server service runs as the virtual account NT Service\MSSQLSERVER,
#       which authenticates over the network as the machine's own AD computer
#       account (DOMAIN\MACHINE$), not as any interactive user. Run on EACH
#       node, granting to the OTHER node's computer account:
#         -- On SQL01:
#         CREATE LOGIN [DBALAB\SQL02$] FROM WINDOWS;
#         GRANT CONNECT ON ENDPOINT::Hadr_endpoint TO [DBALAB\SQL02$];
#         -- On SQL02:
#         CREATE LOGIN [DBALAB\SQL01$] FROM WINDOWS;
#         GRANT CONNECT ON ENDPOINT::Hadr_endpoint TO [DBALAB\SQL01$];
#
# Verify both directions before proceeding:
#   Test-NetConnection -ComputerName SQL02.dbalab.local -Port 5022   (from SQL01)
#   Test-NetConnection -ComputerName SQL01.dbalab.local -Port 5022   (from SQL02)
# Both must show TcpTestSucceeded : True.

# ============================================================
# SECTION E — Restore the database on SQL02 and join it (run on SQL02, then SQL01)
# ============================================================
# On SQL01 — fresh log backup, then copy both files to SQL02:
#   BACKUP LOG DBALAB_OrdersDB TO DISK = 'C:\Backup\DBALAB_OrdersDB.trn';
#   Copy-Item "C:\Backup\DBALAB_OrdersDB.bak" "\\SQL02\C$\Backup\DBALAB_OrdersDB.bak" -Force
#   Copy-Item "C:\Backup\DBALAB_OrdersDB.trn" "\\SQL02\C$\Backup\DBALAB_OrdersDB.trn" -Force
#
# On SQL02 — restore WITH NORECOVERY (required before joining an AG):
#   RESTORE DATABASE DBALAB_OrdersDB FROM DISK = 'C:\Backup\DBALAB_OrdersDB.bak' WITH NORECOVERY;
#   RESTORE LOG DBALAB_OrdersDB FROM DISK = 'C:\Backup\DBALAB_OrdersDB.trn' WITH NORECOVERY;
#
# Join it — T-SQL is more reliable here than the Add-SqlAvailabilityDatabase
# cmdlet, which was observed to hang indefinitely in this environment:
#   -- On SQL02:
#   ALTER DATABASE DBALAB_OrdersDB SET HADR AVAILABILITY GROUP = [DBALAB-AG01];

# ============================================================
# SECTION F — Create the listener (run on SQL01)
# ============================================================
# LESSON: -StaticIp wants a dotted-decimal subnet mask, NOT CIDR notation.
# "10.10.1.30/24" fails with "The format for the IP address, '24', is invalid."
# Use the dotted-decimal equivalent instead:
New-SqlAvailabilityGroupListener -Name "DBALAB-AG01-L" -Port 1433 `
  -StaticIp "10.10.1.30/255.255.255.0" `
  -Path "SQLSERVER:\SQL\SQL01\DEFAULT\AvailabilityGroups\DBALAB-AG01"

# ============================================================
# SECTION G — IMPORTANT: the listener will NOT be reachable from outside
# Azure's network without an Internal Load Balancer (ILB) in front of it.
# ============================================================
# Azure's SDN does not support gratuitous ARP, which on-prem AG listeners
# rely on to move the listener IP between nodes on failover. Connecting
# directly to "DBALAB-AG01-L,1433" from SSMS will time out without an ILB +
# health probe configured. For this lab, verify failover via direct node
# connections and DMVs instead (see scripts/sql/tsql/day1/verify-ag-health.sql).
# A production deployment needs the ILB — see docs/day1-notes.md for the
# rationale and a starting `az network lb` command set.
