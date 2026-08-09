-- scripts/sql/tsql/day2/01-build-workload.sql
--
-- Builds a deliberately unindexed ~6.9M row table for performance tuning
-- exercises. IMPORTANT: create/use a real user database first — creating
-- this directly in master will block Query Store later (see docs/day2-notes.md,
-- issue #2).

CREATE DATABASE DBALAB_PerfLab;
GO

USE DBALAB_PerfLab;
GO

CREATE TABLE dbo.OrdersData (
  OrderID INT IDENTITY, OrderDate DATETIME, Region VARCHAR(10),
  OrderType VARCHAR(50), Status VARCHAR(20), Notes VARCHAR(500)
);

INSERT INTO dbo.OrdersData (OrderDate, Region, OrderType, Status, Notes)
SELECT DATEADD(DAY, -(ABS(CHECKSUM(NEWID())) % 1000), GETDATE()),
       'RGN-' + CAST((ABS(CHECKSUM(NEWID())) % 40) AS VARCHAR),
       CASE ABS(CHECKSUM(NEWID())) % 4 WHEN 0 THEN 'Electronics' WHEN 1 THEN 'Apparel' WHEN 2 THEN 'HomeGoods' ELSE 'Grocery' END,
       'Open', REPLICATE('x', 200)
FROM sys.all_objects a CROSS JOIN sys.all_objects b;
-- NOTE: actual row count observed was ~6.9M, not the ~2M originally estimated —
-- sys.all_objects has grown with the SQL Server version, producing a larger
-- cross join than expected. Not an issue, just larger than planned.

SELECT COUNT(*) FROM dbo.OrdersData;

-- Baseline "before" query — no useful index exists yet (heap table).
-- Turn on Include Actual Execution Plan (Ctrl+M in SSMS) before running this.
SELECT * FROM dbo.OrdersData WHERE Region = 'RGN-12' AND Status = 'Open';
-- Observed: Table Scan, IndexKind=Heap, ~6.9M rows scanned,
-- StatementSubTreeCost 180.016, CpuTime 3083ms, ElapsedTime 2795ms.
-- The plan XML's <MissingIndexes> block already recommends the exact
-- index built in 03-add-index-and-verify.sql.
