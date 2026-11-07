param([int]$Port = 8080)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}
. (Join-Path $PSScriptRoot 'local-store.ps1')

$origin = "http://localhost:$Port"
$contentTypes = @{ '.html' = 'text/html; charset=utf-8'; '.js' = 'application/javascript; charset=utf-8' }

function Send-Response($context, $status, $body, $contentType) {
    $bytes = [Text.Encoding]::UTF8.GetBytes($body)
    $context.Response.StatusCode = $status
    $context.Response.ContentType = $contentType
    $context.Response.Headers['Cache-Control'] = 'no-store'
    $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $context.Response.Close()
}

function Send-Json($context, $status, $data) {
    $json = if ($null -eq $data) { 'null' } else { ConvertTo-Json -InputObject $data -Depth 10 -Compress }
    Send-Response $context $status $json 'application/json; charset=utf-8'
}

function Read-Body($request) {
    $reader = New-Object IO.StreamReader($request.InputStream, [Text.Encoding]::UTF8)
    $text = $reader.ReadToEnd()
    if (-not $text.Trim()) { return $null }
    $parsed = ConvertFrom-Json -InputObject $text
    return $parsed
}

function Find-Demand($list, $id) {
    foreach ($row in $list) { if ("$($row.id)" -eq "$id") { return $row } }
    return $null
}

function Invoke-Api($context, $method, $path) {
    if ($path -eq '/api/demands') {
        if ($method -eq 'GET') { $list = Read-LocalDemands; return Send-Json $context 200 $list }
        if ($method -eq 'POST') {
            $list = Read-LocalDemands
            $created = @(foreach ($values in @(Read-Body $context.Request)) { New-LocalDemand $list $values })
            Write-LocalDemands $list
            return Send-Json $context 201 $created
        }
    }
    if ($path -match '^/api/demands/(\d+)$') {
        $list = Read-LocalDemands
        $row = Find-Demand $list $Matches[1]
        if (-not $row) { return Send-Json $context 404 @{ error = 'Demand not found' } }
        if ($method -eq 'PATCH') {
            $values = Read-Body $context.Request
            if ($values) { Set-RowValues $row $values }
            Write-LocalDemands $list
            return Send-Json $context 200 $row
        }
        if ($method -eq 'DELETE') {
            [void]$list.Remove($row)
            Write-LocalDemands $list
            return Send-Json $context 200 $row
        }
    }
    Send-Json $context 404 @{ error = 'Not found' }
}

function Invoke-Request($context) {
    $request = $context.Request
    $method = $request.HttpMethod
    $path = $request.Url.AbsolutePath

    if ($path.StartsWith('/api/')) {
        $requestOrigin = $request.Headers['Origin']
        if ($method -ne 'GET' -and $requestOrigin -and $requestOrigin -ne $origin) {
            return Send-Json $context 403 @{ error = 'Forbidden' }
        }
        return Invoke-Api $context $method $path
    }

    if ($path -eq '/') { $path = '/index.html' }
    if ($method -eq 'GET' -and $path -match '^/([A-Za-z0-9_-]+(\.html|\.js))$') {
        $file = Join-Path $PSScriptRoot $Matches[1]
        if (Test-Path $file -PathType Leaf) {
            return Send-Response $context 200 ([IO.File]::ReadAllText($file, [Text.Encoding]::UTF8)) $contentTypes[$Matches[2]]
        }
    }
    Send-Response $context 404 'Not found' 'text/plain; charset=utf-8'
}

$listener = New-Object Net.HttpListener
$listener.Prefixes.Add("$origin/")
$listener.Start()
Write-Output "Demand board running at $origin/index.html"
Write-Output "Data file: $localDataFile"
Write-Output 'Press Ctrl+C to stop.'

try {
    while ($listener.IsListening) {
        $task = $listener.GetContextAsync()
        while (-not $task.AsyncWaitHandle.WaitOne(500)) {}
        $context = $task.GetAwaiter().GetResult()
        try { Invoke-Request $context }
        catch {
            Write-Warning "$($context.Request.HttpMethod) $($context.Request.Url.AbsolutePath): $_"
            try { Send-Json $context 500 @{ error = "$_" } } catch {}
        }
    }
} finally {
    $listener.Stop()
}
