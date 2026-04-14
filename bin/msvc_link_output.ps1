#!/usr/bin/env pwsh
# MSVC link.exe の出力を UTF-8 に正規化してそのまま流す
# Normalize MSVC link.exe output to UTF-8 and pass it through unchanged

# [Console]::InputEncoding / OutputEncoding は変更しない。
# stdin をシステムの ANSI コードページで読み、stdout を UTF-8 (BOM なし) として書く。
# link.exe の出力エンコーディングは Windows の ANSI コードページ (GetACP()) に従う。
if ($PSVersionTable.PSEdition -eq 'Core') {
    # .NET Core: Encoding.Default が UTF-8 のため ANSICodePage から明示取得し登録
    [System.Text.Encoding]::RegisterProvider([System.Text.CodePagesEncodingProvider]::Instance)
    $ansiEncoding = [System.Text.Encoding]::GetEncoding(
        [System.Globalization.CultureInfo]::CurrentCulture.TextInfo.ANSICodePage
    )
} else {
    # .NET Framework: Encoding.Default が GetACP() ベースのシステム ANSI エンコーディング
    $ansiEncoding = [System.Text.Encoding]::Default
}
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

$reader = $null
$writer = $null
try {
    $reader = [System.IO.StreamReader]::new(
        [Console]::OpenStandardInput(), $ansiEncoding, $false, 4096, $true
    )
    $writer = [System.IO.StreamWriter]::new(
        [Console]::OpenStandardOutput(), $utf8NoBom, 4096, $true
    )
    $writer.NewLine   = "`n"    # 下流の bash/grep に LF で渡す
    $writer.AutoFlush = $true   # パイプ詰まりを防ぐ

    while ($true) {
        $line = $reader.ReadLine()
        if ($null -eq $line) { break }
        $writer.WriteLine($line)
    }
} finally {
    if ($null -ne $writer) { $writer.Dispose() }
    if ($null -ne $reader) { $reader.Dispose() }
}
