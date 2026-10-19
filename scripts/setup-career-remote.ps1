param([switch]$Enable)
$ErrorActionPreference = 'Stop'
$command = Get-Command tailscale -ErrorAction SilentlyContinue
$binary = if ($command) { $command.Source } else { Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe' }
if (!(Test-Path -LiteralPath $binary)) {
    Write-Output '尚未安装 Tailscale。请从 https://tailscale.com/download/windows 安装官方客户端，然后在电脑和 iPhone 登录同一账号。'
    exit 1
}
if (!$Enable) {
    & $binary status
    Write-Output '登录完成后运行 powershell -File scripts/setup-career-remote.ps1 -Enable，只将个人求职服务发布到自己的 tailnet。'
    exit
}
& $binary serve --bg http://127.0.0.1:4176
if ($LASTEXITCODE -ne 0) { throw 'Tailscale Serve 尚未配置成功，请先完成账号登录和 HTTPS 配置。' }
& $binary serve status
Write-Output '将上方 HTTPS 地址和 data/career-private/token.txt 中的个人服务令牌填写到 App 的求职更新设置。不要配置 Funnel 公网发布。'
