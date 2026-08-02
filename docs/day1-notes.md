# Day 1 Notes — SQL Server Always-On AG on Real WSFC

Real notes from actually building this, including every issue hit and how it was
resolved — kept deliberately unpolished. The point of this file is that it's true,
not that it's tidy.

## Environment

- Azure resource group `dba-lab-rg`, region `westus2`
- 4x Windows Server 2022 Datacenter VMs: `DC01`, `SQL01`, `SQL02`, `JUMP01`
- Domain: `dbalab.local` (NetBIOS `DBALAB`)
- Cluster: `DBALAB-WSFC01`
- Availability Group: `DBALAB-AG01`, database `DBALAB_OrdersDB`
- Listener: `DBALAB-AG01-L` @ `10.10.1.30:1433`
- SQL Server 2022 Developer Edition (unattended install via SSEI bootstrapper)

## Issue log, in the order actually hit

### 1. Azure free-trial subscription blocks quota increases entirely
`az vm create` for SQL01/SQL02/JUMP01 failed with `QuotaExceeded` — the default
4-core regional vCPU cap on a brand-new subscription. Attempting a self-service
quota increase in the portal returned **"Ineligible for quota adjustments — free
trials are not eligible."** Fix: upgraded the subscription to Pay-As-You-Go
(existing $200 trial credit carried over and applied first, per Azure's own FAQ
on the upgrade screen). Even after upgrading, a quota increase request for
`Standard DSv5 Family vCPUs` to 8/16 still failed via self-service (new paid
accounts commonly get auto-denied due to no billing history yet) — a free
support ticket was the eventual guaranteed path, but wasn't needed in the end
because of the next finding.

### 2. Regional total quota ≠ per-VM-family quota
`az vm list-usage --location westus2` showed **Total Regional vCPUs: 2 of 24**
(already raised) but **Standard DSv5 Family vCPUs: 2 of 0** — i.e. genuinely
zero quota for that specific family, a completely separate cap from the
regional total. Grepping the full usage list for any family with nonzero
*available* quota (`grep -v " 0 "`) surfaced `Standard EBDSv5 Family vCPUs`
already sitting at a limit of 10 with 0 used. Switched all 4 VMs from
`Standard_D4s_v5`/`Standard_D2s_v5` to `Standard_E2bds_v5` (2 vCPU / 16GB each,
8 cores total) and provisioning succeeded immediately. Lesson: when a specific
VM size's quota request keeps failing, check `az vm list-usage` for a
same-generation family that already has headroom before escalating further.

