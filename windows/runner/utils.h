#ifndef RUNNER_UTILS_H_
#define RUNNER_UTILS_H_

#include <string>
#include <vector>

// Creates a console for the process, and redirects stdout and stderr to
// it for both the runner and the Flutter library.
void CreateAndAttachConsole();

// Takes a null-terminated wchar_t* encoded in UTF-16 and returns a std::string
// encoded in UTF-8. Returns an empty std::string on failure.
std::string Utf8FromUtf16(const wchar_t* utf16_string);

// Gets the command line arguments passed in as a std::vector<std::string>,
// encoded in UTF-8. Returns an empty std::vector<std::string> on failure.
std::vector<std::string> GetCommandLineArguments();

// The dev profile this process runs as: VOYAGER_PROFILE in a debug build,
// empty for the normal instance and always in a profile or release build.
// See DEV_PROFILE_HLD.md. wWinMain refuses an invalid name before anything
// else runs.
const std::wstring& DevProfile();

// Whether |profile| is a usable dev profile name: [a-z0-9]{1,16}, not
// "default".
bool IsValidDevProfile(const std::wstring& profile);

// |name| for the normal instance, |name|.<profile> in a dev profile: for the
// single-instance mutex and the broadcast window messages, so instances never
// answer each other's.
std::wstring ProfileScopedName(const wchar_t* name);

#endif  // RUNNER_UTILS_H_
