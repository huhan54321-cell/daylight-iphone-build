$ErrorActionPreference = 'Stop'
[Console]::InputEncoding = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
try {
    $inputData = [Console]::In.ReadToEnd() | ConvertFrom-Json
    if ($inputData.authorization -notmatch '^Bearer .+' -or -not $inputData.body -or $inputData.body.Length -gt 1048576) { throw 'Invalid request' }
    $requestOptions = @{
        Method = 'Post'
        Uri = 'https://api.tavily.com/search'
        Headers = @{ Authorization = [string]$inputData.authorization }
        ContentType = 'application/json; charset=utf-8'
        Body = [Text.Encoding]::UTF8.GetBytes([string]$inputData.body)
        TimeoutSec = 28
        UseBasicParsing = $true
    }
    if ($inputData.proxy) { $requestOptions.Proxy = [string]$inputData.proxy }
    $response = Invoke-WebRequest @requestOptions
    if ([Text.Encoding]::UTF8.GetByteCount([string]$response.Content) -gt 2097152) { throw 'Response too large' }
    $result = @{ status = [int]$response.StatusCode; body = [string]$response.Content }
} catch {
    $status = 502
    if ($_.Exception.Response -and $_.Exception.Response.StatusCode) { $status = [int]$_.Exception.Response.StatusCode }
    # Do not return exception details or error response bodies containing credentials.
    $result = @{ status = $status; body = '' }
}
[Console]::Out.Write(($result | ConvertTo-Json -Compress -Depth 3))