### 3. RDP client compatibility on older macOS
Microsoft's current "Windows App" (formerly Remote Desktop) requires macOS 14+;
this machine is on macOS 13.7.8 (Ventura), and both the App Store listing and
Microsoft's direct `.dmg` redirect served the same gated client. `brew install
freerdp` started compiling from source and stalled (same pattern as an earlier
Azure CLI Homebrew install). Fix: `brew install --cask royal-tsx` — a
pre-built binary with much broader macOS version compatibility, free tier
sufficient for basic RDP connections.

### 4. RDP sessions defaulting to local accounts, not domain accounts
After joining SQL01/SQL02/JUMP01 to the domain, multiple commands failed with
`Login failed for user 'SQL01\labadmin'` — a **local** machine account, not
`DBALAB\labadmin`. Royal TSX (and RDP generally) can default to a cached local
login unless the domain is explicitly qualified. Fix: always specify
`DBALAB\labadmin` (not just `labadmin`) in the username field on every
connection for the rest of the lab.

### 5. `Enable-SqlAlwaysOn` cmdlet not found
`Import-Module SqlServer` failed with "module not found" — because the
unattended install used `/FEATURES=SQLENGINE` only, which doesn't pull in the
PowerShell SqlServer module the way a full GUI/SSMS install does. Fix:
`Install-Module -Name SqlServer -Force -AllowClobber -Scope CurrentUser`.

### 6. `Enable-SqlAlwaysOn` fails restarting the service
Once the module was present, the cmdlet itself failed with `StopService failed
for Service 'MSSQLSERVER'` on its automatic restart attempt. Worked around by
enabling Always On manually via SQL Server Configuration Manager (Properties →
Always On High Availability tab → checkbox) and restarting the service from
there instead of relying on the cmdlet's built-in restart.

### 7. SSMS connection: "Access is denied" (Named Pipes)
Connecting from JUMP01 to SQL01 in SSMS failed with a Named Pipes access-denied
error. Root cause: **Windows Firewall on SQL01 had no inbound rule for port
1433** — a fresh Server 2022 install blocks it by default. Fix:
```powershell
New-NetFirewallRule -DisplayName "SQL Server (TCP-In)" -Direction Inbound -Protocol TCP -LocalPort 1433 -Action Allow
```
(repeated on SQL02, plus the equivalent for port 5022 / HADR up front to
pre-empt the next issue.)

### 8. AG creation partially succeeded, then re-running hit "already exists" everywhere
The AG creation script is long and stateful — endpoints, the AG itself, replica
join, database join, and listener creation all in one block. When the firewall
issue above interrupted an early run, re-running the *whole* script from
scratch threw "already exists" errors for everything that had already
succeeded, and only the genuinely-still-broken steps (the database join, the
listener) surfaced real errors underneath the noise. Lesson: for a multi-step
AG build, check actual current state (`sys.availability_replicas`,
`sys.dm_hadr_availability_replica_states`) before re-running the whole script —
don't assume "already exists" means nothing is wrong, and don't assume a
failure means nothing succeeded.

### 9. "The connection to the primary replica is not active" — three separate causes, layered
This single error message appeared three times, for three genuinely different
underlying reasons, resolved one layer at a time:

**a) Azure NSG (cloud-level firewall), separate from Windows Firewall.**
Each VM in this setup got its own auto-generated NSG (`SQL01NSG`, `SQL02NSG`,
etc.) at NIC creation time — a completely separate firewall layer from the
Windows Firewall rules already fixed in #7. `Test-NetConnection -Port 5022`
failed even with Windows Firewall correctly configured, because the NSG never
allowed port 5022 inbound at all. Fixed via
`az network nsg rule create ... --destination-port-ranges 5022
--source-address-prefixes VirtualNetwork --destination-address-prefixes VirtualNetwork`
on both SQL01NSG and SQL02NSG (and 1433 too, for good measure — it had been
working, but only by coincidence of a broader default rule).

**b) HADR endpoint registered but not actually `STARTED`.**
Even after both firewall layers were fixed, port 5022 tests still failed one
direction at a time (SQL01→SQL02 worked, SQL02→SQL01 didn't, then vice versa
after a partial fix). `sys.tcp_endpoints` showed the endpoint existing but not
actually in a `STARTED` state on whichever node was currently failing. Fixed
per-node with `ALTER ENDPOINT Hadr_endpoint STATE = STARTED;` — had to do this
on **both** SQL01 and SQL02 individually, since each node's endpoint state is
independent.

**c) Missing SQL Server login for the peer node's computer account.**
Even with both directions network-reachable and both endpoints `STARTED`, the
database join still failed with the same error. Root cause: the SQL Server
service on both nodes runs as the virtual service account `NT
Service\MSSQLSERVER`, which authenticates over the network as the **machine's
own AD computer account** (`DBALAB\SQL01$` / `DBALAB\SQL02$`), not as
`DBALAB\labadmin`. SQL Server had no login for either computer account, so the
endpoint connection was rejected at the SQL Server permission layer even
though the network path was fully open. Fixed with, on each node, a login for
*the other* node's computer account, then the endpoint grant:
```sql
CREATE LOGIN [DBALAB\SQL02$] FROM WINDOWS;   -- run on SQL01
GRANT CONNECT ON ENDPOINT::Hadr_endpoint TO [DBALAB\SQL02$];
```
(mirrored on SQL02 for `DBALAB\SQL01$`). This is apparently a very common,
easy-to-miss step in real-world AG setups — the network layer being fine gives
false confidence that the problem must be somewhere else.

### 10. Listener creation — CIDR notation not accepted
`New-SqlAvailabilityGroupListener -StaticIp "10.10.1.30/24"` failed with "The
format for the IP address, '24', is invalid." The cmdlet wants a **dotted-decimal
subnet mask**, not CIDR shorthand. Fixed with
`-StaticIp "10.10.1.30/255.255.255.0"` instead of `/24`.

## What actually worked, end to end

```sql
SELECT ag.name, ar.replica_server_name, ars.role_desc, ars.synchronization_health_desc
FROM sys.availability_groups ag
JOIN sys.availability_replicas ar ON ag.group_id = ar.group_id
LEFT JOIN sys.dm_hadr_availability_replica_states ars ON ar.replica_id = ars.replica_id;
```
```
DBALAB-AG01   SQL01   PRIMARY     HEALTHY
DBALAB-AG01   SQL02   SECONDARY   HEALTHY
```
Listener `DBALAB-AG01-L.dbalab.local` resolves to `10.10.1.30` and routes to
whichever node is currently primary.

## Takeaways worth remembering for an interview

- **"Access denied" / "connection not active" errors during AG setup can stack
  across three independent layers** — cloud-level NSG, OS-level Windows
  Firewall, and SQL Server's own endpoint state/permissions — and fixing one
  doesn't mean the others are fine. Check each layer explicitly rather than
  assuming.
- **Virtual service accounts (`NT Service\MSSQLSERVER`) authenticate over the
  network as the machine's AD computer account**, not as any interactively
  logged-in user. Endpoint permissions need to target `DOMAIN\MACHINE$`
  logins, which SQL Server won't have unless explicitly created with
  `CREATE LOGIN ... FROM WINDOWS`.
- **Quota limits in Azure are layered** (regional total vs. per-VM-family) and
  a free-trial subscription can't request increases at all — upgrading to
  Pay-As-You-Go unlocks the request, but doesn't guarantee instant approval;
  switching to a VM family with existing headroom is often faster than waiting
  on a quota ticket.
- **Re-running a long, multi-step provisioning script after a partial failure
  produces misleading "already exists" noise** — always check actual current
  state before treating a script's exit code as ground truth.
