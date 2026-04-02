// DXGI and PDH Performance Counters Library
// This Windows-only (10/11) library provides accurate VRAM reporting
#include "ggml.h"
#include "ggml-impl.h"

#ifdef _WIN32
#    define WIN32_LEAN_AND_MEAN
#    ifndef NOMINMAX
#        define NOMINMAX
#    endif
#include <windows.h>
#include <pdh.h>
#include <dxgi1_2.h>
#include <algorithm>
#include <cctype>
#include <sstream>
#include <thread>
#include <filesystem>
#include <mutex>

namespace fs = std::filesystem;

static std::mutex ggml_dxgi_pdh_lock;

/*
Struct to keep track of GPU adapter information at runtime
*/
struct GpuInfo {
    std::wstring description; // debug field
    std::string deviceId;
    LUID luid;
    std::wstring pdhInstance;
    double dedicatedTotal = 0.0;
    double sharedTotal = 0.0;
    double dedicatedUsage = 0.0;
    double sharedUsage = 0.0;
};

/*
DLL Function Pointers
*/
struct {
    void *dxgi_dll_handle;
    void *pdh_dll_handle;
    // DXGI Functions
    HRESULT (*CreateDXGIFactory1)(REFIID riid, void **ppFactory);
    // PDH functions  
    PDH_STATUS (*PdhOpenQueryW)(LPCWSTR szDataSource, DWORD_PTR dwUserData, PDH_HQUERY *phQuery);
    PDH_STATUS (*PdhAddCounterW)(PDH_HQUERY hQuery, LPCWSTR szFullCounterPath, DWORD_PTR dwUserData, PDH_HCOUNTER *phCounter);
    PDH_STATUS (*PdhCollectQueryData)(PDH_HQUERY hQuery);
    PDH_STATUS (*PdhGetFormattedCounterValue)(PDH_HCOUNTER hCounter, DWORD dwFormat, LPDWORD lpdwType, PPDH_FMT_COUNTERVALUE pValue);
    PDH_STATUS (*PdhCloseQuery)(PDH_HQUERY hQuery);
} dll_functions {
    nullptr,nullptr,nullptr,nullptr,nullptr,nullptr,nullptr,nullptr
};

/*
Create a PDH Instance name
*/
static std::wstring generate_pdh_instance_name_from_luid(const LUID& luid) {
    std::wstringstream ss;
    ss << L"luid_0x" << std::hex << std::setw(8) << std::setfill(L'0') << std::uppercase << luid.HighPart
        << L"_0x" << std::setw(8) << std::setfill(L'0') << luid.LowPart;
    return ss.str();
}

/*
Conversion from Bytes to GigaBytes
*/
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
static void fetch_dxgi_adapter_desc1(const DXGI_ADAPTER_DESC1& desc, GpuInfo* info) {
    auto dedicatedVideoMemory = desc.DedicatedVideoMemory;
    auto sharedSystemMemory = desc.SharedSystemMemory;
    GGML_LOG_DEBUG("[DXGI] Adapter Description: %ls, LUID: 0x%08X%08X, Dedicated: %.2f GB, Shared: %.2f GB\n", desc.Description, desc.AdapterLuid.HighPart, desc.AdapterLuid.LowPart, b_to_gb(dedicatedVideoMemory), b_to_gb(sharedSystemMemory));
    if (info) {
        info->dedicatedTotal = dedicatedVideoMemory; // values in bytes
        info->sharedTotal = sharedSystemMemory;
    }
}

/*
Enumerate over the GPU adapters detected using DXGI and return their information
*/
static std::vector<GpuInfo> get_dxgi_gpu_infos() {
    std::vector<GpuInfo> infos;
    IDXGIFactory1* pFactory = nullptr;

    if (SUCCEEDED(dll_functions.CreateDXGIFactory1(__uuidof(IDXGIFactory1), (void**)&pFactory))) {
        UINT i = 0;
        IDXGIAdapter1* pAdapter = nullptr;
        while (pFactory->EnumAdapters1(i, &pAdapter) != DXGI_ERROR_NOT_FOUND) {
            DXGI_ADAPTER_DESC1 desc;
            pAdapter->GetDesc1(&desc);
            
            // Get all the GPU adapter info
            GpuInfo info;
            fetch_dxgi_adapter_desc1(desc, &info);
            info.description = std::wstring(desc.Description);
            info.deviceId = format_device_id(desc.DeviceId);
            info.luid = desc.AdapterLuid;
            info.pdhInstance = generate_pdh_instance_name_from_luid(desc.AdapterLuid);
            infos.push_back(info);

            pAdapter->Release();
            ++i;
        }
        pFactory->Release();
    }
    return infos;
}

