-- =============================================================================
-- run_all_tests.sql — runs the whole test in one go, in the right order and
-- in the right database. Alternative to running the scripts one by one.
--
-- How to use (SSMS):
--   1. Open this file.
--   2. Turn on SQLCMD mode: Query menu -> SQLCMD Mode.
--   3. Edit ScriptDir below to the folder that holds these scripts.
--   4. Run (F5). Results for sections A–E appear at the end.
-- =============================================================================

:setvar ScriptDir "C:\path\to\temporal-compliance-arch\scripts"

:on error exit

:r "$(ScriptDir)\create_test_database.sql"

USE AsOfBench;
GO
:r "$(ScriptDir)\examination_calendar.sql"

USE AsOfBench;
GO
:r "$(ScriptDir)\get_positions_asof.sql"

:r "$(ScriptDir)\benchmark_asof.sql"
