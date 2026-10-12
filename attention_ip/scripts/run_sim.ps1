# 仿真脚本 (Windows PowerShell)
# 1) 生成测试向量 -> sim/vectors.txt
# 2) iverilog 编译 RTL + TB
# 3) vvp 运行仿真 -> sim/attention_ip.vcd + 打印比对结果
# 用法: powershell -ExecutionPolicy Bypass -File scripts/run_sim.ps1

$ErrorActionPreference = "Stop"

# 项目根目录 = 本脚本所在目录的上一级
# 说明：请在 attention_ip 目录（或 scripts 目录）下运行此脚本。
if ($PSScriptRoot -and (Test-Path $PSScriptRoot)) {
    $scriptDir = $PSScriptRoot
} else {
    $scriptDir = Get-Location
}
$root  = (Resolve-Path (Join-Path $scriptDir "..")).Path
# 若当前目录即项目根（跑在 attention_ip/ 下），直接把 root 定为当前位置
$rtl   = Join-Path $root "rtl"
$tb    = Join-Path $root "tb"
$sim   = Join-Path $root "sim"
if (-not (Test-Path $rtl)) {
    $root   = Get-Location
    $rtl    = Join-Path $root "rtl"
    $tb     = Join-Path $root "tb"
    $sim    = Join-Path $root "sim"
}

Write-Host ("=== [1/3] 生成测试向量  root=" + $root) -ForegroundColor Cyan
python (Join-Path $root "scripts\gen_vectors.py")
if ($LASTEXITCODE -ne 0) { Write-Host "向量生成失败"; exit 1 }

Write-Host "=== [2/3] 编译 (iverilog) ===" -ForegroundColor Cyan
iverilog -g2012 -o (Join-Path $sim "attention_ip.tb.vvp") (Join-Path $rtl "attention_ip.v") (Join-Path $tb "tb_attention_ip.v")
if ($LASTEXITCODE -ne 0) { Write-Host "编译失败"; exit 1 }

Write-Host "=== [3/3] 运行仿真 ===" -ForegroundColor Cyan
Push-Location $sim
vvp attention_ip.tb.vvp
Pop-Location

Write-Host ("完成。波形: " + (Join-Path $sim "attention_ip.vcd")) -ForegroundColor Green