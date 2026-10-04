#!/usr/bin/env pwsh
# MSVC 並列コンパイルスクリプト
# 複数ソースファイルを一度に cl.exe に渡し、MSYS プロセス起動オーバーヘッドを削減する
#
# /sourceDependencies <dir> を使用して依存関係を JSON で生成する
# - ロケール非依存 (日本語/英語の正規表現が不要)
# - stdout が軽量化 (インクルード情報が stdout に流れない)
# - /MP との併用が可能 (ディレクトリ引数を使用するため競合しない)
# - Visual Studio 2022 以降が必須
#
# 使用方法:
#   powershell -NoProfile -ExecutionPolicy Bypass -File msvc_compile.ps1 `
#       -Compiler "cl" -Flags "/EHsc /MP /FS" -ObjDir "obj/md" `
#       -Sources "foo.c bar.c baz.c" [-ExtraFlags "-D_IN_TEST_SRC"]

param(
    [string]$Compiler = "cl",
    [string]$Flags = "",
    [string]$ObjDir = "obj",
    [string]$Sources = "",
    [string]$ExtraFlags = "",
    [string]$WorkspaceDir = "",
    [switch]$DryRun
)

. "$PSScriptRoot/_msvc_utils.ps1"

# cl.exe の出力は現在のコンソール出力コード ページでデコードする。
$consoleOutputEncoding = Get-ConsoleOutputEncoding
$utf8NoBom = Get-Utf8NoBomEncoding

# 単一の実在パス、または空白を含む項目を引用したソース一覧を受け取る。
if ([string]::IsNullOrWhiteSpace($Sources)) {
    exit 0
}
if (Test-Path -LiteralPath $Sources -PathType Leaf) {
    $sourceList = @($Sources)
}
else {
    $sourceList = @(Split-MsvcCommandLineTokens -Line $Sources | ForEach-Object { $_.Trim('"') })
}

if ($sourceList.Count -eq 0) {
    exit 0
}

# ObjDir が存在しなければ作成
if (-not (Test-Path $ObjDir)) {
    New-Item -ItemType Directory -Path $ObjDir -Force | Out-Null
}

