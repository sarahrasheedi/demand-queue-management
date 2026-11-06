param([switch]$Inspect, [switch]$Demo, [switch]$RemoveDemo)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}

function Read-EnvFile($path) {
    $values = @{}
    if (Test-Path $path) {
        foreach ($line in Get-Content -Path $path -Encoding UTF8) {
            if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$') {
                $values[$Matches[1]] = $Matches[2].Trim().Trim('"').Trim("'")
            }
        }
    }
    return $values
}

$envValues = Read-EnvFile (Join-Path $PSScriptRoot '.env.local')

$required = @()
if (-not ($Demo -or $RemoveDemo)) { $required += @('ODATA_BASE_URL', 'ODATA_USER', 'ODATA_PASS') }
if (-not $Inspect) { $required += @('SUPABASE_URL', 'SUPABASE_SERVICE_KEY') }
$missing = $required | Where-Object { -not $envValues[$_] }
if ($missing) {
    Write-Error "Missing values in .env.local: $($missing -join ', ')"
    exit 1
}

function Get-Setting($name, $default) {
    if ($envValues[$name]) { return $envValues[$name] } else { return $default }
}

$odataBaseUrl = "$($envValues['ODATA_BASE_URL'])".TrimEnd('/')
$supabaseUrl = "$($envValues['SUPABASE_URL'])".TrimEnd('/')
$supabaseKey = $envValues['SUPABASE_SERVICE_KEY']
$entity = Get-Setting 'SMAX_ENTITY' 'Request'
$filterKeyword = Get-Setting 'SMAX_FILTER_KEYWORD' ''
$statusField = Get-Setting 'SMAX_STATUS_FIELD' 'PhaseId'
$assigneeField = Get-Setting 'SMAX_ASSIGNEE_FIELD' ''
$appField = Get-Setting 'SMAX_APP_FIELD' ''
$appName = Get-Setting 'SMAX_APP_NAME' 'General'
$maxPages = 50

$boardStatuses = @('New', 'Requirement Gathering', 'Solution Design', 'Development', 'Testing', 'Deployment', 'Live')

function Get-Key($text) { return ("$text" -replace '[^A-Za-z0-9]', '').ToLower() }

$statusMap = @{}
foreach ($status in $boardStatuses) { $statusMap[(Get-Key $status)] = $status }
foreach ($pair in (Get-Setting 'SMAX_STATUS_MAP' '').Split(';')) {
    $parts = $pair.Split('=', 2)
    if ($parts.Count -eq 2 -and $parts[0].Trim()) {
        $target = $boardStatuses | Where-Object { (Get-Key $_) -eq (Get-Key $parts[1]) }
        if ($target) { $statusMap[(Get-Key $parts[0])] = $target }
        else { Write-Warning "SMAX_STATUS_MAP: '$($parts[1].Trim())' is not a board status" }
    }
}

function Invoke-Json($uri, $method = 'GET', $headers = @{}, $body = $null) {
    $params = @{ Uri = $uri; Method = $method; Headers = $headers; UseBasicParsing = $true; UserAgent = 'demand-queue-sync/1.0' }
    if ($body) {
        $params.Body = [Text.Encoding]::UTF8.GetBytes($body)
        $params.ContentType = 'application/json; charset=utf-8'
    }
    try {
        $response = Invoke-WebRequest @params
    } catch {
        $detail = $_.ErrorDetails.Message
        if (-not $detail -and $_.Exception.Response) {
            try {
                $reader = New-Object IO.StreamReader($_.Exception.Response.GetResponseStream(), [Text.Encoding]::UTF8)
                $detail = $reader.ReadToEnd()
            } catch {}
        }
        if ($detail -and $detail.Length -gt 500) { $detail = $detail.Substring(0, 500) }
        throw "Request failed: $method $uri - $($_.Exception.Message) $detail"
    }
    $text = [Text.Encoding]::UTF8.GetString($response.RawContentStream.ToArray())
    if ($text) { return $text | ConvertFrom-Json }
}

function ConvertTo-IsoDate($value) {
    if ($null -eq $value -or "$value" -eq '') { return $null }
    if ("$value" -match '^\d+$') {
        return [DateTimeOffset]::FromUnixTimeMilliseconds([long]$value).UtcDateTime.ToString('o')
    }
    try { return ([DateTime]$value).ToUniversalTime().ToString('o') } catch { return $null }
}

function Get-FieldValue($item, $path) {
    if (-not $path) { return $null }
    $value = $item
    foreach ($part in $path.Split('/')) {
        if ($null -eq $value) { return $null }
        if ($value -is [array]) { $value = $value | Select-Object -First 1 }
        $value = $value.$part
    }
    return $value
}

$smaxHeaders = @{
    Accept        = 'application/json'
    Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("$($envValues['ODATA_USER']):$($envValues['ODATA_PASS'])"))
}

function Get-FilterQuery {
    if (-not $filterKeyword) { return '' }
    $filter = "contains(DisplayLabel,'$($filterKeyword.Replace("'", "''"))')"
    return '&$filter=' + [Uri]::EscapeDataString($filter)
}

