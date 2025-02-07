Clear-Host
write-host "Starting script at $(Get-Date)"

# Handle cases where the user has multiple subscriptions
$subs = Get-AzSubscription | Select-Object
if($subs.GetType().IsArray -and $subs.length -gt 1){
    Write-Host "You have multiple Azure subscriptions - please select the one you want to use:"
    for($i = 0; $i -lt $subs.length; $i++)
    {
            Write-Host "[$($i)]: $($subs[$i].Name) (ID = $($subs[$i].Id))"
    }
    $selectedIndex = -1
    $selectedValidIndex = 0
    while ($selectedValidIndex -ne 1)
    {
            $enteredValue = Read-Host("Enter 0 to $($subs.Length - 1)")
            if (-not ([string]::IsNullOrEmpty($enteredValue)))
            {
                if ([int]$enteredValue -in (0..$($subs.Length - 1)))
                {
                    $selectedIndex = [int]$enteredValue
                    $selectedValidIndex = 1
                }
                else
                {
                    Write-Output "Please enter a valid subscription number."
                }
            }
            else
            {
                Write-Output "Please enter a valid subscription number."
            }
    }
    $selectedSub = $subs[$selectedIndex].Id
    Select-AzSubscription -SubscriptionId $selectedSub
    az account set --subscription $selectedSub
}

# Register resource providers
Write-Host "Registering resource providers..."
$provider_list = "Microsoft.Storage", "Microsoft.Compute", "Microsoft.Network", "Microsoft.Databricks"
foreach ($provider in $provider_list){
    $result = Register-AzResourceProvider -ProviderNamespace $provider
    $status = $result.RegistrationState
    Write-Host "$provider : $status"
}

# Generate unique random suffix
[string]$suffix =  -join ((48..57) + (97..122) | Get-Random -Count 7 | % {[char]$_})
Write-Host "Your randomly-generated suffix for Azure resources is $suffix"

# Prepare to deploy
Write-Host "Preparing to deploy. This may take several minutes..."
$delay = 0, 30, 60, 90, 120 | Get-Random
Start-Sleep -Seconds $delay # random delay to stagger requests from multi-student classes

# Get a list of locations for Azure Databricks
$locations = Get-AzLocation | Where-Object {
    $_.Providers -contains "Microsoft.Databricks" -and
    $_.Providers -contains "Microsoft.Compute"
}
$max_index = $locations.Count - 1
$rand = (0..$max_index) | Get-Random

# Set region for resource creation
if ($args.count -gt 0 -And $args[0] -in $locations.Location)
{
    $Region = $args[0]
}
else {
    $Region = $locations.Get($rand).Location
}

