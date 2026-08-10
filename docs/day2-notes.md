# Day 2 Notes — Performance Tuning, Resource Governor, SSRS

Real notes from actually building this. Same approach as Day 1: unpolished,
true, includes what broke and how it got fixed.

## Environment

Day 2 uses a single standalone VM (`SQL01`, no domain, no cluster) since
Extended Events, Query Store, Resource Governor, SSRS, SSIS, and native
backup/restore don't require Always-On infrastructure. SQL Server
authentication (`sa`) is used instead of Windows authentication, since there's
no domain in this environment.

- Azure resource group `dba-lab-rg`, region `westus2`
- 1x Windows Server 2022 VM: `SQL01` (`Standard_E2bds_v5`)
- SQL Server 2022 Developer Edition
- Test database: `DBALAB_PerfLab`
- Test table: `dbo.OrdersData` (~6.9M rows)

## Issue log, in the order actually hit

### 1. Named Pipes connection failure after VM deallocate/restart
After stopping and restarting `SQL01` (to save cost between sessions),
connecting via SSMS to `localhost` failed with:
```
Named Pipes Provider, error: 40 - Could not open a connection to SQL Server
```
and separately:
```
Error 64: The specified network name is no longer available
```
`Get-Service MSSQLSERVER` showed the service running, so the instance itself
was healthy. Root cause, found in two parts:
- **SQL Server Browser was stopped** and not set to auto-start — it wasn't
  restarted along with the deallocate/start cycle the way `MSSQLSERVER` was.
- **Named Pipes protocol was disabled** in SQL Server Configuration Manager
  (TCP/IP only was enabled) — so any connection attempt that defaulted to
  trying Named Pipes first would always fail outright, independent of the
  Browser issue.

Immediate workaround: force the connection over TCP explicitly in SSMS's
Server Name field (`tcp:127.0.0.1,1433`), bypassing Named Pipes entirely.
Actual fix: started and set `SQLBrowser` to auto-start (`Set-Service
SQLBrowser -StartupType Automatic`). Left Named Pipes disabled deliberately —
TCP/IP-only is a reasonable, arguably more production-realistic
configuration, and nothing in this lab needs Named Pipes specifically.

### 2. Test table accidentally created in `master`
The original `CREATE TABLE dbo.OrdersData` ran without an explicit `USE`
statement first, landing the ~6.9M-row table in the `master` system database.
This wasn't caught until trying to enable Query Store:
```
Msg 12438: Cannot perform action because Query Store cannot be enabled
on system database master.
```
Query Store cannot be enabled on `master` at all — SQL Server blocks it
outright. Fixed by creating a proper user database (`DBALAB_PerfLab`),
copying the data over, dropping the original table from `master`, then
enabling Query Store on the correct database. Lesson: always confirm the
active database context before creating test objects — `SELECT DB_NAME()`
first, or start every script with an explicit `USE`.

### 3. Missing-index recommendation matched the optimizer's own suggestion
Not an issue so much as a useful confirmation: the execution plan XML for the
baseline slow query included a `<MissingIndexes>` block recommending exactly
the composite index that was then created —
`(Region, Status) INCLUDE (OrderID, OrderDate, OrderType, Notes)`. Worth
knowing SQL Server surfaces this directly in the plan XML (and in
`sys.dm_db_missing_index_details`) rather than needing to guess at index
design from first principles.

### 4. Resource Governor classifier silently misclassified all SSRS traffic
Built the resource pool, workload group, and classifier function correctly
(verified via `sys.dm_resource_governor_resource_pools` immediately after
creation — pool existed with the right CPU/memory caps). Classifier logic:
```sql
IF APP_NAME() LIKE '%SSRS%' RETURN 'ReportingGroup';
```
After deploying and running a real report through SSRS, checked actual
session classification:
```sql
SELECT s.session_id, s.program_name, g.name AS workload_group
FROM sys.dm_exec_sessions s
JOIN sys.dm_resource_governor_workload_groups g ON s.group_id = g.group_id
WHERE s.program_name LIKE '%Report%';
```
Every SSRS session showed `workload_group = default`, not `ReportingGroup`.
Root cause: SSRS identifies itself via `program_name = 'Report Server'`, not
`'SSRS'` — the classifier's `LIKE '%SSRS%'` never matched anything real.