# 引用符直前のバックスラッシュによるエスケープを避け、末尾の / でディレクトリを指定する。
# see: https://learn.microsoft.com/en-us/cpp/build/reference/fo-object-file-name
$objDirRsp = $ObjDir.Replace('\', '/').TrimEnd('/') + '/'

# レスポンスファイルを作成 (並列ビルド対応で一意のファイル名を使用)
$rspFile = Join-Path $ObjDir "msvc_compile_$([guid]::NewGuid().ToString('N').Substring(0,8)).rsp"

# レスポンスファイルの内容を構築
$rspContent = @()

# 引用されたパスを分割せず、呼び出し元のフラグ文字列をそのまま渡す。
$rspContent += "$Flags $ExtraFlags".Trim()

# コンパイルオプション
$rspContent += "/c"
$rspContent += ('/Fo:"{0}"' -f $objDirRsp)
# /sourceDependencies <dir> でロケール非依存の JSON 依存関係ファイルを生成
# response file では 1 引数として渡さないと cl.exe が引数不足と解釈する
$rspContent += ('/sourceDependencies "{0}"' -f $objDirRsp)

# ソースファイルを追加
$rspContent += @($sourceList | ForEach-Object { '"{0}"' -f $_.Replace('\', '/') })

# レスポンスファイルを書き出し (UTF-8 BOM なし)
[System.IO.File]::WriteAllLines($rspFile, $rspContent, $utf8NoBom)

# 従来の cl コマンド風表示を保ちつつ、CI の 1 行制限に当たらないよう複数行に分割
$outputRecords = [System.Collections.Generic.List[object]]::new()
foreach ($record in (New-MsvcCommandDisplayRecords -Tokens @($Compiler, "@$rspFile") -ExpandResponseFiles)) {
    $outputRecords.Add($record)
}

if ($DryRun) {
    Write-MsvcOutputRecords -Records $outputRecords.ToArray()
    exit 0
}

# コンパイル実行して出力をキャプチャ
# fatal error C1060: のときは内部で待ち時間をずらして再試行する。
# 最後の試行の出力だけを以降の診断処理へ渡す。
$run = Invoke-MsvcCompilerWithHeapRetry -SourceList $sourceList -CompileOnce {
    Invoke-MsvcCompilerProcess `
        -FileName $Compiler `
        -Arguments ('@"{0}"' -f $rspFile) `
        -OutputEncoding $consoleOutputEncoding `
        -WorkingDirectory (Get-Location).Path
}
$compileExitCode = $run.ExitCode
$output = $run.Output

# ソースファイルごとに警告を収集
# /sourceDependencies 使用時は "Note: including file:" 行が出ないため、
# ソース名と警告/エラー行のみを抽出する
$currentSource = $null
$warnings = @{}  # source -> warning lines のハッシュテーブル

foreach ($line in $output -split "`r?`n") {
    $trimmedLine = $line.Trim()

    # ソースファイル名の行を検出 (拡張子のみの行)
    foreach ($src in $sourceList) {
        if ($trimmedLine -eq $src -or $trimmedLine -eq [System.IO.Path]::GetFileName($src)) {
            $currentSource = $src
            break
        }
    }

    # 警告/エラー行を出力 (インクルード行は出ないため全行が診断対象)
    # $currentSource が null の段階 (ソースファイル名行より前) のエラーも出力する
    if ($trimmedLine -ne "") {
        $isSourceName = $false
        foreach ($src in $sourceList) {
            if ($trimmedLine -eq $src -or $trimmedLine -eq [System.IO.Path]::GetFileName($src)) {
                $isSourceName = $true
                break
            }
        }
        if (-not $isSourceName) {
            # MSVC 診断メッセージのファイルパスをフルパスに変換 (VS Code でクリック可能にする)
            $outputLine = Resolve-MsvcDiagnosticPath $trimmedLine

            $record = ConvertTo-MsvcOutputRecord -Line $outputLine
            $outputRecords.Add($record)
            $kind = $record.Kind
            if ($kind -eq 'warning' -and $null -ne $currentSource) {
                if (-not $warnings.ContainsKey($currentSource)) {
                    $warnings[$currentSource] = @()
                }
                $warnings[$currentSource] += $outputLine
            }
        }
    }
}

# 8.3 形式の短い名前 (RUNNER~1 など) を含むパスを、長い形式へ展開して返す。
# /sourceDependencies の JSON は長い形式で出力されるため、比較の前に揃える。
# see: https://learn.microsoft.com/en-us/windows/win32/fileio/naming-a-file#short-vs-long-names
function Get-MsvcLongPath {
    param([string]$Path)

    if ($Path -notlike '*~*') {
        return $Path
    }
    try {
        $full = [System.IO.Path]::GetFullPath($Path)
        $root = [System.IO.Path]::GetPathRoot($full)
        $current = $root
        foreach ($part in $full.Substring($root.Length).Split([char[]]@('\', '/'), [System.StringSplitOptions]::RemoveEmptyEntries)) {
            $match = $null
            if ($part -like '*~*') {
                # 検索パターンは短い名前にも一致し、結果は長い形式で返る。
                $match = [System.IO.Directory]::GetFileSystemEntries($current, $part) | Select-Object -First 1
            }
            $current = if ($match) { $match } else { Join-Path $current $part }
        }
        return $current
    }
    catch {
        return $Path
    }
}

# ワークスペースの判定は長い形式で行い、.d には呼び出し元の表記で書き出す。
$workspaceCaller = $WorkspaceDir.Replace('\', '/').TrimEnd('/')
$workspaceLong = $workspaceCaller
if ($WorkspaceDir -ne "") {
    $workspaceLong = (Get-MsvcLongPath $WorkspaceDir).Replace('\', '/').TrimEnd('/')
}

# 各ソースファイルの .d ファイルを JSON から生成
# /sourceDependencies <dir> の出力ファイル名: <ソースファイル名>.json
# 例: foo.cc → <ObjDir>\foo.cc.json
foreach ($src in $sourceList) {
    $srcBaseName = [System.IO.Path]::GetFileName($src)
    $srcNameNoExt = [System.IO.Path]::GetFileNameWithoutExtension($src)
    $objPath = (Join-Path $ObjDir "$srcNameNoExt.obj").Replace('\', '/')
    $dPath = Join-Path $ObjDir "$srcNameNoExt.d"
    $jsonPath = Join-Path $ObjDir "$srcBaseName.json"

    $includes = @()

    if (Test-Path $jsonPath) {
        try {
            $json = Get-Content $jsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $rawIncludes = $json.Data.Includes
            foreach ($inc in $rawIncludes) {
                # 配置先との比較は実パスで行い、その後で make 用に空白を保護する。
                $normalized = $inc.Replace('\', '/')
                # WorkspaceDir が指定されている場合、ワークスペース内のみ追加
                if ($WorkspaceDir -eq "") {
                    $includes += $normalized.Replace(' ', '\ ')
                }
                elseif ($normalized.StartsWith($workspaceLong + '/', [System.StringComparison]::OrdinalIgnoreCase)) {
                    $callerPath = $workspaceCaller + $normalized.Substring($workspaceLong.Length)
                    $includes += $callerPath.Replace(' ', '\ ')
                }
                elseif ($normalized.StartsWith($workspaceCaller + '/', [System.StringComparison]::OrdinalIgnoreCase)) {
                    $includes += $normalized.Replace(' ', '\ ')
                }
            }
        }
        catch {
            $outputRecords.Add((New-MsvcOutputRecord -Text "Warning: Failed to parse $jsonPath : $_" -Kind 'warning'))
        }
    }

    $sb = [System.Text.StringBuilder]::new()
    $objMakePath = $objPath.Replace(' ', '\ ')
    $srcMakePath = $src.Replace('\', '/').Replace(' ', '\ ')
    [void]$sb.Append("${objMakePath}: ${srcMakePath}")

    foreach ($inc in $includes) {
        [void]$sb.Append(" \`n  ${inc}")
    }
    [void]$sb.Append("`n")

    # 空ルール (ヘッダー削除時のエラー回避)
    foreach ($inc in $includes) {
        [void]$sb.Append("`n${inc}:`n")
    }

    [System.IO.File]::WriteAllText($dPath, $sb.ToString(), $utf8NoBom)

    # .d のタイムスタンプを .obj と同じにする
    if (Test-Path $objPath) {
        $objTime = (Get-Item $objPath).LastWriteTime
        (Get-Item $dPath).LastWriteTime = $objTime
    }

    # .warn ファイルを生成 (警告がなければ削除)
    $warnPath = "$src.warn"
    if ($warnings.ContainsKey($src) -and $warnings[$src].Count -gt 0) {
        [System.IO.File]::WriteAllLines($warnPath, $warnings[$src], $utf8NoBom)
    } else {
        Remove-Item -Path $warnPath -Force -ErrorAction SilentlyContinue
    }
}

if ($compileExitCode -ne 0) {
    $outputRecords.Add((New-MsvcOutputRecord -Text "Compilation failed with exit code $compileExitCode" -Kind 'error'))
}

# 一時ファイルの削除
Remove-Item -Path $rspFile -Force -ErrorAction SilentlyContinue

Write-MsvcOutputRecords -Records $outputRecords.ToArray()

exit $compileExitCode
