using namespace System.Net

Function Invoke-RemoveExConnector {
    <#
    .FUNCTIONALITY
        Entrypoint
    .ROLE
        Exchange.Connector.ReadWrite
    #>
    [CmdletBinding()]
    param($Request, $TriggerMetadata)

    $APIName = $TriggerMetadata.FunctionName
    $ExecutingUser = $request.headers.'x-ms-client-principal'
    $TenantFilter = $request.Query.tenantFilter ?? $Request.Body.tenantFilter
    Write-LogMessage -user $ExecutingUser -API $APINAME -message 'Accessed this API' -Sev 'Debug'

    try {
        $Type = $Request.Query.Type ?? $Request.Body.Type
        $Guid = $Request.Query.GUID ?? $Request.Body.GUID
        $Params = @{ Identity = $Guid }

        $null = New-ExoRequest -tenantid $TenantFilter -cmdlet "Remove-$($Type)Connector" -cmdParams $params -useSystemMailbox $true
        $Result = "Deleted Connector: $($Guid)"
        Write-LogMessage -user $ExecutingUser -API $APIName -tenant $TenantFilter -message "Deleted connector $($Guid)" -sev Debug
        $StatusCode = [HttpStatusCode]::OK
    } catch {
        $ErrorMessage = Get-CippException -Exception $_
        Write-LogMessage -user $ExecutingUser -API $APIName -tenant $TenantFilter -message "Failed deleting connector $($Guid). Error:$($ErrorMessage.NormalizedError)" -Sev Error -LogData $ErrorMessage
        $Result = $ErrorMessage.NormalizedError
        $StatusCode = [HttpStatusCode]::Forbidden
    }
    # Associate values to output bindings by calling 'Push-OutputBinding'.
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = $StatusCode
            Body       = @{Results = $Result }
        })

}