Fix required two steps, because SQL Server won't let you `ALTER` a function
while it's actively assigned as the classifier:
```sql
-- 1. Detach first
ALTER RESOURCE GOVERNOR WITH (CLASSIFIER_FUNCTION = NULL);
ALTER RESOURCE GOVERNOR RECONFIGURE;

-- 2. Now the ALTER succeeds
ALTER FUNCTION dbo.ClassifierFn() RETURNS SYSNAME WITH SCHEMABINDING AS
BEGIN
  IF APP_NAME() LIKE '%Report Server%' RETURN 'ReportingGroup';
  RETURN 'default';
END;

-- 3. Reattach
ALTER RESOURCE GOVERNOR WITH (CLASSIFIER_FUNCTION = dbo.ClassifierFn);
ALTER RESOURCE GOVERNOR RECONFIGURE;
```
Resource Governor only classifies a session at connection time, so existing
SSRS sessions didn't retroactively move groups — restarting the SSRS service
(`Restart-Service SQLServerReportingServices`) forced new connections, which
then correctly classified into `ReportingGroup`. Verified via the same query
above, and confirmed the pool was actually constraining real work by checking
`total_cpu_usage_ms` on the pool (nonzero, and increasing with report
activity).

Lesson: a classifier function with no syntax errors and no runtime errors
can still be functionally wrong — it will silently misclassify every session
into `default` with no warning anywhere. Verifying actual session
classification against real traffic, not just checking that the pool/function
exist, is a necessary separate step.

### 5. SSRS caches dataset results, which initially looked like Resource Governor wasn't doing anything
After fixing the classifier, tried to isolate the CPU/duration cost of a
single report execution using Extended Events filtered to
`client_app_name = 'Report Server'`. Captured several minutes of continuous
traffic at a steady ~10-second interval across multiple sessions, but every
individual event showed sub-millisecond duration — nothing close to the
~1500ms the same query took when run directly in SSMS.

This was initially confusing (raised the question: is Resource Governor
actually doing anything, if the pool shows CPU usage but no single query
looks expensive?). Conclusion after review: the ~10-second-interval traffic
was SSRS's own background session/keepalive polling, not re-executions of the
report's dataset query — SSRS caches report data by default, so repeated
browser refreshes within the cache window don't re-query the database at
all. The nonzero cumulative CPU on the pool from earlier was real (confirmed
separately), but per-execution timing for a specific fresh report run wasn't
cleanly isolated in this session — doing so would require explicitly
invalidating or disabling the report's cache first.

