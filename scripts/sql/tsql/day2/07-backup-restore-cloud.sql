-- scripts/sql/tsql/day2/07-backup-restore-cloud.sql
--
-- Native SQL Server backup directly to Azure Blob Storage (no local disk),
-- plus a restore drill verifying the backup is actually usable.
--
-- Prerequisites (run from the Mac terminal, not SQL Server):
--   az provider register --namespace Microsoft.Storage   (see note below —
--     required once per subscription; a brand-new subscription does not
--     have this registered by default)
--   az storage account create -g dba-lab-rg -n <name> --sku Standard_LRS --kind StorageV2 -l <region>
--   az storage container create --account-name <name> --name backups --auth-mode login
--   az storage account keys list ... / az storage container generate-sas ...
--     to produce a SAS token for the container

-- ============================================================
-- 1. Create the credential SQL Server uses to authenticate to blob storage
-- ============================================================
-- The credential NAME must exactly match the container URL (no trailing
-- slash). The SECRET is the SAS token exactly as generated, including its
-- URL-encoded characters (%3A, %3D, etc.) — do not decode it.
CREATE CREDENTIAL [https://dbalabbackup14080.blob.core.windows.net/backups]
WITH IDENTITY = 'SHARED ACCESS SIGNATURE',
SECRET = '<sas-token-here>';

SELECT name, credential_identity FROM sys.credentials;

-- ============================================================
-- 2. Back up directly to blob storage
-- ============================================================
BACKUP DATABASE DBALAB_PerfLab
TO URL = 'https://dbalabbackup14080.blob.core.windows.net/backups/DBALAB_PerfLab_full.bak'
WITH COMPRESSION, CHECKSUM, STATS = 10;
-- Observed: 441,034 pages (~3.4GB), 20.7 seconds, 166.6 MB/sec.

-- ============================================================
-- 3. Restore drill — into a differently-named database, proving the
-- backup is genuinely usable without touching the original.
-- ============================================================
-- Confirm the real data directory and logical file names first — do not
-- assume a path, check it:
SELECT name, physical_name FROM sys.master_files WHERE database_id = DB_ID('DBALAB_PerfLab');

-- IMPORTANT GOTCHA: for a SAS-based credential specifically, RESTORE does
-- NOT accept a WITH CREDENTIAL clause — that syntax is only valid for the
-- older Storage Account Key credential type. Including it produces:
--   Msg 3225: Use of WITH CREDENTIAL syntax is not valid for credentials
--   containing a Shared Access Signature.
-- SQL Server resolves the correct credential automatically by matching the
-- URL prefix against sys.credentials — no explicit reference needed.

RESTORE DATABASE DBALAB_PerfLab_Restored
FROM URL = 'https://dbalabbackup14080.blob.core.windows.net/backups/DBALAB_PerfLab_full.bak'
WITH MOVE 'DBALAB_PerfLab' TO 'C:\Program Files\Microsoft SQL Server\MSSQL16.MSSQLSERVER\MSSQL\DATA\DBALAB_PerfLab_Restored.mdf',
MOVE 'DBALAB_PerfLab_log' TO 'C:\Program Files\Microsoft SQL Server\MSSQL16.MSSQLSERVER\MSSQL\DATA\DBALAB_PerfLab_Restored_log.ldf',
STATS = 10;

-- ============================================================
-- 4. Verify — the actual proof, not just a "success" message
-- ============================================================
SELECT COUNT(*) FROM DBALAB_PerfLab.dbo.OrdersData;
SELECT COUNT(*) FROM DBALAB_PerfLab_Restored.dbo.OrdersData;
-- Observed: both returned 6,922,161 — identical, confirming the restore
-- produced a genuinely usable, complete copy.

-- ============================================================
-- 5. Cleanup
-- ============================================================
DROP DATABASE DBALAB_PerfLab_Restored;
