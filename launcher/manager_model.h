// SPDX-License-Identifier: GPL-3.0-only
#pragma once

#include <windows.h>

#include <cstddef>
#include <string>
#include <vector>

#include "pe_arch.h"

namespace ffb::manager {

struct Profile {
    std::wstring id;
    std::wstring name;
    std::wstring game_path;
    std::wstring game_arguments;
    std::wstring simhub_path;
    bool auto_start_simhub = true;
};

struct PackageLayout {
    std::wstring root;
    std::wstring manifest_path;
    std::wstring installer_script;
    std::wstring uninstaller_script;
    std::wstring launcher_x86;
    std::wstring hook_x86;
    std::wstring launcher_x64;
    std::wstring hook_x64;
    std::wstring simhub_core;
    std::wstring simhub_plugin;
};

struct ManifestEntry {
    std::wstring relative_path;
    std::wstring sha256;
};

struct IntegrityIssue {
    std::wstring relative_path;
    std::wstring detail;
};

struct IntegrityReport {
    bool valid = false;
    std::size_t verified_files = 0;
    std::vector<IntegrityIssue> issues;
};

struct SignatureEvidence {
    std::wstring relative_path;
    bool trusted = false;
    std::wstring signer_sha256;
    std::wstring detail;
};

struct SignaturePolicy {
    bool required = false;
    std::wstring expected_signer_sha256;
};

struct SignatureReport {
    bool allowed = false;
    bool all_trusted = false;
    std::wstring common_signer_sha256;
    std::vector<IntegrityIssue> issues;
};

enum class ElevatedPluginOperation { install, uninstall };

struct ElevatedPluginRequest {
    ElevatedPluginOperation operation = ElevatedPluginOperation::install;
    std::wstring manager_invocation_event;
    std::wstring simhub_install_path;
};

enum class ElevatedPluginParseResult { not_requested, valid, invalid };

class PackageReadLock {
public:
    PackageReadLock() noexcept = default;
    ~PackageReadLock();
    PackageReadLock(const PackageReadLock&) = delete;
    PackageReadLock& operator=(const PackageReadLock&) = delete;
    PackageReadLock(PackageReadLock&& other) noexcept;
    PackageReadLock& operator=(PackageReadLock&& other) noexcept;
    bool empty() const noexcept { return handles_.empty(); }

private:
    friend bool acquire_package_read_lock(const PackageLayout&,
                                          PackageReadLock*, std::wstring*);
    void clear() noexcept;
    std::vector<HANDLE> handles_;
};

// Returns the package root for a manager placed either at the bundle root or
// under launcher/<architecture>. Returns an empty string if no package marker
// can be found within four parent directories.
std::wstring locate_bundle_root(const std::wstring& executable_path);
PackageLayout make_package_layout(const std::wstring& root);

bool parse_manifest_text(const std::string& text,
                         std::vector<ManifestEntry>* entries,
                         std::wstring* error);
IntegrityReport verify_package_integrity(const PackageLayout& layout);
bool file_sha256(const std::wstring& path, std::wstring* digest,
                 std::wstring* error);
SignaturePolicy build_signature_policy();
SignatureReport evaluate_signature_policy(
    const SignaturePolicy& policy,
    const std::vector<SignatureEvidence>& evidence);
SignatureReport verify_package_signatures(
    const PackageLayout& layout, const std::wstring& running_manager_path,
    const SignaturePolicy& policy);
bool acquire_package_read_lock(const PackageLayout& layout,
                               PackageReadLock* package_lock,
                               std::wstring* error);

bool split_game_arguments(const std::wstring& text,
                          std::vector<std::wstring>* arguments,
                          std::wstring* error);
std::wstring quote_command_argument(const std::wstring& argument);
std::wstring redact_user_path(const std::wstring& text);

// Recognizes only the Manager's private, fixed elevated-helper grammar. A
// malformed helper request is distinguished from an ordinary GUI invocation
// so it can fail before the single-instance mutex or any window is created.
ElevatedPluginParseResult parse_elevated_plugin_request(
    const std::vector<std::wstring>& arguments,
    ElevatedPluginRequest* request, std::wstring* error);
bool manager_invocation_event_name_is_valid(const std::wstring& name);

std::wstring launcher_path_for(const PackageLayout& layout,
                               ffb::launcher::PeArchitecture architecture);
std::wstring hook_path_for(const PackageLayout& layout,
                           ffb::launcher::PeArchitecture architecture);

bool file_is_regular(const std::wstring& path);
bool path_is_absolute_local(const std::wstring& path);
// Resolves the native Windows system PowerShell by handle. The returned path
// is an exact local file under the resolved System32 directory; no PATH,
// App Paths, file association, or package-local lookup is used.
bool locate_system_windows_powershell(std::wstring* path,
                                      std::wstring* error);
// Builds a fresh, sorted Unicode environment block for the verified inbox
// Windows PowerShell. No variable from the Manager's inherited environment is
// copied into the result.
bool build_sanitized_powershell_environment(
    const std::wstring& power_shell, std::vector<wchar_t>* environment,
    std::wstring* error);
std::wstring find_simhub_executable(const std::wstring& directory);
bool simhub_pipe_ready(DWORD wait_milliseconds);
bool query_current_process_elevation(bool* elevated, std::wstring* error);

class ProfileStore {
public:
    bool load(std::vector<Profile>* profiles, std::wstring* active_id,
              std::wstring* error) const;
    bool save(const Profile& profile, bool make_active,
              std::wstring* error) const;
    bool erase(const std::wstring& id, std::wstring* error) const;
    bool set_active(const std::wstring& id, std::wstring* error) const;

    static std::wstring create_id();
};

}  // namespace ffb::manager
