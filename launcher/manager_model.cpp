// SPDX-License-Identifier: GPL-3.0-only
#include "manager_model.h"

#include <bcrypt.h>
#include <objbase.h>
#include <shellapi.h>
#include <shlobj.h>
#include <softpub.h>
#include <wintrust.h>

#include <algorithm>
#include <array>
#include <cctype>
#include <cwctype>
#include <limits>
#include <map>
#include <memory>
#include <string_view>
#include <utility>

#ifndef FFB_STABLE_PACKAGE
#define FFB_STABLE_PACKAGE 0
#endif

#ifndef FFB_EXPECTED_SIGNER_SHA256
#define FFB_EXPECTED_SIGNER_SHA256 ""
#endif

#ifndef FFB_MANAGER_POLICY_SIGNER
#error FFB_MANAGER_POLICY_SIGNER must describe the build policy signer
#endif

#if FFB_STABLE_PACKAGE
#define FFB_MANAGER_POLICY_MODE "STABLE"
#else
#define FFB_MANAGER_POLICY_MODE "EXPERIMENTAL"
#endif

// The release packager reads this exported, NUL-terminated ASCII marker as raw
// bytes. It must remain a single literal: loading an untrusted candidate EXE to
// query its policy would execute attacker-controlled loader behavior.
extern "C" __declspec(dllexport) const char FFB_MANAGER_BUILD_POLICY_MARKER[] =
    "FFB_MANAGER_BUILD_POLICY_V1|MODE=" FFB_MANAGER_POLICY_MODE
    "|SIGNER_SHA256=" FFB_MANAGER_POLICY_SIGNER "|END";

