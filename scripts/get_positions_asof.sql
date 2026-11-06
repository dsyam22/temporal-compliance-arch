-- =============================================================================
-- reg.GetPositionsAsOf — as-of-date position query via ExaminationCalendar
-- SIGMOD 2027 artifact: temporal-compliance-arch
-- Author: Syam Sajit Dondapati
-- =============================================================================
-- Purpose:
--   Returns the regulatory snapshot for a period: positions whose valid
--   date (business date, end of day) equals the examination date T_e, as
--   recorded in the database at the period's locked data cutoff
--   (SnapshotCutoffUtc, UTC). See examination_calendar.sql for the rule.
--
--   Two distinct anchors are used and never mixed:
--     valid time:       p.ValidDate = ExaminationDate          (DATE)
--     transaction time: FOR SYSTEM_TIME AS OF SnapshotCutoffUtc (UTC instant)
--   Casting the DATE to DATETIME2 (midnight UTC at the start of T_e) would
--   be wrong: end-of-day rows for T_e are loaded after market close, so a
--   midnight snapshot would exclude them.
--
--   The procedure enforces that only locked periods may be queried,
--   preventing accidental use of a mutable examination date during live
--   filing runs.
--
-- Usage:
--   EXEC reg.GetPositionsAsOf @FrameworkCode = 'NAIC_RBC', @PeriodLabel = '2026-FY';
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

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'compliance')
    EXEC sp_executesql N'CREATE SCHEMA compliance';
GO

IF OBJECT_ID('compliance.ExaminationQueryLog', 'U') IS NULL
BEGIN
    CREATE TABLE compliance.ExaminationQueryLog (
        LogID         INT       IDENTITY PRIMARY KEY,
        CalendarID    INT       NOT NULL,
        FrameworkCode VARCHAR(20),
        PeriodLabel   VARCHAR(40),
        AsOfDate      DATE,
        SnapshotUtc   DATETIME2(7),
        IsPreview     BIT       NOT NULL DEFAULT 0,
        QueriedBy     SYSNAME   NOT NULL,
        QueriedAt     DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
        RowsReturned  INT       NULL
    );
END;
GO

CREATE OR ALTER PROCEDURE reg.GetPositionsAsOf
    @FrameworkCode  VARCHAR(20),
    @PeriodLabel    VARCHAR(40),
    @AllowUnlocked  BIT = 0    -- 1 = preview of an open period "as currently
                               -- recorded" (snapshot = now). Not filing-grade.
AS
BEGIN
    SET NOCOUNT ON;

    -- ------------------------------------------------------------------
    -- 1. Resolve examination date from calendar
    -- ------------------------------------------------------------------
    DECLARE @AsOfDate    DATE;
    DECLARE @SnapshotUtc DATETIME2(7);
    DECLARE @IsLocked    BIT;
    DECLARE @CalendarID  INT;

    SELECT
        @CalendarID  = CalendarID,
        @AsOfDate    = ExaminationDate,
        @SnapshotUtc = SnapshotCutoffUtc,
        @IsLocked    = IsLocked
    FROM reg.ExaminationCalendar
    WHERE FrameworkCode = @FrameworkCode
      AND PeriodLabel   = @PeriodLabel;

    IF @AsOfDate IS NULL
    BEGIN
        RAISERROR(
            'No calendar entry found for framework "%s", period "%s".',
            16, 1, @FrameworkCode, @PeriodLabel
        );
        RETURN;
    END;

    -- Enforce lock unless caller explicitly allows unlocked (dev only)
    IF @IsLocked = 0 AND @AllowUnlocked = 0
    BEGIN
        RAISERROR(
            'Period "%s / %s" is not locked. Lock it via reg.LockExaminationPeriod before running production queries.',
            16, 1, @FrameworkCode, @PeriodLabel
        );
        RETURN;
    END;

    -- Open period, preview only: snapshot as currently recorded.
    IF @IsLocked = 0
        SET @SnapshotUtc = SYSUTCDATETIME();

    -- ------------------------------------------------------------------
    -- 2. Log query for audit trail
    -- ------------------------------------------------------------------
    INSERT INTO compliance.ExaminationQueryLog
        (CalendarID, FrameworkCode, PeriodLabel, AsOfDate, SnapshotUtc,
         IsPreview, QueriedBy, QueriedAt)
    VALUES
        (@CalendarID, @FrameworkCode, @PeriodLabel, @AsOfDate, @SnapshotUtc,
         CASE WHEN @IsLocked = 0 THEN 1 ELSE 0 END,
         SYSTEM_USER, SYSUTCDATETIME());

    -- ------------------------------------------------------------------
    -- 3. AS OF query against the temporal positions table
    --    risk.Positions is a system-versioned temporal table.
    --    AS OF uses the transaction-time cutoff (UTC instant).
    --    The ValidDate filter selects the business date (T_v = T_e).
    -- ------------------------------------------------------------------
    SELECT
        p.PositionID,
        p.EntityID,
        p.SecurityID,
        p.AssetClass,
        p.Quantity,
        p.MarketValue,
        p.Currency,
        p.ValidDate,
        p.SysStartTime,
        p.SysEndTime,
        @FrameworkCode  AS FrameworkCode,
        @PeriodLabel    AS PeriodLabel,
        @AsOfDate       AS ExaminationDate,
        @SnapshotUtc    AS SnapshotUtc
    FROM risk.Positions
         FOR SYSTEM_TIME AS OF @SnapshotUtc  -- T_t: locked data cutoff (UTC)
    AS p
    WHERE p.ValidDate = @AsOfDate;           -- T_v: business date = T_e

END;
GO

-- =============================================================================
-- Example: temporal table DDL for risk.Positions (reference)
-- A system-versioned temporal table with a history table.
-- =============================================================================
/*
CREATE TABLE risk.Positions (
    PositionID   INT          IDENTITY PRIMARY KEY,
    EntityID     VARCHAR(20)  NOT NULL,
    SecurityID   VARCHAR(20)  NOT NULL,
    AssetClass   VARCHAR(20)  NOT NULL,
    Quantity     DECIMAL(18,4) NOT NULL,
    MarketValue  DECIMAL(18,2) NOT NULL,
    Currency     CHAR(3)      NOT NULL,
    ValidDate    DATE         NOT NULL,     -- T_v: business date (end-of-day position)
    SysStartTime DATETIME2    GENERATED ALWAYS AS ROW START NOT NULL,
    SysEndTime   DATETIME2    GENERATED ALWAYS AS ROW END   NOT NULL,
    PERIOD FOR SYSTEM_TIME (SysStartTime, SysEndTime)
)
WITH (SYSTEM_VERSIONING = ON (
    HISTORY_TABLE = risk.PositionsHistory,
    DATA_CONSISTENCY_CHECK = ON
));
*/

SET NOEXEC OFF;
GO
