#!/usr/bin/env bash
# terraform/day1-sqlserver/01-provision-vms.sh
#
# Provisions the 4 Windows Server 2022 VMs for Day 1 (DC01, SQL01, SQL02, JUMP01).
#
# NOTE ON VM SIZE: the lab originally called for Standard_D2s_v5 / Standard_D4s_v5,
# but this subscription had a genuinely zero quota for the "Standard DSv5 Family"
# specifically (separate from the overall regional vCPU quota, which was fine).
# Standard_E2bds_v5 (2 vCPU / 16GB, memory-optimized) was substituted after
# confirming via `az vm list-usage --location <region>` that this family already
# had headroom. Check your own subscription's quota before assuming D-series
# will work — see docs/day1-notes.md, issue #2.
#
# Prerequisites: az login done, dba-lab.env sourced (see scripts/autofill-env.sh).

set -euo pipefail

: "${AZURE_REGION:?Run 'source dba-lab.env' first (see scripts/autofill-env.sh)}"

VM_SIZE="Standard_E2bds_v5"
RG="dba-lab-rg"
VNET="dba-lab-vnet"
SUBNET="sql-subnet"

echo "==> Resource group + network"
az group create -n "$RG" -l "$AZURE_REGION"
az network vnet create -g "$RG" -n "$VNET" --address-prefix 10.10.0.0/16 \
  --subnet-name "$SUBNET" --subnet-prefix 10.10.1.0/24

read -s -p "Set a strong admin password for the lab VMs: " LAB_ADMIN_PW; echo
export LAB_ADMIN_PW

echo "==> DC01 — domain controller"
az vm create -g "$RG" -n DC01 --image Win2022Datacenter \
  --size "$VM_SIZE" --vnet-name "$VNET" --subnet "$SUBNET" \
  --admin-username labadmin --admin-password "$LAB_ADMIN_PW"

echo "==> SQL01, SQL02, JUMP01"
for VM in SQL01 SQL02 JUMP01; do
  az vm create -g "$RG" -n "$VM" --image Win2022Datacenter \
    --size "$VM_SIZE" --vnet-name "$VNET" --subnet "$SUBNET" \
    --admin-username labadmin --admin-password "$LAB_ADMIN_PW"
done

echo "==> Opening required ports at the Azure NSG layer (per-VM NSGs, not a shared one)"
# Each VM gets its own auto-created NSG (<VMName>NSG). Both SQL nodes need
# 1433 (client connections) and 5022 (HADR endpoint) open to the VNet.
for VM in SQL01 SQL02; do
  az network nsg rule create -g "$RG" --nsg-name "${VM}NSG" \
    --name Allow-SQL-1433 --priority 210 --direction Inbound --access Allow --protocol Tcp \
    --destination-port-ranges 1433 --source-address-prefixes VirtualNetwork --destination-address-prefixes VirtualNetwork
  az network nsg rule create -g "$RG" --nsg-name "${VM}NSG" \
    --name Allow-SQL-HADR --priority 200 --direction Inbound --access Allow --protocol Tcp \
    --destination-port-ranges 5022 --source-address-prefixes VirtualNetwork --destination-address-prefixes VirtualNetwork
done

echo "==> Done. VM public IPs:"
az vm list -g "$RG" -d --output table

echo ""
echo "NOTE: Windows Firewall inside each VM still needs its own matching rules —"
echo "the Azure NSG is a separate layer in front of the OS firewall, not a"
echo "replacement for it. See scripts/powershell/day1/05-install-sql.ps1."
