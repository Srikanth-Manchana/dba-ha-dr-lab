# scripts/powershell/day1/04-build-cluster.ps1
#
# Run on SQL01 (as DBALAB\labadmin) after both SQL01 and SQL02 are domain-joined.
# Installs Failover Clustering on both nodes and builds the WSFC cluster.

# Install the feature on SQL01
Install-WindowsFeature -Name Failover-Clustering -IncludeManagementTools

# Install the feature on SQL02 too (run this block on SQL02, or use
# Invoke-Command -ComputerName SQL02 if remoting is set up):
#   Install-WindowsFeature -Name Failover-Clustering -IncludeManagementTools

# Validate before creating the cluster
Test-Cluster -Node SQL01, SQL02 -Include "Storage Spaces Direct","Inventory","Network","System Configuration"
# NOTE: in this lab, Storage Spaces Direct checks fail by design — there's no
# shared/pooled storage layer (we build a -NoStorage cluster). Result should
# be "ClusterConditionallyApproved", not full "Passed" — that's expected here,
# but in a real production build these warnings would need real resolution
# (redundant NICs, matched patch levels, actual shared storage for S2D if used).

New-Cluster -Name DBALAB-WSFC01 -Node SQL01, SQL02 -StaticAddress 10.10.1.20 -NoStorage

# Verify:
#   Get-Cluster                 -> Name: DBALAB-WSFC01
#   Get-ClusterNode              -> both SQL01 and SQL02, State: Up
