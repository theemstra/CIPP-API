function Invoke-ExecApiClient {
    <#
    .FUNCTIONALITY
        Entrypoint
    .ROLE
        CIPP.Extension.ReadWrite
    #>
    [CmdletBinding()]
    param($Request, $TriggerMetadata)

    $Table = Get-CippTable -tablename 'ApiClients'
    $Action = $Request.Query.Action ?? $Request.Body.Action

    switch ($Action) {
        'List' {
            $Apps = Get-CIPPAzDataTableEntity @Table
            if (!$Apps) {
                $Apps = @()
            } else {
                $Apps = Get-CippApiClient
                $Body = @{ Results = @($Apps) }
            }
        }
        'ListAvailable' {
            $sitename = $env:WEBSITE_SITE_NAME
            $Apps = New-GraphGetRequest -uri "https://graph.microsoft.com/v1.0/applications?`$filter=signInAudience eq 'AzureAdMyOrg' and web/redirectUris/any(x:x eq 'https://$($sitename).azurewebsites.net/.auth/login/aad/callback')&`$top=999&`$select=appId,displayName,createdDateTime,api,web,passwordCredentials&`$count=true" -NoAuthCheck $true -asapp $true -ComplexFilter
            $Body = @{
                Results = @($Apps)
            }
        }
        'AddUpdate' {
            if ($Request.Body.ClientId -or $Request.Body.AppName) {
                $ClientId = $Request.Body.ClientId.value ?? $Request.Body.ClientId
                try {
                    $ApiConfig = @{
                        ExecutingUser = $Request.Headers.'x-ms-client-principal'
                    }
                    if ($ClientId) {
                        $ApiConfig.ClientId = $ClientId
                        $ApiConfig.ResetSecret = $Request.Body.CIPPAPI.ResetSecret
                    }
                    if ($Request.Body.AppName) {
                        $ApiConfig.AppName = $Request.Body.AppName
                    }
                    $APIConfig = New-CIPPAPIConfig @ApiConfig
                    Write-Host ($APIConfig | ConvertTo-Json)
                    $ClientId = $APIConfig.ApplicationID
                    $AddedText = $APIConfig.Results
                } catch {
                    $AddedText = 'Could not modify App Registrations. Check the CIPP documentation for API requirements.'
                    $Body = $Body | Select-Object * -ExcludeProperty CIPPAPI
                }
            }

            if ($Request.Body.IpRange.value) {
                $IpRange = @($Request.Body.IpRange.value)
            } else {
                $IpRange = @()
            }

            $ExistingClient = Get-CIPPAzDataTableEntity @Table -Filter "RowKey eq '$($ClientId)'"
            if ($ExistingClient) {
                $Client = $ExistingClient
                $Client.Role = [string]$Request.Body.Role.value
                $Client.IPRange = "$(@($IpRange) | ConvertTo-Json -Compress)"
                $Client.Enabled = $Request.Body.Enabled ?? $false
                Write-LogMessage -user $Request.Headers.'x-ms-client-principal' -API 'ExecApiClient' -message "Updated API client $($Request.Body.ClientId)" -Sev 'Info'
                $Results = 'API client updated'
            } else {
                $Client = @{
                    'PartitionKey' = 'ApiClients'
                    'RowKey'       = "$($ClientId)"
                    'AppName'      = "$($APIConfig.AppName ?? $Request.Body.ClientId.addedFields.displayName)"
                    'Role'         = [string]$Request.Body.Role.value
                    'IPRange'      = "$(@($IpRange) | ConvertTo-Json -Compress)"
                    'Enabled'      = $Request.Body.Enabled ?? $false
                }
                $Results = @{
                    resultText = "API Client created with the name '$($Client.AppName)'. Use the Copy to Clipboard button to retrieve the secret."
                    copyField  = $APIConfig.ApplicationSecret
                    state      = 'success'
                }
            }

            Add-CIPPAzDataTableEntity @Table -Entity $Client -Force | Out-Null
            $Body = @($Results)
        }
        'GetAzureConfiguration' {
            $RGName = $ENV:WEBSITE_RESOURCE_GROUP
            $FunctionAppName = $ENV:WEBSITE_SITE_NAME
            try {
                $APIClients = Get-CippApiAuth -RGName $RGName -FunctionAppName $FunctionAppName
                $Results = $ApiClients
            } catch {
                $Results = @{
                    Enabled = 'Could not get API clients, ensure you have the appropriate rights to read the Authentication settings.'
                }
            }
            $Body = @{
                Results = $Results
            }
        }
        'SaveToAzure' {
            $TenantId = $ENV:TenantId
            $RGName = $ENV:WEBSITE_RESOURCE_GROUP
            $FunctionAppName = $ENV:WEBSITE_SITE_NAME
            $AllClients = Get-CIPPAzDataTableEntity @Table -Filter 'Enabled eq true'
            $ClientIds = $AllClients.RowKey
            try {
                Set-CippApiAuth -RGName $RGName -FunctionAppName $FunctionAppName -TenantId $TenantId -ClientIds $ClientIds
                $Body = @{ Results = 'API clients saved to Azure' }
            } catch {
                $Body = @{ Results = 'Failed to save allowed API clients to Azure, ensure your function app has the appropriate rights to make changes to the Authentication settings.' }
            }
        }
        'ResetSecret' {
            $Client = Get-CIPPAzDataTableEntity @Table -Filter "RowKey eq '$($Request.Body.ClientId)'"
            if (!$Client) {
                $Results = @{
                    resultText = 'API client not found'
                    severity   = 'error'
                }
            } else {
                $ApiConfig = New-CIPPAPIConfig -ResetSecret -AppId $Request.Body.ClientId

                if ($ApiConfig.ApplicationSecret) {
                    $Results = @{
                        resultText = "API secret reset for $($Client.AppName). Use the Copy to Clipboard button to retrieve the new secret."
                        copyField  = $ApiConfig.ApplicationSecret
                        state      = 'success'
                    }
                } else {
                    $Results = @{
                        resultText = "Failed to reset secret for $($Client.AppName)"
                        state      = 'error'
                    }
                }
            }
            $Body = @($Results)
        }
        'Delete' {
            try {
                if ($Request.Body.ClientId) {
                    $ClientId = $Request.Body.ClientId.value ?? $Request.Body.ClientId
                    if ($Request.Body.RemoveAppReg -eq $true) {
                        $Apps = New-GraphGetRequest -uri "https://graph.microsoft.com/v1.0/applications?`$filter=signInAudience eq 'AzureAdMyOrg' and web/redirectUris/any(x:x eq 'https://$($sitename).azurewebsites.net/.auth/login/aad/callback')&`$top=999&`$select=id,appId&`$count=true" -NoAuthCheck $true -asapp $true -ComplexFilter
                        $Id = $Apps | Where-Object { $_.appId -eq $ClientId } | Select-Object -ExpandProperty id
                        if ($Id) {
                            New-GraphPOSTRequest -uri "https://graph.microsoft.com/v1.0/applications(appId='$ClientId')" -Method DELETE -Body '{}' -NoAuthCheck $true -asapp $true
                        }
                    }

                    $Client = Get-CIPPAzDataTableEntity @Table -Filter "RowKey eq '$($ClientId)'" -Property RowKey, PartitionKey, ETag
                    Remove-AzDataTableEntity @Table -Entity $Client
                    Write-LogMessage -user $Request.Headers.'x-ms-client-principal' -API 'ExecApiClient' -message "Deleted API client $ClientId" -Sev 'Info'
                    $Body = @{ Results = "API client $ClientId deleted" }
                } else {
                    $Body = @{ Results = "API client $ClientId not found or not a valid CIPP-API application" }
                }
            } catch {
                Write-LogMessage -user $Request.Headers.'x-ms-client-principal' -API 'ExecApiClient' -message "Failed to remove app registration for $ClientId" -Sev 'Warning'
            }
        }
        default {
            $Body = @{Results = 'Invalid action' }
        }
    }

    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::OK
            Body       = $Body
        })
}