Documented here as a real, worth-remembering distinction: cumulative
resource-pool counters and correct session classification are not the same
thing as being able to isolate a single fresh query execution — caching
layers upstream of the database (here, SSRS's own dataset cache) can make
the two look inconsistent with each other even when both are actually
correct.

## What actually worked, end to end

- Baseline: `SELECT * FROM dbo.OrdersData WHERE Region = 'RGN-12' AND
  Status = 'Open'` against a 6.9M-row heap — Table Scan, ~2313ms
  (Extended Events), ~230K logical reads, `<MissingIndexes>` hint present
  in the plan.
- After `CREATE NONCLUSTERED INDEX IX_OrdersData_Region_Status ON
  dbo.OrdersData (Region, Status) INCLUDE (OrderID, OrderDate, OrderType,
  Notes)`: Index Seek, plan cost dropped from 180.016 to 4.32257 (~97.6%
  reduction), logical reads dropped to 5,614, CPU time 156ms (server-side
  elapsed time 1505ms — see note below on decomposing that gap).
- Plan forced via `sp_query_store_force_plan` against the known-good
  plan_id, confirmed via `is_forced_plan = 1`.
- Resource Governor pool (`ReportingPool`, 30% CPU / 20% memory cap) and
  workload group (`ReportingGroup`) built, classifier fixed after the
  `program_name` mismatch above, verified against real SSRS session traffic.
- SSRS installed, configured (Report Server database + Web Service + Web
  Portal URLs), a real report (`OpenOrdersByRegion`) built in Report
  Builder and deployed to `http://sql01/ReportServer`, confirmed rendering
  live data at `http://sql01/reports/browse/`.

## Note on decomposing "elapsed time" for the post-index query

`SET STATISTICS TIME ON` showed CPU time = 156ms but server-side elapsed
time = 1505ms, with `physical reads = 0` (everything served from buffer
cache, so the gap isn't disk I/O). The likely explanation is
`ASYNC_NETWORK_IO` — SQL Server waiting on the client to receive/acknowledge
a genuinely large result set (173,107 matching rows). This is a useful
distinction to be able to make: an index fixes a bad access-path problem
(scan vs. seek), but it does not make transmitting a large result set to the
client instantaneous — those are two separate costs, and conflating them
would lead to an incorrect read of "the index didn't really help."

### 6. SSIS package: retry-wrapped loop did not actually retry on failure
Built a package (`scripts/ssis/day2/Package.dtsx`) with an Execute SQL Task
(truncate staging) feeding a For Loop Container wrapping a Data Flow Task
(OLE DB Source -> Derived Column -> OLE DB Destination), plus an OnError
event handler logging to `staging.SSIS_ErrorLog`.

First failure encountered was a validation-time error (renamed the
destination table to simulate an outage) — this never reached the retry
loop or error handler at all, since SSIS validates object existence before
execution begins. Switched to a genuine runtime failure instead: added a
temporary CHECK constraint (`Region <> 'RGN-12'`) that some source rows
violate, forcing a mid-execution failure.

Result: the package failed after a single attempt, not three. Root cause,
found via the detailed Output log:
- `MaximumErrorCount` on the Data Flow Task was set to 1, not the intended 3.
- More fundamentally, wrapping a task in a `For Loop Container` does not by
  itself implement retry-on-failure — it only controls how many times the
  loop iterates. A task failure inside a container propagates upward and
  stops the container immediately by default; actually retrying requires
  explicitly telling the failed task not to propagate its failure (e.g.
  `FailParentOnFailure = False`) combined with loop logic that continues on
  failure rather than exiting.

The OnError handler itself worked correctly once properly configured
(Parameter Mapping tab, mapping `System::ErrorDescription` and
`System::SourceName` to the logging Execute SQL Task's parameters) — it
captured three real, distinct error events per failed run, showing the
actual cascade: the SQL Server CHECK constraint violation, then two layers
of SSIS pipeline error propagation reacting to it.

Lesson: a container that visually looks like retry logic (a loop wrapped
around a task, with a MaximumErrorCount property set) is not automatically
retry-on-failure logic. The two need to be explicitly connected, and the
only way this gap was caught was by forcing a real failure and reading the
actual execution log rather than assuming a successful design-time build
meant the intended behavior was in place.

### 7. Backup/restore to Azure Blob Storage: two provider/syntax gotchas
Storage account creation initially failed with:
```
(SubscriptionNotFound) Subscription <id> was not found.
```
despite `az account show` and `az group list` both confirming the
subscription and resource group were valid and accessible. Root cause:
`Microsoft.Storage` was not a registered resource provider on this
subscription — brand-new subscriptions only have a small default set of
providers registered, and Azure's error message for "provider not
registered" can surface as this same misleading "SubscriptionNotFound" text
rather than a clearer message. Fixed with:
```bash
az provider register --namespace Microsoft.Storage
# wait for: az provider show --namespace Microsoft.Storage --query registrationState -o tsv
# to return "Registered" before retrying
```

Separately, the initial `RESTORE DATABASE ... WITH CREDENTIAL = '<url>', ...`
failed with:
```
Msg 3225: Use of WITH CREDENTIAL syntax is not valid for credentials
containing a Shared Access Signature.
```
`WITH CREDENTIAL` in a `RESTORE` statement is only valid for the older
Storage Account Key credential type. For a SAS-based credential (created via
`CREATE CREDENTIAL ... WITH IDENTITY = 'SHARED ACCESS SIGNATURE'`), SQL
Server resolves the correct credential automatically by matching the blob
URL against `sys.credentials` — the clause must be omitted entirely, not
just referenced differently.

Also hit an Azure CLI MFA/token-expiry issue mid-session (same class of
issue as Day 0/2's earlier `AADSTS50076` errors) — resolved the same way,
via `az logout` then `az login --tenant <tenant-id> --scope
https://management.core.windows.net//.default`.

## What actually worked, end to end

Backup: 441,034 pages (~3.4GB) written directly to Azure Blob Storage via
`BACKUP DATABASE ... TO URL`, no local disk involved, 20.7 seconds at 166.6
MB/sec with COMPRESSION and CHECKSUM. Restore into a differently-named
database (`DBALAB_PerfLab_Restored`), verified by an exact row-count match
against the original (6,922,161 on both) — the actual proof a restore drill
needs, not just a completion message.