static bool get_gpu_memory_usage(GpuInfo& gpu) {
    PDH_HQUERY query;
    if (dll_functions.PdhOpenQueryW(NULL, 0, &query) != ERROR_SUCCESS) {
        return false;
    }

    struct GpuCounters {
        PDH_HCOUNTER dedicated;
        PDH_HCOUNTER shared;
    };

    GpuCounters gpuCounter{};

    std::wstring dedicatedPath = L"\\GPU Adapter Memory(" + gpu.pdhInstance + L"*)\\Dedicated Usage";
    std::wstring sharedPath = L"\\GPU Adapter Memory(" + gpu.pdhInstance + L"*)\\Shared Usage";

    if (dll_functions.PdhAddCounterW(query, dedicatedPath.c_str(), 0, &gpuCounter.dedicated) != ERROR_SUCCESS ||
        dll_functions.PdhAddCounterW(query, sharedPath.c_str(), 0, &gpuCounter.shared) != ERROR_SUCCESS) {
            GGML_LOG_ERROR("Failed to add PDH counters for GPU %s\n", std::string(gpu.pdhInstance.begin(), gpu.pdhInstance.end()).c_str());
            dll_functions.PdhCloseQuery(query);
            return false;
    }

    // Sample the data
    if (dll_functions.PdhCollectQueryData(query) != ERROR_SUCCESS) {
            dll_functions.PdhCloseQuery(query);
            return false;
    }

    // Read final values
    PDH_FMT_COUNTERVALUE val;

    if (dll_functions.PdhGetFormattedCounterValue(gpuCounter.dedicated, PDH_FMT_DOUBLE, NULL, &val) == ERROR_SUCCESS)
        gpu.dedicatedUsage = val.doubleValue;

    if (dll_functions.PdhGetFormattedCounterValue(gpuCounter.shared, PDH_FMT_DOUBLE, NULL, &val) == ERROR_SUCCESS)
        gpu.sharedUsage = val.doubleValue;

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

    int ggml_dxgi_pdh_init() {
        GGML_LOG_DEBUG("%s called\n", __func__);
        std::lock_guard<std::mutex> lock(ggml_dxgi_pdh_lock);
        if (dll_functions.dxgi_dll_handle != NULL && dll_functions.pdh_dll_handle != NULL) {
            // Already initialized as we have both DLL handles
            return ERROR_SUCCESS;
        }

        DWORD old_mode = SetErrorMode(SEM_FAILCRITICALERRORS);
        SetErrorMode(old_mode | SEM_FAILCRITICALERRORS);
        fs::path libPath_dxgi = fs::path("\\Windows") / fs::path("System32") / fs::path("dxgi.dll");
        fs::path libPath_pdh = fs::path("\\Windows") / fs::path("System32") / fs::path("pdh.dll");

        // Call LoadLibraryW on both DLLs to ensure they are loaded
        void *dxgi = (void*)LoadLibraryW(libPath_dxgi.wstring().c_str());
        void *pdh = (void*)LoadLibraryW(libPath_pdh.wstring().c_str());
        if(dxgi == NULL || pdh == NULL) {
            if (dxgi != NULL) {
                FreeLibrary((HMODULE)(dxgi));
            }
            if (pdh != NULL) {
                FreeLibrary((HMODULE)(pdh));
            }
            SetErrorMode(old_mode);
            return ERROR_DLL_NOT_FOUND;
        }
        else {
            // save the dll handles
            dll_functions.dxgi_dll_handle = dxgi;
            dll_functions.pdh_dll_handle = pdh;
        }

        // Get pointers to the library functions loaded by the DLLs
        dll_functions.CreateDXGIFactory1 = (HRESULT (*)(REFIID riid, void **ppFactory)) GetProcAddress((HMODULE)(dll_functions.dxgi_dll_handle), "CreateDXGIFactory1");
        dll_functions.PdhOpenQueryW = (PDH_STATUS (*)(LPCWSTR szDataSource, DWORD_PTR dwUserData, PDH_HQUERY *phQuery)) GetProcAddress((HMODULE)(dll_functions.pdh_dll_handle), "PdhOpenQueryW");
        dll_functions.PdhAddCounterW = (PDH_STATUS (*)(PDH_HQUERY hQuery, LPCWSTR szFullCounterPath, DWORD_PTR dwUserData, PDH_HCOUNTER *phCounter)) GetProcAddress((HMODULE)(dll_functions.pdh_dll_handle), "PdhAddCounterW");
        dll_functions.PdhCollectQueryData = (PDH_STATUS (*)(PDH_HQUERY hQuery)) GetProcAddress((HMODULE)(dll_functions.pdh_dll_handle), "PdhCollectQueryData");
        dll_functions.PdhGetFormattedCounterValue = (PDH_STATUS (*)(PDH_HCOUNTER hCounter, DWORD dwFormat, LPDWORD lpdwType, PPDH_FMT_COUNTERVALUE pValue)) GetProcAddress((HMODULE)(dll_functions.pdh_dll_handle), "PdhGetFormattedCounterValue");
        dll_functions.PdhCloseQuery = (PDH_STATUS (*)(PDH_HQUERY hQuery)) GetProcAddress((HMODULE)(dll_functions.pdh_dll_handle), "PdhCloseQuery");
    
        SetErrorMode(old_mode); // set old mode before any return

        // Check if any function pointers are NULL (not found)
        if (dll_functions.CreateDXGIFactory1 == NULL || dll_functions.PdhOpenQueryW == NULL || dll_functions.PdhAddCounterW == NULL || dll_functions.PdhCollectQueryData == NULL || dll_functions.PdhGetFormattedCounterValue == NULL || dll_functions.PdhCloseQuery == NULL) {
            GGML_LOG_INFO("%s unable to locate required symbols in either dxgi.dll or pdh.dll", __func__);
            FreeLibrary((HMODULE)(dll_functions.dxgi_dll_handle));
            FreeLibrary((HMODULE)(dll_functions.pdh_dll_handle));
            dll_functions.dxgi_dll_handle = NULL;
            dll_functions.pdh_dll_handle = NULL;
            return ERROR_PROC_NOT_FOUND;
        }
    
        // No other initializations needed, successfully loaded the libraries and functions!
        return ERROR_SUCCESS;
    }

    void ggml_dxgi_pdh_release() {
        std::lock_guard<std::mutex> lock(ggml_dxgi_pdh_lock);
        if (dll_functions.dxgi_dll_handle == NULL && dll_functions.pdh_dll_handle == NULL) {
            // Already freed the DLLs
            return;
        }

        // Call FreeLibrary on both DLLs
        FreeLibrary((HMODULE)(dll_functions.dxgi_dll_handle));
        FreeLibrary((HMODULE)(dll_functions.pdh_dll_handle));

        dll_functions.dxgi_dll_handle = NULL;
        dll_functions.pdh_dll_handle = NULL;

        return; // successfully released
    }

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

} // extern "C"

#else // #ifdef _WIN32

extern "C" {

    // DXGI + PDH not available for Linux implementation
    int ggml_dxgi_pdh_init() {
        return -1;
    }
    void ggml_dxgi_pdh_release() {}
    int ggml_dxgi_pdh_get_device_memory(const char* luid, size_t *free, size_t *total, bool is_integrated_gpu) {
        return -1;
    }
    int ggml_dxgi_pdh_get_device_memory_by_adapter(const char * device_id, const char * description, size_t * free, size_t * total, bool is_integrated_gpu) {
        return -1;
    }

} // extern "C"

#endif // #ifdef _WIN32
