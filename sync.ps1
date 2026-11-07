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
$useLocalStorage = "$($envValues['STORAGE'])".Trim().ToLower() -eq 'local'
if ($useLocalStorage) { . (Join-Path $PSScriptRoot 'local-store.ps1') }

$required = @()
if (-not ($Demo -or $RemoveDemo)) { $required += @('ODATA_BASE_URL', 'ODATA_USER', 'ODATA_PASS') }
if (-not $Inspect -and -not $useLocalStorage) { $required += @('SUPABASE_URL', 'SUPABASE_SERVICE_KEY') }
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
$odataVersionSetting = Get-Setting 'ODATA_VERSION' ''
$createdField = Get-Setting 'SMAX_CREATED_FIELD' 'CreateTime'
$customFilter = Get-Setting 'SMAX_FILTER' ''
$personEntity = Get-Setting 'SMAX_PERSON_ENTITY' 'Person'
$personNameField = Get-Setting 'SMAX_PERSON_NAME_FIELD' 'Name'
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
    $script:lastResponseHeaders = $response.Headers
    $text = [Text.Encoding]::UTF8.GetString($response.RawContentStream.ToArray())
    if (-not $text) { return }
    $contentType = "$($response.Headers['Content-Type'])"
    $script:lastWasXml = $contentType -match 'xml' -or $text.TrimStart().StartsWith('<')
    try {
        if ($script:lastWasXml) { return ConvertFrom-ODataXml $text }
        return $text | ConvertFrom-Json
    } catch {
        $preview = ($text -replace '\s+', ' ').Trim()
        if ($preview.Length -gt 300) { $preview = $preview.Substring(0, 300) + '...' }
        $finalUrl = $response.BaseResponse.ResponseUri.AbsoluteUri
        throw "Unreadable response: $method $uri`n  $($_.Exception.Message)`n  Status: $($response.StatusCode)  Content-Type: $contentType`n  Final URL: $finalUrl`n  Starts with: $preview"
    }
}

function ConvertFrom-AtomEntry($entry) {
    $obj = [ordered]@{}
    $props = $entry.SelectSingleNode("*[local-name()='content']/*[local-name()='properties']")
    if (-not $props) { $props = $entry.SelectSingleNode("*[local-name()='properties']") }
    if ($props) {
        foreach ($p in $props.ChildNodes) {
            if ($p.NodeType -ne 'Element') { continue }
            $isNull = $p.Attributes | Where-Object { $_.LocalName -eq 'null' -and $_.Value -eq 'true' }
            $obj[$p.LocalName] = if ($isNull) { $null } else { $p.InnerText }
        }
    }
    foreach ($link in $entry.SelectNodes("*[local-name()='link']")) {
        $inline = $link.SelectSingleNode("*[local-name()='inline']")
        if (-not $inline) { continue }
        $name = $link.GetAttribute('title')
        if (-not $name) { $name = ($link.GetAttribute('rel') -split '/')[-1] }
        $innerFeed = $inline.SelectSingleNode("*[local-name()='feed']")
        $innerEntries = if ($innerFeed) { $innerFeed.SelectNodes("*[local-name()='entry']") } else { $inline.SelectNodes("*[local-name()='entry']") }
        $converted = @($innerEntries | ForEach-Object { ConvertFrom-AtomEntry $_ })
        $obj[$name] = if ($innerFeed) { $converted } elseif ($converted.Count) { $converted[0] } else { $null }
    }
    return [pscustomobject]$obj
}

function ConvertFrom-ODataXml($text) {
    $xml = New-Object System.Xml.XmlDocument
    $xml.LoadXml($text)
    $root = $xml.DocumentElement
    switch ($root.LocalName) {
        'feed' {
            $entries = @($root.SelectNodes("*[local-name()='entry']") | ForEach-Object { ConvertFrom-AtomEntry $_ })
            $next = $root.SelectSingleNode("*[local-name()='link'][@rel='next']")
            return [pscustomobject]@{ value = $entries; '@odata.nextLink' = $(if ($next) { $next.GetAttribute('href') } else { $null }) }
        }
        'entry' { return [pscustomobject]@{ value = @(ConvertFrom-AtomEntry $root) } }
        'service' {
            $sets = @($root.SelectNodes("//*[local-name()='collection']") | ForEach-Object { $_.GetAttribute('href') })
            return [pscustomobject]@{ value = @(); entitySets = $sets }
        }
        default { throw "Unexpected XML (root element '$($root.LocalName)')" }
    }
}

function Get-ODataPage($data) {
    if ($null -ne $data.d) {
        if ($null -ne $data.d.results) { return @{ items = @($data.d.results); next = $data.d.__next } }
        return @{ items = @($data.d); next = $null }
    }
    return @{ items = @($data.value); next = $data.'@odata.nextLink' }
}