namespace {

constexpr wchar_t kManifestName[] = L"SHA256SUMS.txt";
constexpr wchar_t kPipeName[] = L"\\\\.\\pipe\\ffb-interceptor-simhub-v1";
constexpr wchar_t kRegistryRoot[] = L"Software\\FFBInterceptor\\Launcher";
constexpr wchar_t kElevatedPluginOperationSwitch[] =
    L"--elevated-plugin-op";
constexpr wchar_t kManagerInvocationEventSwitch[] =
    L"--manager-invocation-event";
constexpr wchar_t kSimHubInstallPathSwitch[] = L"--simhub-install-path";
constexpr wchar_t kManagerInvocationEventPrefix[] =
    L"Local\\FFBInterceptor.ManagerElevation.v1.";
constexpr std::size_t kMaximumManifestBytes = 4U * 1024U * 1024U;
constexpr std::size_t kMaximumManifestEntries = 256;
constexpr std::size_t kMaximumProfiles = 64;
constexpr DWORD kMaximumProfileSubkeys = 256;
constexpr DWORD kMaximumRegistryStringBytes = 64U * 1024U;
constexpr unsigned long long kMaximumHashedFileBytes =
    512ULL * 1024ULL * 1024ULL;
constexpr unsigned long long kMaximumPackageBytes =
    1024ULL * 1024ULL * 1024ULL;

class UniqueHandle {
public:
    UniqueHandle() noexcept = default;
    explicit UniqueHandle(HANDLE value) noexcept : value_(value) {}
    ~UniqueHandle() { reset(); }
    UniqueHandle(const UniqueHandle&) = delete;
    UniqueHandle& operator=(const UniqueHandle&) = delete;
    HANDLE get() const noexcept { return value_; }
    explicit operator bool() const noexcept {
        return value_ && value_ != INVALID_HANDLE_VALUE;
    }
    void reset(HANDLE value = nullptr) noexcept {
        if (value_ && value_ != INVALID_HANDLE_VALUE) CloseHandle(value_);
        value_ = value;
    }
    HANDLE release() noexcept {
        HANDLE value = value_;
        value_ = nullptr;
        return value;
    }

private:
    HANDLE value_ = nullptr;
};

class UniqueRegistryKey {
public:
    UniqueRegistryKey() noexcept = default;
    explicit UniqueRegistryKey(HKEY value) noexcept : value_(value) {}
    ~UniqueRegistryKey() {
        if (value_) RegCloseKey(value_);
    }
    UniqueRegistryKey(const UniqueRegistryKey&) = delete;
    UniqueRegistryKey& operator=(const UniqueRegistryKey&) = delete;
    HKEY get() const noexcept { return value_; }
    HKEY* receive() noexcept { return &value_; }
    explicit operator bool() const noexcept { return value_ != nullptr; }

private:
    HKEY value_ = nullptr;
};

std::wstring join_path(const std::wstring& left, const std::wstring& right) {
    if (left.empty()) return right;
    if (right.empty()) return left;
    if (left.back() == L'\\' || left.back() == L'/') return left + right;
    return left + L"\\" + right;
}

std::wstring parent_path(std::wstring path) {
    while (path.size() > 3 && (path.back() == L'\\' || path.back() == L'/')) {
        path.pop_back();
    }
    const auto slash = path.find_last_of(L"\\/");
    if (slash == std::wstring::npos) return {};
    if (slash == 2 && path.size() >= 3 && path[1] == L':') return path.substr(0, 3);
    return path.substr(0, slash);
}

std::wstring lower_copy(std::wstring value) {
    std::transform(value.begin(), value.end(), value.begin(),
                   [](wchar_t character) {
                       return static_cast<wchar_t>(std::towlower(character));
                   });
    return value;
}

struct EnvironmentNameLess {
    bool operator()(const std::wstring& left,
                    const std::wstring& right) const noexcept {
        return _wcsicmp(left.c_str(), right.c_str()) < 0;
    }
};

bool get_known_folder_path(REFKNOWNFOLDERID folder_id,
                           std::wstring* path) {
    if (!path) return false;
    path->clear();
    PWSTR raw = nullptr;
    const HRESULT result = SHGetKnownFolderPath(
        folder_id, KF_FLAG_DONT_VERIFY, nullptr, &raw);
    if (FAILED(result) || !raw) {
        if (raw) CoTaskMemFree(raw);
        return false;
    }
    *path = raw;
    CoTaskMemFree(raw);
    return !path->empty() && ffb::manager::path_is_absolute_local(*path);
}

bool get_windows_directory_path(std::wstring* path) {
    if (!path) return false;
    path->clear();
    std::vector<wchar_t> buffer(32768);
    const UINT written = GetWindowsDirectoryW(
        buffer.data(), static_cast<UINT>(buffer.size()));
    if (written == 0 || written >= buffer.size()) return false;
    *path = std::wstring(buffer.data(), written);
    return ffb::manager::path_is_absolute_local(*path);
}

bool add_environment_value(
    std::map<std::wstring, std::wstring, EnvironmentNameLess>* values,
    const std::wstring& name, const std::wstring& value) {
    if (!values || name.empty() || value.empty() ||
        name.find(L'=') != std::wstring::npos ||
        name.find(L'\0') != std::wstring::npos ||
        value.find(L'\0') != std::wstring::npos) {
        return false;
    }
    (*values)[name] = value;
    return true;
}

bool starts_with_case_insensitive(const std::wstring& value,
                                  const std::wstring& prefix) {
    return value.size() >= prefix.size() &&
           _wcsnicmp(value.c_str(), prefix.c_str(), prefix.size()) == 0;
}

bool path_within_or_equal(const std::wstring& path,
                          const std::wstring& directory) {
    if (_wcsicmp(path.c_str(), directory.c_str()) == 0) return true;
    std::wstring prefix = directory;
    while (!prefix.empty() &&
           (prefix.back() == L'\\' || prefix.back() == L'/')) {
        prefix.pop_back();
    }
    prefix.push_back(L'\\');
    return starts_with_case_insensitive(path, prefix);
}

std::wstring strip_extended_prefix(const std::wstring& path) {
    if (path.rfind(L"\\\\?\\UNC\\", 0) == 0) return L"\\\\" + path.substr(8);
    if (path.rfind(L"\\\\?\\", 0) == 0) return path.substr(4);
    return path;
}

bool final_path_for_handle(HANDLE handle, std::wstring* path) {
    const DWORD required = GetFinalPathNameByHandleW(
        handle, nullptr, 0, FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
    if (required == 0 || required > 32768) return false;
    std::vector<wchar_t> buffer(static_cast<std::size_t>(required) + 1);
    const DWORD written = GetFinalPathNameByHandleW(
        handle, buffer.data(), static_cast<DWORD>(buffer.size()),
        FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
    if (written == 0 || written >= buffer.size()) return false;
    *path = strip_extended_prefix(std::wstring(buffer.data(), written));
    return true;
}

bool open_regular_file(const std::wstring& path, UniqueHandle* file,
                       std::wstring* final_path = nullptr) {
    UniqueHandle candidate(CreateFileW(
        path.c_str(), GENERIC_READ,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
        OPEN_EXISTING,
        FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT, nullptr));
    if (!candidate) return false;
    BY_HANDLE_FILE_INFORMATION information{};
    if (!GetFileInformationByHandle(candidate.get(), &information) ||
        (information.dwFileAttributes &
         (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) != 0) {
        return false;
    }
    if (final_path && !final_path_for_handle(candidate.get(), final_path)) {
        return false;
    }
    file->reset(candidate.release());
    return true;
}

bool read_file_limited(const std::wstring& path, std::size_t limit,
                       std::string* contents, std::wstring* error) {
    UniqueHandle file;
    if (!open_regular_file(path, &file)) {
        if (error) *error = L"找不到一般檔案，或檔案是重新導向連結。";
        return false;
    }
    LARGE_INTEGER size{};
    if (!GetFileSizeEx(file.get(), &size) || size.QuadPart < 0 ||
        static_cast<unsigned long long>(size.QuadPart) > limit) {
        if (error) *error = L"檔案大小超過安全上限。";
        return false;
    }
    contents->assign(static_cast<std::size_t>(size.QuadPart), '\0');
    std::size_t offset = 0;
    while (offset < contents->size()) {
        const DWORD requested = static_cast<DWORD>(std::min<std::size_t>(
            contents->size() - offset, std::numeric_limits<DWORD>::max()));
        DWORD read = 0;
        if (!ReadFile(file.get(), contents->data() + offset, requested, &read,
                      nullptr) ||
            read == 0) {
            if (error) *error = L"無法完整讀取檔案。";
            return false;
        }
        offset += read;
    }
    return true;
}

bool is_hex_character(char character) {
    return (character >= '0' && character <= '9') ||
           (character >= 'a' && character <= 'f') ||
           (character >= 'A' && character <= 'F');
}

std::wstring ascii_to_wide(const std::string& value) {
    return std::wstring(value.begin(), value.end());
}

bool normalize_manifest_path(const std::string& input,
                             std::wstring* normalized) {
    if (input.empty() || input.size() > 1024 || input.front() == '/' ||
        input.front() == '\\' || input.find(':') != std::string::npos) {
        return false;
    }
    std::wstring output;
    std::string segment;
    const auto flush_segment = [&]() -> bool {
        if (segment.empty() || segment.size() > 255 || segment == "." ||
            segment == ".." || segment.back() == '.' ||
            segment.back() == ' ') {
            return false;
        }
        std::string device_name = segment.substr(0, segment.find('.'));
        while (!device_name.empty() && device_name.back() == ' ') {
            device_name.pop_back();
        }
        std::transform(device_name.begin(), device_name.end(),
                       device_name.begin(), [](unsigned char character) {
                           return static_cast<char>(std::toupper(character));
                       });
        const bool numbered_device =
            device_name.size() == 4 &&
            (device_name.rfind("COM", 0) == 0 ||
             device_name.rfind("LPT", 0) == 0) &&
            device_name[3] >= '1' && device_name[3] <= '9';
        if (device_name == "CON" || device_name == "PRN" ||
            device_name == "AUX" || device_name == "NUL" ||
            device_name == "CONIN$" || device_name == "CONOUT$" ||
            numbered_device) {
            return false;
        }
        if (!output.empty()) output.push_back(L'\\');
        for (const unsigned char character : segment) {
            if (character < 0x20 || character >= 0x7f ||
                character == '<' || character == '>' || character == '"' ||
                character == '|' || character == '?' || character == '*') {
                return false;
            }
            output.push_back(static_cast<wchar_t>(character));
        }
        segment.clear();
        return true;
    };
    for (const char character : input) {
        if (character == '/' || character == '\\') {
            if (!flush_segment()) return false;
        } else {
            segment.push_back(character);
        }
    }
    if (!flush_segment()) return false;
    *normalized = output;
    return true;
}

bool enumerate_package_files(const std::wstring& root,
                             std::vector<std::wstring>* relative_paths,
                             std::wstring* error) {
    if (!relative_paths) return false;
    relative_paths->clear();
    struct Directory {
        std::wstring full_path;
        std::wstring relative_path;
    };
    std::vector<Directory> pending{{root, std::wstring{}}};
    std::size_t next_directory = 0;
    while (next_directory < pending.size()) {
        const Directory directory = pending[next_directory++];
        WIN32_FIND_DATAW data{};
        const std::wstring pattern = join_path(directory.full_path, L"*");
        HANDLE search = FindFirstFileW(pattern.c_str(), &data);
        if (search == INVALID_HANDLE_VALUE) {
            if (error) *error = L"無法列舉套件內容。";
            return false;
        }
        bool ok = true;
        do {
            const std::wstring name = data.cFileName;
            if (name == L"." || name == L"..") continue;
            const std::wstring relative =
                directory.relative_path.empty()
                    ? name
                    : join_path(directory.relative_path, name);
            if ((data.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0) {
                if (error) *error = L"套件含有重新導向連結：" + relative;
                ok = false;
                break;
            }
            if ((data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0) {
                if (pending.size() >= kMaximumManifestEntries + 1) {
                    if (error) *error = L"套件資料夾數量超過安全上限。";
                    ok = false;
                    break;
                }
                pending.push_back(
                    {join_path(directory.full_path, name), relative});
                continue;
            }
            if (directory.relative_path.empty() &&
                _wcsicmp(name.c_str(), kManifestName) == 0) {
                continue;
            }
            if (relative_paths->size() >= kMaximumManifestEntries) {
                if (error) *error = L"套件檔案數量超過安全上限。";
                ok = false;
                break;
            }
            relative_paths->push_back(relative);
        } while (FindNextFileW(search, &data));
        const DWORD enumeration_error = GetLastError();
        FindClose(search);
        if (!ok) return false;
        if (enumeration_error != ERROR_NO_MORE_FILES) {
            if (error) *error = L"列舉套件內容時發生錯誤。";
            return false;
        }
    }
    return true;
}

bool sha256_file(const std::wstring& path, const std::wstring& package_root,
                 std::wstring* digest, std::wstring* error) {
    UniqueHandle file;
    std::wstring final_file;
    if (!open_regular_file(path, &file, &final_file)) {
        if (error) *error = L"檔案不存在、不是一般檔案，或是重新導向連結。";
        return false;
    }
    LARGE_INTEGER file_size{};
    if (!GetFileSizeEx(file.get(), &file_size) || file_size.QuadPart < 0 ||
        static_cast<unsigned long long>(file_size.QuadPart) >
            kMaximumHashedFileBytes) {
        if (error) *error = L"檔案超過完整性驗證的 512 MiB 安全上限。";
        return false;
    }

    if (!package_root.empty()) {
        UniqueHandle root(CreateFileW(
            package_root.c_str(), FILE_READ_ATTRIBUTES,
            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
            OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, nullptr));
        std::wstring final_root;
        if (!root || !final_path_for_handle(root.get(), &final_root) ||
            !path_within_or_equal(final_file, final_root)) {
            if (error) *error = L"檔案解析後位於套件資料夾之外。";
            return false;
        }
    }

    BCRYPT_ALG_HANDLE algorithm = nullptr;
    BCRYPT_HASH_HANDLE hash = nullptr;
    DWORD object_length = 0;
    DWORD hash_length = 0;
    DWORD returned = 0;
    NTSTATUS status = BCryptOpenAlgorithmProvider(
        &algorithm, BCRYPT_SHA256_ALGORITHM, nullptr, 0);
    if (status >= 0) {
        status = BCryptGetProperty(
            algorithm, BCRYPT_OBJECT_LENGTH,
            reinterpret_cast<PUCHAR>(&object_length), sizeof(object_length),
            &returned, 0);
    }
    if (status >= 0) {
        status = BCryptGetProperty(
            algorithm, BCRYPT_HASH_LENGTH,
            reinterpret_cast<PUCHAR>(&hash_length), sizeof(hash_length),
            &returned, 0);
    }
    std::vector<unsigned char> object(object_length);
    std::vector<unsigned char> bytes(hash_length);
    if (status >= 0 && hash_length == 32) {
        status = BCryptCreateHash(algorithm, &hash, object.data(),
                                  static_cast<ULONG>(object.size()), nullptr, 0,
                                  0);
    }
    std::array<unsigned char, 64U * 1024U> buffer{};
    while (status >= 0) {
        DWORD read = 0;
        if (!ReadFile(file.get(), buffer.data(),
                      static_cast<DWORD>(buffer.size()), &read, nullptr)) {
            status = static_cast<NTSTATUS>(-1);
            break;
        }
        if (read == 0) break;
        status = BCryptHashData(hash, buffer.data(), read, 0);
    }
    if (status >= 0) {
        status = BCryptFinishHash(hash, bytes.data(),
                                  static_cast<ULONG>(bytes.size()), 0);
    }
    if (hash) BCryptDestroyHash(hash);
    if (algorithm) BCryptCloseAlgorithmProvider(algorithm, 0);
    if (status < 0 || bytes.size() != 32) {
        if (error) *error = L"Windows SHA-256 驗證失敗。";
        return false;
    }

    constexpr wchar_t kHex[] = L"0123456789ABCDEF";
    std::wstring result;
    result.reserve(bytes.size() * 2);
    for (const unsigned char value : bytes) {
        result.push_back(kHex[value >> 4]);
        result.push_back(kHex[value & 0x0f]);
    }
    *digest = result;
    return true;
}

bool valid_profile_id(const std::wstring& id) {
    if (id.size() != 38 || id.front() != L'{' || id.back() != L'}') return false;
    GUID parsed{};
    if (FAILED(CLSIDFromString(id.c_str(), &parsed))) return false;
    wchar_t canonical[40]{};
    return StringFromGUID2(parsed, canonical, 40) > 0 &&
           _wcsicmp(id.c_str(), canonical) == 0;
}

bool read_registry_string(HKEY key, const wchar_t* name,
                          std::wstring* value) {
    DWORD type = 0;
    DWORD size = 0;
    LONG result = RegGetValueW(key, nullptr, name, RRF_RT_REG_SZ, &type,
                               nullptr, &size);
    if (result == ERROR_FILE_NOT_FOUND) {
        value->clear();
        return true;
    }
    if (result != ERROR_SUCCESS || size < sizeof(wchar_t) ||
        size > kMaximumRegistryStringBytes || size % sizeof(wchar_t) != 0) {
        return false;
    }
    std::vector<wchar_t> buffer(size / sizeof(wchar_t));
    result = RegGetValueW(key, nullptr, name, RRF_RT_REG_SZ, &type,
                          buffer.data(), &size);
    if (result != ERROR_SUCCESS || buffer.empty() || buffer.back() != L'\0' ||
        std::find(buffer.begin(), buffer.end() - 1, L'\0') !=
            buffer.end() - 1) {
        return false;
    }
    value->assign(buffer.data(), buffer.size() - 1);
    return true;
}

bool write_registry_string(HKEY key, const wchar_t* name,
                           const std::wstring& value) {
    if (value.size() >= kMaximumRegistryStringBytes / sizeof(wchar_t) ||
        value.find(L'\0') != std::wstring::npos) {
        return false;
    }
    const DWORD bytes =
        static_cast<DWORD>((value.size() + 1) * sizeof(wchar_t));
    return RegSetValueExW(key, name, 0, REG_SZ,
                          reinterpret_cast<const BYTE*>(value.c_str()),
                          bytes) == ERROR_SUCCESS;
}

std::wstring bytes_to_hex(const unsigned char* bytes, std::size_t size) {
    constexpr wchar_t kHex[] = L"0123456789ABCDEF";
    std::wstring result;
    result.reserve(size * 2);
    for (std::size_t index = 0; index < size; ++index) {
        result.push_back(kHex[bytes[index] >> 4]);
        result.push_back(kHex[bytes[index] & 0x0f]);
    }
    return result;
}

std::wstring signer_thumbprint(PCCERT_CONTEXT certificate) {
    if (!certificate) return {};
    DWORD size = 0;
    if (CertGetCertificateContextProperty(
            certificate, CERT_SHA256_HASH_PROP_ID, nullptr, &size) &&
        size > 0 && size <= 128) {
        std::vector<unsigned char> bytes(size);
        if (CertGetCertificateContextProperty(
                certificate, CERT_SHA256_HASH_PROP_ID, bytes.data(), &size)) {
            return bytes_to_hex(bytes.data(), size);
        }
    }
    size = 32;
    std::vector<unsigned char> bytes(size);
    if (!CryptHashCertificate2(L"SHA256", 0, nullptr,
                               certificate->pbCertEncoded,
                               certificate->cbCertEncoded, bytes.data(),
                               &size)) {
        return {};
    }
    return bytes_to_hex(bytes.data(), size);
}

ffb::manager::SignatureEvidence verify_trusted_signature(
    const std::wstring& label, const std::wstring& path,
    bool require_revocation) {
    ffb::manager::SignatureEvidence evidence{};
    evidence.relative_path = label;
    if (!ffb::manager::file_is_regular(path)) {
        evidence.detail = L"簽章驗證目標缺少或不是一般檔案。";
        return evidence;
    }

    WINTRUST_FILE_INFO file{};
    file.cbStruct = sizeof(file);
    file.pcwszFilePath = path.c_str();
    WINTRUST_DATA trust{};
    trust.cbStruct = sizeof(trust);
    trust.dwUIChoice = WTD_UI_NONE;
    trust.fdwRevocationChecks =
        require_revocation ? WTD_REVOKE_WHOLECHAIN : WTD_REVOKE_NONE;
    trust.dwUnionChoice = WTD_CHOICE_FILE;
    trust.pFile = &file;
    trust.dwStateAction = WTD_STATEACTION_VERIFY;
    trust.dwProvFlags = require_revocation
                            ? WTD_REVOCATION_CHECK_CHAIN_EXCLUDE_ROOT
                            : (WTD_CACHE_ONLY_URL_RETRIEVAL |
                               WTD_REVOCATION_CHECK_NONE);
    GUID action = WINTRUST_ACTION_GENERIC_VERIFY_V2;
    const HWND trust_window = reinterpret_cast<HWND>(INVALID_HANDLE_VALUE);
    const LONG status = WinVerifyTrust(trust_window, &action, &trust);
    if (status == ERROR_SUCCESS && trust.hWVTStateData) {
        CRYPT_PROVIDER_DATA* provider =
            WTHelperProvDataFromStateData(trust.hWVTStateData);
        CRYPT_PROVIDER_SGNR* signer =
            provider ? WTHelperGetProvSignerFromChain(provider, 0, FALSE, 0)
                     : nullptr;
        if (signer && signer->csCertChain > 0 && signer->pasCertChain) {
            evidence.signer_sha256 =
                signer_thumbprint(signer->pasCertChain[0].pCert);
        }
    }
    trust.dwStateAction = WTD_STATEACTION_CLOSE;
    WinVerifyTrust(trust_window, &action, &trust);

    evidence.trusted = status == ERROR_SUCCESS &&
                       !evidence.signer_sha256.empty();
    if (evidence.trusted) {
        evidence.detail = require_revocation
                              ? L"Windows 信任鏈與撤銷狀態有效。"
                              : L"Windows 信任鏈有效。";
    } else {
        wchar_t code[24]{};
        swprintf_s(code, L"0x%08lX", static_cast<unsigned long>(status));
        evidence.detail = L"Windows 無法驗證受信任簽章（" +
                          std::wstring(code) + L"）。";
    }
    return evidence;
}

bool valid_sha256_text(const std::wstring& value) {
    return value.size() == 64 &&
           std::all_of(value.begin(), value.end(), [](wchar_t character) {
               return (character >= L'0' && character <= L'9') ||
                      (character >= L'a' && character <= L'f') ||
                      (character >= L'A' && character <= L'F');
           });
}

bool manifest_path_requires_signature(const std::wstring& path) {
    const std::size_t dot = path.find_last_of(L'.');
    if (dot == std::wstring::npos) return false;
    const std::wstring extension = lower_copy(path.substr(dot));
    return extension == L".exe" || extension == L".dll" ||
           extension == L".ps1" || extension == L".psm1";
}

std::wstring compile_time_signer_thumbprint() {
    const char* source = FFB_EXPECTED_SIGNER_SHA256;
    std::wstring result;
    while (*source) {
        result.push_back(static_cast<unsigned char>(*source));
        ++source;
    }
    return result;
}

bool open_registry_root(REGSAM access, UniqueRegistryKey* key,
                        bool create) {
    if (create) {
        return RegCreateKeyExW(HKEY_CURRENT_USER, kRegistryRoot, 0, nullptr,
                               REG_OPTION_NON_VOLATILE, access, nullptr,
                               key->receive(), nullptr) == ERROR_SUCCESS;
    }
    return RegOpenKeyExW(HKEY_CURRENT_USER, kRegistryRoot, 0, access,
                         key->receive()) == ERROR_SUCCESS;
}

std::wstring profile_key_path(const std::wstring& id) {
    return std::wstring(kRegistryRoot) + L"\\Profiles\\" + id;
}

}  // namespace

namespace ffb::manager {

std::wstring locate_bundle_root(const std::wstring& executable_path) {
    std::wstring candidate = parent_path(executable_path);
    for (int depth = 0; depth <= 4 && !candidate.empty(); ++depth) {
        if (file_is_regular(join_path(candidate, kManifestName)) &&
            file_is_regular(join_path(candidate, L"Install-SimHubPlugin.ps1"))) {
            return candidate;
        }
        const std::wstring parent = parent_path(candidate);
        if (parent.empty() || _wcsicmp(parent.c_str(), candidate.c_str()) == 0) {
            break;
        }
        candidate = parent;
    }
    return {};
}

PackageLayout make_package_layout(const std::wstring& root) {
    PackageLayout layout{};
    layout.root = root;
    layout.manifest_path = join_path(root, kManifestName);
    layout.installer_script = join_path(root, L"Install-SimHubPlugin.ps1");
    layout.uninstaller_script = join_path(root, L"Uninstall-SimHubPlugin.ps1");
    layout.launcher_x86 =
        join_path(root, L"launcher\\x86\\FFBInterceptor.Launcher.exe");
    layout.hook_x86 =
        join_path(root, L"launcher\\x86\\FFBInterceptor.Hook.dll");
    layout.launcher_x64 =
        join_path(root, L"launcher\\x64\\FFBInterceptor.Launcher.exe");
    layout.hook_x64 =
        join_path(root, L"launcher\\x64\\FFBInterceptor.Hook.dll");
    layout.simhub_core = join_path(root, L"simhub\\FFBInterceptor.Core.dll");
    layout.simhub_plugin =
        join_path(root, L"simhub\\FFBInterceptor.SimHub.dll");
    return layout;
}

bool parse_manifest_text(const std::string& text,
                         std::vector<ManifestEntry>* entries,
                         std::wstring* error) {
    if (!entries) return false;
    entries->clear();
    if (text.empty() || text.size() > kMaximumManifestBytes) {
        if (error) *error = L"套件 manifest 為空或超過大小上限。";
        return false;
    }
    std::map<std::wstring, bool> seen;
    std::size_t offset = 0;
    while (offset < text.size()) {
        const std::size_t end = text.find('\n', offset);
        std::string line = text.substr(
            offset, end == std::string::npos ? std::string::npos : end - offset);
        if (!line.empty() && line.back() == '\r') line.pop_back();
        offset = end == std::string::npos ? text.size() : end + 1;
        if (line.empty()) continue;
        if (line.size() < 67 || line[64] != ' ' || line[65] != ' ' ||
            !std::all_of(line.begin(), line.begin() + 64, is_hex_character)) {
            if (error) *error = L"套件 manifest 含有格式錯誤的資料列。";
            entries->clear();
            return false;
        }
        std::wstring path;
        if (!normalize_manifest_path(line.substr(66), &path)) {
            if (error) *error = L"套件 manifest 含有不安全的相對路徑。";
            entries->clear();
            return false;
        }
        const std::wstring key = lower_copy(path);
        if (seen.count(key) != 0 || entries->size() >= kMaximumManifestEntries) {
            if (error) *error = L"套件 manifest 含有重複路徑或項目過多。";
            entries->clear();
            return false;
        }
        seen.emplace(key, true);
        std::wstring digest = ascii_to_wide(line.substr(0, 64));
        std::transform(digest.begin(), digest.end(), digest.begin(),
                       [](wchar_t character) {
                           return static_cast<wchar_t>(std::towupper(character));
                       });
        entries->push_back(ManifestEntry{path, digest});
    }
    if (entries->empty()) {
        if (error) *error = L"套件 manifest 沒有任何檔案。";
        return false;
    }
    return true;
}

IntegrityReport verify_package_integrity(const PackageLayout& layout) {
    IntegrityReport report{};
    if (layout.root.empty()) {
        report.issues.push_back({L"SHA256SUMS.txt",
                                 L"找不到完整套件根目錄；請勿單獨移動管理器。"});
        return report;
    }
    if (!path_is_absolute_local(layout.root)) {
        report.issues.push_back(
            {L"SHA256SUMS.txt", L"套件必須解壓縮到本機磁碟，不能從網路路徑執行。"});
        return report;
    }
    std::string contents;
    std::wstring error;
    if (!read_file_limited(layout.manifest_path, kMaximumManifestBytes,
                           &contents, &error)) {
        report.issues.push_back({L"SHA256SUMS.txt", error});
        return report;
    }
    std::vector<ManifestEntry> entries;
    if (!parse_manifest_text(contents, &entries, &error)) {
        report.issues.push_back({L"SHA256SUMS.txt", error});
        return report;
    }

    std::map<std::wstring, const ManifestEntry*> by_path;
    for (const auto& entry : entries) {
        by_path.emplace(lower_copy(entry.relative_path), &entry);
    }
    std::vector<std::wstring> actual_files;
    if (!enumerate_package_files(layout.root, &actual_files, &error)) {
        report.issues.push_back({L"SHA256SUMS.txt", error});
        return report;
    }
    if (actual_files.size() != entries.size()) {
        report.issues.push_back(
            {L"SHA256SUMS.txt",
             L"manifest 未精確涵蓋解壓縮後的所有檔案。"});
        return report;
    }
    for (const auto& actual : actual_files) {
        if (by_path.count(lower_copy(actual)) == 0) {
            report.issues.push_back(
                {actual, L"套件含有 manifest 未列出的檔案。"});
            if (report.issues.size() >= 32) break;
        }
    }
    if (!report.issues.empty()) return report;

    const std::array<const wchar_t*, 11> required = {
        L"FFBInterceptor.Manager.exe",
        L"Install-SimHubPlugin.ps1",
        L"Uninstall-SimHubPlugin.ps1",
        L"FFBInterceptor.Common.ps1",
        L"launcher\\x86\\FFBInterceptor.Launcher.exe",
        L"launcher\\x86\\FFBInterceptor.Hook.dll",
        L"launcher\\x64\\FFBInterceptor.Launcher.exe",
        L"launcher\\x64\\FFBInterceptor.Hook.dll",
        L"simhub\\FFBInterceptor.Core.dll",
        L"simhub\\FFBInterceptor.SimHub.dll",
        L"Start-FFBInterceptor.ps1"};
    for (const wchar_t* path : required) {
        if (by_path.count(lower_copy(path)) == 0) {
            report.issues.push_back(
                {path, L"manifest 未列出這個啟動必要檔案。"});
        }
    }
    if (!report.issues.empty()) return report;

    unsigned long long package_bytes = 0;
    for (const auto& entry : entries) {
        WIN32_FILE_ATTRIBUTE_DATA attributes{};
        const std::wstring full_path =
            join_path(layout.root, entry.relative_path);
        if (!GetFileAttributesExW(full_path.c_str(), GetFileExInfoStandard,
                                  &attributes) ||
            (attributes.dwFileAttributes &
             (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) != 0) {
            report.issues.push_back(
                {entry.relative_path, L"檔案不存在、不是一般檔案，或是重新導向連結。"});
            if (report.issues.size() >= 32) break;
            continue;
        }
        const unsigned long long file_bytes =
            (static_cast<unsigned long long>(attributes.nFileSizeHigh) << 32) |
            attributes.nFileSizeLow;
        if (file_bytes > kMaximumHashedFileBytes ||
            package_bytes > kMaximumPackageBytes - file_bytes) {
            report.issues.push_back(
                {entry.relative_path,
                 L"套件檔案總量超過 1 GiB 完整性驗證安全上限。"});
            break;
        }
        package_bytes += file_bytes;
        std::wstring actual;
        if (!sha256_file(full_path, layout.root, &actual, &error)) {
            report.issues.push_back({entry.relative_path, error});
        } else if (_wcsicmp(actual.c_str(), entry.sha256.c_str()) != 0) {
            report.issues.push_back(
                {entry.relative_path, L"SHA-256 不符，檔案可能損毀或遭修改。"});
        } else {
            ++report.verified_files;
        }
        if (report.issues.size() >= 32) break;
    }
    report.valid = report.issues.empty() && report.verified_files == entries.size();
    return report;
}

bool file_sha256(const std::wstring& path, std::wstring* digest,
                 std::wstring* error) {
    if (!digest) return false;
    return sha256_file(path, std::wstring{}, digest, error);
}

SignaturePolicy build_signature_policy() {
    SignaturePolicy policy{};
    policy.required = FFB_STABLE_PACKAGE != 0;
    policy.expected_signer_sha256 = compile_time_signer_thumbprint();
    std::transform(policy.expected_signer_sha256.begin(),
                   policy.expected_signer_sha256.end(),
                   policy.expected_signer_sha256.begin(),
                   [](wchar_t character) {
                       return static_cast<wchar_t>(std::towupper(character));
                   });
    return policy;
}

SignatureReport evaluate_signature_policy(
    const SignaturePolicy& policy,
    const std::vector<SignatureEvidence>& evidence) {
    SignatureReport report{};
    report.all_trusted = !evidence.empty();
    if (evidence.empty()) {
        report.issues.push_back(
            {L"簽章政策", L"沒有任何簽章證據可供驗證。"});
    }
    if (!policy.expected_signer_sha256.empty() &&
        !valid_sha256_text(policy.expected_signer_sha256)) {
        report.issues.push_back(
            {L"簽章政策", L"編譯時指定的簽署者 SHA-256 格式無效。"});
    }

    std::wstring common_signer;
    for (const auto& item : evidence) {
        if (!item.trusted || !valid_sha256_text(item.signer_sha256)) {
            report.all_trusted = false;
            report.issues.push_back({item.relative_path, item.detail.empty()
                                                            ? L"缺少受信任簽章。"
                                                            : item.detail});
            continue;
        }
        const std::wstring signer = lower_copy(item.signer_sha256);
        if (common_signer.empty()) {
            common_signer = signer;
        } else if (common_signer != signer) {
            report.issues.push_back(
                {item.relative_path, L"簽署者與套件內其他必要檔案不同。"});
        }
        if (!policy.expected_signer_sha256.empty() &&
            _wcsicmp(item.signer_sha256.c_str(),
                     policy.expected_signer_sha256.c_str()) != 0) {
            report.issues.push_back(
                {item.relative_path, L"簽署者不是穩定版指定的憑證。"});
        }
    }
    report.common_signer_sha256 = common_signer;
    report.allowed = !policy.required || report.issues.empty();
    return report;
}

SignatureReport verify_package_signatures(
    const PackageLayout& layout, const std::wstring& running_manager_path,
    const SignaturePolicy& policy) {
    std::vector<SignatureEvidence> evidence;
    evidence.reserve(kMaximumManifestEntries + 1);
    std::map<std::wstring, bool> seen_paths;
    const auto add = [&](const std::wstring& label, const std::wstring& path) {
        if (seen_paths.emplace(lower_copy(path), true).second) {
            evidence.push_back(
                verify_trusted_signature(label, path, policy.required));
        }
    };
    add(L"FFBInterceptor.Manager.exe（執行中）", running_manager_path);
    std::string contents;
    std::wstring manifest_error;
    std::vector<ManifestEntry> entries;
    if (!read_file_limited(layout.manifest_path, kMaximumManifestBytes,
                           &contents, &manifest_error) ||
        !parse_manifest_text(contents, &entries, &manifest_error)) {
        evidence.push_back({L"SHA256SUMS.txt", false, std::wstring{},
                            manifest_error.empty()
                                ? L"無法取得簽章驗證所需的 manifest。"
                                : manifest_error});
    } else {
        for (const auto& entry : entries) {
            if (manifest_path_requires_signature(entry.relative_path)) {
                add(entry.relative_path,
                    join_path(layout.root, entry.relative_path));
            }
        }
    }
    return evaluate_signature_policy(policy, evidence);
}

PackageReadLock::~PackageReadLock() { clear(); }

PackageReadLock::PackageReadLock(PackageReadLock&& other) noexcept
    : handles_(std::move(other.handles_)) {
    other.handles_.clear();
}

PackageReadLock& PackageReadLock::operator=(PackageReadLock&& other) noexcept {
    if (this != &other) {
        clear();
        handles_ = std::move(other.handles_);
        other.handles_.clear();
    }
    return *this;
}

void PackageReadLock::clear() noexcept {
    for (HANDLE handle : handles_) {
        if (handle && handle != INVALID_HANDLE_VALUE) CloseHandle(handle);
    }
    handles_.clear();
}

bool acquire_package_read_lock(const PackageLayout& layout,
                               PackageReadLock* package_lock,
                               std::wstring* error) {
    if (!package_lock || !path_is_absolute_local(layout.root)) {
        if (error) *error = L"套件讀取鎖的根目錄無效。";
        return false;
    }
    package_lock->clear();

    std::wstring locked_root;
    const auto lock_path = [&](const std::wstring& path,
                               bool directory,
                               bool require_within_root) -> bool {
        const DWORD flags = FILE_FLAG_OPEN_REPARSE_POINT |
                            (directory ? FILE_FLAG_BACKUP_SEMANTICS : 0U);
        UniqueHandle candidate(CreateFileW(
            path.c_str(), directory ? FILE_READ_ATTRIBUTES : GENERIC_READ,
            FILE_SHARE_READ, nullptr, OPEN_EXISTING, flags, nullptr));
        if (!candidate) {
            if (error) *error = L"無法鎖定套件檔案以避免執行前遭替換：" + path;
            return false;
        }
        BY_HANDLE_FILE_INFORMATION information{};
        if (!GetFileInformationByHandle(candidate.get(), &information)) {
            if (error) *error = L"無法檢查套件鎖定路徑：" + path;
            return false;
        }
        const bool is_directory =
            (information.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
        if ((information.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0 ||
            is_directory != directory) {
            if (error) {
                *error = L"套件含有缺漏、類型錯誤或重新導向的路徑：" +
                         path;
            }
            return false;
        }
        std::wstring final_path;
        if (!final_path_for_handle(candidate.get(), &final_path)) {
            if (error) *error = L"無法解析套件鎖定路徑：" + path;
            return false;
        }
        if (require_within_root) {
            if (locked_root.empty() ||
                !path_within_or_equal(final_path, locked_root)) {
                if (error) *error = L"套件鎖定路徑解析到根目錄之外：" + path;
                return false;
            }
        } else {
            if (!path_is_absolute_local(final_path)) {
                if (error) *error = L"套件根目錄解析後不是本機磁碟。";
                return false;
            }
            locked_root = final_path;
        }
        package_lock->handles_.push_back(candidate.release());
        return true;
    };

    if (!lock_path(layout.root, true, false) ||
        !lock_path(layout.manifest_path, false, true)) {
        package_lock->clear();
        return false;
    }
    std::string contents;
    if (!read_file_limited(layout.manifest_path, kMaximumManifestBytes,
                           &contents, error)) {
        package_lock->clear();
        return false;
    }
    std::vector<ManifestEntry> entries;
    if (!parse_manifest_text(contents, &entries, error)) {
        package_lock->clear();
        return false;
    }
    std::map<std::wstring, bool> locked_directories;
    for (const auto& entry : entries) {
        std::size_t separator = entry.relative_path.find(L'\\');
        while (separator != std::wstring::npos) {
            const std::wstring relative_directory =
                entry.relative_path.substr(0, separator);
            if (locked_directories
                    .emplace(lower_copy(relative_directory), true)
                    .second &&
                !lock_path(join_path(layout.root, relative_directory), true,
                           true)) {
                package_lock->clear();
                return false;
            }
            separator = entry.relative_path.find(L'\\', separator + 1);
        }
        if (!lock_path(join_path(layout.root, entry.relative_path), false,
                       true)) {
            package_lock->clear();
            return false;
        }
    }
    return true;
}

bool split_game_arguments(const std::wstring& text,
                          std::vector<std::wstring>* arguments,
                          std::wstring* error) {
    if (!arguments) return false;
    arguments->clear();
    if (text.empty()) return true;
    if (text.size() > 32768) {
        if (error) *error = L"遊戲參數超過 Windows 命令列長度上限。";
        return false;
    }
    std::wstring command = L"ffb-placeholder.exe ";
    command += text;
    int count = 0;
    LPWSTR* parsed = CommandLineToArgvW(command.c_str(), &count);
    if (!parsed || count < 1) {
        if (parsed) LocalFree(parsed);
        if (error) *error = L"無法解析遊戲參數。";
        return false;
    }
    for (int index = 1; index < count; ++index) {
        arguments->emplace_back(parsed[index]);
    }
    LocalFree(parsed);
    return true;
}

std::wstring quote_command_argument(const std::wstring& argument) {
    if (argument.empty()) return L"\"\"";
    if (argument.find_first_of(L" \t\"") == std::wstring::npos) {
        return argument;
    }
    std::wstring quoted = L"\"";
    std::size_t backslashes = 0;
    for (const wchar_t character : argument) {
        if (character == L'\\') {
            ++backslashes;
        } else if (character == L'\"') {
            quoted.append(backslashes * 2 + 1, L'\\');
            quoted.push_back(L'\"');
            backslashes = 0;
        } else {
            quoted.append(backslashes, L'\\');
            backslashes = 0;
            quoted.push_back(character);
        }
    }
    quoted.append(backslashes * 2, L'\\');
    quoted.push_back(L'\"');
    return quoted;
}

bool manager_invocation_event_name_is_valid(const std::wstring& name) {
    constexpr std::size_t kEntropyHexLength = 64;
    const std::wstring prefix = kManagerInvocationEventPrefix;
    if (name.size() != prefix.size() + kEntropyHexLength ||
        name.compare(0, prefix.size(), prefix) != 0) {
        return false;
    }
    return std::all_of(
        name.begin() + static_cast<std::wstring::difference_type>(prefix.size()),
        name.end(), [](wchar_t character) {
            return (character >= L'0' && character <= L'9') ||
                   (character >= L'A' && character <= L'F');
        });
}

ElevatedPluginParseResult parse_elevated_plugin_request(
    const std::vector<std::wstring>& arguments,
    ElevatedPluginRequest* request, std::wstring* error) {
    if (arguments.empty() || arguments[0] != kElevatedPluginOperationSwitch) {
        return ElevatedPluginParseResult::not_requested;
    }
    if (!request) return ElevatedPluginParseResult::invalid;
    *request = ElevatedPluginRequest{};
    const bool base_grammar =
        (arguments.size() == 4 || arguments.size() == 6) &&
        arguments[2] == kManagerInvocationEventSwitch &&
        manager_invocation_event_name_is_valid(arguments[3]);
    if (!base_grammar) {
        if (error) *error = L"受控提權 helper 的參數格式無效。";
        return ElevatedPluginParseResult::invalid;
    }
    if (arguments[1] == L"install") {
        request->operation = ElevatedPluginOperation::install;
        if (arguments.size() == 6) {
            if (arguments[4] != kSimHubInstallPathSwitch ||
                !path_is_absolute_local(arguments[5])) {
                if (error) *error = L"受控安裝的 SimHub 路徑無效。";
                return ElevatedPluginParseResult::invalid;
            }
            request->simhub_install_path = arguments[5];
        }
    } else if (arguments[1] == L"uninstall" && arguments.size() == 4) {
        request->operation = ElevatedPluginOperation::uninstall;
    } else {
        if (error) *error = L"受控提權 helper 只接受固定的安裝或解除安裝操作。";
        return ElevatedPluginParseResult::invalid;
    }
    request->manager_invocation_event = arguments[3];
    return ElevatedPluginParseResult::valid;
}

std::wstring redact_user_path(const std::wstring& text) {
    DWORD required = GetEnvironmentVariableW(L"USERPROFILE", nullptr, 0);
    if (required == 0 || required > 32768) return text;
    std::vector<wchar_t> buffer(required);
    if (GetEnvironmentVariableW(L"USERPROFILE", buffer.data(), required) == 0) {
        return text;
    }
    const std::wstring home(buffer.data());
    if (home.empty()) return text;
    std::wstring result = text;
    std::size_t offset = 0;
    while (offset < result.size()) {
        const std::wstring remaining = result.substr(offset);
        const std::wstring lower_remaining = lower_copy(remaining);
        const std::size_t found = lower_remaining.find(lower_copy(home));
        if (found == std::wstring::npos) break;
        const std::size_t absolute = offset + found;
        result.replace(absolute, home.size(), L"%USERPROFILE%");
        offset = absolute + 13;
    }
    return result;
}

std::wstring launcher_path_for(const PackageLayout& layout,
                               ffb::launcher::PeArchitecture architecture) {
    return architecture == ffb::launcher::PeArchitecture::x86
               ? layout.launcher_x86
               : architecture == ffb::launcher::PeArchitecture::x64
                     ? layout.launcher_x64
                     : std::wstring{};
}

std::wstring hook_path_for(const PackageLayout& layout,
                           ffb::launcher::PeArchitecture architecture) {
    return architecture == ffb::launcher::PeArchitecture::x86
               ? layout.hook_x86
               : architecture == ffb::launcher::PeArchitecture::x64
                     ? layout.hook_x64
                     : std::wstring{};
}

bool file_is_regular(const std::wstring& path) {
    UniqueHandle file;
    return open_regular_file(path, &file);
}

bool locate_system_windows_powershell(std::wstring* path,
                                      std::wstring* error) {
    if (!path) return false;
    path->clear();

    std::vector<wchar_t> directory(32768);
    const UINT written = GetSystemDirectoryW(
        directory.data(), static_cast<UINT>(directory.size()));
    if (written == 0 || written >= directory.size()) {
        if (error) *error = L"Windows 無法解析原生 System32 目錄。";
        return false;
    }
    const std::wstring system_directory(directory.data(), written);
    if (!path_is_absolute_local(system_directory)) {
        if (error) *error = L"Windows 回報的 System32 不是本機絕對路徑。";
        return false;
    }

    UniqueHandle directory_handle(CreateFileW(
        system_directory.c_str(), FILE_READ_ATTRIBUTES,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
        OPEN_EXISTING,
        FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, nullptr));
    BY_HANDLE_FILE_INFORMATION directory_information{};
    std::wstring final_directory;
    if (!directory_handle ||
        !GetFileInformationByHandle(directory_handle.get(),
                                    &directory_information) ||
        (directory_information.dwFileAttributes &
         (FILE_ATTRIBUTE_REPARSE_POINT)) != 0 ||
        (directory_information.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) ==
            0 ||
        !final_path_for_handle(directory_handle.get(), &final_directory)) {
        if (error) *error = L"無法以安全 handle 驗證原生 System32 目錄。";
        return false;
    }

    const std::wstring relative =
        L"WindowsPowerShell\\v1.0\\powershell.exe";
    const std::wstring candidate = join_path(system_directory, relative);
    UniqueHandle executable;
    std::wstring final_executable;
    if (!open_regular_file(candidate, &executable, &final_executable)) {
        if (error) {
            *error = L"找不到 System32 內建 Windows PowerShell 執行檔。";
        }
        return false;
    }
    const std::wstring expected = join_path(final_directory, relative);
    if (_wcsicmp(final_executable.c_str(), expected.c_str()) != 0) {
        if (error) {
            *error = L"Windows PowerShell 路徑解析到 System32 之外，已拒絕執行。";
        }
        return false;
    }
    *path = std::move(final_executable);
    return true;
}

bool build_sanitized_powershell_environment(
    const std::wstring& power_shell, std::vector<wchar_t>* environment,
    std::wstring* error) {
    if (!environment) return false;
    environment->clear();

    std::wstring verified_power_shell;
    if (!locate_system_windows_powershell(&verified_power_shell, error) ||
        _wcsicmp(power_shell.c_str(), verified_power_shell.c_str()) != 0) {
        if (error && error->empty()) {
            *error = L"只允許替 System32 內建 Windows PowerShell 建立環境。";
        }
        return false;
    }
    const std::wstring power_shell_home = parent_path(verified_power_shell);
    const std::wstring system_directory =
        parent_path(parent_path(power_shell_home));
    std::wstring windows_directory;
    if (power_shell_home.empty() || system_directory.empty() ||
        !get_windows_directory_path(&windows_directory) ||
        _wcsicmp(parent_path(system_directory).c_str(),
                 windows_directory.c_str()) != 0) {
        if (error) *error = L"無法確認 Windows 與 System32 的固定路徑。";
        return false;
    }

    std::wstring profile;
    std::wstring local_app_data;
    std::wstring program_data;
    std::wstring program_files;
    if (!get_known_folder_path(FOLDERID_Profile, &profile) ||
        !get_known_folder_path(FOLDERID_LocalAppData, &local_app_data) ||
        !get_known_folder_path(FOLDERID_ProgramData, &program_data) ||
        !get_known_folder_path(FOLDERID_ProgramFiles, &program_files)) {
        if (error) *error = L"Windows 無法解析受控 PowerShell 所需的已知資料夾。";
        return false;
    }

    std::map<std::wstring, std::wstring, EnvironmentNameLess> values;
    const std::wstring temporary = join_path(local_app_data, L"Temp");
    const std::wstring module_path = join_path(power_shell_home, L"Modules");
    if (!add_environment_value(&values, L"SystemRoot", windows_directory) ||
        !add_environment_value(&values, L"WINDIR", windows_directory) ||
        !add_environment_value(
            &values, L"Path", system_directory + L";" + windows_directory) ||
        !add_environment_value(&values, L"PSModulePath", module_path) ||
        !add_environment_value(&values, L"USERPROFILE", profile) ||
        !add_environment_value(&values, L"LOCALAPPDATA", local_app_data) ||
        !add_environment_value(&values, L"ProgramData", program_data) ||
        !add_environment_value(&values, L"ProgramFiles", program_files) ||
        !add_environment_value(&values, L"TEMP", temporary) ||
        !add_environment_value(&values, L"TMP", temporary)) {
        if (error) *error = L"無法建立受控 PowerShell 的最小環境。";
        return false;
    }

    std::wstring optional;
    if (get_known_folder_path(FOLDERID_RoamingAppData, &optional)) {
        add_environment_value(&values, L"APPDATA", optional);
    }
    if (get_known_folder_path(FOLDERID_ProgramFilesX86, &optional)) {
        add_environment_value(&values, L"ProgramFiles(x86)", optional);
    }
    if (get_known_folder_path(FOLDERID_ProgramFilesX64, &optional)) {
        add_environment_value(&values, L"ProgramW6432", optional);
    }

    std::size_t required = 1;
    for (const auto& entry : values) {
        required += entry.first.size() + 1 + entry.second.size() + 1;
    }
    if (required > 32767) {
        if (error) *error = L"受控 PowerShell 的環境超過 Windows 長度上限。";
        return false;
    }
    environment->reserve(required);
    for (const auto& entry : values) {
        environment->insert(environment->end(), entry.first.begin(),
                            entry.first.end());
        environment->push_back(L'=');
        environment->insert(environment->end(), entry.second.begin(),
                            entry.second.end());
        environment->push_back(L'\0');
    }
    environment->push_back(L'\0');
    return true;
}

bool path_is_absolute_local(const std::wstring& path) {
    if (path.size() < 3 ||
        !((path[0] >= L'A' && path[0] <= L'Z') ||
          (path[0] >= L'a' && path[0] <= L'z')) ||
        path[1] != L':' || (path[2] != L'\\' && path[2] != L'/')) {
        return false;
    }
    const wchar_t root[] = {path[0], L':', L'\\', L'\0'};
    const UINT drive_type = GetDriveTypeW(root);
    return drive_type == DRIVE_FIXED || drive_type == DRIVE_REMOVABLE ||
           drive_type == DRIVE_CDROM || drive_type == DRIVE_RAMDISK;
}

std::wstring find_simhub_executable(const std::wstring& directory) {
    for (const wchar_t* name : {L"SimHubWPF.exe", L"SimHub.exe"}) {
        const std::wstring candidate = join_path(directory, name);
        if (file_is_regular(candidate)) return candidate;
    }
    return {};
}

bool simhub_pipe_ready(DWORD wait_milliseconds) {
    return WaitNamedPipeW(kPipeName, wait_milliseconds) != FALSE;
}

bool query_current_process_elevation(bool* elevated, std::wstring* error) {
    if (!elevated) return false;
    *elevated = false;
    HANDLE raw = nullptr;
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &raw)) {
        if (error) *error = L"無法開啟目前程序的權杖。";
        return false;
    }
    UniqueHandle token(raw);
    TOKEN_ELEVATION elevation{};
    DWORD returned = 0;
    if (!GetTokenInformation(token.get(), TokenElevation, &elevation,
                             sizeof(elevation), &returned) ||
        returned < sizeof(elevation)) {
        if (error) *error = L"無法確認目前程序是否具有系統管理員權限。";
        return false;
    }
    *elevated = elevation.TokenIsElevated != 0;
    return true;
}

bool ProfileStore::load(std::vector<Profile>* profiles,
                        std::wstring* active_id,
                        std::wstring* error) const {
    if (!profiles || !active_id) return false;
    profiles->clear();
    active_id->clear();
    UniqueRegistryKey root;
    const LONG root_result = RegOpenKeyExW(HKEY_CURRENT_USER, kRegistryRoot, 0,
                                           KEY_READ, root.receive());
    if (root_result != ERROR_SUCCESS) {
        if (root_result == ERROR_FILE_NOT_FOUND) return true;
        if (error) *error = L"無法讀取目前使用者的啟動設定。";
        return false;
    }
    if (!read_registry_string(root.get(), L"ActiveProfile", active_id)) {
        if (error) *error = L"目前使用中的設定檔格式錯誤。";
        return false;
    }

    UniqueRegistryKey profiles_key;
    if (RegOpenKeyExW(root.get(), L"Profiles", 0, KEY_READ,
                      profiles_key.receive()) == ERROR_FILE_NOT_FOUND) {
        active_id->clear();
        return true;
    }
    if (!profiles_key) {
        if (error) *error = L"無法讀取遊戲設定檔。";
        return false;
    }
    for (DWORD index = 0;; ++index) {
        wchar_t name[64]{};
        DWORD name_length = static_cast<DWORD>(std::size(name));
        const LONG enumeration = RegEnumKeyExW(
            profiles_key.get(), index, name, &name_length, nullptr, nullptr,
            nullptr, nullptr);
        if (enumeration == ERROR_NO_MORE_ITEMS) break;
        if (enumeration != ERROR_SUCCESS) {
            if (error) *error = L"列舉遊戲設定檔時發生錯誤。";
            return false;
        }
        if (index >= kMaximumProfileSubkeys) {
            if (error) *error = L"遊戲設定檔的登錄子機碼數量超過安全上限。";
            return false;
        }
        const std::wstring id(name, name_length);
        if (!valid_profile_id(id)) continue;
        if (profiles->size() >= kMaximumProfiles) {
            if (error) *error = L"遊戲設定檔數量超過 64 個上限。";
            return false;
        }
        UniqueRegistryKey profile_key;
        if (RegOpenKeyExW(profiles_key.get(), id.c_str(), 0, KEY_READ,
                          profile_key.receive()) != ERROR_SUCCESS) {
            continue;
        }
        Profile profile{};
        profile.id = id;
        if (!read_registry_string(profile_key.get(), L"Name", &profile.name) ||
            !read_registry_string(profile_key.get(), L"GamePath",
                                  &profile.game_path) ||
            !read_registry_string(profile_key.get(), L"Arguments",
                                  &profile.game_arguments) ||
            !read_registry_string(profile_key.get(), L"SimHubPath",
                                  &profile.simhub_path)) {
            if (error) *error = L"遊戲設定檔含有無效或過大的字串。";
            return false;
        }
        DWORD auto_start = 1;
        DWORD size = sizeof(auto_start);
        DWORD type = 0;
        const LONG read_auto = RegGetValueW(
            profile_key.get(), nullptr, L"AutoStartSimHub", RRF_RT_REG_DWORD,
            &type, &auto_start, &size);
        if (read_auto != ERROR_FILE_NOT_FOUND &&
            (read_auto != ERROR_SUCCESS || size != sizeof(auto_start))) {
            if (error) *error = L"SimHub 自動啟動偏好格式錯誤。";
            return false;
        }
        profile.auto_start_simhub =
            read_auto == ERROR_FILE_NOT_FOUND ||
            (read_auto == ERROR_SUCCESS && auto_start != 0);
        if (profile.name.empty()) profile.name = L"未命名遊戲";
        profiles->push_back(std::move(profile));
    }
    if (!active_id->empty() && !valid_profile_id(*active_id)) {
        active_id->clear();
    }
    return true;
}

bool ProfileStore::save(const Profile& profile, bool make_active,
                        std::wstring* error) const {
    if (!valid_profile_id(profile.id) || profile.name.empty() ||
        profile.name.size() > 200 || profile.game_path.size() > 32767 ||
        profile.game_arguments.size() > 32767 ||
        profile.simhub_path.size() > 32767 ||
        profile.name.find(L'\0') != std::wstring::npos ||
        profile.game_path.find(L'\0') != std::wstring::npos ||
        profile.game_arguments.find(L'\0') != std::wstring::npos ||
        profile.simhub_path.find(L'\0') != std::wstring::npos) {
        if (error) *error = L"設定檔欄位為空、過長或識別碼無效。";
        return false;
    }
    UniqueRegistryKey key;
    const std::wstring path = profile_key_path(profile.id);
    if (RegCreateKeyExW(HKEY_CURRENT_USER, path.c_str(), 0, nullptr,
                        REG_OPTION_NON_VOLATILE, KEY_READ | KEY_WRITE, nullptr,
                        key.receive(), nullptr) != ERROR_SUCCESS ||
        !write_registry_string(key.get(), L"Name", profile.name) ||
        !write_registry_string(key.get(), L"GamePath", profile.game_path) ||
        !write_registry_string(key.get(), L"Arguments",
                               profile.game_arguments) ||
        !write_registry_string(key.get(), L"SimHubPath",
                               profile.simhub_path)) {
        if (error) *error = L"無法儲存目前使用者的遊戲設定檔。";
        return false;
    }
    const DWORD auto_start = profile.auto_start_simhub ? 1U : 0U;
    if (RegSetValueExW(key.get(), L"AutoStartSimHub", 0, REG_DWORD,
                       reinterpret_cast<const BYTE*>(&auto_start),
                       sizeof(auto_start)) != ERROR_SUCCESS) {
        if (error) *error = L"無法儲存 SimHub 啟動偏好。";
        return false;
    }
    return !make_active || set_active(profile.id, error);
}

bool ProfileStore::erase(const std::wstring& id, std::wstring* error) const {
    if (!valid_profile_id(id)) {
        if (error) *error = L"拒絕刪除識別碼無效的設定檔。";
        return false;
    }
    const LONG result = RegDeleteTreeW(HKEY_CURRENT_USER,
                                       profile_key_path(id).c_str());
    if (result != ERROR_SUCCESS && result != ERROR_FILE_NOT_FOUND) {
        if (error) *error = L"無法刪除遊戲設定檔。";
        return false;
    }
    return true;
}

bool ProfileStore::set_active(const std::wstring& id,
                              std::wstring* error) const {
    if (!valid_profile_id(id)) {
        if (error) *error = L"使用中的設定檔識別碼無效。";
        return false;
    }
    UniqueRegistryKey root;
    if (!open_registry_root(KEY_READ | KEY_WRITE, &root, true) ||
        !write_registry_string(root.get(), L"ActiveProfile", id)) {
        if (error) *error = L"無法更新目前使用中的設定檔。";
        return false;
    }
    return true;
}

std::wstring ProfileStore::create_id() {
    GUID id{};
    if (FAILED(CoCreateGuid(&id))) return {};
    wchar_t text[40]{};
    return StringFromGUID2(id, text, 40) > 0 ? std::wstring(text)
                                             : std::wstring{};
}

}  // namespace ffb::manager