# Try to create an Azure Databricks workspace in a region that has capacity
$stop = 0
$tried_regions = New-Object Collections.Generic.List[string]
while ($stop -ne 1){
    write-host "Trying $Region..."
    
    # Check for sufficient compute capacity
    $available_quota = 0
    $skus = Get-AzComputeResourceSku $Region | Where-Object {$_.ResourceType -eq "VirtualMachines" -and $_.Name -eq "standard_ds3_v2"}
    
    if ($skus.length -gt 0)
    {
        $r = $skus.Restrictions
        if ($r -ne $null)
        {
            Write-Host $r[0].ReasonCode
        }
        
        # Governor to manage VM quotas
        $quota = @(Get-AzVMUsage -Location $Region).where{$_.name.LocalizedValue -match 'Standard DSv2 Family vCPUs'}
        $cores =  $quota.currentvalue
        $maxcores = $quota.limit
        Write-Host "$cores of $maxcores cores in use."
        $available_quota = $quota.limit - $quota.currentvalue
    }

    # Determine if there is capacity in the region
    if (($available_quota -lt 4) -or ($skus.length -eq 0))
    {
        Write-Host "$Region has insufficient capacity."
        $tried_regions.Add($Region)
        $locations = $locations | Where-Object {$_.Location -notin $tried_regions}
        if ($locations.Count -ne 1){
            $rand = (0..$($locations.Count - 1)) | Get-Random
            $Region = $locations.Get($rand).Location
            $stop = 0
        }
        else {
            Write-Host "Could not create a Databricks workspace."
            Write-Host "Use the Azure portal to add one to the $resourceGroupName resource group."
            $stop = 1
        }
    }
    else {
        $resourceGroupName = "dp203-$suffix"
        Write-Host "Creating $resourceGroupName resource group ..."
        New-AzResourceGroup -Name $resourceGroupName -Location $Region | Out-Null

        # Create Virtual Network for NAT Instance and Databricks
        $vnetName = "databricks-vnet-$suffix"
        Write-Host "Creating Virtual Network..."
        $vnet = New-AzVirtualNetwork -ResourceGroupName $resourceGroupName -Location $Region `
            -Name $vnetName -AddressPrefix "10.0.0.0/16"
        
        # Create Subnets
        $publicSubnet = New-AzVirtualNetworkSubnetConfig -Name "public-subnet" -AddressPrefix "10.0.0.0/24"
        $privateSubnet = New-AzVirtualNetworkSubnetConfig -Name "private-subnet" -AddressPrefix "10.0.1.0/24"
        $vnet | Set-AzVirtualNetworkSubnetConfig -Subnet $publicSubnet 
        $vnet | Set-AzVirtualNetworkSubnetConfig -Subnet $privateSubnet
        
        $vnet.Subnets = @($publicSubnet, $privateSubnet)
        Set-AzVirtualNetwork -VirtualNetwork $vnet | Out-Null

        # Create a Network Security Group
        $nsg = New-AzNetworkSecurityGroup -ResourceGroupName $resourceGroupName -Location $Region -Name "nsg-$suffix"
        
        # Attach NSG to private subnet
        Set-AzVirtualNetworkSubnetConfig -VirtualNetwork $vnet -Name "private-subnet" -NetworkSecurityGroup $nsg | Set-AzVirtualNetwork

        # Create NAT Instance using Standard_F1s
        Write-Host "Creating NAT Instance using Standard_F1s..."
        $natVMName = "nat-instance-$suffix"
        $natPublicIP = New-AzPublicIpAddress -ResourceGroupName $resourceGroupName -Location $Region `
            -Name "nat-ip-$suffix" -AllocationMethod Static -Sku Basic
        
        $natNIC = New-AzNetworkInterface -ResourceGroupName $resourceGroupName -Location $Region `
            -Name "nat-nic-$suffix" -SubnetId $vnet.Subnets[0].Id -PublicIpAddressId $natPublicIP.Id `
            -EnableIPForwarding

        $natVMConfig = New-AzVMConfig -VMName $natVMName -VMSize "Standard_F1s"
        $natVMConfig = Add-AzVMNetworkInterface -VM $natVMConfig -Id $natNIC.Id
        $natVM = Set-AzVMOperatingSystem -VM $natVMConfig -Linux -ComputerName $natVMName `
            -Credential (New-Object PSCredential ("azureuser", (ConvertTo-SecureString "P@ssw0rd123!" -AsPlainText -Force)))
        $natVM = Set-AzVMSourceImage -VM $natVM -PublisherName "Canonical" -Offer "UbuntuServer" `
            -Skus "18.04-LTS" -Version "latest"
        
        Write-Host "Deploying NAT Instance VM..."
        New-AzVM -ResourceGroupName $resourceGroupName -Location $Region -VM $natVM | Out-Null

        # Configure NAT Instance
        Write-Host "Configuring NAT Instance..."
        $natScript = @"
#!/bin/bash
sudo apt-get update
sudo apt-get install -y iptables-persistent
sudo iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
sudo echo 1 > /proc/sys/net/ipv4/ip_forward
sudo echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
"@
        Invoke-AzVMRunCommand -ResourceGroupName $resourceGroupName -VMName $natVMName `
            -CommandId "RunShellScript" -ScriptString $natScript

        # Create and Configure Route Table
        Write-Host "Configuring routing..."
        $routeTable = New-AzRouteTable -ResourceGroupName $resourceGroupName -Location $Region `
            -Name "nat-routes-$suffix"
        Add-AzRouteConfig -RouteTable $routeTable -Name "ToInternet" -AddressPrefix "0.0.0.0/0" `
            -NextHopType "VirtualAppliance" -NextHopIpAddress $natNIC.IpConfigurations[0].PrivateIpAddress | Set-AzRouteTable
        
        Set-AzVirtualNetworkSubnetConfig -VirtualNetwork $vnet -Name "private-subnet" `
            -RouteTable $routeTable | Set-AzVirtualNetwork

        # Create Databricks Workspace
        $dbworkspace = "databricks$suffix"
        Write-Host "Creating $dbworkspace Azure Databricks workspace in $resourceGroupName resource group..."
        New-AzDatabricksWorkspace -Name $dbworkspace -ResourceGroupName $resourceGroupName `
            -Location $Region -Sku standard -VirtualNetworkId $vnet.Id -PrivateSubnetName "private-subnet" `
            -PublicSubnetName "public-subnet" | Out-Null

        # Grant permissions for Databricks workspace
        write-host "Granting permissions on the $dbworkspace resource..."
        write-host "(you can ignore any warnings!)"
        $subscriptionId = (Get-AzContext).Subscription.Id
        $userName = ((az ad signed-in-user show) | ConvertFrom-JSON).UserPrincipalName
        New-AzRoleAssignment -SignInName $userName -RoleDefinitionName "Owner" `
            -Scope "/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName/providers/Microsoft.Databricks/workspaces/$dbworkspace";

        # Create Data Factory
        $dataFactoryName = "adf$suffix"
        Write-Host "Creating $dataFactoryName Azure Data Factory in $resourceGroupName resource group..."
        Set-AzDataFactoryV2 -ResourceGroupName $resourceGroupName -Location $Region -Name $dataFactoryName | Out-Null

        $stop = 1
    }
}

write-host "Script completed at $(Get-Date)"
