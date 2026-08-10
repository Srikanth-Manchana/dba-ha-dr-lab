-- scripts/sql/tsql/day2/06-ssis-staging-setup.sql
--
-- Supporting T-SQL for the DBALAB_ETL SSIS package (see scripts/ssis/day2/).
-- Creates the staging destination table and an error log table used by the
-- package's OnError event handler, plus the test procedure used to force a
-- genuine runtime failure and verify the error-handling behavior actually
-- built into the package.

USE DBALAB_PerfLab;
GO

CREATE SCHEMA staging;
GO

CREATE TABLE staging.OrdersData_Staging (
  OrderID INT, OrderDate DATETIME, Region VARCHAR(10),
  OrderType VARCHAR(50), Status VARCHAR(20), Notes VARCHAR(500)
);

-- Populated by the package's Event Handlers -> OnError -> Execute SQL Task,
-- via parameters mapped from System::ErrorDescription and System::SourceName.
CREATE TABLE staging.SSIS_ErrorLog (
  LogID INT IDENTITY PRIMARY KEY,
  LogTime DATETIME DEFAULT GETDATE(),
  ErrorDescription NVARCHAR(4000),
  SourceComponent NVARCHAR(200)
);

-- ============================================================
-- Forcing a genuine RUNTIME failure to test error handling
-- ============================================================
-- IMPORTANT: renaming or dropping the destination table produces a
-- VALIDATION-time failure (SSIS checks object existence before execution
-- starts), which never reaches the retry loop, MaximumErrorCount, or the
-- OnError handler at all. A CHECK constraint violation happens mid-execution
-- instead, which is what those mechanisms are actually designed to react to.

ALTER TABLE staging.OrdersData_Staging
ADD CONSTRAINT CK_ForceFailure CHECK (Region <> 'RGN-12');

-- Run the package (F5 in Visual Studio) here, then check what was captured:
SELECT * FROM staging.SSIS_ErrorLog ORDER BY LogTime DESC;
-- Observed: 3 rows per failed run, showing the actual cascade — the root
-- CHECK constraint violation from SQL Server, then two layers of SSIS
-- pipeline errors reacting to it (OLE DB Destination input failure, then
-- the Data Flow Task's own failure).

-- Remove the constraint once done testing, to allow a clean successful run:
ALTER TABLE staging.OrdersData_Staging DROP CONSTRAINT CK_ForceFailure;

-- Reset staging for a clean re-run (also done by the package's own
-- Execute SQL Task at the start of Control Flow, but useful standalone):
TRUNCATE TABLE staging.OrdersData_Staging;

-- ============================================================
-- Finding worth recording: what the constraint test actually revealed
-- ============================================================
-- The package's For Loop Container does NOT retry the Data Flow Task on
-- failure by default. Wrapping a task in a loop only means "run this task
-- N times" — it does not by itself mean "if this task fails, try it again."
-- A failed task inside a container propagates its failure upward and stops
-- the container immediately unless something explicitly tells the failed
-- task not to propagate (e.g. setting FailParentOnFailure = False on the
-- task, combined with loop logic that continues on failure rather than
-- exiting). MaximumErrorCount is a tolerance threshold ("how many errors
-- before I count myself as failed"), not a retry mechanism either — it was
-- also found set to 1 rather than the intended 3 during this exercise,
-- which was part of why only a single failed attempt occurred rather than
-- three. See docs/day2-notes.md for the full narrative.
