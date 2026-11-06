-- =============================================================================
-- create_test_database.sql — step 1 of the test run (see README).
-- Creates the AsOfBench test database. Run once, on a TEST instance only.
-- =============================================================================
USE master;
GO

IF DB_ID('AsOfBench') IS NULL
BEGIN
    CREATE DATABASE AsOfBench;
    PRINT 'Created database AsOfBench.';
END
ELSE
    PRINT 'Database AsOfBench already exists.';
GO

USE AsOfBench;
GO
PRINT 'Now connected to: ' + DB_NAME()
    + '. In each new script window, select AsOfBench in the database dropdown.';
GO
