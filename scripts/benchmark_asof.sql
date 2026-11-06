-- =============================================================================
-- benchmark_asof.sql — reproduces Table 4 (overhead of as-of resolution)
-- SIGMOD 2027 artifact: temporal-compliance-arch
-- Author: Syam Sajit Dondapati
-- =============================================================================
-- RUN ON A TEST INSTANCE ONLY (e.g., SQL Server 2022 Developer Edition).
--
-- Order:
--   1. create_test_database.sql
--   2. examination_calendar.sql
--   3. get_positions_asof.sql
--   4. this file (takes a few minutes)
--   Each script switches to AsOfBench itself.
--
-- What it does:
--   * Builds a synthetic system-versioned risk.Positions table:
--       @Positions positions per business day x @Days business days.
--   * Applies @PreRounds correction rounds (5% of rows each) BEFORE the
--     data cutoff and @PostRounds rounds AFTER it, so the history table
--     holds both in-window and late corrections.
--   * Locks a calendar row with SnapshotCutoffUtc = the cutoff.
--   * Times three query types, direct vs. as-of, @Runs measured runs each
--     after 5 warm-up runs, and reports medians and row counts.
--   * Prints a correctness check (midnight cast vs. locked cutoff).
--
-- Send back the result grids printed at the end (sections A–D).
-- =============================================================================

SET NOEXEC OFF;
SET NOCOUNT ON;
GO

-- Test database (see README). Change the name here to run in another database.
USE AsOfBench;
GO

-- The two artifact scripts must have been run in AsOfBench first.
-- (If AsOfBench is missing, USE fails and this check stops the run in master.)
IF OBJECT_ID('reg.ExaminationCalendar', 'U') IS NULL
   OR OBJECT_ID('reg.GetPositionsAsOf', 'P') IS NULL
BEGIN
    RAISERROR('Run examination_calendar.sql and get_positions_asof.sql in AsOfBench first.', 16, 1);
    SET NOEXEC ON;
END;
GO

-- -----------------------------------------------------------------------------
-- 0. Schemas and the synthetic positions table
-- -----------------------------------------------------------------------------
IF SCHEMA_ID('risk')  IS NULL EXEC ('CREATE SCHEMA risk');
IF SCHEMA_ID('bench') IS NULL EXEC ('CREATE SCHEMA bench');
GO

IF OBJECT_ID('risk.Positions', 'U') IS NOT NULL
BEGIN
    ALTER TABLE risk.Positions SET (SYSTEM_VERSIONING = OFF);
    DROP TABLE risk.Positions;
END;
DROP TABLE IF EXISTS risk.PositionsHistory;
GO

CREATE TABLE risk.Positions (
    PositionID   BIGINT        IDENTITY(1,1) NOT NULL
                 CONSTRAINT PK_Positions PRIMARY KEY,
    ValidDate    DATE          NOT NULL,   -- T_v: business date (end of day)
    PositionKey  INT           NOT NULL,   -- business key within a day
    EntityID     VARCHAR(20)   NOT NULL,
    SecurityID   VARCHAR(20)   NOT NULL,
    AssetClass   VARCHAR(20)   NOT NULL,
    Quantity     DECIMAL(18,4) NOT NULL,
    MarketValue  DECIMAL(18,2) NOT NULL,
    Currency     CHAR(3)       NOT NULL,
    SysStartTime DATETIME2(7)  GENERATED ALWAYS AS ROW START NOT NULL,
    SysEndTime   DATETIME2(7)  GENERATED ALWAYS AS ROW END   NOT NULL,
    PERIOD FOR SYSTEM_TIME (SysStartTime, SysEndTime)
)
WITH (SYSTEM_VERSIONING = ON (HISTORY_TABLE = risk.PositionsHistory));
GO

CREATE UNIQUE INDEX UX_Positions_Date_Key
    ON risk.Positions (ValidDate, PositionKey) INCLUDE (AssetClass, MarketValue);
CREATE INDEX IX_PositionsHistory_Date_Key
    ON risk.PositionsHistory (ValidDate, PositionKey, SysEndTime, SysStartTime)
    INCLUDE (AssetClass, MarketValue);
