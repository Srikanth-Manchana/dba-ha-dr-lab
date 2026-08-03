-- scripts/sql/tsql/day1/verify-ag-health.sql
-- The diagnostic queries used to prove AG health end-to-end — the kind of
-- evidence you'd actually pull for a post-incident review.

-- Replica-level health: role, connection state, sync health, last error
SELECT r.replica_server_name, rs.role_desc, rs.connected_state_desc,
       rs.synchronization_health_desc, rs.last_connect_error_description
FROM sys.dm_hadr_availability_replica_states rs
JOIN sys.availability_replicas r ON rs.replica_id = r.replica_id;

-- Database-level health: sync state, suspend status/reason
SELECT database_name, synchronization_state_desc, is_suspended, suspend_reason_desc
FROM sys.dm_hadr_database_replica_states drs
JOIN sys.availability_databases_cluster adc ON drs.group_database_id = adc.group_database_id;

-- Full combined view (role + database sync state in one query)
SELECT ag.name AS AGName, ar.replica_server_name, ars.role_desc,
       ars.synchronization_health_desc,
       drs.synchronization_state_desc, drs.is_suspended, drs.suspend_reason_desc
FROM sys.availability_groups ag
JOIN sys.availability_replicas ar ON ag.group_id = ar.group_id
LEFT JOIN sys.dm_hadr_availability_replica_states ars ON ar.replica_id = ars.replica_id
LEFT JOIN sys.dm_hadr_database_replica_states drs ON ar.replica_id = drs.replica_id;

-- Endpoint state check — useful when replicas show CONNECTED : false or
-- "connection to primary replica is not active" errors during setup
SELECT name, protocol_desc, state_desc, port
FROM sys.tcp_endpoints
WHERE type_desc = 'DATABASE_MIRRORING';

-- HADR-enabled flag — authoritative via T-SQL; the SQLSERVER:\ PowerShell
-- provider (Get-Item "SQLSERVER:\SQL\<instance>\Default").IsHadrEnabled can
-- show stale cached state, so prefer this when the two disagree:
SELECT SERVERPROPERTY('IsHadrEnabled') AS IsHadrEnabled;

-- Listener registration check
SELECT listener_id, dns_name, port FROM sys.availability_group_listeners;

-- ============================================================
-- Cluster log capture (run in PowerShell, not SSMS)
-- ============================================================
-- Get-ClusterLog -Node SQL01, SQL02 -Destination C:\ClusterLogs -TimeSpan 30
-- Then search for failover events around a known timestamp:
-- Select-String -Path C:\ClusterLogs\SQL01_cluster.log -Pattern "FailoverUnit" | Select-Object -First 10
