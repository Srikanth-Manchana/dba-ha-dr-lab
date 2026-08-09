-- scripts/sql/tsql/day2/02-extended-events-capture.sql
--
-- Captures slow queries (>1 second) with full SQL text, without the
-- overhead of legacy SQL Profiler.

USE DBALAB_PerfLab;
GO

CREATE EVENT SESSION [DBALAB_SlowQueries] ON SERVER
ADD EVENT sqlserver.sql_statement_completed(
  ACTION (sqlserver.sql_text, sqlserver.query_hash)
  WHERE duration > 1000000) -- >1 sec, in microseconds
ADD TARGET package0.event_file(SET filename=N'DBALAB_SlowQueries.xel')
WITH (MAX_MEMORY=4096 KB, EVENT_RETENTION_MODE=ALLOW_SINGLE_EVENT_LOSS);

ALTER EVENT SESSION [DBALAB_SlowQueries] ON SERVER STATE = START;

-- Re-run the baseline slow query so the session captures it:
-- SELECT * FROM dbo.OrdersData WHERE Region = 'RGN-12' AND Status = 'Open';

-- Read back what was captured:
SELECT event_data.value('(event/@timestamp)[1]', 'datetime2') AS ts,
       event_data.value('(event/data[@name="duration"]/value)[1]', 'bigint')/1000 AS duration_ms,
       event_data.value('(event/action[@name="sql_text"]/value)[1]', 'nvarchar(max)') AS sql_text
FROM (SELECT CAST(event_data AS XML) AS event_data
      FROM sys.fn_xe_file_target_read_file('DBALAB_SlowQueries*.xel', NULL, NULL, NULL)) AS tab;
-- Observed: 2313ms for the baseline query, matching the execution plan's
-- reported elapsed time closely.

-- Cleanup when done with this session:
-- ALTER EVENT SESSION [DBALAB_SlowQueries] ON SERVER STATE = STOP;
-- DROP EVENT SESSION [DBALAB_SlowQueries] ON SERVER;