GO

IF OBJECT_ID('bench.Config', 'U') IS NULL
    CREATE TABLE bench.Config (
        ConfigID    INT IDENTITY PRIMARY KEY,
        PeriodLabel VARCHAR(40)  NOT NULL,
        Te          DATE         NOT NULL,
        CutoffUtc   DATETIME2(7) NOT NULL,
        Positions   INT NOT NULL,
        Days        INT NOT NULL,
        PreRounds   INT NOT NULL,
        PostRounds  INT NOT NULL,
        LoadedAt    DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME()
    );
GO

-- -----------------------------------------------------------------------------
-- 1. Load synthetic data
-- -----------------------------------------------------------------------------
DECLARE @Positions  INT = 100000;   -- positions per business day
DECLARE @Days       INT = 20;       -- business days of history
DECLARE @PreRounds  INT = 3;        -- correction rounds before the cutoff
DECLARE @PostRounds INT = 2;        -- late correction rounds after the cutoff

-- Examination date = today (UTC), so the midnight-cast check is meaningful:
-- every row is inserted after 00:00 UTC today.
DECLARE @Te DATE = CAST(SYSUTCDATETIME() AS DATE);

WITH n AS (
    SELECT TOP (@Positions) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS k
    FROM sys.all_objects a CROSS JOIN sys.all_objects b
), d AS (
    SELECT TOP (@Days) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS dayoffset
    FROM sys.all_objects
)
INSERT INTO risk.Positions
    (ValidDate, PositionKey, EntityID, SecurityID, AssetClass,
     Quantity, MarketValue, Currency)
SELECT
    DATEADD(DAY, -d.dayoffset, @Te),
    CAST(n.k AS INT),
    CONCAT('E', n.k % 500),
    CONCAT('S', n.k),
    CHOOSE(CAST(n.k % 5 AS INT) + 1, 'EQUITY', 'CORP_BOND', 'GOVT_BOND', 'MBS', 'DERIV'),
    (n.k % 1000) + 1,
    ((n.k * 7919) % 1000000) / 100.0 + 100,
    'USD'
FROM n CROSS JOIN d;

-- In-window corrections (each round is its own transaction => own system time)
DECLARE @r INT = 1;
WHILE @r <= @PreRounds
BEGIN
    UPDATE risk.Positions SET MarketValue = MarketValue * 1.01
    WHERE PositionKey % 20 = @r;
    SET @r += 1;
END;

WAITFOR DELAY '00:00:01';
DECLARE @Cutoff DATETIME2(7) = SYSUTCDATETIME();
WAITFOR DELAY '00:00:01';

-- Late corrections (after the cutoff; must NOT appear in the filing)
WHILE @r <= @PreRounds + @PostRounds
BEGIN
    UPDATE risk.Positions SET MarketValue = MarketValue * 1.02
    WHERE PositionKey % 20 = @r;
    SET @r += 1;
END;

-- Calendar row for this run, locked at the cutoff.
-- (The artifact's lock procedure computes the cutoff from RevisionCutoff;
--  the benchmark sets it directly so the cutoff falls inside this run.)
DECLARE @Label VARCHAR(40) = CONCAT('BENCH-', CONVERT(VARCHAR(19), SYSUTCDATETIME(), 126));

INSERT INTO reg.ExaminationCalendar
    (FrameworkCode, PeriodLabel, ExaminationDate, SubmissionDeadline, RevisionCutoff)
VALUES ('BENCH', @Label, @Te, DATEADD(DAY, 30, @Te), @Te);

UPDATE reg.ExaminationCalendar
SET    IsLocked = 1, SnapshotCutoffUtc = @Cutoff,
       LockedAt = SYSUTCDATETIME(), LockedBy = SYSTEM_USER
WHERE  FrameworkCode = 'BENCH' AND PeriodLabel = @Label;

INSERT INTO bench.Config (PeriodLabel, Te, CutoffUtc, Positions, Days, PreRounds, PostRounds)
VALUES (@Label, @Te, @Cutoff, @Positions, @Days, @PreRounds, @PostRounds);

