[CmdletBinding()]
param(
    [string]$WorkRoot = "",
    [string]$OutputDir = "",
    [string]$OllamaRef = "",
    [string]$LlvmMingwVersion = "20240619",
    [string]$GoVersion = "",
    [string]$DnnlDir = "",
    [string]$SyclDeviceArch = "",
    [switch]$EnableExperimentalSyclF16,
    [switch]$EnableExperimentalSyclDnn,
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
$script:DefaultOllamaNumCtx = 4096

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

function Resolve-DnnlConfigDir {
    param(
        [string]$RequestedDir = "",
        [string]$OneApiRoot = ""
    )

    $candidates = @()
    foreach ($candidate in @($RequestedDir, $env:DNNL_DIR)) {
        if ($candidate) {
            $candidates += $candidate
        }
    }

    if ($env:DNNLROOT) {
        $candidates += Join-Path $env:DNNLROOT "lib\cmake\dnnl"
        $candidates += Join-Path $env:DNNLROOT "latest\lib\cmake\dnnl"
    }

    if ($OneApiRoot) {
        $candidates += Join-Path $OneApiRoot "dnnl\latest\lib\cmake\dnnl"
        $candidates += Join-Path $OneApiRoot "lib\cmake\dnnl"
    }

    foreach ($candidate in $candidates | Where-Object { $_ } | Select-Object -Unique) {
        if (-not (Test-Path -LiteralPath $candidate)) {
            continue
        }

        $configPath = Join-Path $candidate "dnnl-config.cmake"
        if (Test-Path -LiteralPath $configPath) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    $searchRoots = @($env:DNNLROOT, $OneApiRoot) |
        Where-Object { $_ -and (Test-Path -LiteralPath $_) } |
        Select-Object -Unique

    foreach ($root in $searchRoots) {
        $match = Get-ChildItem -Path $root -Filter "dnnl-config.cmake" -Recurse -ErrorAction SilentlyContinue |
            Sort-Object FullName -Descending |
            Select-Object -First 1
        if ($match) {
            return $match.Directory.FullName
        }
    }

    throw "Unable to locate oneDNN CMake config. Install Intel oneDNN / oneAPI Base Toolkit or pass -DnnlDir."
}

function Resolve-SyclDeviceArch {
    param([string]$RequestedArch = "")

    $resolved = if ($RequestedArch) {
        $RequestedArch.Trim()
    } elseif ($env:GGML_SYCL_DEVICE_ARCH) {
        $env:GGML_SYCL_DEVICE_ARCH.Trim()
    } else {
        ""
    }

    return $resolved
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

function Replace-RequiredContent {
    param(
        [string]$Content,
        [string]$OldValue,
        [string]$NewValue,
        [string]$Description
    )

    if (-not $Content.Contains($OldValue)) {
        throw "Unable to apply patch: $Description"
    }

    return $Content.Replace($OldValue, $NewValue)
}

function Patch-WindowsSyclIntegratedGpuSupport {
    param(
        [string]$OllamaRoot,
        [string]$SyclDir
    )

    $ggmlImplPath = Join-Path $OllamaRoot "ml\backend\ggml\ggml\src\ggml-impl.h"
    $ggmlImplContent = Get-Content -LiteralPath $ggmlImplPath -Raw
    if ($ggmlImplContent -notmatch "ggml_dxgi_pdh_get_device_memory_by_adapter") {
        $ggmlImplContent = Replace-RequiredContent `
            -Content $ggmlImplContent `
            -OldValue 'GGML_API int ggml_dxgi_pdh_get_device_memory(const char* luid, size_t *free, size_t *total, bool is_integrated_gpu);' `
            -NewValue @'
GGML_API int ggml_dxgi_pdh_get_device_memory(const char* luid, size_t *free, size_t *total, bool is_integrated_gpu);
GGML_API int ggml_dxgi_pdh_get_device_memory_by_adapter(const char * device_id, const char * description, size_t * free, size_t * total, bool is_integrated_gpu);
'@ `
            -Description "ggml DXGI/PDH adapter declaration"
        Set-Content -LiteralPath $ggmlImplPath -Value $ggmlImplContent -NoNewline
    }

    $memDxgiPath = Join-Path $OllamaRoot "ml\backend\ggml\ggml\src\mem_dxgi_pdh.cpp"
    $memDxgiContent = Get-Content -LiteralPath $memDxgiPath -Raw
    if ($memDxgiContent -notmatch "ggml_dxgi_pdh_get_device_memory_by_adapter") {
        $memDxgiContent = Replace-RequiredContent `
            -Content $memDxgiContent `
            -OldValue @'
#include <windows.h>
#include <pdh.h>
#include <dxgi1_2.h>
#include <sstream>
'@ `
            -NewValue @'
#include <windows.h>
#include <pdh.h>
#include <dxgi1_2.h>
#include <algorithm>
#include <cctype>
#include <sstream>
'@ `
            -Description "DXGI include extensions"

        $memDxgiContent = Replace-RequiredContent `
            -Content $memDxgiContent `
            -OldValue @'
struct GpuInfo {
    std::wstring description; // debug field
    LUID luid;
'@ `
            -NewValue @'
struct GpuInfo {
    std::wstring description; // debug field
    std::string deviceId;
    LUID luid;
'@ `
            -Description "GpuInfo device ID field"

        $memDxgiContent = Replace-RequiredContent `
            -Content $memDxgiContent `
            -OldValue @'
template <typename T>
static inline double b_to_gb(T n)
{
    return (double(n) / (1024.0 * 1024 * 1024));
}

/*
Fetch the GPU adapter 'dedicated memory' and 'shared memory' using DXGI
*/
'@ `
            -NewValue @'
template <typename T>
static inline double b_to_gb(T n)
{
    return (double(n) / (1024.0 * 1024 * 1024));
}

static std::string normalize_device_id(std::string value) {
    value.erase(std::remove_if(value.begin(), value.end(), [](unsigned char ch) {
        return std::isspace(ch) != 0;
    }), value.end());

    if (value.rfind("0x", 0) == 0 || value.rfind("0X", 0) == 0) {
        value = value.substr(2);
    }

    std::transform(value.begin(), value.end(), value.begin(), [](unsigned char ch) {
        return (char) std::tolower(ch);
    });

    size_t first_non_zero = value.find_first_not_of('0');
    if (first_non_zero == std::string::npos) {
        return value.empty() ? std::string() : "0";
    }

    return value.substr(first_non_zero);
}

static std::string normalize_description(std::string value) {
    auto is_space = [](unsigned char ch) {
        return std::isspace(ch) != 0;
    };

    while (!value.empty() && is_space((unsigned char) value.front())) {
        value.erase(value.begin());
    }

    while (!value.empty() && is_space((unsigned char) value.back())) {
        value.pop_back();
    }

    std::transform(value.begin(), value.end(), value.begin(), [](unsigned char ch) {
        return (char) std::tolower(ch);
    });

    return value;
}

static std::string format_device_id(UINT device_id) {
    char buffer[16];
    snprintf(buffer, sizeof(buffer), "%x", device_id);
    return normalize_device_id(buffer);
}

static std::string utf8_from_wstring(const std::wstring & value) {
    if (value.empty()) {
        return {};
    }

    int size = WideCharToMultiByte(CP_UTF8, 0, value.c_str(), -1, nullptr, 0, nullptr, nullptr);
    if (size <= 1) {
        return {};
    }

    std::string result(size, '\0');
    WideCharToMultiByte(CP_UTF8, 0, value.c_str(), -1, result.data(), size, nullptr, nullptr);
    result.pop_back();
    return result;
}

/*
Fetch the GPU adapter 'dedicated memory' and 'shared memory' using DXGI
*/
'@ `
            -Description "DXGI helper functions"

        $memDxgiContent = Replace-RequiredContent `
            -Content $memDxgiContent `
            -OldValue @'
            GpuInfo info;
            fetch_dxgi_adapter_desc1(desc, &info);
            info.description = std::wstring(desc.Description);
            info.luid = desc.AdapterLuid;
'@ `
            -NewValue @'
            GpuInfo info;
            fetch_dxgi_adapter_desc1(desc, &info);
            info.description = std::wstring(desc.Description);
            info.deviceId = format_device_id(desc.DeviceId);
            info.luid = desc.AdapterLuid;
'@ `
            -Description "DXGI adapter device ID capture"

        $memDxgiContent = Replace-RequiredContent `
            -Content $memDxgiContent `
            -OldValue @'
    dll_functions.PdhCloseQuery(query);
    return true;
}


extern "C" {
'@ `
            -NewValue @'
    dll_functions.PdhCloseQuery(query);
    return true;
}

static GpuInfo * find_gpu_by_luid(std::vector<GpuInfo> & gpus, const char * luid) {
    if (luid == nullptr || *luid == '\0') {
        return nullptr;
    }

    for (auto & gpu : gpus) {
        char luid_buffer[32];
        snprintf(luid_buffer, sizeof(luid_buffer), "0x%08x%08x", gpu.luid.HighPart, gpu.luid.LowPart);
        if (std::string(luid_buffer) == std::string(luid)) {
            return &gpu;
        }
    }

    return nullptr;
}

static GpuInfo * find_gpu_by_adapter(std::vector<GpuInfo> & gpus, const char * device_id, const char * description) {
    std::string normalized_device_id = device_id != nullptr ? normalize_device_id(device_id) : std::string();
    std::string normalized_description = description != nullptr ? normalize_description(description) : std::string();

    GpuInfo * device_id_match = nullptr;
    GpuInfo * description_match = nullptr;

    for (auto & gpu : gpus) {
        bool matches_device_id = !normalized_device_id.empty() && gpu.deviceId == normalized_device_id;

        std::string gpu_description = normalize_description(utf8_from_wstring(gpu.description));
        bool matches_description = !normalized_description.empty() &&
            (gpu_description == normalized_description ||
             gpu_description.find(normalized_description) != std::string::npos ||
             normalized_description.find(gpu_description) != std::string::npos);

        if (matches_device_id && matches_description) {
            return &gpu;
        }

        if (matches_device_id && device_id_match == nullptr) {
            device_id_match = &gpu;
        }

        if (matches_description && description_match == nullptr) {
            description_match = &gpu;
        }
    }

    return device_id_match != nullptr ? device_id_match : description_match;
}

static int ggml_dxgi_pdh_get_gpu_memory(GpuInfo * targetGpu, const char * identifier, size_t * free, size_t * total, bool is_integrated_gpu) {
    if (targetGpu == nullptr) {
        return ERROR_NOT_FOUND;
    }

    int status = get_gpu_memory_usage(*targetGpu);
    if (!status) {
        GGML_LOG_ERROR("Failed to get GPU memory usage.\n");
        return ERROR_DEVICE_NOT_AVAILABLE;
    }

    if (is_integrated_gpu) {
        GGML_LOG_DEBUG("Integrated GPU (%ls) with adapter %s detected. Shared Total: %.2f bytes (%.2f GB), Shared Usage: %.2f bytes (%.2f GB), Dedicated Total: %.2f bytes (%.2f GB), Dedicated Usage: %.2f bytes (%.2f GB)\n",
            targetGpu->description.c_str(), identifier, targetGpu->sharedTotal, b_to_gb(targetGpu->sharedTotal), targetGpu->sharedUsage, b_to_gb(targetGpu->sharedUsage),
            targetGpu->dedicatedTotal, b_to_gb(targetGpu->dedicatedTotal), targetGpu->dedicatedUsage, b_to_gb(targetGpu->dedicatedUsage));
        *free = (targetGpu->sharedTotal - targetGpu->sharedUsage) + (targetGpu->dedicatedTotal - targetGpu->dedicatedUsage);
        *total = targetGpu->sharedTotal + targetGpu->dedicatedTotal;
    } else {
        GGML_LOG_DEBUG("Discrete GPU (%ls) with adapter %s detected. Dedicated Total: %.2f bytes (%.2f GB), Dedicated Usage: %.2f bytes (%.2f GB)\n",
            targetGpu->description.c_str(), identifier, targetGpu->dedicatedTotal, b_to_gb(targetGpu->dedicatedTotal), targetGpu->dedicatedUsage, b_to_gb(targetGpu->dedicatedUsage));
        *free = targetGpu->dedicatedTotal - targetGpu->dedicatedUsage;
        *total = targetGpu->dedicatedTotal;
    }

    return ERROR_SUCCESS;
}


extern "C" {
'@ `
            -Description "DXGI adapter matching helpers"

        $memDxgiContent = Replace-RequiredContent `
            -Content $memDxgiContent `
            -OldValue @'
    int ggml_dxgi_pdh_get_device_memory(const char* luid, size_t *free, size_t *total, bool is_integrated_gpu) {

        std::lock_guard<std::mutex> lock(ggml_dxgi_pdh_lock);

        // Enumerate GPUs using DXGI and find the matching LUID
        // This also fetches the total memory info for each of the enumerated GPUs
        std::vector<GpuInfo> gpus = get_dxgi_gpu_infos();
        GpuInfo *targetGpu = nullptr;
        for (auto& gpu : gpus) {
            char luid_buffer[32]; // "0x" + 16 hex digits + null terminator
            snprintf(luid_buffer, sizeof(luid_buffer), "0x%08x%08x", gpu.luid.HighPart, gpu.luid.LowPart);
            std::string gpu_luid_str(luid_buffer);
            if (gpu_luid_str == std::string(luid)) {
                targetGpu = &gpu;
                break;
            }
        }
        if (!targetGpu) {
            GGML_LOG_ERROR("GPU with LUID %s not found.\n", luid);
            return ERROR_NOT_FOUND;
        }

        // Get the current memory usage for the target GPU
        int status = get_gpu_memory_usage(*targetGpu);
        if (!status) {
            GGML_LOG_ERROR("Failed to get GPU memory usage.\n");
            return ERROR_DEVICE_NOT_AVAILABLE;
        }

        // Calculate the free memory based on whether it's an integrated or discrete GPU
        if (is_integrated_gpu) {
            // IGPU free = SharedTotal - SharedUsage
            GGML_LOG_DEBUG("Integrated GPU (%ls) with LUID %s detected. Shared Total: %.2f bytes (%.2f GB), Shared Usage: %.2f bytes (%.2f GB), Dedicated Total: %.2f bytes (%.2f GB), Dedicated Usage: %.2f bytes (%.2f GB)\n", targetGpu->description.c_str(), luid, targetGpu->sharedTotal, b_to_gb(targetGpu->sharedTotal), targetGpu->sharedUsage, b_to_gb(targetGpu->sharedUsage), targetGpu->dedicatedTotal, b_to_gb(targetGpu->dedicatedTotal), targetGpu->dedicatedUsage, b_to_gb(targetGpu->dedicatedUsage));
            *free = (targetGpu->sharedTotal - targetGpu->sharedUsage) + (targetGpu->dedicatedTotal - targetGpu->dedicatedUsage); // Some IGPUs also have dedicated memory, which can be used along with the IGPU's shared memory
            *total = targetGpu->sharedTotal + targetGpu->dedicatedTotal;
        }
        else {
            // DGPU free = DedicatedTotal - DedicatedUsage
            GGML_LOG_DEBUG("Discrete GPU (%ls) with LUID %s detected. Dedicated Total: %.2f bytes (%.2f GB), Dedicated Usage: %.2f bytes (%.2f GB)\n", targetGpu->description.c_str(), luid, targetGpu->dedicatedTotal, b_to_gb(targetGpu->dedicatedTotal), targetGpu->dedicatedUsage, b_to_gb(targetGpu->dedicatedUsage));
            *free = targetGpu->dedicatedTotal - targetGpu->dedicatedUsage;
            *total = targetGpu->dedicatedTotal;
        }

        return ERROR_SUCCESS;
    }
'@ `
            -NewValue @'
    int ggml_dxgi_pdh_get_device_memory(const char* luid, size_t *free, size_t *total, bool is_integrated_gpu) {

        std::lock_guard<std::mutex> lock(ggml_dxgi_pdh_lock);

        std::vector<GpuInfo> gpus = get_dxgi_gpu_infos();
        GpuInfo *targetGpu = find_gpu_by_luid(gpus, luid);
        if (!targetGpu) {
            GGML_LOG_ERROR("GPU with LUID %s not found.\n", luid);
            return ERROR_NOT_FOUND;
        }

        return ggml_dxgi_pdh_get_gpu_memory(targetGpu, luid, free, total, is_integrated_gpu);
    }

    int ggml_dxgi_pdh_get_device_memory_by_adapter(const char * device_id, const char * description, size_t * free, size_t * total, bool is_integrated_gpu) {
        std::lock_guard<std::mutex> lock(ggml_dxgi_pdh_lock);

        std::vector<GpuInfo> gpus = get_dxgi_gpu_infos();
        GpuInfo * targetGpu = find_gpu_by_adapter(gpus, device_id, description);
        if (!targetGpu) {
            GGML_LOG_ERROR("GPU with device ID %s and description %s not found.\n",
                device_id != nullptr ? device_id : "<null>",
                description != nullptr ? description : "<null>");
            return ERROR_NOT_FOUND;
        }

        const char * identifier = device_id != nullptr && *device_id != '\0' ? device_id : description;
        return ggml_dxgi_pdh_get_gpu_memory(targetGpu, identifier != nullptr ? identifier : "<unknown>", free, total, is_integrated_gpu);
    }
'@ `
            -Description "DXGI adapter memory lookup"

        $memDxgiContent = Replace-RequiredContent `
            -Content $memDxgiContent `
            -OldValue @'
    void ggml_dxgi_pdh_release() {}
    int ggml_dxgi_pdh_get_device_memory(const char* luid, size_t *free, size_t *total, bool is_integrated_gpu) {
        return -1;
    }
'@ `
            -NewValue @'
    void ggml_dxgi_pdh_release() {}
    int ggml_dxgi_pdh_get_device_memory(const char* luid, size_t *free, size_t *total, bool is_integrated_gpu) {
        return -1;
    }
    int ggml_dxgi_pdh_get_device_memory_by_adapter(const char * device_id, const char * description, size_t * free, size_t * total, bool is_integrated_gpu) {
        return -1;
    }
'@ `
            -Description "DXGI adapter non-Windows stub"

        Set-Content -LiteralPath $memDxgiPath -Value $memDxgiContent -NoNewline
    }

    $syclFile = Join-Path $SyclDir "ggml-sycl.cpp"
    $syclContent = Get-Content -LiteralPath $syclFile -Raw
    if ($syclContent -notmatch "ggml_dxgi_pdh_get_device_memory_by_adapter") {
        $syclContent = Replace-RequiredContent `
            -Content $syclContent `
            -OldValue @'
struct ggml_backend_sycl_device_context {
    int device;
    std::string name;
    std::string description;
};
'@ `
            -NewValue @'
struct ggml_backend_sycl_device_context {
    int device;
    bool integrated;
    std::string name;
    std::string id;
    std::string description;
    std::string dxgi_device_id;
};
'@ `
            -Description "SYCL device context fields"

        $syclContent = Replace-RequiredContent `
            -Content $syclContent `
            -OldValue @'
static void ggml_backend_sycl_device_get_memory(ggml_backend_dev_t dev, size_t * free, size_t * total) {
    ggml_backend_sycl_device_context * ctx = (ggml_backend_sycl_device_context *)dev->context;
    ggml_sycl_set_device(ctx->device);
    SYCL_CHECK(CHECK_TRY_ERROR(
    dpct::dev_mgr::instance().get_device(ctx->device).get_memory_info(*free, *total)));
}
'@ `
            -NewValue @'
static void ggml_backend_sycl_device_get_memory(ggml_backend_dev_t dev, size_t * free, size_t * total) {
    ggml_backend_sycl_device_context * ctx = (ggml_backend_sycl_device_context *)dev->context;
    ggml_sycl_set_device(ctx->device);

#ifdef _WIN32
    if (ctx->integrated && ggml_dxgi_pdh_init() == 0) {
        int status = ggml_dxgi_pdh_get_device_memory_by_adapter(
            ctx->dxgi_device_id.empty() ? nullptr : ctx->dxgi_device_id.c_str(),
            ctx->description.empty() ? nullptr : ctx->description.c_str(),
            free,
            total,
            true);
        ggml_dxgi_pdh_release();
        if (status == 0) {
            return;
        }
    }
#endif

    SYCL_CHECK(CHECK_TRY_ERROR(
    dpct::dev_mgr::instance().get_device(ctx->device).get_memory_info(*free, *total)));
}
'@ `
            -Description "SYCL integrated GPU memory reporting"

        $syclContent = Replace-RequiredContent `
            -Content $syclContent `
            -OldValue @'
static enum ggml_backend_dev_type ggml_backend_sycl_device_get_type(ggml_backend_dev_t dev) {
    GGML_UNUSED(dev);
    return GGML_BACKEND_DEVICE_TYPE_GPU;
}
'@ `
            -NewValue @'
static enum ggml_backend_dev_type ggml_backend_sycl_device_get_type(ggml_backend_dev_t dev) {
    ggml_backend_sycl_device_context * ctx = (ggml_backend_sycl_device_context *)dev->context;
    return ctx->integrated ? GGML_BACKEND_DEVICE_TYPE_IGPU : GGML_BACKEND_DEVICE_TYPE_GPU;
}
'@ `
            -Description "SYCL integrated GPU type"

        $syclContent = Replace-RequiredContent `
            -Content $syclContent `
            -OldValue @'
static void ggml_backend_sycl_device_get_props(ggml_backend_dev_t dev, ggml_backend_dev_props * props) {
    props->name        = ggml_backend_sycl_device_get_name(dev);
    props->description = ggml_backend_sycl_device_get_description(dev);
    props->type        = ggml_backend_sycl_device_get_type(dev);
    ggml_backend_sycl_device_get_memory(dev, &props->memory_free, &props->memory_total);

    bool host_buffer = getenv("GGML_SYCL_NO_PINNED") == nullptr;
#ifdef GGML_SYCL_NO_PEER_COPY
    bool events = false;
#else
    bool events = true;
#endif

    props->caps = {
        /* .async                 = */ true,
        /* .host_buffer           = */ host_buffer,
        /* .buffer_from_host_ptr  = */ false,
        /* .events                = */ events,
    };
}
'@ `
            -NewValue @'
static void ggml_backend_sycl_device_get_props(ggml_backend_dev_t dev, ggml_backend_dev_props * props) {
    ggml_backend_sycl_device_context * ctx = (ggml_backend_sycl_device_context *)dev->context;
    props->name        = ggml_backend_sycl_device_get_name(dev);
    props->description = ggml_backend_sycl_device_get_description(dev);
    props->id          = ctx->id.c_str();
    props->type        = ggml_backend_sycl_device_get_type(dev);
    ggml_backend_sycl_device_get_memory(dev, &props->memory_free, &props->memory_total);

    bool host_buffer = getenv("GGML_SYCL_NO_PINNED") == nullptr;
#ifdef GGML_SYCL_NO_PEER_COPY
    bool events = false;
#else
    bool events = true;
#endif

    props->caps = {
        /* .async                 = */ true,
        /* .host_buffer           = */ host_buffer,
        /* .buffer_from_host_ptr  = */ false,
        /* .events                = */ events,
    };

    props->integrated = ctx->integrated;
    props->library = GGML_SYCL_NAME;
}
'@ `
            -Description "SYCL device properties"

        $syclContent = Replace-RequiredContent `
            -Content $syclContent `
            -OldValue @'
            for (int i = 0; i < ggml_sycl_info().device_count; i++) {
                ggml_backend_sycl_device_context * dev_ctx = new ggml_backend_sycl_device_context;
                dev_ctx->device = i;
                dev_ctx->name = GGML_SYCL_NAME + std::to_string(i);

                ggml_sycl_set_device(i);

                dpct::device_info prop;
                SYCL_CHECK(CHECK_TRY_ERROR(dpct::get_device_info(
                    prop, dpct::dev_mgr::instance().get_device(i))));

                dev_ctx->description = prop.get_name();

                ggml_backend_dev_t dev = new ggml_backend_device {
'@ `
            -NewValue @'
            for (int i = 0; i < ggml_sycl_info().device_count; i++) {
                ggml_backend_sycl_device_context * dev_ctx = new ggml_backend_sycl_device_context;
                dev_ctx->device = i;
                dev_ctx->name = GGML_SYCL_NAME + std::to_string(i);
                dev_ctx->id = dev_ctx->name;

                ggml_sycl_set_device(i);

                dpct::device_info prop;
                SYCL_CHECK(CHECK_TRY_ERROR(dpct::get_device_info(
                    prop, dpct::dev_mgr::instance().get_device(i))));

                dev_ctx->description = prop.get_name();
                dev_ctx->integrated = prop.get_integrated() != 0 || prop.get_host_unified_memory();
                if (prop.get_device_id() != 0) {
                    char device_id[16];
                    snprintf(device_id, sizeof(device_id), "%x", prop.get_device_id());
                    dev_ctx->dxgi_device_id = device_id;
                }

                ggml_backend_dev_t dev = new ggml_backend_device {
'@ `
            -Description "SYCL device registration metadata"

        Set-Content -LiteralPath $syclFile -Value $syclContent -NoNewline
    }
}

function Patch-WindowsSharedGgmlBaseName {
    param([string]$OllamaRoot)

    $cmakePath = Join-Path $OllamaRoot "ml\backend\ggml\ggml\src\CMakeLists.txt"
    $cmakeContent = Get-Content -LiteralPath $cmakePath -Raw

    if ($cmakeContent -notmatch 'if \(WIN32 AND CMAKE_CXX_COMPILER_ID STREQUAL "IntelLLVM"\)\s+set_target_properties\(ggml-base PROPERTIES PREFIX "lib"\)') {
        $cmakeContent = Replace-RequiredContent `
            -Content $cmakeContent `
            -OldValue @'
set_target_properties(ggml-base PROPERTIES
    VERSION ${GGML_VERSION}
    SOVERSION ${GGML_VERSION_MAJOR}
)
'@ `
            -NewValue @'
set_target_properties(ggml-base PROPERTIES
    VERSION ${GGML_VERSION}
    SOVERSION ${GGML_VERSION_MAJOR}
)

if (WIN32 AND CMAKE_CXX_COMPILER_ID STREQUAL "IntelLLVM")
    set_target_properties(ggml-base PROPERTIES PREFIX "lib")
endif()
'@ `
            -Description "IntelLLVM Windows ggml-base prefix"

        Set-Content -LiteralPath $cmakePath -Value $cmakeContent -NoNewline
    }
}

function Patch-WindowsSyclFlashAttentionSupport {
    param([string]$OllamaRoot)

    $devicePath = Join-Path $OllamaRoot "ml\device.go"
    $deviceContent = Get-Content -LiteralPath $devicePath -Raw

    if ($deviceContent -notmatch 'gpu\.Library == "SYCL"') {
        $deviceContent = Replace-RequiredContent `
            -Content $deviceContent `
            -OldValue @'
		supportsFA := gpu.Library == "cpu" ||
			gpu.Name == "Metal" || gpu.Library == "Metal" ||
			(gpu.Library == "CUDA" && gpu.DriverMajor >= 7 && !(gpu.ComputeMajor == 7 && gpu.ComputeMinor == 2)) ||
			gpu.Library == "ROCm" ||
			gpu.Library == "Vulkan"
'@ `
            -NewValue @'
		supportsFA := gpu.Library == "cpu" ||
			gpu.Name == "Metal" || gpu.Library == "Metal" ||
			(gpu.Library == "CUDA" && gpu.DriverMajor >= 7 && !(gpu.ComputeMajor == 7 && gpu.ComputeMinor == 2)) ||
			gpu.Library == "ROCm" ||
			gpu.Library == "Vulkan" ||
			gpu.Library == "SYCL"
'@ `
            -Description "SYCL flash attention capability"

        Set-Content -LiteralPath $devicePath -Value $deviceContent -NoNewline
    }
}

function Patch-WindowsSharedMemoryGpuScheduling {
    param([string]$OllamaRoot)

    $routesPath = Join-Path $OllamaRoot "server\routes.go"
    $routesContent = Get-Content -LiteralPath $routesPath -Raw

    if ($routesContent -notmatch "defaultNumCtxForGPUs") {
        $routesContent = Replace-RequiredContent `
            -Content $routesContent `
            -OldValue @'
	"os/signal"
	"slices"
'@ `
            -NewValue @'
	"os/signal"
	"runtime"
	"slices"
'@ `
            -Description "routes runtime import for context heuristics"

        $routesContent = Replace-RequiredContent `
            -Content $routesContent `
            -OldValue @'
	"github.com/ollama/ollama/manifest"
	"github.com/ollama/ollama/middleware"
	"github.com/ollama/ollama/model/parsers"
'@ `
            -NewValue @'
	"github.com/ollama/ollama/manifest"
	"github.com/ollama/ollama/middleware"
	"github.com/ollama/ollama/ml"
	"github.com/ollama/ollama/model/parsers"
'@ `
            -Description "routes ml import for gpu-aware defaults"

        $routesContent = Replace-RequiredContent `
            -Content $routesContent `
            -OldValue @'
const (
	cloudErrRemoteInferenceUnavailable    = "remote model is unavailable"
	cloudErrRemoteModelDetailsUnavailable = "remote model details are unavailable"
	cloudErrWebSearchUnavailable          = "web search is unavailable"
	cloudErrWebFetchUnavailable           = "web fetch is unavailable"
	copilotChatUserAgentPrefix            = "GitHubCopilotChat/"
)

func writeModelRefParseError(c *gin.Context, err error, fallbackStatus int, fallbackMessage string) {
'@ `
            -NewValue @'
const (
	cloudErrRemoteInferenceUnavailable    = "remote model is unavailable"
	cloudErrRemoteModelDetailsUnavailable = "remote model details are unavailable"
	cloudErrWebSearchUnavailable          = "web search is unavailable"
	cloudErrWebFetchUnavailable           = "web fetch is unavailable"
	copilotChatUserAgentPrefix            = "GitHubCopilotChat/"
)

func defaultNumCtxForVRAM(totalVRAM uint64) int {
	switch {
	case totalVRAM >= 47*format.GibiByte:
		return 262144
	case totalVRAM >= 23*format.GibiByte:
		return 32768
	default:
		return 4096
	}
}

func defaultNumCtxForGPUs(gpus []ml.DeviceInfo, goos string) (uint64, int, string) {
	var totalVRAM uint64
	var discreteVRAM uint64
	var hasIntegrated bool
	var hasDiscrete bool

	for _, gpu := range gpus {
		usableVRAM := gpu.TotalMemory
		if usableVRAM > envconfig.GpuOverhead() {
			usableVRAM -= envconfig.GpuOverhead()
		} else {
			usableVRAM = 0
		}

		totalVRAM += usableVRAM
		if gpu.Integrated {
			hasIntegrated = true
			continue
		}

		hasDiscrete = true
		discreteVRAM += usableVRAM
	}

	if goos == "windows" && hasIntegrated {
		if hasDiscrete {
			return discreteVRAM, defaultNumCtxForVRAM(discreteVRAM), "windows discrete-vram default context"
		}

		return 0, 4096, "windows integrated-gpu default context"
	}

	return totalVRAM, defaultNumCtxForVRAM(totalVRAM), "vram-based default context"
}

func writeModelRefParseError(c *gin.Context, err error, fallbackStatus int, fallbackMessage string) {
'@ `
            -Description "gpu-aware default context helpers"

        $routesContent = Replace-RequiredContent `
            -Content $routesContent `
            -OldValue @'
	var totalVRAM uint64
	for _, gpu := range gpus {
		totalVRAM += gpu.TotalMemory - envconfig.GpuOverhead()
	}

	// Set default context based on VRAM tier
	// Use slightly lower thresholds (47/23 GiB vs. 48/24 GiB) to account for small differences in the exact value
	switch {
	case totalVRAM >= 47*format.GibiByte:
		s.defaultNumCtx = 262144
	case totalVRAM >= 23*format.GibiByte:
		s.defaultNumCtx = 32768
	default:
		s.defaultNumCtx = 4096
	}
	slog.Info("vram-based default context", "total_vram", format.HumanBytes2(totalVRAM), "default_num_ctx", s.defaultNumCtx)
'@ `
            -NewValue @'
	totalVRAM, defaultNumCtx, contextSource := defaultNumCtxForGPUs(gpus, runtime.GOOS)
	s.defaultNumCtx = defaultNumCtx
	slog.Info(contextSource, "total_vram", format.HumanBytes2(totalVRAM), "default_num_ctx", s.defaultNumCtx)
'@ `
            -Description "windows shared-memory gpu default context handling"

        Set-Content -LiteralPath $routesPath -Value $routesContent -NoNewline
    }

    $schedPath = Join-Path $OllamaRoot "server\sched.go"
    $schedContent = Get-Content -LiteralPath $schedPath -Raw

    if ($schedContent -notmatch "normalizeLoadRequestOptions") {
        $schedContent = Replace-RequiredContent `
            -Content $schedContent `
            -OldValue @'
var defaultModelsPerGPU = 3

var ErrMaxQueue = errors.New("server busy, please try again.  maximum pending requests exceeded")

func InitScheduler(ctx context.Context) *Scheduler {
'@ `
            -NewValue @'
var defaultModelsPerGPU = 3

var ErrMaxQueue = errors.New("server busy, please try again.  maximum pending requests exceeded")

func capBatchSizeForContext(numCtx, numBatch int) int {
	switch {
	case numCtx >= 131072:
		return min(numBatch, 64)
	case numCtx >= 65536:
		return min(numBatch, 128)
	case numCtx >= 32768:
		return min(numBatch, 256)
	default:
		return numBatch
	}
}

func normalizeLoadRequestOptions(opts api.Options) api.Options {
	opts.NumBatch = capBatchSizeForContext(opts.NumCtx, opts.NumBatch)
	return opts
}

func InitScheduler(ctx context.Context) *Scheduler {
'@ `
            -Description "long-context batch normalization helpers"

        $schedContent = Replace-RequiredContent `
            -Content $schedContent `
            -OldValue @'
	if m.CheckCapabilities(model.CapabilityVision) == nil {
		// multimodal models require at least 2048 context
		opts.NumCtx = max(opts.NumCtx, 2048)
	}

	req := &LlmRequest{
'@ `
            -NewValue @'
	if m.CheckCapabilities(model.CapabilityVision) == nil {
		// multimodal models require at least 2048 context
		opts.NumCtx = max(opts.NumCtx, 2048)
	}

	normalized := normalizeLoadRequestOptions(opts)
	if normalized.NumBatch != opts.NumBatch {
		slog.Info("reducing batch size for long context load", "num_ctx", normalized.NumCtx, "requested_num_batch", opts.NumBatch, "adjusted_num_batch", normalized.NumBatch)
	}
	opts = normalized

	req := &LlmRequest{
'@ `
            -Description "apply long-context batch normalization"

        Set-Content -LiteralPath $schedPath -Value $schedContent -NoNewline
    }

    $llmPath = Join-Path $OllamaRoot "llm\server.go"
    $llmContent = Get-Content -LiteralPath $llmPath -Raw

    if ($llmContent -notmatch "windowsIntegratedGPUSchedulingBudget") {
        $llmContent = Replace-RequiredContent `
            -Content $llmContent `
            -OldValue '	gpuLayers, layers := s.buildLayout(systemGPUs, memory, requireFull, backoff)' `
            -NewValue '	gpuLayers, layers := s.buildLayout(systemInfo, systemGPUs, memory, requireFull, backoff)' `
            -Description "layout creation passes system memory context"

        $llmContent = Replace-RequiredContent `
            -Content $llmContent `
            -OldValue @'
func (s *llmServer) buildLayout(systemGPUs []ml.DeviceInfo, memory *ml.BackendMemory, requireFull bool, backoff float32) (ml.GPULayersList, []uint64) {
'@ `
            -NewValue @'
func windowsIntegratedGPUHeadroom(freeMemory uint64) uint64 {
	reserve := freeMemory / 5
	minReserve := uint64(2 * format.GibiByte)
	if reserve < minReserve {
		reserve = minReserve
	}
	if reserve > freeMemory {
		return freeMemory
	}
	return reserve
}

const windowsIntegratedGPUMaxOffloadBudget = 10 * format.GibiByte

func windowsIntegratedGPUSchedulingBudget(systemInfo ml.SystemInfo, gpus []ml.DeviceInfo, goos string) (uint64, uint64) {
	if goos != "windows" {
		return 0, 0
	}

	var integratedCount uint64
	for _, gpu := range gpus {
		if gpu.Integrated {
			integratedCount++
		}
	}
	if integratedCount == 0 {
		return 0, 0
	}

	reserve := windowsIntegratedGPUHeadroom(systemInfo.FreeMemory)
	if systemInfo.FreeMemory <= reserve {
		return 0, reserve
	}

	budgetPerGPU := (systemInfo.FreeMemory - reserve) / integratedCount
	if budgetPerGPU > windowsIntegratedGPUMaxOffloadBudget {
		budgetPerGPU = windowsIntegratedGPUMaxOffloadBudget
	}

	return budgetPerGPU, reserve
}

func isWindowsIntegratedGPU(goos string, gpu ml.DeviceInfo) bool {
	return goos == "windows" && gpu.Integrated
}

func integratedGPUMemoryRequirement(systemGPUs []ml.DeviceInfo, memory *ml.BackendMemory, gpuLayers ml.GPULayersList, layers []uint64, goos string) uint64 {
	if goos != "windows" {
		return 0
	}

	integratedGPUByID := make(map[ml.DeviceID]struct{}, len(systemGPUs))
	for _, gpu := range systemGPUs {
		if gpu.Integrated {
			integratedGPUByID[gpu.DeviceID] = struct{}{}
		}
	}

	if len(integratedGPUByID) == 0 {
		return 0
	}

	var sharedMemorySize uint64
	for _, gl := range gpuLayers {
		if _, ok := integratedGPUByID[gl.DeviceID]; !ok {
			continue
		}

		for _, gpu := range memory.GPUs {
			if gl.DeviceID == gpu.DeviceID {
				sharedMemorySize += gpu.Graph
				break
			}
		}

		for _, layer := range gl.Layers {
			sharedMemorySize += layers[layer]
		}
	}

	return sharedMemorySize
}

func (s *llmServer) buildLayout(systemInfo ml.SystemInfo, systemGPUs []ml.DeviceInfo, memory *ml.BackendMemory, requireFull bool, backoff float32) (ml.GPULayersList, []uint64) {
'@ `
            -Description "windows integrated gpu scheduling helpers"

        $llmContent = Replace-RequiredContent `
            -Content $llmContent `
            -OldValue @'
	gpus := append(make([]ml.DeviceInfo, 0, len(systemGPUs)), systemGPUs...)
	sort.Sort(sort.Reverse(ml.ByFreeMemory(gpus)))
'@ `
            -NewValue @'
	gpus := append(make([]ml.DeviceInfo, 0, len(systemGPUs)), systemGPUs...)
	sort.Sort(sort.Reverse(ml.ByFreeMemory(gpus)))
	integratedBudgetPerGPU, integratedReserve := windowsIntegratedGPUSchedulingBudget(systemInfo, gpus, runtime.GOOS)
'@ `
            -Description "windows integrated gpu budget discovery"

        $llmContent = Replace-RequiredContent `
            -Content $llmContent `
            -OldValue @'
					reserved := uint64(float32(gl[i].FreeMemory)*backoff) + gl[i].MinimumMemory() + envconfig.GpuOverhead() + memory.GPUs[j].Graph
					if gl[i].FreeMemory > reserved {
						gl[i].FreeMemory -= reserved
					} else {
						gl[i].FreeMemory = 0
					}

					slog.Debug("available gpu", "id", gl[i].ID, "library", gl[i].Library,
'@ `
            -NewValue @'
					usableFreeMemory := gl[i].FreeMemory
					if isWindowsIntegratedGPU(runtime.GOOS, gl[i]) && integratedBudgetPerGPU > 0 && usableFreeMemory > integratedBudgetPerGPU {
						slog.Debug("capping integrated gpu scheduling budget",
							"id", gl[i].ID,
							"library", gl[i].Library,
							"reported_free", format.HumanBytes2(gl[i].FreeMemory),
							"usable_free", format.HumanBytes2(integratedBudgetPerGPU),
							"system_free", format.HumanBytes2(systemInfo.FreeMemory),
							"system_reserve", format.HumanBytes2(integratedReserve))
						usableFreeMemory = integratedBudgetPerGPU
					}

					reserved := uint64(float32(usableFreeMemory)*backoff) + gl[i].MinimumMemory() + envconfig.GpuOverhead() + memory.GPUs[j].Graph
					if usableFreeMemory > reserved {
						gl[i].FreeMemory = usableFreeMemory - reserved
					} else {
						gl[i].FreeMemory = 0
					}

					slog.Debug("available gpu", "id", gl[i].ID, "library", gl[i].Library,
'@ `
            -Description "windows integrated gpu scheduling cap"

        $llmContent = Replace-RequiredContent `
            -Content $llmContent `
            -OldValue @'
func (s *llmServer) verifyLayout(systemInfo ml.SystemInfo, systemGPUs []ml.DeviceInfo, memory *ml.BackendMemory, requireFull bool, gpuLayers ml.GPULayersList, layers []uint64) error {
	// These sizes will only increase as we go through additional iterations and get additional information.
	cpuSize := memory.InputWeights + memory.CPU.Graph
	var vramSize uint64
	for _, gl := range gpuLayers {
		for _, gpu := range memory.GPUs {
			if gl.DeviceID == gpu.DeviceID {
				vramSize += gpu.Graph
				break
			}
		}
	}

nextLayer:
	for i := range layers {
		for _, g := range gpuLayers {
			for _, gl := range g.Layers {
				if i == gl {
					vramSize += layers[i]
					continue nextLayer
				}
			}
		}
		cpuSize += layers[i]
	}

	if requireFull {
		if len(systemGPUs) > 0 && gpuLayers.Sum() < len(layers) && (s.options.NumGPU < 0 || gpuLayers.Sum() < s.options.NumGPU) {
			slog.Info("model requires more gpu memory than is currently available, evicting a model to make space", "loaded layers", gpuLayers.Sum())
			return ErrLoadRequiredFull
		}

		if cpuSize > systemInfo.FreeMemory {
			slog.Info("model requires more system memory than is currently available, evicting a model to make space", "required", cpuSize, "free", systemInfo.FreeMemory)
			return fmt.Errorf("model requires more system memory than is currently available %w", ErrLoadRequiredFull)
		}
	}

	// On linux and windows, over-allocating CPU memory will almost always result in an error
	// Darwin has fully dynamic swap so has no direct concept of free swap space
	if runtime.GOOS != "darwin" {
		available := systemInfo.FreeMemory + systemInfo.FreeSwap
		if cpuSize > available {
			slog.Warn("model request too large for system", "requested", format.HumanBytes2(cpuSize), "available", format.HumanBytes2(available), "total", format.HumanBytes2(systemInfo.TotalMemory), "free", format.HumanBytes2(systemInfo.FreeMemory), "swap", format.HumanBytes2(systemInfo.FreeSwap))
			return fmt.Errorf("model requires more system memory (%s) than is available (%s)", format.HumanBytes2(cpuSize), format.HumanBytes2(available))
		}
	} else {
		if vramSize > systemInfo.TotalMemory {
			// disable partial offloading when model is greater than total system memory as this
			// can lead to locking up the system
			s.options.NumGPU = 0
			gpuLayers = ml.GPULayersList{}
		}
	}

	if len(systemGPUs) > 0 && gpuLayers.Sum() == 0 {
		slog.Debug("insufficient VRAM to load any model layers")
	}

	return nil
}
'@ `
            -NewValue @'
func (s *llmServer) verifyLayout(systemInfo ml.SystemInfo, systemGPUs []ml.DeviceInfo, memory *ml.BackendMemory, requireFull bool, gpuLayers ml.GPULayersList, layers []uint64) error {
	// These sizes will only increase as we go through additional iterations and get additional information.
	cpuSize := memory.InputWeights + memory.CPU.Graph
	var vramSize uint64
	sharedMemorySize := integratedGPUMemoryRequirement(systemGPUs, memory, gpuLayers, layers, runtime.GOOS)
	for _, gl := range gpuLayers {
		if sharedMemorySize > 0 {
			for _, gpu := range systemGPUs {
				if gl.DeviceID == gpu.DeviceID && gpu.Integrated {
					goto nextGraph
				}
			}
		}
		for _, gpu := range memory.GPUs {
			if gl.DeviceID == gpu.DeviceID {
				vramSize += gpu.Graph
				break
			}
		}

	nextGraph:
	}

nextLayer:
	for i := range layers {
		for _, g := range gpuLayers {
			for _, gl := range g.Layers {
				if i == gl {
					for _, gpu := range systemGPUs {
						if g.DeviceID == gpu.DeviceID && gpu.Integrated && runtime.GOOS == "windows" {
							continue nextLayer
						}
					}
					vramSize += layers[i]
					continue nextLayer
				}
			}
		}
		cpuSize += layers[i]
	}

	if requireFull {
		if len(systemGPUs) > 0 && gpuLayers.Sum() < len(layers) && (s.options.NumGPU < 0 || gpuLayers.Sum() < s.options.NumGPU) {
			slog.Info("model requires more gpu memory than is currently available, evicting a model to make space", "loaded layers", gpuLayers.Sum())
			return ErrLoadRequiredFull
		}

		requiredSystemMemory := cpuSize + sharedMemorySize
		if requiredSystemMemory > systemInfo.FreeMemory {
			slog.Info("model requires more system memory than is currently available, evicting a model to make space", "required", requiredSystemMemory, "free", systemInfo.FreeMemory)
			return fmt.Errorf("model requires more system memory than is currently available %w", ErrLoadRequiredFull)
		}
	}

	// On linux and windows, over-allocating CPU memory will almost always result in an error
	// Darwin has fully dynamic swap so has no direct concept of free swap space
	if runtime.GOOS != "darwin" {
		available := systemInfo.FreeMemory + systemInfo.FreeSwap
		if runtime.GOOS == "windows" && sharedMemorySize > 0 {
			available = systemInfo.FreeMemory
		}

		requiredSystemMemory := cpuSize + sharedMemorySize
		if requiredSystemMemory > available {
			slog.Warn("model request too large for system",
				"requested", format.HumanBytes2(requiredSystemMemory),
				"cpu", format.HumanBytes2(cpuSize),
				"shared_gpu", format.HumanBytes2(sharedMemorySize),
				"available", format.HumanBytes2(available),
				"total", format.HumanBytes2(systemInfo.TotalMemory),
				"free", format.HumanBytes2(systemInfo.FreeMemory),
				"swap", format.HumanBytes2(systemInfo.FreeSwap))
			return fmt.Errorf("model requires more system memory (%s) than is available (%s)", format.HumanBytes2(requiredSystemMemory), format.HumanBytes2(available))
		}
	} else {
		if vramSize > systemInfo.TotalMemory {
			// disable partial offloading when model is greater than total system memory as this
			// can lead to locking up the system
			s.options.NumGPU = 0
			gpuLayers = ml.GPULayersList{}
		}
	}

	if len(systemGPUs) > 0 && gpuLayers.Sum() == 0 {
		slog.Debug("insufficient VRAM to load any model layers")
	}

	return nil
}
'@ `
            -Description "windows shared-memory gpu system memory accounting"

        Set-Content -LiteralPath $llmPath -Value $llmContent -NoNewline
    }
}

function Patch-EmbeddingRequestContextDefaults {
    param([string]$OllamaRoot)

    $routesPath = Join-Path $OllamaRoot "server\routes.go"
    $routesContent = Get-Content -LiteralPath $routesPath -Raw

    if ($routesContent -notmatch "withDefaultEmbeddingNumCtx") {
        $routesContent = Replace-RequiredContent `
            -Content $routesContent `
            -OldValue @'
type Server struct {
	addr          net.Addr
	sched         *Scheduler
	defaultNumCtx int
	requestLogger *inferenceRequestLogger
}

func init() {
'@ `
            -NewValue @'
type Server struct {
	addr          net.Addr
	sched         *Scheduler
	defaultNumCtx int
	requestLogger *inferenceRequestLogger
}

const defaultEmbeddingNumCtx = 4096

// Embedding requests should not inherit the aggressive VRAM-based chat default.
// On large shared-memory Intel iGPUs that can inflate num_ctx enough to make
// embed loads fail before the first request is processed.
func withDefaultEmbeddingNumCtx(requestOpts map[string]any) map[string]any {
	if value, ok := requestOpts["num_ctx"]; ok && value != nil {
		return requestOpts
	}

	opts := make(map[string]any, len(requestOpts)+1)
	for key, value := range requestOpts {
		opts[key] = value
	}

	opts["num_ctx"] = int64(defaultEmbeddingNumCtx)
	return opts
}

func init() {
'@ `
            -Description "embedding request default context helper"

        $routesContent = Replace-RequiredContent `
            -Content $routesContent `
            -OldValue '	r, m, opts, err := s.scheduleRunner(c.Request.Context(), name.String(), []model.Capability{}, req.Options, req.KeepAlive)' `
            -NewValue @'
	embedOptions := withDefaultEmbeddingNumCtx(req.Options)
	r, m, opts, err := s.scheduleRunner(c.Request.Context(), name.String(), []model.Capability{}, embedOptions, req.KeepAlive)
'@ `
            -Description "embed handler conservative default context"

        $routesContent = Replace-RequiredContent `
            -Content $routesContent `
            -OldValue '	r, _, _, err := s.scheduleRunner(c.Request.Context(), name.String(), []model.Capability{}, req.Options, req.KeepAlive)' `
            -NewValue @'
	embedOptions := withDefaultEmbeddingNumCtx(req.Options)
	r, _, _, err := s.scheduleRunner(c.Request.Context(), name.String(), []model.Capability{}, embedOptions, req.KeepAlive)
'@ `
            -Description "legacy embeddings handler conservative default context"

        Set-Content -LiteralPath $routesPath -Value $routesContent -NoNewline
    }
}

function Normalize-GgmlDllNames {
    param([string]$Directory)

    if (-not (Test-Path -LiteralPath $Directory)) {
        return
    }

    Get-ChildItem -LiteralPath $Directory -Filter "libggml-*.dll" |
        Where-Object { $_.Name -ne "libggml-base.dll" } |
        ForEach-Object {
        $target = Join-Path $_.DirectoryName $_.Name.Substring(3)
        if (Test-Path -LiteralPath $target) {
            Remove-Item -LiteralPath $target -Force
        }
        Rename-Item -LiteralPath $_.FullName -NewName ([System.IO.Path]::GetFileName($target))
    }
}

function Ensure-GgmlBaseDiscoveryCopy {
    param([string]$Directory)

    $baseDll = Join-Path $Directory "libggml-base.dll"
    $discoveryDll = Join-Path $Directory "ggml-base.dll"

    if (-not (Test-Path -LiteralPath $baseDll)) {
        return
    }

    Copy-Item -LiteralPath $baseDll -Destination $discoveryDll -Force
}

function Resolve-DnnlBinDirectory {
    param([string]$DnnlConfigDir = "")

    if (-not $DnnlConfigDir) {
        return $null
    }

    $cmakeRoot = Split-Path -Parent $DnnlConfigDir
    if (-not $cmakeRoot) {
        return $null
    }

    $libRoot = Split-Path -Parent $cmakeRoot
    if (-not $libRoot) {
        return $null
    }

    $installRoot = Split-Path -Parent $libRoot
    if (-not $installRoot) {
        return $null
    }

    $binDir = Join-Path $installRoot "bin"
    if (Test-Path -LiteralPath $binDir) {
        return $binDir
    }

    return $null
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
    param(
        [string]$Destination,
        [string]$DnnlConfigDir = "",
        [string]$OneApiRoot = ""
    )

    $candidates = @(
        "sycl8.dll",
        "sycl-jit.dll",
        "ur_loader.dll",
        "ur_adapter_opencl.dll",
        "ur_win_proxy_loader.dll",
        "ur_adapter_level_zero.dll",
        "ur_adapter_level_zero_v2.dll",
        "libiomp5md.dll",
        "libmmd.dll",
        "svml_dispmd.dll",
        "mkl_sycl_blas.5.dll",
        "mkl_core.2.dll",
        "mkl_intel_thread.2.dll",
        "mkl_tbb_thread.2.dll",
        "dnnl.dll",
        "tbb12.dll",
        "tbbmalloc.dll",
        "tbbmalloc_proxy.dll"
    )

    $resolvedDnnlBin = Resolve-DnnlBinDirectory -DnnlConfigDir $DnnlConfigDir
    $preferredTbbBin = $null
    if ($env:TBBROOT) {
        $candidate = Join-Path $env:TBBROOT "bin"
        if (Test-Path -LiteralPath $candidate) {
            $preferredTbbBin = $candidate
        }
    }

    $searchRoots = @(
        $(if ($env:CMPLR_ROOT) { Join-Path $env:CMPLR_ROOT "bin" }),
        $(if ($env:CMPLR_ROOT) { Join-Path $env:CMPLR_ROOT "bin\compiler" }),
        $(if ($env:MKLROOT) { Join-Path $env:MKLROOT "bin" }),
        $(if ($env:TBBROOT) { Join-Path $env:TBBROOT "bin" }),
        $(if ($env:DNNLROOT) { Join-Path $env:DNNLROOT "bin" }),
        $resolvedDnnlBin,
        $(if ($OneApiRoot) { Join-Path $OneApiRoot "bin" })
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique

    foreach ($dll in $candidates) {
        $match = $null

        if ($preferredTbbBin -and $dll -like "tbb*.dll") {
            $preferredSource = Join-Path $preferredTbbBin $dll
            if (Test-Path -LiteralPath $preferredSource) {
                $match = Get-Item -LiteralPath $preferredSource
            }
        }

        foreach ($root in $searchRoots) {
            if ($match) {
                break
            }

            $directSource = Join-Path $root $dll
            if (Test-Path -LiteralPath $directSource) {
                $match = Get-Item -LiteralPath $directSource
                break
            }

            $match = Get-ChildItem -LiteralPath $root -Filter $dll -Recurse -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.FullName -notmatch '\\vc14_uwp\\' -and
                    $_.FullName -notmatch '\\vc14_uwd\\' -and
                    $_.FullName -notmatch '\\vc_mt\\'
                } |
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

function Copy-SyclRootRuntimeDependencies {
    param(
        [string]$SourceDirectory,
        [string]$DestinationDirectory
    )

    foreach ($dll in @("libmmd.dll", "svml_dispmd.dll")) {
        $source = Join-Path $SourceDirectory $dll
        if (Test-Path -LiteralPath $source) {
            Copy-Item -LiteralPath $source -Destination (Join-Path $DestinationDirectory $dll) -Force
        } else {
            Write-Warning "Unable to locate SYCL root runtime '$dll'."
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
    Ensure-GgmlBaseDiscoveryCopy $cpuOutDir
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
        [string]$OneApiSetvars,
        [string]$ResolvedDnnlDir,
        [string]$ResolvedSyclDeviceArch = "",
        [string]$ResolvedOneApiRoot = "",
        [bool]$UseExperimentalSyclF16 = $false,
        [bool]$UseExperimentalSyclDnn = $false
    )

    Write-Step "Building Windows SYCL backend"
    Import-BatchEnvironment $OneApiSetvars @("intel64", "--force")

    $buildDir = Join-Path $OllamaSourceRoot "build-sycl"
    if (Test-Path -LiteralPath $buildDir) {
        Remove-Item -LiteralPath $buildDir -Recurse -Force
    }

    $syclOutDir = Join-Path $InstallPrefix "lib\ollama\sycl"
    New-Item -ItemType Directory -Path $syclOutDir -Force | Out-Null

    $cmakeArgs = @(
        "-S", ".",
        "-B", $buildDir,
        "-G", "Ninja",
        "-DCMAKE_BUILD_TYPE=Release",
        "-DCMAKE_C_COMPILER=icx",
        "-DCMAKE_CXX_COMPILER=icx",
        "-DGGML_SYCL=ON",
        "-DGGML_SYCL_TARGET=INTEL",
        "-DGGML_SYCL_F16=$(if ($UseExperimentalSyclF16) { 'ON' } else { 'OFF' })",
        "-DGGML_SYCL_DNN=$(if ($UseExperimentalSyclDnn) { 'ON' } else { 'OFF' })",
        "-DGGML_SYCL_GRAPH=ON",
        "-DDNNL_DIR=$ResolvedDnnlDir",
        "-DOLLAMA_RUNNER_DIR=sycl"
    )
    if ($ResolvedSyclDeviceArch) {
        $cmakeArgs += "-DGGML_SYCL_DEVICE_ARCH=$ResolvedSyclDeviceArch"
        Write-Step "Using GGML_SYCL_DEVICE_ARCH=$ResolvedSyclDeviceArch"
    }
    if ($UseExperimentalSyclF16) {
        Write-Step "Building SYCL backend with experimental GGML_SYCL_F16=ON"
    } else {
        Write-Step "Building SYCL backend with stable GGML_SYCL_F16=OFF"
    }
    if ($UseExperimentalSyclDnn) {
        Write-Step "Building SYCL backend with experimental GGML_SYCL_DNN=ON from $ResolvedDnnlDir"
    } else {
        Write-Step "Building SYCL backend with stable GGML_SYCL_DNN=OFF"
    }
    Invoke-Checked "cmake" $cmakeArgs $OllamaSourceRoot

    Invoke-Checked "cmake" @("--build", $buildDir, "--target", "ggml-sycl", "--parallel", "$Parallel") $OllamaSourceRoot

    $builtDll = Join-Path $buildDir "lib\ollama\ggml-sycl.dll"
    if (-not (Test-Path -LiteralPath $builtDll)) {
        throw "ggml-sycl.dll was not produced."
    }

    $rootOutDir = Join-Path $InstallPrefix "lib\ollama"
    New-Item -ItemType Directory -Path $rootOutDir -Force | Out-Null

    foreach ($baseName in @("ggml-base.dll", "libggml-base.dll")) {
        $baseSource = Join-Path $buildDir "lib\ollama\$baseName"
        if (Test-Path -LiteralPath $baseSource) {
            Copy-Item -LiteralPath $baseSource -Destination (Join-Path $rootOutDir $baseName) -Force
        }
    }

    Normalize-GgmlDllNames $rootOutDir
    Ensure-GgmlBaseDiscoveryCopy $rootOutDir

    Copy-Item -LiteralPath $builtDll -Destination (Join-Path $syclOutDir "ggml-sycl.dll") -Force
    Copy-OneApiRuntimeDependencies -Destination $syclOutDir -DnnlConfigDir $ResolvedDnnlDir -OneApiRoot $ResolvedOneApiRoot
    Copy-SyclRootRuntimeDependencies -SourceDirectory $syclOutDir -DestinationDirectory $rootOutDir
}

function Write-WindowsLaunchScripts {
    param([string]$InstallPrefix)

    $serveScript = @'
@echo off
setlocal

@REM Prefer bundled runtimes and avoid inheriting stale Intel device filters.
set "PATH=%~dp0;%~dp0lib\ollama;%~dp0lib\ollama\sycl;%PATH%"

@REM SYCL persistent cache can reduce warm-up time, but some recent Windows
@REM Intel runtime stacks become unstable when it is forced globally. Leave it
@REM as an opt-in environment override instead of enabling it by default.

@REM Flash Attention plus a quantized KV cache dramatically lowers the memory
@REM pressure of long-context runs. Keep them enabled by default on the
@REM packaged Windows build, but allow users to override both knobs.
if not defined OLLAMA_FLASH_ATTENTION (
  set "OLLAMA_FLASH_ATTENTION=1"
)
if not defined OLLAMA_KV_CACHE_TYPE (
  set "OLLAMA_KV_CACHE_TYPE=q8_0"
)

@REM Shared-memory Intel iGPUs can report a huge VRAM figure and make Ollama
@REM pick an oversized default context. Keep a conservative default unless the
@REM user explicitly overrides OLLAMA_CONTEXT_LENGTH before launch. Preserve a
@REM legacy OLLAMA_NUM_CTX override for older wrappers.
if not defined OLLAMA_CONTEXT_LENGTH (
  if defined OLLAMA_NUM_CTX (
    set "OLLAMA_CONTEXT_LENGTH=%OLLAMA_NUM_CTX%"
  ) else (
    set "OLLAMA_CONTEXT_LENGTH=4096"
  )
)

set "OLLAMA_NUM_GPU=999"
set "OLLAMA_KEEP_ALIVE=-1"
set "OLLAMA_HOST=127.0.0.1:11434"
set "NO_PROXY=localhost,127.0.0.1"
set "no_proxy=localhost,127.0.0.1"
set "ZES_ENABLE_SYSMAN=1"
set "GIN_MODE=release"

@REM Newer Ollama discovery relies on /info from a child runner. On some
@REM Windows Intel iGPU systems a stale selector like ONEAPI_DEVICE_SELECTOR=level_zero:0
@REM prevents SYCL discovery entirely. The portable wrapper clears those filters.
set "ONEAPI_DEVICE_SELECTOR="
set "SYCL_DEVICE_FILTER="
set "ZE_AFFINITY_MASK="

cd /d %~dp0
ollama.exe serve
'@

    $startScript = @'
@echo off

start "Ollama Serve" cmd /k "cd /d %~dp0 && call ollama-serve.bat"
'@

    Set-Content -LiteralPath (Join-Path $InstallPrefix "ollama-serve.bat") -Value $serveScript -NoNewline
    Set-Content -LiteralPath (Join-Path $InstallPrefix "start-ollama.bat") -Value $startScript -NoNewline
}

function Write-BuildMetadata {
    param(
        [string]$InstallPrefix,
        [string]$ResolvedRef,
        [string]$OllamaCommit,
        [string]$GoVersionText,
        [string]$LlamaUpstream,
        [string]$LlamaCommit,
        [string]$ResolvedDnnlDir = "",
        [string]$ResolvedSyclDeviceArch = ""
    )

    $metadata = [ordered]@{
        built_at_utc       = (Get-Date).ToUniversalTime().ToString("o")
        ollama_ref         = $ResolvedRef
        ollama_commit      = $OllamaCommit
        llama_sync_upstream = $LlamaUpstream
        llama_sync_commit  = $LlamaCommit
        go_version         = $GoVersionText
        llvm_mingw_version = $LlvmMingwVersion
        ollama_context_length_default = $script:DefaultOllamaNumCtx
        legacy_ollama_num_ctx_passthrough = $true
        sycl_cache_persistent_default = $false
        sycl_cache_persistent_opt_in = $true
        ollama_flash_attention_default = $true
        ollama_kv_cache_type_default = "q8_0"
        ggml_sycl_f16      = $EnableExperimentalSyclF16.IsPresent
        ggml_sycl_dnn      = $EnableExperimentalSyclDnn.IsPresent
        ggml_sycl_graph    = $true
        dnnl_dir           = $ResolvedDnnlDir
        ggml_sycl_device_arch = $ResolvedSyclDeviceArch
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
Patch-WindowsSyclIntegratedGpuSupport -OllamaRoot $ollamaSourceRoot -SyclDir $syclSourceDir
Patch-WindowsSharedGgmlBaseName -OllamaRoot $ollamaSourceRoot
Patch-WindowsSyclFlashAttentionSupport -OllamaRoot $ollamaSourceRoot
Patch-WindowsSharedMemoryGpuScheduling -OllamaRoot $ollamaSourceRoot
Patch-EmbeddingRequestContextDefaults -OllamaRoot $ollamaSourceRoot

$vsDevCmd = Resolve-VsDevCmd
$oneApiSetvars = Resolve-OneApiSetvars
$oneApiRoot = Split-Path -Parent $oneApiSetvars
$goRequestedVersion = if ($GoVersion) { Normalize-GoVersion $GoVersion } else { Get-GoVersionFromMod (Join-Path $ollamaSourceRoot "go.mod") }
$goInfo = Resolve-GoTool -RequestedVersion $goRequestedVersion
$llvmMingwBin = Ensure-LlvmMingw -Version $LlvmMingwVersion
$resolvedSyclDeviceArch = Resolve-SyclDeviceArch -RequestedArch $SyclDeviceArch
$resolvedDnnlDir = ""

if (-not $SkipSyclBuild) {
    Import-BatchEnvironment $oneApiSetvars @("intel64", "--force")
    $resolvedDnnlDir = Resolve-DnnlConfigDir -RequestedDir $DnnlDir -OneApiRoot $oneApiRoot
}

if (-not $SkipCpuBuild) {
    Build-CpuDependencies -OllamaSourceRoot $ollamaSourceRoot -InstallPrefix $OutputDir -VsDevCmd $vsDevCmd -LlvmBin $llvmMingwBin
}

if (-not $SkipGoBuild) {
    Build-OllamaBinary -OllamaSourceRoot $ollamaSourceRoot -InstallPrefix $OutputDir -GoExe $goInfo.GoExe -LlvmBin $llvmMingwBin -BuildVersion $buildVersion
}

if (-not $SkipSyclBuild) {
    Build-SyclBackend `
        -OllamaSourceRoot $ollamaSourceRoot `
        -InstallPrefix $OutputDir `
        -OneApiSetvars $oneApiSetvars `
        -ResolvedDnnlDir $resolvedDnnlDir `
        -ResolvedSyclDeviceArch $resolvedSyclDeviceArch `
        -ResolvedOneApiRoot $oneApiRoot `
        -UseExperimentalSyclF16 $EnableExperimentalSyclF16.IsPresent `
        -UseExperimentalSyclDnn $EnableExperimentalSyclDnn.IsPresent
}

Write-WindowsLaunchScripts -InstallPrefix $OutputDir

Write-BuildMetadata `
    -InstallPrefix $OutputDir `
    -ResolvedRef $resolvedRef `
    -OllamaCommit $ollamaCommit `
    -GoVersionText $goInfo.Version `
    -LlamaUpstream $syncInfo.Upstream `
    -LlamaCommit $syncInfo.FetchHead `
    -ResolvedDnnlDir $resolvedDnnlDir `
    -ResolvedSyclDeviceArch $resolvedSyclDeviceArch

Write-Step "Build complete"
Write-Host "Output: $((Resolve-Path $OutputDir).Path)"
