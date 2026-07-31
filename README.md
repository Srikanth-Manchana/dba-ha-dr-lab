# DBA HA/DR & Performance Lab — SQL Server + Oracle, Automation

Hands-on infrastructure lab reproducing enterprise DBA mechanics: SQL Server
Always-On Availability Groups on real WSFC, Oracle 19c Data Guard on Oracle
Linux, AWR/ASH and Extended Events/Query Store performance tuning, RMAN/Data
Pump, and cross-engine PowerShell/Python automation with Jenkins + Prometheus
+ Grafana.

## Structure
- `terraform/` — infrastructure as code for each day's environment (gitignored: `lab.tfvars`)
- `scripts/powershell`, `scripts/python` — automation and health-check scripts
- `scripts/sql/tsql`, `scripts/sql/plsql` — tuning, HA/DR, and scheduling scripts
- `docker/day5-monitoring` — Jenkins/Prometheus/Grafana compose stack
- `docs/` — day-by-day runbook narrative

## Cost
Designed to run for ~$75–125 total across the full lab, torn down after each session.

## Usage
Copy `terraform/lab.tfvars.example` to `terraform/lab.tfvars`, fill in your own
subscription/tenancy IDs, then run `bash scripts/autofill-env.sh && source dba-lab.env`.