UPDATE STATISTICS risk.Positions WITH FULLSCAN;
UPDATE STATISTICS risk.PositionsHistory WITH FULLSCAN;
GO

-- -----------------------------------------------------------------------------
-- 2. Timed runs
--    Q1: 1,000 single-position lookups (reported per lookup)
--    Q2: aggregate risk metric over all positions of T_e
--    Q3: full examination package (all positions of T_e) into a temp table
--    "direct" reads the current table; "asof" resolves T_e and the cutoff
--    from the locked calendar and reads FOR SYSTEM_TIME AS OF the cutoff
--    (the same logic as reg.GetPositionsAsOf).
-- -----------------------------------------------------------------------------
SET NOCOUNT ON;

DECLARE @Runs INT = 100;
DECLARE @Label VARCHAR(40), @Te DATE, @Positions INT;
SELECT TOP 1 @Label = PeriodLabel, @Te = Te, @Positions = Positions
FROM bench.Config ORDER BY ConfigID DESC;

IF @Label IS NULL OR NOT EXISTS (SELECT 1 FROM risk.Positions)
BEGIN
    RAISERROR('No data loaded: section 1 did not complete. Fix that error first.', 16, 1);
    SET NOEXEC ON;
    RETURN;
END;

DROP TABLE IF EXISTS bench.Timing;
CREATE TABLE bench.Timing (
    Query   VARCHAR(20) NOT NULL,
    Variant VARCHAR(10) NOT NULL,
    Run     INT         NOT NULL,
    Micro   BIGINT      NOT NULL,
    RowsOut BIGINT      NOT NULL
);

DROP TABLE IF EXISTS #agg;
CREATE TABLE #agg (AssetClass VARCHAR(20), MV DECIMAL(38,2), N INT);
DROP TABLE IF EXISTS #pkg;
CREATE TABLE #pkg (
    PositionID BIGINT, EntityID VARCHAR(20), SecurityID VARCHAR(20),
    AssetClass VARCHAR(20), Quantity DECIMAL(18,4), MarketValue DECIMAL(18,2),
    Currency CHAR(3), ValidDate DATE, SysStartTime DATETIME2(7), SysEndTime DATETIME2(7)
);

DECLARE @run INT = -4;            -- runs -4..0 are warm-up, not recorded
DECLARE @t0 DATETIME2(7), @i INT, @key INT, @rows BIGINT, @us BIGINT;
DECLARE @mv DECIMAL(18,2), @d DATE, @c DATETIME2(7);

