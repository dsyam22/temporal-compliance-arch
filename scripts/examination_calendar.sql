-- =============================================================================
-- reg.ExaminationCalendar — DDL and seed data
-- SIGMOD 2027 artifact: temporal-compliance-arch
-- Author: Syam Sajit Dondapati
-- =============================================================================
-- Purpose:
--   This table is the "third calendar" in the three-calendar model.
--   It records the date on which each regulatory framework's examination
--   clock is frozen for a given reporting period — the ExaminationDate.
--
--   T_e (examination time): the business date a regulator names as the
--   as-of date for a reporting period (ExaminationDate, a DATE).
--   This is distinct from:
--     T_t (transaction time): when the fact was recorded in the database.
--     T_v (valid time):       the business date the fact describes.
--
-- Time semantics (one rule, used everywhere):
--   * Valid time is DATE-granular. A position row with ValidDate = d is the
--     end-of-day (market-close) position for business date d. No clock time
--     is attached to valid time.
--   * The regulatory snapshot is "rows with ValidDate = ExaminationDate, as
--     recorded in the database at the period's data cutoff". The data cutoff
--     is the last instant of RevisionCutoff in the reporting time zone
--     (America/New_York), stored in UTC as SnapshotCutoffUtc because SQL
--     Server records system time (SysStartTime/SysEndTime) in UTC.
--   * SnapshotCutoffUtc is computed once, when the period is locked, and is
--     immutable afterwards. Every filing query uses it for FOR SYSTEM_TIME AS OF.
--
-- The IsLocked flag prevents retroactive modification after examination.
-- =============================================================================

-- --------------------------------------------------------------------------
-- Schema
-- --------------------------------------------------------------------------
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

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'reg')
    EXEC sp_executesql N'CREATE SCHEMA reg';
GO

-- --------------------------------------------------------------------------
-- Table
-- --------------------------------------------------------------------------
IF OBJECT_ID('reg.ExaminationCalendar') IS NOT NULL
    DROP TABLE reg.ExaminationCalendar;
GO

CREATE TABLE reg.ExaminationCalendar (
    CalendarID         INT          IDENTITY(1,1)  PRIMARY KEY,
    FrameworkCode      VARCHAR(20)  NOT NULL,      -- e.g. 'NAIC_RBC', 'EIOPA_SII'
    PeriodLabel        VARCHAR(40)  NOT NULL,      -- e.g. '2026-Q4', '2026-FY'
    ExaminationDate    DATE         NOT NULL,      -- T_e: as-of date for queries
    SubmissionDeadline DATE         NOT NULL,      -- regulatory filing deadline
    RevisionCutoff     DATE         NOT NULL,      -- last business day for corrections (ET)
    SnapshotCutoffUtc  DATETIME2(7) NULL,          -- T_t anchor; set at lock (see header)
    IsLocked           BIT          NOT NULL DEFAULT 0,
    CreatedAt          DATETIME2    NOT NULL DEFAULT SYSUTCDATETIME(),
    LockedAt           DATETIME2    NULL,
    LockedBy           SYSNAME      NULL,

    CONSTRAINT UQ_Framework_Period
        UNIQUE (FrameworkCode, PeriodLabel),

    CONSTRAINT CK_ExamBeforeDeadline
        CHECK (ExaminationDate <= SubmissionDeadline),

    CONSTRAINT CK_RevisionBeforeDeadline
        CHECK (RevisionCutoff <= SubmissionDeadline),

    CONSTRAINT CK_ExamBeforeRevision
        CHECK (ExaminationDate <= RevisionCutoff),

    CONSTRAINT CK_LockedHasCutoff
        CHECK (IsLocked = 0 OR SnapshotCutoffUtc IS NOT NULL),

    INDEX IX_Framework_Period (FrameworkCode, ExaminationDate)
);
GO

-- Locked rows cannot be edited or deleted; the lock procedure permits the
-- one-way transition from IsLocked = 0 to IsLocked = 1.
CREATE OR ALTER TRIGGER reg.TR_ExaminationCalendar_ImmutableWhenLocked
ON reg.ExaminationCalendar
AFTER UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;

    IF EXISTS (SELECT 1 FROM deleted WHERE IsLocked = 1)
        THROW 50001, 'Locked examination calendar rows are immutable.', 1;
END;
GO