function Get-ODataVersion {
    if ($odataVersionSetting) { return $odataVersionSetting }
    Invoke-Json ("$odataBaseUrl/$entity" + '?$top=1') 'GET' $smaxHeaders | Out-Null
    $headers = $script:lastResponseHeaders
    if ($headers['OData-Version']) { return '4' }
    if ($headers['DataServiceVersion'] -or $script:lastWasXml) { return '2' }
    return '4'
}

function ConvertTo-IsoDate($value) {
    if ($null -eq $value -or "$value" -eq '') { return $null }
    if ("$value" -match '^\d+$') {
        return [DateTimeOffset]::FromUnixTimeMilliseconds([long]$value).UtcDateTime.ToString('o')
    }
    if ("$value" -match '^/Date\((-?\d+)') {
        return [DateTimeOffset]::FromUnixTimeMilliseconds([long]$Matches[1]).UtcDateTime.ToString('o')
    }
    if ($value -is [DateTime]) { return $value.ToUniversalTime().ToString('o') }
    $styles = [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal
    try { return [DateTime]::Parse("$value", [Globalization.CultureInfo]::InvariantCulture, $styles).ToString('o') } catch { return $null }
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
    Accept        = 'application/json, application/atom+xml;q=0.9, application/xml;q=0.8'
    Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("$($envValues['ODATA_USER']):$($envValues['ODATA_PASS'])"))
}

function Get-FilterQuery($version) {
    if ($customFilter) { return '&$filter=' + [Uri]::EscapeDataString($customFilter) }
    if (-not $filterKeyword) { return '' }
    $keyword = $filterKeyword.Replace("'", "''")
    $filter = if ($version -eq '2') { "substringof('$keyword',DisplayLabel)" } else { "contains(DisplayLabel,'$keyword')" }
    return '&$filter=' + [Uri]::EscapeDataString($filter)
}

function Get-SmaxRequests {
    $version = Get-ODataVersion
    $select = New-Object System.Collections.Generic.List[string]
    $expand = New-Object System.Collections.Generic.List[string]
    foreach ($field in @('Id', 'DisplayLabel', $createdField, $statusField, $assigneeField, $appField)) {
        if (-not $field) { continue }
        $parts = $field.Split('/', 2)
        if ($parts.Count -eq 2 -and $version -eq '2') {
            $select.Add($field)
            if (-not $expand.Contains($parts[0])) { $expand.Add($parts[0]) }
            continue
        }
        if (-not $select.Contains($parts[0])) { $select.Add($parts[0]) }
        if ($parts.Count -eq 2) { $expand.Add("$($parts[0])(`$select=$($parts[1]))") }
    }

    $url = "$odataBaseUrl/$entity" + '?$select=' + ($select -join ',')
    if ($expand.Count) { $url += '&$expand=' + ($expand -join ',') }
    $url += Get-FilterQuery $version

    $items = New-Object System.Collections.ArrayList
    for ($page = 0; $url -and $page -lt $maxPages; $page++) {
        $data = Get-ODataPage (Invoke-Json $url 'GET' $smaxHeaders)
        foreach ($item in $data.items) { [void]$items.Add($item) }

        $url = if ($data.next) { ([Uri]::new([Uri]"$odataBaseUrl/", $data.next)).AbsoluteUri } else { $null }
    }
    return $items
}

