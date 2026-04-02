[CmdletBinding()]
param(
    [string]$WorkRoot = "",
    [string]$OutputDir = "",
    [string]$OllamaRef = "",
    [string]$LlvmMingwVersion = "20240619",
    [string]$GoVersion = "",
    [switch]$SkipCpuBuild,
    [switch]$SkipSyclBuild,
    [switch]$SkipGoBuild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path
$script:Headers = @{
    "User-Agent" = "ipex-llm-ollama-ipex-builder"
    "Accept"     = "application/vnd.github+json"
}

if (-not $WorkRoot) {
    $WorkRoot = Join-Path $script:RepoRoot "_build\ollama-ipex-latest"
}
if (-not $OutputDir) {
    $OutputDir = Join-Path $WorkRoot "dist\windows-amd64"
}

$WorkRoot = [System.IO.Path]::GetFullPath($WorkRoot)
$OutputDir = [System.IO.Path]::GetFullPath($OutputDir)

$DownloadsDir = Join-Path $WorkRoot "downloads"
$SourcesDir = Join-Path $WorkRoot "src"
$ToolsDir = Join-Path $WorkRoot "tools"
$Parallel = [Math]::Max([Environment]::ProcessorCount, 1)

function Write-Step {
    param([string]$Message)
    Write-Host "==> $Message"
}

function Invoke-Checked {
    param(
        [string]$FilePath,
        [string[]]$Arguments,
        [string]$WorkingDirectory = (Get-Location).Path
    )

    Push-Location $WorkingDirectory
    try {
        & $FilePath @Arguments
        if ($LASTEXITCODE -ne 0) {
            $joined = ($Arguments -join " ")
            throw "Command failed ($LASTEXITCODE): $FilePath $joined"
        }
    } finally {
        Pop-Location
    }
}

function Reset-Directory {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Recurse -Force
    }
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
}

function Prepare-OutputDirectory {
    param([string]$Path)

    New-Item -ItemType Directory -Path $Path -Force | Out-Null

    $ollamaLib = Join-Path $Path "lib\ollama"
    if (Test-Path -LiteralPath $ollamaLib) {
        Remove-Item -LiteralPath $ollamaLib -Recurse -Force
    }

    foreach ($name in @("ollama.exe", "ollama_ipex.exe", "build-metadata.json")) {
        $target = Join-Path $Path $name
        if (Test-Path -LiteralPath $target) {
            Remove-Item -LiteralPath $target -Force
        }
    }
}

function Get-FirstChildDirectory {
    param([string]$Path)

    $dir = Get-ChildItem -LiteralPath $Path -Directory | Select-Object -First 1
    if ($null -eq $dir) {
        throw "Expected an extracted source directory under '$Path'."
    }
    return $dir.FullName
}

function Invoke-GitHubJson {
    param([string]$Uri)
    return Invoke-RestMethod -Headers $script:Headers -Uri $Uri
}

function Download-GitHubZipball {
    param(
        [string]$Owner,
        [string]$Repo,
        [string]$Ref,
        [string]$Destination
    )

    Invoke-WebRequest -Headers $script:Headers `
        -Uri "https://api.github.com/repos/$Owner/$Repo/zipball/$Ref" `
        -OutFile $Destination
}

function Expand-Zipball {
    param(
        [string]$ArchivePath,
        [string]$DestinationDirectory
    )

    Reset-Directory $DestinationDirectory
    Expand-Archive -LiteralPath $ArchivePath -DestinationPath $DestinationDirectory
    return Get-FirstChildDirectory $DestinationDirectory
}

