-- scripts/sql/tsql/day2/04-resource-governor.sql
--
-- Isolates reporting workload (SSRS) from OLTP by capping its CPU/memory.
-- Includes the real fix for a classifier bug that silently misclassified
-- every SSRS session into the default group — see docs/day2-notes.md, issue #4.

USE master; -- classifier functions MUST live in master
GO

CREATE RESOURCE POOL ReportingPool WITH (MAX_CPU_PERCENT = 30, MAX_MEMORY_PERCENT = 20);
CREATE WORKLOAD GROUP ReportingGroup USING ReportingPool;
GO

-- ORIGINAL (WRONG) VERSION — kept here for reference on why it silently failed:
--   CREATE FUNCTION dbo.ClassifierFn() RETURNS SYSNAME WITH SCHEMABINDING AS
--   BEGIN
--     IF APP_NAME() LIKE '%SSRS%' RETURN 'ReportingGroup';
--     RETURN 'default';
--   END;
-- SSRS actually identifies itself via APP_NAME() = 'Report Server', not
-- 'SSRS' — the LIKE '%SSRS%' predicate never matched real traffic. This
-- produced no error anywhere; every SSRS session was just silently
-- classified into 'default' instead. Only caught by explicitly checking
-- actual session classification against real report traffic (see the
-- verification query at the bottom of this file).

CREATE FUNCTION dbo.ClassifierFn() RETURNS SYSNAME
WITH SCHEMABINDING AS
BEGIN
  IF APP_NAME() LIKE '%Report Server%' RETURN 'ReportingGroup';
  RETURN 'default';
END;
GO

ALTER RESOURCE GOVERNOR WITH (CLASSIFIER_FUNCTION = dbo.ClassifierFn);
ALTER RESOURCE GOVERNOR RECONFIGURE;

-- Confirm the pool/group registered correctly:
SELECT * FROM sys.dm_resource_governor_resource_pools WHERE name = 'ReportingPool';
SELECT * FROM sys.dm_resource_governor_workload_groups WHERE name = 'ReportingGroup';

-- ============================================================
-- If the classifier function ever needs to change later, it must be
-- detached first — SQL Server refuses ALTER FUNCTION while a function is
-- actively assigned as the classifier:
-- ============================================================
--   ALTER RESOURCE GOVERNOR WITH (CLASSIFIER_FUNCTION = NULL);
--   ALTER RESOURCE GOVERNOR RECONFIGURE;
--   ALTER FUNCTION dbo.ClassifierFn() RETURNS SYSNAME WITH SCHEMABINDING AS ...
--   ALTER RESOURCE GOVERNOR WITH (CLASSIFIER_FUNCTION = dbo.ClassifierFn);
--   ALTER RESOURCE GOVERNOR RECONFIGURE;

-- ============================================================
-- Verification against real traffic — the step that actually caught the bug.
-- Resource Governor classifies at connection time only; after changing the
-- classifier, existing sessions must reconnect (e.g. restart the SSRS
-- service) before this will show ReportingGroup.
-- ============================================================
SELECT s.session_id, s.program_name, g.name AS workload_group
FROM sys.dm_exec_sessions s
JOIN sys.dm_resource_governor_workload_groups g ON s.group_id = g.group_id
WHERE s.program_name = 'Report Server';

-- Confirm the pool is constraining real work, not just labeling sessions:
SELECT pool_id, name, max_cpu_percent, max_memory_percent, total_cpu_usage_ms
FROM sys.dm_resource_governor_resource_pools
WHERE name = 'ReportingPool';
