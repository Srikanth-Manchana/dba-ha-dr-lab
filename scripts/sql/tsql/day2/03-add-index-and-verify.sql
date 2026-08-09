-- scripts/sql/tsql/day2/03-add-index-and-verify.sql
--
-- Fixes the baseline slow query with a targeted covering index, then uses
-- Query Store to compare before/after plans and force the good plan.

USE DBALAB_PerfLab;
GO

-- Query Store must be enabled on a real user database — this fails outright
-- if attempted against master (see docs/day2-notes.md, issue #2).
ALTER DATABASE DBALAB_PerfLab SET QUERY_STORE = ON;
ALTER DATABASE DBALAB_PerfLab SET QUERY_STORE (OPERATION_MODE = READ_WRITE);

-- Exact index recommended in the baseline plan's <MissingIndexes> block.
CREATE NONCLUSTERED INDEX IX_OrdersData_Region_Status
  ON dbo.OrdersData (Region, Status) INCLUDE (OrderID, OrderDate, OrderType, Notes);

-- Re-run the same query — Ctrl+M for the plan again.
SELECT * FROM dbo.OrdersData WHERE Region = 'RGN-12' AND Status = 'Open';
-- Observed: Index Seek on IX_OrdersData_Region_Status,
-- StatementSubTreeCost 4.32257 (down from 180.016, ~97.6% reduction),
-- logical reads 5,614 (down from ~230,739).

-- Decompose elapsed time vs CPU time to understand where the remaining
-- ~1.5s actually goes:
SET STATISTICS TIME ON;
SET STATISTICS IO ON;
SELECT * FROM dbo.OrdersData WHERE Region = 'RGN-12' AND Status = 'Open';
SET STATISTICS TIME OFF;
SET STATISTICS IO OFF;
-- Observed: CPU time 156ms, elapsed time 1505ms, physical reads 0.
-- Zero physical reads rules out disk I/O; the gap is most likely
-- ASYNC_NETWORK_IO — time spent transmitting a genuinely large result set
-- (173,107 matching rows) back to the client, not query execution cost.
-- The index fixed the access path; it does not make returning ~173K rows
-- to a client instantaneous, which is a separate, distinct cost.

-- Identify the query in Query Store and compare both plans:
SELECT qsq.query_id, qsqt.query_sql_text
FROM sys.query_store_query qsq
JOIN sys.query_store_query_text qsqt ON qsq.query_text_id = qsqt.query_text_id
ORDER BY qsq.query_id;

SELECT qsq.query_id, qsp.plan_id, qsrs.avg_duration/1000 AS avg_ms, qsp.is_forced_plan
FROM sys.query_store_query qsq
JOIN sys.query_store_plan qsp ON qsq.query_id = qsp.query_id
JOIN sys.query_store_runtime_stats qsrs ON qsp.plan_id = qsrs.plan_id
ORDER BY qsq.query_id;

-- Force the known-good (post-index) plan — replace @query_id/@plan_id with
-- the actual IDs from the query above:
EXEC sp_query_store_force_plan @query_id = 25, @plan_id = 5;

-- Verify it's actually forced:
SELECT qsq.query_id, qsp.plan_id, qsp.is_forced_plan
FROM sys.query_store_query qsq
JOIN sys.query_store_plan qsp ON qsq.query_id = qsp.query_id
WHERE qsq.query_id = 25;
