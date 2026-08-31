// SPDX-License-Identifier: GPL-3.0-only
#include <windows.h>
#include <shellapi.h>

#include <algorithm>
#include <cwctype>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <iterator>
#include <map>
#include <string>
#include <vector>

#include "manager_model.h"

namespace {

int failures = 0;

void expect(bool condition, const char* message) {
    if (!condition) {
        std::cerr << "FAIL: " << message << '\n';
        ++failures;
    }
}

std::filesystem::path make_test_root() {
    const auto temporary = std::filesystem::temp_directory_path();
    const std::wstring name =
        L"ffb-manager-model-tests-" + std::to_wstring(GetCurrentProcessId()) +
        L"-" + std::to_wstring(GetTickCount64());
    const auto root = temporary / name;
    std::filesystem::create_directories(root);
    return root;
}

void write_empty_file(const std::filesystem::path& path) {
    std::filesystem::create_directories(path.parent_path());
    std::ofstream stream(path, std::ios::binary | std::ios::trunc);
    if (!stream) throw std::runtime_error("cannot create test file");
}

void write_manifest(const std::filesystem::path& root,
                    const std::vector<std::string>& paths) {
    constexpr char kEmptySha256[] =
        "E3B0C44298FC1C149AFBF4C8996FB924"
        "27AE41E4649B934CA495991B7852B855";
    std::ofstream stream(root / "SHA256SUMS.txt",
                         std::ios::binary | std::ios::trunc);
    if (!stream) throw std::runtime_error("cannot create test manifest");
    for (const auto& path : paths) {
        stream << kEmptySha256 << "  " << path << '\n';
    }
}

std::size_t count_substrings(const std::string& value,
                             const std::string& needle) {
    std::size_t count = 0;
    std::size_t position = 0;
    while ((position = value.find(needle, position)) != std::string::npos) {
        ++count;
        position += needle.size();
    }
    return count;
}

void test_build_policy_marker(const std::filesystem::path& manager_path,
                              const std::string& expected_mode,
                              const std::string& expected_signer) {
    expect(expected_mode == "STABLE" || expected_mode == "EXPERIMENTAL",
           "CMake should provide a recognized Manager policy mode");
    expect(expected_signer == "NONE" || expected_signer == "UNPINNED" ||
               (expected_signer.size() == 64 &&
                std::all_of(expected_signer.begin(), expected_signer.end(),
                            [](unsigned char character) {
                                return (character >= '0' && character <= '9') ||
                                       (character >= 'A' && character <= 'F');
                            })),
           "CMake should provide a canonical policy signer value");

    std::ifstream stream(manager_path, std::ios::binary);
    expect(static_cast<bool>(stream),
           "the built Manager binary should be available to inspect");
    if (!stream) return;
    const std::string bytes((std::istreambuf_iterator<char>(stream)),
                            std::istreambuf_iterator<char>());
    constexpr char kPrefix[] = "FFB_MANAGER_BUILD_POLICY_V1|MODE=";
    const std::string expected =
        std::string(kPrefix) + expected_mode + "|SIGNER_SHA256=" +
        expected_signer + "|END";

    expect(count_substrings(bytes, kPrefix) == 1,
           "the Manager binary should contain exactly one policy marker");
    expect(count_substrings(bytes, expected) == 1,
           "the Manager policy marker should match its CMake policy");
    const std::size_t marker = bytes.find(expected);
    expect(marker != std::string::npos &&
               marker + expected.size() < bytes.size() &&
               bytes[marker + expected.size()] == '\0',
           "the Manager policy marker should be NUL-terminated");
}

void test_manifest_parser() {
    std::vector<ffb::manager::ManifestEntry> entries;
    std::wstring error;
    const std::string valid =
        "E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855"
        "  launcher/x64/FFBInterceptor.Hook.dll\n";
    expect(ffb::manager::parse_manifest_text(valid, &entries, &error),
           "valid manifest should parse");
    expect(entries.size() == 1, "valid manifest should contain one entry");
    expect(entries[0].relative_path ==
               L"launcher\\x64\\FFBInterceptor.Hook.dll",
           "manifest path should normalize separators");

    const std::string traversal =
        "E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855"
        "  ../outside.dll\n";
    expect(!ffb::manager::parse_manifest_text(traversal, &entries, &error),
           "manifest traversal should be rejected");

    const std::string duplicate = valid +
        "E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855"
        "  LAUNCHER/X64/ffbinterceptor.hook.dll\n";
    expect(!ffb::manager::parse_manifest_text(duplicate, &entries, &error),
           "case-insensitive duplicate should be rejected");

    const std::string trailing_dot =
        "E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855"
        "  launcher/x64/hook.dll.\n";
    expect(!ffb::manager::parse_manifest_text(trailing_dot, &entries, &error),
           "Windows trailing-dot aliases should be rejected");

    const std::string reserved_device =
        "E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855"
        "  launcher/AUX.txt\n";
    expect(!ffb::manager::parse_manifest_text(reserved_device, &entries,
                                               &error),
           "Windows reserved device names should be rejected");

    const std::string wildcard =
        "E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855"
        "  launcher/*.dll\n";
    expect(!ffb::manager::parse_manifest_text(wildcard, &entries, &error),
           "manifest wildcard paths should be rejected");
}

void test_argument_handling() {
    std::vector<std::wstring> arguments;
    std::wstring error;
    expect(ffb::manager::split_game_arguments(
               L"-windowed \"profile one\" path\\", &arguments, &error),
           "game arguments should parse");
    expect(arguments.size() == 3, "three game arguments should be returned");
    expect(arguments.size() >= 2 && arguments[1] == L"profile one",
           "quoted game argument should retain spaces");
    expect(ffb::manager::quote_command_argument(L"plain") == L"plain",
           "plain argument should not be quoted");
    expect(ffb::manager::quote_command_argument(L"two words") ==
               L"\"two words\"",
           "spaced argument should be quoted");
    expect(ffb::manager::quote_command_argument(L"ends with slash \\") ==
               L"\"ends with slash \\\\\"",
           "trailing slash in quoted argument should be doubled");
    const std::vector<std::wstring> round_trip_arguments = {
        L"", L"plain", L"two words", L"embedded\"quote",
        L"slashes\\\\before\"quote", L"tab\tvalue", L"tail \\",
        L"; Remove-Item C:\\*", L"$(Get-ChildItem)", L"&calc.exe"};
    for (const auto& argument : round_trip_arguments) {
        const std::wstring command =
            L"placeholder.exe " +
            ffb::manager::quote_command_argument(argument);
        int count = 0;
        LPWSTR* parsed = CommandLineToArgvW(command.c_str(), &count);
        const bool round_tripped =
            parsed && count == 2 && argument == parsed[1];
        expect(round_tripped,
               "quoted arguments should round-trip through CommandLineToArgvW");
        if (parsed) LocalFree(parsed);
    }
    expect(ffb::manager::path_is_absolute_local(L"C:\\Games\\game.exe"),
           "local drive path should be accepted");
    expect(!ffb::manager::path_is_absolute_local(
               L"\\\\server\\share\\game.exe"),
           "UNC path should be rejected");

    std::wstring power_shell;
    error.clear();
    expect(ffb::manager::locate_system_windows_powershell(&power_shell,
                                                           &error),
           "native System32 Windows PowerShell should resolve by handle");
    expect(ffb::manager::path_is_absolute_local(power_shell),
           "resolved Windows PowerShell should use an absolute local path");
    expect(ffb::manager::file_is_regular(power_shell),
           "resolved Windows PowerShell should be a regular non-reparse file");
    const std::wstring expected_suffix =
        L"\\WindowsPowerShell\\v1.0\\powershell.exe";
    expect(power_shell.size() >= expected_suffix.size() &&
               _wcsicmp(power_shell.c_str() +
                            (power_shell.size() - expected_suffix.size()),
                        expected_suffix.c_str()) == 0,
           "resolved executable should be the fixed System32 PowerShell");
}

std::map<std::wstring, std::wstring> parse_environment_block(
    const std::vector<wchar_t>& block) {
    std::map<std::wstring, std::wstring> values;
    std::size_t offset = 0;
    while (offset < block.size() && block[offset] != L'\0') {
        const std::wstring entry(block.data() + offset);
        const auto separator = entry.find(L'=');
        if (separator != std::wstring::npos) {
            std::wstring name = entry.substr(0, separator);
            std::transform(name.begin(), name.end(), name.begin(),
                           [](wchar_t character) {
                               return static_cast<wchar_t>(
                                   std::towlower(character));
                           });
            values[name] = entry.substr(separator + 1);
        }
        offset += entry.size() + 1;
    }
    return values;
}

void test_elevated_helper_boundary() {
    const std::wstring event =
        L"Local\\FFBInterceptor.ManagerElevation.v1." +
        std::wstring(64, L'A');
    ffb::manager::ElevatedPluginRequest request{};
    std::wstring error;
    expect(ffb::manager::parse_elevated_plugin_request({}, &request, &error) ==
               ffb::manager::ElevatedPluginParseResult::not_requested,
           "ordinary GUI invocation should not enter elevated helper mode");
    const std::vector<std::wstring> install = {
        L"--elevated-plugin-op", L"install",
        L"--manager-invocation-event", event,
        L"--simhub-install-path", L"C:\\Program Files\\SimHub & literal"};
    expect(ffb::manager::parse_elevated_plugin_request(
               install, &request, &error) ==
               ffb::manager::ElevatedPluginParseResult::valid,
           "fixed install helper grammar should parse");
    expect(request.operation ==
               ffb::manager::ElevatedPluginOperation::install &&
               request.simhub_install_path ==
                   L"C:\\Program Files\\SimHub & literal",
           "install helper should preserve the literal SimHub path");
    const std::vector<std::wstring> uninstall = {
        L"--elevated-plugin-op", L"uninstall",
        L"--manager-invocation-event", event};
    expect(ffb::manager::parse_elevated_plugin_request(
               uninstall, &request, &error) ==
               ffb::manager::ElevatedPluginParseResult::valid &&
               request.operation ==
                   ffb::manager::ElevatedPluginOperation::uninstall,
           "fixed uninstall helper grammar should parse");

    auto invalid = install;
    invalid[3].back() = L'a';
    expect(ffb::manager::parse_elevated_plugin_request(
               invalid, &request, &error) ==
               ffb::manager::ElevatedPluginParseResult::invalid,
           "lowercase event entropy should fail the exact grammar");
    invalid = install;
    std::swap(invalid[2], invalid[4]);
    expect(ffb::manager::parse_elevated_plugin_request(
               invalid, &request, &error) ==
               ffb::manager::ElevatedPluginParseResult::invalid,
           "reordered helper switches should be rejected");
    invalid = uninstall;
    invalid.push_back(L"--simhub-install-path");
    invalid.push_back(L"C:\\SimHub");
    expect(ffb::manager::parse_elevated_plugin_request(
               invalid, &request, &error) ==
               ffb::manager::ElevatedPluginParseResult::invalid,
           "uninstall helper should reject an unrelated path argument");
    invalid = install;
    invalid[5] = L"relative\\SimHub";
    expect(ffb::manager::parse_elevated_plugin_request(
               invalid, &request, &error) ==
               ffb::manager::ElevatedPluginParseResult::invalid,
           "helper should reject a relative SimHub path");

    std::wstring power_shell;
    expect(ffb::manager::locate_system_windows_powershell(&power_shell,
                                                           &error),
           "environment fixture should resolve System32 PowerShell");
    SetEnvironmentVariableW(L"COR_ENABLE_PROFILING", L"1");
    SetEnvironmentVariableW(L"COR_PROFILER_PATH", L"C:\\attacker.dll");
    SetEnvironmentVariableW(L"COMPLUS_ReadyToRun", L"0");
    SetEnvironmentVariableW(L"DOTNET_STARTUP_HOOKS", L"C:\\hook.dll");
    SetEnvironmentVariableW(L"APPDOMAIN_MANAGER_ASM", L"Evil.Manager");
    SetEnvironmentVariableW(L"PSModulePath", L"C:\\attacker-modules");
    SetEnvironmentVariableW(L"Path", L"C:\\attacker-bin");
    std::vector<wchar_t> environment;
    expect(ffb::manager::build_sanitized_powershell_environment(
               power_shell, &environment, &error),
           "verified System32 PowerShell should receive a fresh environment");
    expect(environment.size() >= 2 &&
               environment[environment.size() - 1] == L'\0' &&
               environment[environment.size() - 2] == L'\0',
           "Unicode environment block should be double-NUL terminated");
    const auto values = parse_environment_block(environment);
    for (const wchar_t* forbidden : {
             L"cor_enable_profiling", L"cor_profiler_path",
             L"complus_readytorun", L"dotnet_startup_hooks",
             L"appdomain_manager_asm"}) {
        expect(values.count(forbidden) == 0,
               "inherited CLR startup controls must not enter child environment");
    }
    expect(values.count(L"path") == 1 &&
               values.at(L"path").find(L"attacker-bin") ==
                   std::wstring::npos,
           "child PATH should not inherit caller-controlled directories");
    expect(values.count(L"psmodulepath") == 1 &&
               values.at(L"psmodulepath").find(L"attacker-modules") ==
                   std::wstring::npos,
           "child PSModulePath should not inherit caller-controlled modules");
    expect(values.count(L"systemroot") == 1 &&
               ffb::manager::path_is_absolute_local(
                   values.at(L"systemroot")),
           "child SystemRoot should come from a local OS path");
}

void test_package_integrity() {
    const std::vector<std::string> required = {
        "FFBInterceptor.Manager.exe",
        "Install-SimHubPlugin.ps1",
        "Uninstall-SimHubPlugin.ps1",
        "FFBInterceptor.Common.ps1",
        "launcher/x86/FFBInterceptor.Launcher.exe",
        "launcher/x86/FFBInterceptor.Hook.dll",
        "launcher/x64/FFBInterceptor.Launcher.exe",
        "launcher/x64/FFBInterceptor.Hook.dll",
        "simhub/FFBInterceptor.Core.dll",
        "simhub/FFBInterceptor.SimHub.dll",
        "Start-FFBInterceptor.ps1"};
    const auto root = make_test_root();
    try {
        for (const auto& relative : required) {
            write_empty_file(root / std::filesystem::path(relative));
        }
        write_manifest(root, required);
        const auto layout = ffb::manager::make_package_layout(root.wstring());
        const auto good = ffb::manager::verify_package_integrity(layout);
        expect(good.valid, "matching package should pass integrity validation");
        expect(good.verified_files == required.size(),
               "all manifest files should be verified");
        expect(ffb::manager::locate_bundle_root(
                   (root / "launcher/x64/FFBInterceptor.Manager.exe").wstring()) ==
                   root.wstring(),
               "manager should locate bundle root from architecture folder");

        const auto unlisted = root / "launcher/x64/version.dll";
        write_empty_file(unlisted);
        const auto extra = ffb::manager::verify_package_integrity(layout);
        expect(!extra.valid,
               "an unlisted package file should fail exact manifest coverage");
        std::filesystem::remove(unlisted);

        {
            ffb::manager::PackageReadLock package_lock;
            std::wstring lock_error;
            expect(ffb::manager::acquire_package_read_lock(
                       layout, &package_lock, &lock_error),
                   "a valid package should acquire a read lock");
            HANDLE writable = CreateFileW(
                (root / "launcher/x64/FFBInterceptor.Hook.dll")
                    .c_str(),
                GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE |
                                   FILE_SHARE_DELETE,
                nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
            expect(writable == INVALID_HANDLE_VALUE,
                   "the package lock should deny payload writes");
            if (writable != INVALID_HANDLE_VALUE) CloseHandle(writable);
            expect(ffb::manager::verify_package_integrity(layout).valid,
                   "a second verifier should reopen and hash the package while the parent lock is held");
            const auto renamed =
                root / "launcher/x64/FFBInterceptor.Hook.renamed.dll";
            expect(!MoveFileExW(
                       (root / "launcher/x64/FFBInterceptor.Hook.dll")
                           .c_str(),
                       renamed.c_str(), MOVEFILE_REPLACE_EXISTING),
                   "the package lock should deny payload replacement by rename");
            expect(!DeleteFileW(
                       (root / "launcher/x64/FFBInterceptor.Hook.dll")
                           .c_str()),
                   "the package lock should deny payload deletion");
        }

        std::ofstream tamper(root / "launcher/x64/FFBInterceptor.Hook.dll",
                             std::ios::binary | std::ios::app);
        tamper << 'x';
        tamper.close();
        const auto bad = ffb::manager::verify_package_integrity(layout);
        expect(!bad.valid, "tampered package should fail integrity validation");
        expect(!bad.issues.empty(), "tamper should produce a diagnostic issue");
    } catch (...) {
        std::filesystem::remove_all(root);
        throw;
    }
    std::filesystem::remove_all(root);
}

void test_signature_policy() {
    const std::wstring signer_a(64, L'A');
    const std::wstring signer_b(64, L'B');
    ffb::manager::SignaturePolicy stable{};
    stable.required = true;
    std::vector<ffb::manager::SignatureEvidence> same_signer = {
        {L"manager", true, signer_a, L"ok"},
        {L"hook", true, signer_a, L"ok"}};
    auto report =
        ffb::manager::evaluate_signature_policy(stable, same_signer);
    expect(report.allowed,
           "stable policy should allow trusted files from one signer");

    report = ffb::manager::evaluate_signature_policy(stable, {});
    expect(!report.allowed,
           "stable policy should fail closed without signature evidence");

    auto mixed_signer = same_signer;
    mixed_signer[1].signer_sha256 = signer_b;
    report = ffb::manager::evaluate_signature_policy(stable, mixed_signer);
    expect(!report.allowed,
           "stable policy should reject trusted files from different signers");

    stable.expected_signer_sha256 = signer_b;
    report = ffb::manager::evaluate_signature_policy(stable, same_signer);
    expect(!report.allowed,
           "stable policy should reject a non-matching expected thumbprint");
    stable.expected_signer_sha256 = signer_a;
    report = ffb::manager::evaluate_signature_policy(stable, same_signer);
    expect(report.allowed,
           "stable policy should accept the expected signer thumbprint");

    stable.expected_signer_sha256 = L"not-a-thumbprint";
    report = ffb::manager::evaluate_signature_policy(stable, same_signer);
    expect(!report.allowed,
           "stable policy should reject an invalid pinned thumbprint");
    stable.expected_signer_sha256 = signer_a;

    auto unsigned_files = same_signer;
    unsigned_files[0].trusted = false;
    unsigned_files[0].signer_sha256.clear();
    report = ffb::manager::evaluate_signature_policy(stable, unsigned_files);
    expect(!report.allowed, "stable policy should reject an unsigned file");

    ffb::manager::SignaturePolicy experimental{};
    report =
        ffb::manager::evaluate_signature_policy(experimental, unsigned_files);
    expect(report.allowed,
           "experimental policy should defer trust to external attestation");
    expect(!report.issues.empty(),
           "experimental policy should retain signature warnings");
}

}  // namespace

int main(int argc, char** argv) {
    try {
        if (argc != 4) {
            std::cerr << "FAIL: expected Manager path, policy mode and signer\n";
            return 1;
        }
        test_build_policy_marker(argv[1], argv[2], argv[3]);
        test_manifest_parser();
        test_argument_handling();
        test_elevated_helper_boundary();
        test_package_integrity();
        test_signature_policy();
    } catch (const std::exception& exception) {
        std::cerr << "FAIL: unexpected exception: " << exception.what() << '\n';
        ++failures;
    }
    if (failures == 0) std::cout << "manager model tests passed\n";
    return failures == 0 ? 0 : 1;
}