WHILE @run <= @Runs
BEGIN
    -- Q1 direct --------------------------------------------------------------
    SELECT @t0 = SYSDATETIME(), @i = 1, @rows = 0;
    WHILE @i <= 1000
    BEGIN
        SET @key = (@i * 97) % @Positions + 1;
        SELECT @mv = MarketValue FROM risk.Positions
        WHERE ValidDate = @Te AND PositionKey = @key;
        SET @rows += @@ROWCOUNT; SET @i += 1;
    END;
    SET @us = DATEDIFF_BIG(MICROSECOND, @t0, SYSDATETIME());
    IF @run > 0 INSERT bench.Timing VALUES ('Q1_lookup', 'direct', @run, @us, @rows);

    -- Q1 as-of ---------------------------------------------------------------
    SELECT @t0 = SYSDATETIME(), @i = 1, @rows = 0;
    WHILE @i <= 1000
    BEGIN
        SET @key = (@i * 97) % @Positions + 1;
        SELECT @d = ExaminationDate, @c = SnapshotCutoffUtc
        FROM reg.ExaminationCalendar
        WHERE FrameworkCode = 'BENCH' AND PeriodLabel = @Label AND IsLocked = 1;
        SELECT @mv = MarketValue FROM risk.Positions FOR SYSTEM_TIME AS OF @c
        WHERE ValidDate = @d AND PositionKey = @key;
        SET @rows += @@ROWCOUNT; SET @i += 1;
    END;
    SET @us = DATEDIFF_BIG(MICROSECOND, @t0, SYSDATETIME());
    IF @run > 0 INSERT bench.Timing VALUES ('Q1_lookup', 'asof', @run, @us, @rows);

    -- Q2 direct --------------------------------------------------------------
    TRUNCATE TABLE #agg;
    SET @t0 = SYSDATETIME();
    INSERT #agg SELECT AssetClass, SUM(MarketValue), COUNT(*)
    FROM risk.Positions WHERE ValidDate = @Te GROUP BY AssetClass;
    SET @us = DATEDIFF_BIG(MICROSECOND, @t0, SYSDATETIME());
    SELECT @rows = ISNULL(SUM(N), 0) FROM #agg;
    IF @run > 0 INSERT bench.Timing VALUES ('Q2_aggregate', 'direct', @run, @us, @rows);

    -- Q2 as-of ---------------------------------------------------------------
    TRUNCATE TABLE #agg;
    SET @t0 = SYSDATETIME();
    SELECT @d = ExaminationDate, @c = SnapshotCutoffUtc
    FROM reg.ExaminationCalendar
    WHERE FrameworkCode = 'BENCH' AND PeriodLabel = @Label AND IsLocked = 1;
    INSERT #agg SELECT AssetClass, SUM(MarketValue), COUNT(*)
    FROM risk.Positions FOR SYSTEM_TIME AS OF @c
    WHERE ValidDate = @d GROUP BY AssetClass;
    SET @us = DATEDIFF_BIG(MICROSECOND, @t0, SYSDATETIME());
    SELECT @rows = ISNULL(SUM(N), 0) FROM #agg;
    IF @run > 0 INSERT bench.Timing VALUES ('Q2_aggregate', 'asof', @run, @us, @rows);

    -- Q3 direct --------------------------------------------------------------
    TRUNCATE TABLE #pkg;
    SET @t0 = SYSDATETIME();
    INSERT #pkg SELECT PositionID, EntityID, SecurityID, AssetClass, Quantity,
                       MarketValue, Currency, ValidDate, SysStartTime, SysEndTime
    FROM risk.Positions WHERE ValidDate = @Te;
    SET @rows = @@ROWCOUNT;
    SET @us = DATEDIFF_BIG(MICROSECOND, @t0, SYSDATETIME());
    IF @run > 0 INSERT bench.Timing VALUES ('Q3_package', 'direct', @run, @us, @rows);

    -- Q3 as-of ---------------------------------------------------------------
    TRUNCATE TABLE #pkg;
    SET @t0 = SYSDATETIME();
    SELECT @d = ExaminationDate, @c = SnapshotCutoffUtc
    FROM reg.ExaminationCalendar
    WHERE FrameworkCode = 'BENCH' AND PeriodLabel = @Label AND IsLocked = 1;
    INSERT #pkg SELECT PositionID, EntityID, SecurityID, AssetClass, Quantity,
                       MarketValue, Currency, ValidDate, SysStartTime, SysEndTime
    FROM risk.Positions FOR SYSTEM_TIME AS OF @c WHERE ValidDate = @d;
    SET @rows = @@ROWCOUNT;
    SET @us = DATEDIFF_BIG(MICROSECOND, @t0, SYSDATETIME());
    IF @run > 0 INSERT bench.Timing VALUES ('Q3_package', 'asof', @run, @us, @rows);

    SET @run += 1;
END;
GO

-- -----------------------------------------------------------------------------
-- 3. Results — send these grids back
-- -----------------------------------------------------------------------------
SET NOCOUNT ON;
DECLARE @Label VARCHAR(40), @Te DATE, @Cutoff DATETIME2(7);
SELECT TOP 1 @Label = PeriodLabel, @Te = Te, @Cutoff = CutoffUtc
FROM bench.Config ORDER BY ConfigID DESC;