function Resolve-VsDevCmd {
    $vsDevCmd = Get-ChildItem "C:\Program Files\Microsoft Visual Studio" `
        -Recurse -Filter "VsDevCmd.bat" -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending |
        Select-Object -First 1 -ExpandProperty FullName

    if (-not $vsDevCmd) {
        throw "VsDevCmd.bat was not found. Install Visual Studio C++ build tools."
    }

    return $vsDevCmd
}

function Resolve-OneApiSetvars {
    $candidates = @(
        "C:\Program Files (x86)\Intel\oneAPI\setvars.bat",
        "C:\Program Files\Intel\oneAPI\setvars.bat"
    )

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    throw "Intel oneAPI setvars.bat was not found."
}

function Import-BatchEnvironment {
    param(
        [string]$BatchFile,
        [string[]]$Arguments = @()
    )

    $argString = ($Arguments -join " ")
    $command = if ($argString) {
        "`"$BatchFile`" $argString >nul && set"
    } else {
        "`"$BatchFile`" >nul && set"
    }

    $output = & cmd.exe /d /s /c $command
    foreach ($line in $output) {
        if ($line -notmatch "^(.*?)=(.*)$") {
            continue
        }

        $name = $matches[1]
        $value = $matches[2]
        if (-not $name -or $name.StartsWith("=")) {
            continue
        }

        Set-Item -Path "Env:$name" -Value $value
    }
}

function Normalize-GoVersion {
    param([string]$VersionText)

    $version = $VersionText.Trim()
    if ($version -match "^\d+\.\d+$") {
        return "$version.0"
    }
    return $version
}

function Get-GoVersionFromMod {
    param([string]$GoModPath)

    $line = Get-Content -LiteralPath $GoModPath | Where-Object { $_ -match "^go\s+\d+\.\d+(\.\d+)?$" } | Select-Object -First 1
    if (-not $line) {
        throw "Unable to determine Go version from '$GoModPath'."
    }

    return Normalize-GoVersion (($line -split "\s+")[1])
}

function Resolve-GoTool {
    param([string]$RequestedVersion)

    $goCommand = Get-Command go -ErrorAction SilentlyContinue
    if ($goCommand) {
        return @{
            GoExe   = $goCommand.Path
            Version = (& $goCommand.Path version)
        }
    }

    $normalized = Normalize-GoVersion $RequestedVersion
    if (-not $normalized) {
        throw "Go is not installed and no version was supplied."
    }

    $archiveName = "go$normalized.windows-amd64.zip"
    $archivePath = Join-Path $DownloadsDir $archiveName
    $goRoot = Join-Path $ToolsDir "go"
    $goExe = Join-Path $goRoot "bin\go.exe"

    if (-not (Test-Path -LiteralPath $goExe)) {
        Write-Step "Downloading Go $normalized"
        New-Item -ItemType Directory -Path $DownloadsDir -Force | Out-Null
        Invoke-WebRequest -Uri "https://go.dev/dl/$archiveName" -OutFile $archivePath

        if (Test-Path -LiteralPath $goRoot) {
            Remove-Item -LiteralPath $goRoot -Recurse -Force
        }
        Expand-Archive -LiteralPath $archivePath -DestinationPath $ToolsDir
    }

    return @{
        GoExe   = $goExe
        Version = (& $goExe version)
    }
}

function Ensure-LlvmMingw {
    param([string]$Version)

    $folderName = "llvm-mingw-$Version-ucrt-x86_64"
    $installRoot = Join-Path $ToolsDir $folderName
    $binDir = Join-Path $installRoot "bin"

    if (-not (Test-Path -LiteralPath $binDir)) {
        Write-Step "Downloading llvm-mingw $Version"
        New-Item -ItemType Directory -Path $DownloadsDir -Force | Out-Null
        $archivePath = Join-Path $DownloadsDir "$folderName.zip"
        Invoke-WebRequest `
            -Uri "https://github.com/mstorsjo/llvm-mingw/releases/download/$Version/$folderName.zip" `
            -OutFile $archivePath
        Expand-Archive -LiteralPath $archivePath -DestinationPath $ToolsDir
    }

    return $binDir
}

function Convert-GitHubUrlToRepoId {
    param([string]$Url)

    if ($Url -notmatch "github\.com/([^/]+)/([^/]+?)(?:\.git)?$") {
        throw "Unsupported upstream repository URL '$Url'."
    }

    return @{
        Owner = $matches[1]
        Repo  = $matches[2]
    }
}

function Get-MakefileSyncInfo {
    param([string]$MakefileSyncPath)

    $upstream = $null
    $fetchHead = $null

    foreach ($line in Get-Content -LiteralPath $MakefileSyncPath) {
        if ($line -match "^UPSTREAM=(.+)$") {
            $upstream = $matches[1].Trim()
        } elseif ($line -match "^FETCH_HEAD=(.+)$") {
            $fetchHead = $matches[1].Trim()
        }
    }

    if (-not $upstream -or -not $fetchHead) {
        throw "Unable to parse UPSTREAM/FETCH_HEAD from '$MakefileSyncPath'."
    }

    return @{
        Upstream  = $upstream
        FetchHead = $fetchHead
    }
}

function Overlay-SyclSources {
    param(
        [string]$LlamaRoot,
        [string]$OllamaRoot
    )

    $sourceDir = Join-Path $LlamaRoot "ggml\src\ggml-sycl"
    $targetDir = Join-Path $OllamaRoot "ml\backend\ggml\ggml\src\ggml-sycl"

    if (-not (Test-Path -LiteralPath $sourceDir)) {
        throw "Pinned llama.cpp source does not contain ggml-sycl."
    }

    if (Test-Path -LiteralPath $targetDir) {
        Remove-Item -LiteralPath $targetDir -Recurse -Force
    }

    Copy-Item -LiteralPath $sourceDir -Destination $targetDir -Recurse -Force
    return $targetDir
}

function Patch-SyclCompatibility {
    param([string]$SyclDir)

    $syclFile = Join-Path $SyclDir "ggml-sycl.cpp"
    $content = Get-Content -LiteralPath $syclFile -Raw
    $updated = $false

    $oldSignature = "static ggml_status ggml_backend_sycl_graph_compute(ggml_backend_t backend, ggml_cgraph * cgraph)"
    $newSignature = "static ggml_status ggml_backend_sycl_graph_compute(ggml_backend_t backend, ggml_cgraph * cgraph, int batch_size)"

    if ($content.Contains($oldSignature)) {
        $content = $content.Replace($oldSignature, $newSignature)
        $updated = $true
    }

    $signaturePattern = [regex]::Escape($newSignature) + "\s*\{"
    if ($content -match $signaturePattern -and $content -notmatch [regex]::Escape($newSignature) + "\s*\{\s*\(void\)\s*batch_size;") {
        $content = [regex]::Replace(
            $content,
            $signaturePattern,
            "$newSignature`r`n{`r`n    (void) batch_size;",
            1
        )
        $updated = $true
    }

    if ($updated) {
        Set-Content -LiteralPath $syclFile -Value $content -NoNewline
    }
}

function Normalize-GgmlDllNames {
    param([string]$Directory)

    if (-not (Test-Path -LiteralPath $Directory)) {
        return
    }

    Get-ChildItem -LiteralPath $Directory -Filter "libggml-*.dll" | ForEach-Object {
        $target = Join-Path $_.DirectoryName $_.Name.Substring(3)
        if (Test-Path -LiteralPath $target) {
            Remove-Item -LiteralPath $target -Force
        }
        Rename-Item -LiteralPath $_.FullName -NewName ([System.IO.Path]::GetFileName($target))
    }
}

function Ensure-GgmlBaseAlias {
    param([string]$Directory)

    $baseDll = Join-Path $Directory "ggml-base.dll"
    $aliasDll = Join-Path $Directory "libggml-base.dll"

    if (-not (Test-Path -LiteralPath $baseDll)) {
        return
    }

    Copy-Item -LiteralPath $baseDll -Destination $aliasDll -Force
}

function Copy-LlvmMingwRuntimeDependencies {
    param(
        [string]$Destination,
        [string]$LlvmBin
    )

    $candidates = @(
        "libc++.dll",
        "libunwind.dll"
    )

    foreach ($dll in $candidates) {
        $source = Join-Path $LlvmBin $dll
        if (Test-Path -LiteralPath $source) {
            Copy-Item -LiteralPath $source -Destination (Join-Path $Destination $dll) -Force
        } else {
            Write-Warning "Unable to locate llvm-mingw runtime '$dll'."
        }
    }
}

function Copy-OneApiRuntimeDependencies {
    param([string]$Destination)

    $candidates = @(
        "sycl8.dll",
        "sycl-jit.dll",
        "ur_adapter_level_zero.dll",
        "libiomp5md.dll",
        "libmmd.dll",
        "svml_dispmd.dll",
        "mkl_sycl_blas.5.dll",
        "mkl_core.2.dll",
        "mkl_intel_thread.2.dll",
        "tbb12.dll",
        "tbbmalloc.dll",
        "tbbmalloc_proxy.dll"
    )

    $searchRoots = @(
        (Join-Path $env:CMPLR_ROOT "bin"),
        (Join-Path $env:CMPLR_ROOT "bin\compiler"),
        (Join-Path $env:MKLROOT "bin"),
        (Join-Path $env:TBBROOT "bin")
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique

    foreach ($dll in $candidates) {
        $match = $null
        foreach ($root in $searchRoots) {
            $match = Get-ChildItem -LiteralPath $root -Filter $dll -Recurse -ErrorAction SilentlyContinue |
                Sort-Object FullName -Descending |
                Select-Object -First 1
            if ($match) {
                break
            }
        }

        if ($match) {
            Copy-Item -LiteralPath $match.FullName -Destination (Join-Path $Destination $dll) -Force
        } else {
            Write-Warning "Unable to locate oneAPI runtime '$dll'."
        }
    }
}

function Build-CpuDependencies {
    param(
        [string]$OllamaSourceRoot,
        [string]$InstallPrefix,
        [string]$VsDevCmd,
        [string]$LlvmBin
    )

    Write-Step "Building Windows CPU backends"
    Import-BatchEnvironment $VsDevCmd @("-arch=x64", "-no_logo")
    $env:PATH = "$LlvmBin;$env:PATH"
    $env:CC = "clang.exe"
    $env:CXX = "clang++.exe"
    $env:CMAKE_GENERATOR = "Ninja"

    Invoke-Checked "cmake" @("--preset", "CPU", "--install-prefix", $InstallPrefix) $OllamaSourceRoot
    Invoke-Checked "cmake" @("--build", "--parallel", "$Parallel", "--preset", "CPU") $OllamaSourceRoot
    Invoke-Checked "cmake" @("--install", "build", "--component", "CPU", "--strip") $OllamaSourceRoot

    $cpuOutDir = Join-Path $InstallPrefix "lib\ollama"
    Normalize-GgmlDllNames $cpuOutDir
    Ensure-GgmlBaseAlias $cpuOutDir
    Copy-LlvmMingwRuntimeDependencies $cpuOutDir $LlvmBin
}

function Build-OllamaBinary {
    param(
        [string]$OllamaSourceRoot,
        [string]$InstallPrefix,
        [string]$GoExe,
        [string]$LlvmBin,
        [string]$BuildVersion
    )

    Write-Step "Building ollama.exe"
    $env:PATH = "$LlvmBin;$([System.IO.Path]::GetDirectoryName($GoExe));$env:PATH"
    $env:CGO_ENABLED = "1"
    $env:CGO_CFLAGS = "-O3"
    $env:CGO_CXXFLAGS = "-O3"
    $env:VERSION = $BuildVersion

    $ldflags = "-s -w -X=github.com/ollama/ollama/version.Version=$BuildVersion -X=github.com/ollama/ollama/server.mode=release"
    Invoke-Checked $GoExe @("build", "-trimpath", "-ldflags", $ldflags, "-o", (Join-Path $InstallPrefix "ollama.exe"), ".") $OllamaSourceRoot
}

function Build-SyclBackend {
    param(
        [string]$OllamaSourceRoot,
        [string]$InstallPrefix,
        [string]$OneApiSetvars
    )

    Write-Step "Building Windows SYCL backend"
    Import-BatchEnvironment $OneApiSetvars @("intel64", "--force")

    $buildDir = Join-Path $OllamaSourceRoot "build-sycl"
    if (Test-Path -LiteralPath $buildDir) {
        Remove-Item -LiteralPath $buildDir -Recurse -Force
    }

    $syclOutDir = Join-Path $InstallPrefix "lib\ollama\sycl"
    New-Item -ItemType Directory -Path $syclOutDir -Force | Out-Null

    Invoke-Checked "cmake" @(
        "-S", ".",
        "-B", $buildDir,
        "-G", "Ninja",
        "-DCMAKE_BUILD_TYPE=Release",
        "-DCMAKE_C_COMPILER=icx",
        "-DCMAKE_CXX_COMPILER=icx",
        "-DGGML_SYCL=ON",
        "-DGGML_SYCL_TARGET=INTEL",
        "-DOLLAMA_RUNNER_DIR=sycl"
    ) $OllamaSourceRoot

    Invoke-Checked "cmake" @("--build", $buildDir, "--target", "ggml-sycl", "--parallel", "$Parallel") $OllamaSourceRoot

    $builtDll = Join-Path $buildDir "lib\ollama\ggml-sycl.dll"
    if (-not (Test-Path -LiteralPath $builtDll)) {
        throw "ggml-sycl.dll was not produced."
    }

    Copy-Item -LiteralPath $builtDll -Destination (Join-Path $syclOutDir "ggml-sycl.dll") -Force
    Copy-OneApiRuntimeDependencies $syclOutDir
}

function Write-BuildMetadata {
    param(
        [string]$InstallPrefix,
        [string]$ResolvedRef,
        [string]$OllamaCommit,
        [string]$GoVersionText,
        [string]$LlamaUpstream,
        [string]$LlamaCommit
    )

    $metadata = [ordered]@{
        built_at_utc       = (Get-Date).ToUniversalTime().ToString("o")
        ollama_ref         = $ResolvedRef
        ollama_commit      = $OllamaCommit
        llama_sync_upstream = $LlamaUpstream
        llama_sync_commit  = $LlamaCommit
        go_version         = $GoVersionText
        llvm_mingw_version = $LlvmMingwVersion
        output_dir         = (Resolve-Path $InstallPrefix).Path
    }

    $metadata | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $InstallPrefix "build-metadata.json")
}

if ($env:OS -ne "Windows_NT") {
    throw "This script only supports Windows."
}

foreach ($tool in @("cmake", "ninja")) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        throw "Required tool '$tool' is not available in PATH."
    }
}

Write-Step "Preparing work directories"
New-Item -ItemType Directory -Path $WorkRoot -Force | Out-Null
New-Item -ItemType Directory -Path $DownloadsDir -Force | Out-Null
New-Item -ItemType Directory -Path $ToolsDir -Force | Out-Null
Reset-Directory $SourcesDir
Prepare-OutputDirectory $OutputDir

Write-Step "Resolving upstream Ollama state"
$ollamaRepo = Invoke-GitHubJson "https://api.github.com/repos/ollama/ollama"
$resolvedRef = if ($OllamaRef) { $OllamaRef } else { $ollamaRepo.default_branch }
$ollamaCommit = (Invoke-GitHubJson "https://api.github.com/repos/ollama/ollama/commits/$resolvedRef").sha
$buildVersion = $ollamaCommit.Substring(0, [Math]::Min(12, $ollamaCommit.Length))

$ollamaZip = Join-Path $DownloadsDir "ollama-$($ollamaCommit.Substring(0, 12)).zip"
Write-Step "Pulling Ollama $resolvedRef ($($ollamaCommit.Substring(0, 12)))"
Download-GitHubZipball -Owner "ollama" -Repo "ollama" -Ref $resolvedRef -Destination $ollamaZip
$ollamaSourceRoot = Expand-Zipball -ArchivePath $ollamaZip -DestinationDirectory (Join-Path $SourcesDir "ollama")

Write-Step "Resolving pinned llama.cpp sync target"
$syncInfo = Get-MakefileSyncInfo (Join-Path $ollamaSourceRoot "Makefile.sync")
$llamaRepo = Convert-GitHubUrlToRepoId $syncInfo.Upstream
$llamaZip = Join-Path $DownloadsDir "llama-$($syncInfo.FetchHead).zip"
Download-GitHubZipball -Owner $llamaRepo.Owner -Repo $llamaRepo.Repo -Ref $syncInfo.FetchHead -Destination $llamaZip
$llamaSourceRoot = Expand-Zipball -ArchivePath $llamaZip -DestinationDirectory (Join-Path $SourcesDir "llama-sync")

Write-Step "Overlaying ggml-sycl from pinned llama.cpp"
$syclSourceDir = Overlay-SyclSources -LlamaRoot $llamaSourceRoot -OllamaRoot $ollamaSourceRoot
Patch-SyclCompatibility -SyclDir $syclSourceDir

$vsDevCmd = Resolve-VsDevCmd
$oneApiSetvars = Resolve-OneApiSetvars
$goRequestedVersion = if ($GoVersion) { Normalize-GoVersion $GoVersion } else { Get-GoVersionFromMod (Join-Path $ollamaSourceRoot "go.mod") }
$goInfo = Resolve-GoTool -RequestedVersion $goRequestedVersion
$llvmMingwBin = Ensure-LlvmMingw -Version $LlvmMingwVersion

if (-not $SkipCpuBuild) {
    Build-CpuDependencies -OllamaSourceRoot $ollamaSourceRoot -InstallPrefix $OutputDir -VsDevCmd $vsDevCmd -LlvmBin $llvmMingwBin
}

if (-not $SkipGoBuild) {
    Build-OllamaBinary -OllamaSourceRoot $ollamaSourceRoot -InstallPrefix $OutputDir -GoExe $goInfo.GoExe -LlvmBin $llvmMingwBin -BuildVersion $buildVersion
}

if (-not $SkipSyclBuild) {
    Build-SyclBackend -OllamaSourceRoot $ollamaSourceRoot -InstallPrefix $OutputDir -OneApiSetvars $oneApiSetvars
}

Write-BuildMetadata `
    -InstallPrefix $OutputDir `
    -ResolvedRef $resolvedRef `
    -OllamaCommit $ollamaCommit `
    -GoVersionText $goInfo.Version `
    -LlamaUpstream $syncInfo.Upstream `
    -LlamaCommit $syncInfo.FetchHead

Write-Step "Build complete"
Write-Host "Output: $((Resolve-Path $OutputDir).Path)"
