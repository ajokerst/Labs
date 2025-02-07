# Clear the console
Clear-Host
Write-Host "Starting script at $(Get-Date)"

# Retrieve Azure subscription
$subs = Get-AzSubscription | Select-Object
if ($subs.Length -gt 1) {
    Write-Host "You have multiple subscriptions. Please select one:"
    for ($i = 0; $i -lt $subs.Length; $i++) {
        Write-Host "[$i]: $($subs[$i].Name) (ID = $($subs[$i].Id))"
    }
    $selectedIndex = [int](Read-Host "Enter the subscription number (0-$($subs.Length - 1))")
    $selectedSub = $subs[$selectedIndex].Id
    Select-AzSubscription -SubscriptionId $selectedSub
}

# Register required resource providers
Write-Host "Registering required providers..."
$requiredProviders = @("Microsoft.Storage", "Microsoft.Compute", "Microsoft.Network", "Microsoft.Databricks")
foreach ($provider in $requiredProviders) {
    Register-AzResourceProvider -ProviderNamespace $provider | Out-Null
}

# Generate unique suffix
$suffix = -join ((48..57) + (97..122) | Get-Random -Count 7 | ForEach-Object { [char]$_ })
Write-Host "Unique suffix: $suffix"

# Set parameters
$resourceGroupName = "db-lab-$suffix"
$location = "eastus"  # Change this to your preferred Azure region
$vnetName = "lab-vnet-$suffix"
$subnetName = "lab-subnet"
$natVMName = "nat-instance-$suffix"
$dbWorkspaceName = "databricks-$suffix"

# Create a resource group
Write-Host "Creating resource group: $resourceGroupName in $location..."
New-AzResourceGroup -Name $resourceGroupName -Location $location | Out-Null

# Create a virtual network with a subnet
Write-Host "Creating virtual network: $vnetName..."
$vnet = New-AzVirtualNetwork -ResourceGroupName $resourceGroupName -Location $location `
    -Name $vnetName -AddressPrefix "10.0.0.0/16" `
    -Subnet @(New-AzVirtualNetworkSubnetConfig -Name $subnetName -AddressPrefix "10.0.1.0/24") `
    | Out-Null

# Get subnet config
$subnet = Get-AzVirtualNetworkSubnetConfig -Name $subnetName -VirtualNetwork $vnet

# Create a public IP for the NAT instance
Write-Host "Creating public IP for NAT instance..."
$publicIp = New-AzPublicIpAddress -ResourceGroupName $resourceGroupName -Location $location `
    -Name "nat-public-ip-$suffix" -AllocationMethod Static -Sku Basic

# Create a NIC for the NAT instance
Write-Host "Creating NIC for NAT instance..."
$nic = New-AzNetworkInterface -ResourceGroupName $resourceGroupName -Location $location `
    -Name "nat-nic-$suffix" -SubnetId $subnet.Id -PublicIpAddressId $publicIp.Id

# Create the NAT instance using the cheapest VM: Standard_F1s
Write-Host "Creating NAT instance (Standard_F1s)..."
$securePassword = Read-Host "Enter password for NAT instance" -AsSecureString
$vm = New-AzVM -ResourceGroupName $resourceGroupName -Location $location `
    -Name $natVMName -Credential (New-Object PSCredential "azureuser", $securePassword) `
    -ImageName "Canonical:UbuntuServer:18.04-LTS:latest" `
    -NetworkInterfaceId $nic.Id -Size "Standard_F1s"

# Install and configure NAT on the instance
Write-Host "Configuring NAT on the NAT instance..."
$vmScript = @"
sudo apt update
sudo apt install -y iptables-persistent
sudo iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
sudo sh -c 'echo 1 > /proc/sys/net/ipv4/ip_forward'
sudo sh -c 'echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf'
"@
Invoke-AzVMRunCommand -ResourceGroupName $resourceGroupName -VMName $natVMName `
    -CommandId "RunShellScript" -ScriptString $vmScript

# Update subnet's route table to send outbound traffic through the NAT instance
Write-Host "Creating route table for NAT instance..."
$routeTable = New-AzRouteTable -ResourceGroupName $resourceGroupName -Location $location `
    -Name "nat-route-table-$suffix"
$route = Add-AzRouteConfig -RouteTable $routeTable -Name "default-route" `
    -AddressPrefix "0.0.0.0/0" -NextHopType VirtualAppliance -NextHopIpAddress "10.0.1.4"  # NAT instance private IP
Set-AzVirtualNetworkSubnetConfig -VirtualNetwork $vnet -Name $subnet.Name `
    -AddressPrefix "10.0.1.0/24" -RouteTable $routeTable | Out-Null

# Create Databricks workspace
Write-Host "Creating Azure Databricks workspace..."
New-AzDatabricksWorkspace -Location $location -Name $dbWorkspaceName `
    -ResourceGroupName $resourceGroupName -Sku Standard | Out-Null

Write-Host "Azure Databricks lab with NAT instance created successfully!"