-- A. Environment and data size
SELECT
    @@VERSION                                         AS SqlServerVersion,
    (SELECT cpu_count FROM sys.dm_os_sys_info)        AS LogicalCpus,
    (SELECT physical_memory_kb / 1048576 FROM sys.dm_os_sys_info) AS MemoryGB,
    (SELECT COUNT_BIG(*) FROM risk.Positions)         AS CurrentRows,
    (SELECT COUNT_BIG(*) FROM risk.PositionsHistory)  AS HistoryRows,
    (SELECT COUNT_BIG(*) FROM risk.Positions WHERE ValidDate = @Te) AS RowsForTe,
    (SELECT TOP 1 CONCAT(Positions, ' x ', Days, ' days; ', PreRounds, ' pre + ',
                         PostRounds, ' post-cutoff rounds of 5%')
     FROM bench.Config ORDER BY ConfigID DESC)        AS Workload;

-- B. Medians (ms). Q1 is per single lookup.
WITH m AS (
    SELECT DISTINCT Query, Variant,
        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY Micro)
            OVER (PARTITION BY Query, Variant) AS MedianMicro,
        MAX(RowsOut) OVER (PARTITION BY Query, Variant) AS RowsOut,
        COUNT(*)     OVER (PARTITION BY Query, Variant) AS Runs
    FROM bench.Timing
)
SELECT
    d.Query,
    CAST(d.MedianMicro / CASE WHEN d.Query = 'Q1_lookup' THEN 1000000.0 ELSE 1000.0 END
         AS DECIMAL(12,3)) AS DirectMs,
    CAST(a.MedianMicro / CASE WHEN d.Query = 'Q1_lookup' THEN 1000000.0 ELSE 1000.0 END
         AS DECIMAL(12,3)) AS AsOfMs,
    CAST(100.0 * (a.MedianMicro - d.MedianMicro) / NULLIF(d.MedianMicro, 0)
         AS DECIMAL(6,1)) AS OverheadPct,
    d.RowsOut AS DirectRows,
    a.RowsOut AS AsOfRows,
    d.Runs
FROM m d JOIN m a ON a.Query = d.Query AND a.Variant = 'asof'
WHERE d.Variant = 'direct'
ORDER BY d.Query;

-- C. Correctness of the cutoff rule (Table 3 in the paper)
DECLARE @Midnight DATETIME2(7) = CAST(@Te AS DATETIME2(7));
SELECT 'midnight cast'  AS Anchor, COUNT_BIG(*) AS RowsForTe
FROM risk.Positions FOR SYSTEM_TIME AS OF @Midnight WHERE ValidDate = @Te
UNION ALL
SELECT 'locked cutoff', COUNT_BIG(*)
FROM risk.Positions FOR SYSTEM_TIME AS OF @Cutoff WHERE ValidDate = @Te
UNION ALL
SELECT 'current (direct)', COUNT_BIG(*)
FROM risk.Positions WHERE ValidDate = @Te;

-- D. Late corrections excluded by the cutoff (should equal the rows touched
--    by the post-cutoff rounds for ValidDate = @Te)
SELECT COUNT_BIG(*) AS RowsDifferingCutoffVsCurrent
FROM risk.Positions FOR SYSTEM_TIME AS OF @Cutoff AS s
JOIN risk.Positions AS cur
  ON cur.ValidDate = s.ValidDate AND cur.PositionKey = s.PositionKey
WHERE s.ValidDate = @Te AND s.MarketValue <> cur.MarketValue;

-- E. Sanity check: the artifact procedure returns the same row count as Q3 as-of
DROP TABLE IF EXISTS #proc;
CREATE TABLE #proc (
    PositionID BIGINT, EntityID VARCHAR(20), SecurityID VARCHAR(20),
    AssetClass VARCHAR(20), Quantity DECIMAL(18,4), MarketValue DECIMAL(18,2),
    Currency CHAR(3), ValidDate DATE, SysStartTime DATETIME2(7), SysEndTime DATETIME2(7),
    FrameworkCode VARCHAR(20), PeriodLabel VARCHAR(40), ExaminationDate DATE,
    SnapshotUtc DATETIME2(7)
);
INSERT #proc EXEC reg.GetPositionsAsOf @FrameworkCode = 'BENCH', @PeriodLabel = @Label;
SELECT COUNT_BIG(*) AS ProcedureRows FROM #proc;
GO

SET NOEXEC OFF;
GO
