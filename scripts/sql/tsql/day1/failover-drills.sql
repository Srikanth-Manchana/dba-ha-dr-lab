-- scripts/sql/tsql/day1/failover-drills.sql
-- Manual (planned) and forced (data-loss) failover drills for DBALAB-AG01.
-- Run each section on the node/context indicated.

-- ============================================================
-- 1. MANUAL (PLANNED) FAILOVER — zero data loss
-- ============================================================
-- Run on the CURRENT SECONDARY (e.g. SQL02), connected directly to that node
-- via SSMS. Requires the secondary to already be SYNCHRONIZED.
ALTER AVAILABILITY GROUP [DBALAB-AG01] FAILOVER;

-- Verify: connect to either node and check role_desc for the node you just
-- failed over to — should now show PRIMARY.
SELECT ag.name, ar.replica_server_name, ars.role_desc, ars.synchronization_health_desc
FROM sys.availability_groups ag
JOIN sys.availability_replicas ar ON ag.group_id = ar.group_id
LEFT JOIN sys.dm_hadr_availability_replica_states ars ON ar.replica_id = ars.replica_id;

-- Easiest live view: right-click the AG in SSMS Object Explorer -> Show Dashboard.


-- ============================================================
-- 2. FORCED FAILOVER WITH DATA LOSS — simulates a real outage
-- ============================================================
-- Step A: simulate the current primary going down. In PowerShell, ON THE
-- PRIMARY NODE:
--   Stop-Service MSSQLSERVER
--
-- Step B: on the SURVIVING node, force it to take over:
ALTER AVAILABILITY GROUP [DBALAB-AG01] FORCE_FAILOVER_ALLOW_DATA_LOSS;

-- Step C: bring the old primary back and observe the AG go UNHEALTHY.
-- In PowerShell, on the node that was stopped:
--   Start-Service MSSQLSERVER
--
-- LESSON: after a forced failover, the returning old-primary node does NOT
-- automatically know a failover happened, and may hold data that diverged
-- from the new primary. SQL Server will NOT auto-resolve this — the AG
-- dashboard shows "Unhealthy" and data movement is paused, requiring an
-- explicit human decision. In SSMS: right-click the now-secondary replica
-- in the dashboard -> "Resume Data Movement" to explicitly discard the
-- divergent state and resynchronize from the current primary.
--
-- This is the actual, concrete difference between manual and forced
-- failover: manual is a non-event because both sides already agree; forced
-- requires a human to explicitly accept potential data loss afterward, not
-- just at the moment of failover.

SELECT ag.name, ar.replica_server_name, ars.role_desc, ars.synchronization_health_desc
FROM sys.availability_groups ag
JOIN sys.availability_replicas ar ON ag.group_id = ar.group_id
LEFT JOIN sys.dm_hadr_availability_replica_states ars ON ar.replica_id = ars.replica_id;
-- Expect both HEALTHY again only after Resume Data Movement completes.