function Get-PersonNames($ids) {
    $names = @{}
    $ids = @($ids | Where-Object { $_ } | ForEach-Object { "$_" } | Select-Object -Unique)
    for ($i = 0; $i -lt $ids.Count; $i += 15) {
        $chunk = $ids[$i..([Math]::Min($i + 14, $ids.Count - 1))]
        $people = $null
        foreach ($quote in @("'", '')) {
            $filter = ($chunk | ForEach-Object { "Id eq $quote$($_.Replace("'", "''"))$quote" }) -join ' or '
            $url = "$odataBaseUrl/$personEntity" + '?$select=Id,' + $personNameField + '&$filter=' + [Uri]::EscapeDataString($filter)
            try { $people = (Get-ODataPage (Invoke-Json $url 'GET' $smaxHeaders)).items; break } catch { $lookupError = $_ }
        }
        if ($null -eq $people) {
            Write-Warning "Could not look up names in $personEntity, showing IDs instead: $lookupError"
            return $names
        }
        foreach ($person in $people) { $names["$($person.Id)"] = $person.$personNameField }
    }
    return $names
}

function Show-FieldValues($fields) {
    $version = Get-ODataVersion
    $url = "$odataBaseUrl/$entity" + '?$select=' + ($fields -join ',') + '&$top=500' + (Get-FilterQuery $version)
    $items = @((Get-ODataPage (Invoke-Json $url 'GET' $smaxHeaders)).items)
    Write-Output ''
    foreach ($field in $fields) {
        $groups = $items | Group-Object { "$($_.$field)" } | Sort-Object Count -Descending
        Write-Output "Values of $field (in $($items.Count) records): $(($groups | ForEach-Object { "$($_.Name) ($($_.Count))" }) -join ', ')"
    }
}

function Show-SmaxFields {
    try {
        $service = Invoke-Json "$odataBaseUrl/" 'GET' $smaxHeaders
        $sets = if ($service.entitySets) { $service.entitySets }
                elseif ($service.d.EntitySets) { $service.d.EntitySets }
                elseif ($service.value) { $service.value | ForEach-Object { if ($_.url) { $_.url } else { $_.name } } }
        if ($sets) { Write-Output "Entities available (use one as SMAX_ENTITY): $($sets -join ', ')"; Write-Output '' }
    } catch {}

    $version = Get-ODataVersion
    $data = Get-ODataPage (Invoke-Json ("$odataBaseUrl/$entity" + '?$top=3' + (Get-FilterQuery $version)) 'GET' $smaxHeaders)
    $items = @($data.items)
    Write-Output "OData version: $version"
    if (-not $items.Count) { Write-Output "No $entity records returned."; return }

    Write-Output "Fields on $entity (sample values from $($items.Count) records):"
    foreach ($property in $items[0].PSObject.Properties) {
        $samples = $items | ForEach-Object {
            $value = "$($_.($property.Name))"
            if ($value.Length -gt 40) { $value.Substring(0, 40) + '...' } else { $value }
        }
        Write-Output ("  {0,-30} {1}" -f $property.Name, ($samples -join ' | '))
    }

    $statusFields = @('PhaseId', 'Status', $statusField) | Where-Object { $_ -and $items[0].PSObject.Properties[$_] } | Select-Object -Unique
    if ($statusFields) { Show-FieldValues @($statusFields) }
}

function Save-Demands($rows) {
    if (-not @($rows).Count) { return }
    if ($useLocalStorage) { return Save-LocalSmaxRows $rows }
    $headers = Get-SupabaseHeaders
    $headers.Prefer = 'resolution=merge-duplicates,return=minimal'
    Invoke-Json "$supabaseUrl/rest/v1/demands?on_conflict=smax_id" 'POST' $headers (ConvertTo-Json -InputObject @($rows) -Depth 5 -Compress) | Out-Null
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
    Save-Demands @($rows)
    Write-Output "[DEMO] Added $(@($rows).Count) sample demands. Open index.html to see them. Remove with -RemoveDemo."
}

function Remove-DemoDemands {
    if ($useLocalStorage) { Remove-LocalDemoRows }
    else { Invoke-Json "$supabaseUrl/rest/v1/demands?smax_id=like.DEMO-*" 'DELETE' (Get-SupabaseHeaders) | Out-Null }
    Write-Output "[DEMO] Removed the sample demands."
}

try {
    if ($Inspect) { Show-SmaxFields; exit 0 }
    if ($Demo) { Add-DemoDemands; exit 0 }
    if ($RemoveDemo) { Remove-DemoDemands; exit 0 }

    $smaxItems = @(Get-SmaxRequests | Where-Object { $_.Id })
    $unmapped = @{}
    $personNames = @{}
    if ($assigneeField -and -not $assigneeField.Contains('/')) {
        $personNames = Get-PersonNames ($smaxItems | ForEach-Object { Get-FieldValue $_ $assigneeField })
    }

    $rows = foreach ($item in $smaxItems) {
        $smaxId = [string]$item.Id
        $smaxStatus = Get-FieldValue $item $statusField
        $status = $statusMap[(Get-Key $smaxStatus)]
        if (-not $status) {
            $status = 'New'
            if ($smaxStatus) { $unmapped["$smaxStatus"] = $true }
        }
        $created = ConvertTo-IsoDate (Get-FieldValue $item $createdField)
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
            if ($assignee -and $personNames.ContainsKey("$assignee")) { $assignee = $personNames["$assignee"] }
            $row.assigned_developer = if ($assignee) { "$assignee" } else { 'Unassigned' }
        }
        $row
    }
    $rows = @($rows)

    Save-Demands $rows

    $target = if ($useLocalStorage) { "saved to $localDataFile" } else { 'sent to Supabase' }
    Write-Output "[SYNC] $([DateTime]::Now.ToString('s')) - $($rows.Count) demands from SMAX, $target"
    if ($unmapped.Count) {
        Write-Warning "These SMAX statuses have no board column and were put under New. Add them to SMAX_STATUS_MAP: $($unmapped.Keys -join ', ')"
    }
} catch {
    Write-Error "[SYNC] Failed: $_"
    exit 1
}
