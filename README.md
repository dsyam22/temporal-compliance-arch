# temporal-compliance-arch

SQL Server scripts that accompany the paper
**"Examination Time: A Temporal Data Architecture for Multi-Jurisdictional Regulatory Reporting"**
(Syam Sajit Dondapati, submitted to SIGMOD 2027 Industry Track).

The scripts implement a regulatory calendar that binds each examination date to a
frozen transaction-time cutoff, an as-of resolution procedure over a system-versioned
temporal table, two change-data-capture (CDC) checks, and a benchmark that reproduces
the paper's correctness and overhead measurements on synthetic data.

All data is synthetic. Nothing in this repository comes from a production system.

## The time rule in one paragraph

A regulatory as-of date is a **date**; a system-time snapshot needs an **instant**.
For each (framework, period) the calendar stores the examination date `T_e` and, when the
period is locked, a data cutoff `SnapshotCutoffUtc`: the last instant of the revision-cutoff
day in America/New_York, converted to UTC (SQL Server records system time in UTC).
A filing query selects rows with `ValidDate = T_e` (end-of-day positions for that business
date) `FOR SYSTEM_TIME AS OF SnapshotCutoffUtc`. Casting the date to midnight instead would
take the snapshot before that day's end-of-day load and return the wrong rows.

## Contents

| Script | What it does |
|---|---|
| `scripts/examination_calendar.sql` | Calendar table, immutability trigger, lock procedure (computes and freezes the UTC cutoff), seed data for seven example frameworks |
| `scripts/get_positions_asof.sql` | `reg.GetPositionsAsOf`: resolves `T_e` and the cutoff from the locked calendar, queries the temporal table, logs every call |
| `scripts/lsn_gap_monitor.sql` | CDC freshness alarm: flags capture instances with no recent change. A signal, not proof of a gap (an idle table looks the same) |
| `scripts/cdc_consumer_gap_check.sql` | Detects a downstream consumer that has fallen behind the CDC retention window (its next LSN is older than `fn_cdc_get_min_lsn`) |
| `scripts/create_test_database.sql` | Creates the `AsOfBench` test database |
| `scripts/benchmark_asof.sql` | Loads synthetic data, checks the cutoff rule, times direct vs. as-of queries, prints results |
| `scripts/run_all_tests.sql` | Optional: runs the test steps in order (SSMS SQLCMD mode) |

## Requirements

- SQL Server 2016 SP1 or later (system-versioned temporal tables, `CREATE OR ALTER`, `AT TIME ZONE`).
  Tested on SQL Server 2025.
- A **test instance**, never production. Developer Edition is free for testing.
- The two CDC scripts also need CDC enabled on the database and SQL Server Agent running.
  They are not part of the benchmark.

## How to run the test

Every script starts with `USE AsOfBench;`, so the SSMS database dropdown does not matter.
To use another database name, change that line at the top of each script.

| Step | Script | What it does |
|---|---|---|
| 1 | `create_test_database.sql` | One time. Creates `AsOfBench`. |
| 2 | `examination_calendar.sql` | Calendar table, lock procedure, seed data. |
| 3 | `get_positions_asof.sql` | Audit log table and `reg.GetPositionsAsOf`. |
| 4 | `benchmark_asof.sql` | Loads 2,000,000 synthetic rows, times the queries, prints results A–E. Takes a few minutes. |

**Shortcut:** `run_all_tests.sql` runs steps 1–4 in one go. In SSMS, turn on
*Query → SQLCMD Mode*, set `ScriptDir` at the top to your `scripts` folder, and press F5.

If `AsOfBench` does not exist, steps 2 and 3 stop with an error instead of running in `master`.
Step 4 stops if steps 2 and 3 have not been run.

### Expected results

The correctness checks should match exactly, whatever the hardware:

- **Section C:** `midnight cast` returns 0 rows; `locked cutoff` returns 100,000 rows.
- **Section D:** 10,000 rows differ between the cutoff and the current table (the corrections made after the cutoff).
- **Section E:** the procedure returns 100,000 rows.

Timings (section B) depend on hardware and history size. The benchmark reports medians over
100 runs after 5 warm-up runs, for a single-position lookup, an aggregate over all positions
of the examination date, and the full examination package.

To rerun, run step 4 again; it rebuilds its data each time. To remove everything:
`DROP DATABASE AsOfBench;`

### A note on publishing results

This repository contains the benchmark, not its timing results. SQL Server's license terms
restrict disclosing benchmark results to third parties without Microsoft's approval; check
the terms for your edition before publishing numbers you measure.

## License

MIT. See [LICENSE](LICENSE). 