-- --------------------------------------------------------------------------
-- Lock procedure
-- Freezes the calendar row and records the transaction-time cutoff.
-- Can run only after the data cutoff has passed, so the frozen snapshot can
-- no longer change. Called by an Agent job after each RevisionCutoff.
-- --------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE reg.LockExaminationPeriod
    @FrameworkCode  VARCHAR(20),
    @PeriodLabel    VARCHAR(40),
    @ReportingTimeZone SYSNAME = N'Eastern Standard Time'  -- Windows TZ name; DST-aware
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @RevisionCutoff DATE;
    SELECT @RevisionCutoff = RevisionCutoff
    FROM   reg.ExaminationCalendar
    WHERE  FrameworkCode = @FrameworkCode
      AND  PeriodLabel   = @PeriodLabel
      AND  IsLocked      = 0;

    IF @RevisionCutoff IS NULL
    BEGIN
        RAISERROR('Period not found or already locked: %s / %s', 16, 1,
                  @FrameworkCode, @PeriodLabel);
        RETURN;
    END;

    -- Last instant of RevisionCutoff in the reporting time zone, in UTC.
    -- (Start of the next local day, minus one DATETIME2(7) tick.)
    DECLARE @CutoffUtc DATETIME2(7) =
        DATEADD(NANOSECOND, -100,
            CAST(
                (CAST(DATEADD(DAY, 1, @RevisionCutoff) AS DATETIME2(7))
                    AT TIME ZONE @ReportingTimeZone)
                AT TIME ZONE 'UTC'
            AS DATETIME2(7)));

    IF SYSUTCDATETIME() <= @CutoffUtc
    BEGIN
        RAISERROR('Data cutoff for %s / %s has not passed yet; cannot lock.', 16, 1,
                  @FrameworkCode, @PeriodLabel);
        RETURN;
    END;

    UPDATE reg.ExaminationCalendar
    SET    IsLocked          = 1,
           SnapshotCutoffUtc = @CutoffUtc,
           LockedAt          = SYSUTCDATETIME(),
           LockedBy          = SYSTEM_USER
    WHERE  FrameworkCode = @FrameworkCode
      AND  PeriodLabel   = @PeriodLabel
      AND  IsLocked      = 0;

    PRINT 'Locked: ' + @FrameworkCode + ' / ' + @PeriodLabel
        + ' at cutoff ' + CONVERT(VARCHAR(30), @CutoffUtc, 126) + ' UTC';
END;
GO

-- --------------------------------------------------------------------------
-- Seed data — 7 regulatory frameworks, representative periods
-- Matches Table 1 in the SIGMOD paper.
-- --------------------------------------------------------------------------
INSERT INTO reg.ExaminationCalendar
    (FrameworkCode, PeriodLabel, ExaminationDate, SubmissionDeadline, RevisionCutoff)
VALUES
-- EIOPA — Solvency II QRT
('EIOPA_SII',    '2025-FY',    '2025-12-31', '2026-05-20', '2026-05-13'),
('EIOPA_SII',    '2026-QRT1',  '2026-03-31', '2026-07-05', '2026-06-28'),

-- Bank of England — PRA Solvency II
('PRA_SII',      '2025-FY',    '2025-12-31', '2026-06-30', '2026-06-23'),

-- NAIC — Risk-Based Capital
('NAIC_RBC',     '2025-FY',    '2025-12-31', '2026-03-01', '2026-02-22'),
('NAIC_RBC',     '2026-FY',    '2026-12-31', '2027-03-01', '2027-02-22'),

-- SEC — Form 10-K
('SEC_10K',      '2025-FY',    '2025-12-31', '2026-03-02', '2026-02-23'),
('SEC_10K',      '2026-FY',    '2026-12-31', '2027-03-02', '2027-02-23'),

-- SEC — Form 10-Q
('SEC_10Q',      '2026-Q1',    '2026-03-31', '2026-05-11', '2026-05-04'),
('SEC_10Q',      '2026-Q2',    '2026-06-30', '2026-08-10', '2026-08-03'),
('SEC_10Q',      '2026-Q3',    '2026-09-30', '2026-11-09', '2026-11-02'),

-- FSB — G-SII Data Collection
('FSB_GSII',     '2025-REF',   '2025-12-31', '2026-06-30', '2026-06-23'),

-- IAIS — ComFrame / ICS
('IAIS_ICS',     '2025-FY',    '2025-12-31', '2026-07-31', '2026-07-24');
GO

-- --------------------------------------------------------------------------
-- View: currently open (unlocked) periods approaching examination
-- --------------------------------------------------------------------------
CREATE OR ALTER VIEW reg.UpcomingExaminations AS
SELECT
    CalendarID,
    FrameworkCode,
    PeriodLabel,
    ExaminationDate,
    SubmissionDeadline,
    RevisionCutoff,
    SnapshotCutoffUtc,
    DATEDIFF(DAY, CAST(SYSUTCDATETIME() AS DATE), ExaminationDate) AS DaysToExam,
    DATEDIFF(DAY, CAST(SYSUTCDATETIME() AS DATE), SubmissionDeadline) AS DaysToDeadline
FROM reg.ExaminationCalendar
WHERE IsLocked = 0
  AND ExaminationDate >= DATEADD(DAY, -7, CAST(SYSUTCDATETIME() AS DATE))
  AND ExaminationDate <= DATEADD(MONTH, 6, CAST(SYSUTCDATETIME() AS DATE));
GO

SET NOEXEC OFF;
GO
