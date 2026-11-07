$localDataDir = Join-Path $PSScriptRoot 'local-data'
$localDataFile = Join-Path $localDataDir 'demands.json'

function Read-LocalDemands {
    $list = New-Object System.Collections.ArrayList
    if (-not (Test-Path $localDataFile)) { return ,$list }
    $text = [IO.File]::ReadAllText($localDataFile, [Text.Encoding]::UTF8)
    if (-not $text.Trim()) { return ,$list }
    foreach ($row in (ConvertFrom-Json -InputObject $text)) { [void]$list.Add($row) }
    return ,$list
}

function Write-LocalDemands($list) {
    New-Item -ItemType Directory -Force $localDataDir | Out-Null
    $json = if ($list.Count) { ConvertTo-Json -InputObject @($list) -Depth 10 } else { '[]' }
    $temp = "$localDataFile.tmp"
    [IO.File]::WriteAllText($temp, $json, (New-Object Text.UTF8Encoding $false))
    Move-Item -Force $temp $localDataFile
}

function Set-RowValues($row, $values) {
    foreach ($property in $values.PSObject.Properties) {
        if ($row.PSObject.Properties[$property.Name]) { $row.($property.Name) = $property.Value }
        else { $row | Add-Member -NotePropertyName $property.Name -NotePropertyValue $property.Value }
    }
}

function Get-NextLocalId($list) {
    $max = 0
    foreach ($row in $list) { if ([long]$row.id -gt $max) { $max = [long]$row.id } }
    return $max + 1
}

function New-LocalDemand($list, $values) {
    $row = [pscustomobject][ordered]@{
        id = Get-NextLocalId $list; ref_id = $null; title = ''; department = $null; requester = $null
        status = 'New'; priority = 'Medium'; assigned_developer = $null; estimated_days = 1; due_date = $null
        created_at = [DateTime]::UtcNow.ToString('o'); smax_id = $null; smax_status = $null
        priority_answers = $null; priority_score = $null; priority_evaluated_at = $null
    }
    Set-RowValues $row $values
    [void]$list.Add($row)
    return $row
}

function Save-LocalSmaxRows($rows) {
    $list = Read-LocalDemands
    $bySmaxId = @{}
    foreach ($row in $list) { if ($row.smax_id) { $bySmaxId["$($row.smax_id)"] = $row } }
    foreach ($values in $rows) {
        $values = [pscustomobject]$values
        $existing = $bySmaxId["$($values.smax_id)"]
        if ($existing) { Set-RowValues $existing $values }
        else { $bySmaxId["$($values.smax_id)"] = New-LocalDemand $list $values }
    }
    Write-LocalDemands $list
}

function Remove-LocalDemoRows {
    $list = Read-LocalDemands
    $kept = New-Object System.Collections.ArrayList
    foreach ($row in $list) { if (-not "$($row.smax_id)".StartsWith('DEMO-')) { [void]$kept.Add($row) } }
    Write-LocalDemands $kept
}
