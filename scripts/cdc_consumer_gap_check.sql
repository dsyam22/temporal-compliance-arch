-- =============================================================================
-- CDC Consumer Gap Check — detects changes a downstream consumer can no
-- longer read because CDC cleanup removed them first.
-- SIGMOD 2027 artifact: temporal-compliance-arch
-- Author: Syam Sajit Dondapati
-- =============================================================================
-- Purpose:
--   The freshness alarm (lsn_gap_monitor.sql) only says "nothing new has
--   been captured recently". This check answers a different question that
--   CAN be decided from metadata: has the incremental staging consumer
--   fallen behind the CDC retention window?
--
--   A consumer records the last LSN it processed per capture instance.
--   If the next LSN it needs is older than sys.fn_cdc_get_min_lsn(), the
--   cleanup job may have deleted change rows the consumer never read
--   (the same condition under which cdc.fn_cdc_get_all_changes_* refuses
--   the requested range).
--   Those changes are unrecoverable from the change table; the consumer
--   must do a full refresh from the source (or temporal history).
--
--   This check does NOT detect changes that were never captured at all.
--   Only reconciliation against the source can show that.
--
-- Status: provided as an artifact. Whether it runs in the production
-- deployment described in the paper must be stated there explicitly.
-- =============================================================================

-- Test database (see README). Change the name here to run in another database.
USE AsOfBench;
GO

SET NOEXEC OFF;
GO
-- Refuse to run in a system database (SSMS opens new windows in master).
DECLARE @db SYSNAME = DB_NAME();
IF @db IN ('master', 'model', 'msdb', 'tempdb')
BEGIN
    RAISERROR('This script must run in a user database, not %s. Select your database first (e.g. USE AsOfBench;) and run it again.', 16, 1, @db);
    SET NOEXEC ON;   -- skip every remaining batch in this script
END;
GO

SET NOCOUNT ON;

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'compliance')
    EXEC sp_executesql N'CREATE SCHEMA compliance';
GO

-- Watermark written by the incremental staging job after each successful run.
IF OBJECT_ID('compliance.CdcConsumerWatermark', 'U') IS NULL
BEGIN
    CREATE TABLE compliance.CdcConsumerWatermark (
        ConsumerName     SYSNAME    NOT NULL,
        CaptureInstance  SYSNAME    NOT NULL,
        LastProcessedLSN BINARY(10) NOT NULL,
        UpdatedAt        DATETIME2  NOT NULL DEFAULT SYSUTCDATETIME(),
        CONSTRAINT PK_CdcConsumerWatermark PRIMARY KEY (ConsumerName, CaptureInstance)
    );
END;
GO

-- Returns one row per consumer/capture instance that has fallen out of the
-- retention window. An empty result means no consumer-side gap.
SELECT
    w.ConsumerName,
    w.CaptureInstance,
    w.LastProcessedLSN,
    sys.fn_cdc_get_min_lsn(w.CaptureInstance)                    AS MinAvailableLSN,
    sys.fn_cdc_map_lsn_to_time(w.LastProcessedLSN)               AS LastProcessedTime,
    sys.fn_cdc_map_lsn_to_time(sys.fn_cdc_get_min_lsn(w.CaptureInstance)) AS MinAvailableTime
FROM compliance.CdcConsumerWatermark AS w
-- Next LSN the consumer needs is older than the oldest LSN still retained.
WHERE sys.fn_cdc_increment_lsn(w.LastProcessedLSN) < sys.fn_cdc_get_min_lsn(w.CaptureInstance);
GO

SET NOEXEC OFF;
GO
