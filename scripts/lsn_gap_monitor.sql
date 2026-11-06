-- =============================================================================
-- CDC Freshness Alarm — SQL Server CDC / Always On Availability Group
-- SIGMOD 2027 artifact: temporal-compliance-arch
-- Author: Syam Sajit Dondapati
-- =============================================================================
-- Purpose:
--   Measure the age of the latest captured change per capture instance.
--   This is a freshness signal, not proof of an LSN gap: an idle source
--   table can also have an old latest-change timestamp.
--
-- Deployment:
--   Run this full file once in SSMS or sqlcmd to create the alert table.
--   For SQL Server Agent, use the monitoring batch after the second GO,
--   schedule it every 5 minutes, and run it on the primary replica only.
--   Use an AG listener IP check or sys.dm_hadr_availability_replica_states
--   to skip execution on secondary replicas.
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

IF OBJECT_ID('compliance.CdcFreshnessAlert', 'U') IS NULL
BEGIN
    CREATE TABLE compliance.CdcFreshnessAlert (
        AlertID                INT          IDENTITY PRIMARY KEY,
        CaptureInstance        SYSNAME      NOT NULL,
        LastCapturedLSN        BINARY(10),
        SecondsSinceLastChange INT,
        DetectedAt             DATETIME2    NOT NULL DEFAULT SYSUTCDATETIME(),
        Acknowledged           BIT          NOT NULL DEFAULT 0,
        AcknowledgedBy         SYSNAME      NULL,
        AcknowledgedAt         DATETIME2    NULL,
        RemediationNote        NVARCHAR(500) NULL
    );
END;
GO

DECLARE @AlertThresholdSeconds INT = 300;   -- 5-minute freshness threshold

-- -----------------------------------------------------------------------
-- Step 1: Check whether this instance is the current AG primary.
--         Skip the job on secondary replicas to avoid false positives.
-- -----------------------------------------------------------------------
IF EXISTS (
    SELECT 1
    FROM sys.dm_hadr_availability_replica_states r
    JOIN sys.availability_groups ag ON ag.group_id = r.group_id
    WHERE r.is_local = 1
      AND r.role_desc = 'SECONDARY'
)
BEGIN
    RAISERROR('Running on secondary replica — CDC freshness alarm skipped.', 0, 1) WITH NOWAIT;
    RETURN;
END;

-- -----------------------------------------------------------------------
-- Step 2: Enumerate CDC capture instances and measure change age.
-- -----------------------------------------------------------------------
DECLARE @CaptureInstance SYSNAME;
DECLARE @SQL             NVARCHAR(2000);
DECLARE @ChangeTable     NVARCHAR(258);

DECLARE capture_cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT capture_instance
    FROM   cdc.change_tables
    ;

OPEN capture_cur;
FETCH NEXT FROM capture_cur INTO @CaptureInstance;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @ChangeTable = QUOTENAME(@CaptureInstance + N'_CT');
    SET @SQL = N'
        DECLARE @LastCapturedLSN BINARY(10);
        DECLARE @LastChangeTime DATETIME2;
        SELECT @LastCapturedLSN = MAX(__$start_lsn)
        FROM cdc.' + @ChangeTable + N';
        SET @LastChangeTime = sys.fn_cdc_map_lsn_to_time(@LastCapturedLSN);

        IF @LastChangeTime IS NOT NULL
           AND DATEDIFF(SECOND, @LastChangeTime, SYSUTCDATETIME()) > @Threshold
        BEGIN
            INSERT INTO compliance.CdcFreshnessAlert
                (CaptureInstance, LastCapturedLSN,
                 SecondsSinceLastChange, DetectedAt)
            VALUES
                (@CaptureInstance, @LastCapturedLSN,
                 DATEDIFF(SECOND, @LastChangeTime, SYSUTCDATETIME()),
                 SYSUTCDATETIME());
        END;';

    EXEC sp_executesql @SQL,
        N'@CaptureInstance SYSNAME, @Threshold INT',
        @CaptureInstance = @CaptureInstance,
        @Threshold = @AlertThresholdSeconds;

    FETCH NEXT FROM capture_cur INTO @CaptureInstance;
END;

CLOSE capture_cur;
DEALLOCATE capture_cur;

-- -----------------------------------------------------------------------
-- Step 3: If any alerts were written, send an operator notification.
-- -----------------------------------------------------------------------
IF EXISTS (
    SELECT 1 FROM compliance.CdcFreshnessAlert
    WHERE  DetectedAt >= DATEADD(MINUTE, -6, SYSUTCDATETIME())
      AND  Acknowledged = 0
)
BEGIN
    EXEC msdb.dbo.sp_notify_operator
        @profile_name = N'DBA Alerts',
        @name         = N'DBA On-Call',
        @subject      = N'ALERT: CDC Change Freshness Threshold Exceeded',
        @body         = N'One or more capture instances have no recent captured changes.
    This is a freshness signal, not proof of an LSN gap; the source may be idle.
    Review compliance.CdcFreshnessAlert and reconcile before regulatory filing.';
END;
GO

SET NOEXEC OFF;
GO
