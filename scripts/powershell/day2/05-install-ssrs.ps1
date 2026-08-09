# scripts/powershell/day2/05-install-ssrs.ps1
#
# Installs SQL Server Reporting Services and deploys one report.
# Run on SQL01.

# 1. Download the SSRS installer. Microsoft rotates the direct download URL
#    periodically — if a hardcoded fwlink 404s, search "download SQL Server
#    Reporting Services" and grab the current .exe through the browser
#    instead of scripting the download.
#    Example of a URL that went stale during this build:
#      https://download.microsoft.com/download/1/6/8/168FF56F-1D3D-4223-9AB0-BF37978F9377/SQLServerReportingServices.exe
#    Current download page as of this lab:
#      https://www.microsoft.com/en-us/download/details.aspx?id=105336

# 2. Unattended install (adjust path to wherever the installer downloaded):
& "C:\Users\labadmin\Downloads\SQLServerReportingServices.exe" /Quiet /IAcceptLicenseTerms /Edition=Dev

# Check install progress if needed (the /Quiet install returns control to
# the shell immediately while it continues in the background):
#   Get-Process | Where-Object {$_.ProcessName -like "*Reporting*"}
#   Get-Service | Where-Object {$_.DisplayName -like "*Report*"}

# 3. Configure via Report Server Configuration Manager (GUI tool, no
#    reliable unattended CLI path for the database + URL setup):
#   Search Start Menu for "Report Server Configuration Manager"
#   -> Connect to the SQL01 instance
#   -> Database tab -> Change Database -> Create a new report server database
#   -> Web Service URL tab -> Apply (defaults are fine)
#   -> Web Portal URL tab -> Apply (defaults are fine)

# 4. Verify:
#   http://sql01/ReportServer   -> raw report server listing
#   http://sql01/reports/browse/  -> web portal (this is where reports are browsed/run)

# 5. Build the report in Report Builder (separate free download from Microsoft):
#    Data source: Data Source=sql01;Initial Catalog=DBALAB_PerfLab
#    Dataset query:
#      SELECT Region, COUNT(*) AS OpenOrders
#      FROM dbo.OrdersData
#      WHERE Status = 'Open'
#      GROUP BY Region
#      ORDER BY OpenOrders DESC;
#    Insert -> Table/Matrix -> Table Wizard -> Region to Row groups,
#    OpenOrders to Values -> Finish.
#    File -> Save As -> http://sql01/ReportServer -> name: OpenOrdersByRegion

# 6. SQL Server Reporting Services identifies itself to SQL Server via
#    APP_NAME() = 'Report Server' (not 'SSRS') — relevant if writing a
#    Resource Governor classifier function to isolate this traffic; see
#    scripts/sql/tsql/day2/04-resource-governor.sql.

# 7. Note: SSRS caches dataset query results by default. Repeated report
#    refreshes within the cache window will not re-query the database —
#    relevant when trying to measure per-execution query cost via Extended
#    Events or similar; see docs/day2-notes.md, issue #5.

# 8. Restart the service any time the classifier function or other
#    server-side config changes and existing sessions need to reconnect:
Restart-Service SQLServerReportingServices