function Get-SmaxRequests {
    $select = New-Object System.Collections.Generic.List[string]
    $expand = New-Object System.Collections.Generic.List[string]
    foreach ($field in @('Id', 'DisplayLabel', 'CreatedDate', $statusField, $assigneeField, $appField)) {
        if (-not $field) { continue }
        $parts = $field.Split('/', 2)
        if (-not $select.Contains($parts[0])) { $select.Add($parts[0]) }
        if ($parts.Count -eq 2) { $expand.Add("$($parts[0])(`$select=$($parts[1]))") }
    }

    $url = "$odataBaseUrl/$entity" + '?$select=' + ($select -join ',')
    if ($expand.Count) { $url += '&$expand=' + ($expand -join ',') }
    $url += Get-FilterQuery

    $items = New-Object System.Collections.ArrayList
    for ($page = 0; $url -and $page -lt $maxPages; $page++) {
        $data = Invoke-Json $url 'GET' $smaxHeaders
        foreach ($item in $data.value) { [void]$items.Add($item) }

        $next = $data.'@odata.nextLink'
        $url = if ($next) { ([Uri]::new([Uri]"$odataBaseUrl/", $next)).AbsoluteUri } else { $null }
    }
    return $items
}

function Show-SmaxFields {
    $data = Invoke-Json ("$odataBaseUrl/$entity" + '?$top=3' + (Get-FilterQuery)) 'GET' $smaxHeaders
    $items = @($data.value)
    if (-not $items.Count) { Write-Output "No $entity records returned."; return }

    Write-Output "Fields on $entity (sample values from $($items.Count) records):"
    foreach ($property in $items[0].PSObject.Properties) {
        $samples = $items | ForEach-Object {
            $value = "$($_.($property.Name))"
            if ($value.Length -gt 40) { $value.Substring(0, 40) + '...' } else { $value }
        }
        Write-Output ("  {0,-30} {1}" -f $property.Name, ($samples -join ' | '))
    }
}

function Get-SupabaseHeaders {
    $headers = @{ apikey = $supabaseKey }
    if ($supabaseKey.StartsWith('eyJ')) { $headers.Authorization = "Bearer $supabaseKey" }
    return $headers
}

function Add-DemoDemands {
    $samples = @(
        @('New', 'Tahani', 'Rahabah'), @('Requirement Gathering', 'Moaid', 'Rahabah'),
        @('Solution Design', 'Tahani', 'Portal'), @('Development', 'Moaid', 'Rahabah'),
        @('Testing', 'Tahani', 'Portal'), @('Deployment', 'Unassigned', 'Rahabah'), @('Live', 'Moaid', 'Portal')
    )
    $rows = for ($i = 0; $i -lt $samples.Count; $i++) {
        [ordered]@{
            smax_id            = "DEMO-$($i + 1)"
            ref_id             = "DEMO-$($i + 1)"
            title              = "Demo demand $($i + 1) - $($samples[$i][0])"
            smax_status        = 'Demo'
            status             = $samples[$i][0]
            department         = $samples[$i][2]
            created_at         = [DateTime]::UtcNow.AddDays(-$i).ToString('o')
            assigned_developer = $samples[$i][1]
        }
    }
    $headers = Get-SupabaseHeaders
    $headers.Prefer = 'resolution=merge-duplicates,return=minimal'
    Invoke-Json "$supabaseUrl/rest/v1/demands?on_conflict=smax_id" 'POST' $headers (ConvertTo-Json -InputObject @($rows) -Depth 5 -Compress) | Out-Null
    Write-Output "[DEMO] Added $(@($rows).Count) sample demands. Open index.html to see them. Remove with -RemoveDemo."
}

function Remove-DemoDemands {
    Invoke-Json "$supabaseUrl/rest/v1/demands?smax_id=like.DEMO-*" 'DELETE' (Get-SupabaseHeaders) | Out-Null
    Write-Output "[DEMO] Removed the sample demands."
}

try {
    if ($Inspect) { Show-SmaxFields; exit 0 }
    if ($Demo) { Add-DemoDemands; exit 0 }
    if ($RemoveDemo) { Remove-DemoDemands; exit 0 }

    $smaxItems = @(Get-SmaxRequests | Where-Object { $_.Id })
    $unmapped = @{}

    $rows = foreach ($item in $smaxItems) {
        $smaxId = [string]$item.Id
        $smaxStatus = Get-FieldValue $item $statusField
        $status = $statusMap[(Get-Key $smaxStatus)]
        if (-not $status) {
            $status = 'New'
            if ($smaxStatus) { $unmapped["$smaxStatus"] = $true }
        }
        $created = ConvertTo-IsoDate $item.CreatedDate
        $app = if ($appField) { Get-FieldValue $item $appField } else { $appName }

        $row = [ordered]@{
            smax_id     = $smaxId
            ref_id      = "SMAX-$smaxId"
            title       = if ($item.DisplayLabel) { $item.DisplayLabel } else { 'Untitled request' }
            smax_status = if ($smaxStatus) { "$smaxStatus" } else { $null }
            status      = $status
            department  = if ($app) { "$app" } else { 'General' }
            created_at  = if ($created) { $created } else { [DateTime]::UtcNow.ToString('o') }
        }
        if ($assigneeField) {
            $assignee = Get-FieldValue $item $assigneeField
            $row.assigned_developer = if ($assignee) { "$assignee" } else { 'Unassigned' }
        }
        $row
    }
    $rows = @($rows)

    if ($rows.Count) {
        $headers = Get-SupabaseHeaders
        $headers.Prefer = 'resolution=merge-duplicates,return=minimal'
        Invoke-Json "$supabaseUrl/rest/v1/demands?on_conflict=smax_id" 'POST' $headers (ConvertTo-Json -InputObject $rows -Depth 5 -Compress) | Out-Null
    }

    Write-Output "[SYNC] $([DateTime]::Now.ToString('s')) - $($rows.Count) demands from SMAX"
    if ($unmapped.Count) {
        Write-Warning "These SMAX statuses have no board column and were put under New. Add them to SMAX_STATUS_MAP: $($unmapped.Keys -join ', ')"
    }
} catch {
    Write-Error "[SYNC] Failed: $_"
    exit 1
}
