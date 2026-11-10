#include "gaia_pipe.h"

#include <sddl.h>

#include <algorithm>
#include <cstdint>
#include <cstdlib>
#include <utility>
#include <vector>

#include "utils.h"

namespace {

// Larger frames are refused: a message over this is a protocol bug, and
// reading it would only grow the buffer.
constexpr DWORD kMaxFrame = 64 * 1024 * 1024;

// How long the companion waits for the main instance's pipe to appear.
constexpr DWORD kConnectTimeoutMs = 15000;

}  // namespace

std::wstring CurrentUserOnlySddl() {
  HANDLE token = nullptr;
  if (!::OpenProcessToken(::GetCurrentProcess(), TOKEN_QUERY, &token)) {
    return std::wstring();
  }
  DWORD length = 0;
  ::GetTokenInformation(token, TokenUser, nullptr, 0, &length);
  std::vector<BYTE> buffer(length);
  std::wstring sddl;
  if (::GetTokenInformation(token, TokenUser, buffer.data(), length, &length)) {
    LPWSTR sid = nullptr;
    if (::ConvertSidToStringSidW(
            reinterpret_cast<TOKEN_USER*>(buffer.data())->User.Sid, &sid)) {
      sddl = std::wstring(L"D:P(A;;GA;;;") + sid + L")";
      ::LocalFree(sid);
    }
  }
  ::CloseHandle(token);
  return sddl;
}

namespace {

#ifndef NDEBUG
// qa/harness/gaia.ps1: the companion's own Dart VM service port. A QA launch
// gives the main instance a fixed one through FLUTTER_ENGINE_SWITCH_1, which
// the companion would otherwise inherit and fail to bind.
constexpr wchar_t kQaCompanionVmPortEnv[] = L"VOYAGER_QA_COMPANION_VM_PORT";
constexpr wchar_t kEngineSwitch1Env[] = L"FLUTTER_ENGINE_SWITCH_1";

std::wstring EnvironmentVariable(const wchar_t* name) {
  std::wstring value(32767, L'\0');
  value.resize(::GetEnvironmentVariableW(name, value.data(),
                                         static_cast<DWORD>(value.size())));
  return value;
}
#endif

std::wstring ExecutablePath() {
  std::wstring path(32768, L'\0');
  path.resize(::GetModuleFileNameW(nullptr, path.data(),
                                   static_cast<DWORD>(path.size())));
  return path;
}

DWORD ParentPidFromEnvironment() {
  wchar_t value[16] = {};
  if (::GetEnvironmentVariableW(kGaiaParentEnv, value, 16) == 0) return 0;
  return static_cast<DWORD>(std::wcstoul(value, nullptr, 10));
}

std::wstring Utf16FromUtf8(const std::string& utf8) {
  if (utf8.empty()) return std::wstring();
  const int size = static_cast<int>(utf8.size());
  const int length =
      ::MultiByteToWideChar(CP_UTF8, 0, utf8.data(), size, nullptr, 0);
  std::wstring utf16(length, L'\0');
  ::MultiByteToWideChar(CP_UTF8, 0, utf8.data(), size, utf16.data(), length);
  return utf16;
}

// Keeps the last three: <path>.1 is the newest, <path>.3 the oldest.
void RotateLog(const std::wstring& path) {
  for (int i = 2; i >= 1; i--) {
    ::MoveFileExW((path + L"." + std::to_wstring(i)).c_str(),
                  (path + L"." + std::to_wstring(i + 1)).c_str(),
                  MOVEFILE_REPLACE_EXISTING);
  }
  ::MoveFileExW(path.c_str(), (path + L".1").c_str(),
                MOVEFILE_REPLACE_EXISTING);
}

// The companion's stdout and stderr, which is where the engine writes its own errors
// (`Failed to update ui::AXTree`, ...): no Dart handler ever sees them, and
// the companion has no console. Inheritable, and readable while written.
HANDLE OpenEngineLog(const std::wstring& log_dir) {
  if (log_dir.empty()) return INVALID_HANDLE_VALUE;
  const std::wstring path = log_dir + L"\\companion_engine.log";
  RotateLog(path);
  SECURITY_ATTRIBUTES inheritable{sizeof(inheritable), nullptr, TRUE};
  return ::CreateFileW(path.c_str(), GENERIC_WRITE,
                       FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                       &inheritable, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL,
                       nullptr);
}

#ifndef NDEBUG
// A full dump is over a gigabyte: the two newest are kept, so with the next
// crash's there are three.
void PruneDumps(const std::wstring& log_dir) {
  std::vector<std::pair<uint64_t, std::wstring>> dumps;
  WIN32_FIND_DATAW found;
  HANDLE find =
      ::FindFirstFileW((log_dir + L"\\companion*.dmp").c_str(), &found);
  if (find == INVALID_HANDLE_VALUE) return;
  do {
    dumps.emplace_back((static_cast<uint64_t>(found.ftLastWriteTime.dwHighDateTime)
                        << 32) |
                           found.ftLastWriteTime.dwLowDateTime,
                       found.cFileName);
  } while (::FindNextFileW(find, &found));
  ::FindClose(find);
  std::sort(dumps.rbegin(), dumps.rend());
  for (size_t i = 2; i < dumps.size(); i++) {
    ::DeleteFileW((log_dir + L"\\" + dumps[i].second).c_str());
  }
}

// Debug builds, with the Windows SDK's Debugging Tools installed: cdb attached
// to the companion for as long as it runs, with gaia_cdb.js. Its log and any
// crash dump go to |log_dir|. -pd: should cdb itself go, the companion stays.
void AttachDebugger(DWORD pid, const std::wstring& log_dir) {
  const std::wstring cdb = EnvironmentVariable(L"ProgramFiles(x86)") +
                           L"\\Windows Kits\\10\\Debuggers\\x64\\cdb.exe";
  if (log_dir.empty() ||
      ::GetFileAttributesW(cdb.c_str()) == INVALID_FILE_ATTRIBUTES) {
    return;
  }
  const std::wstring log = log_dir + L"\\companion_cdb.log";
  RotateLog(log);
  PruneDumps(log_dir);
  std::wstring command_line =
      L"\"" + cdb + L"\" -p " + std::to_wstring(pid) + L" -pd -G -logo \"" +
      log + L"\" -y \"" GAIA_ENGINE_SYMBOLS L"\" -c \".scriptrun \\\"" +
      GAIA_CDB_SCRIPT L"\\\"; g\"";
  STARTUPINFOW startup{sizeof(startup)};
  PROCESS_INFORMATION process{};
  if (::CreateProcessW(cdb.c_str(), command_line.data(), nullptr, nullptr,
                       FALSE, CREATE_NO_WINDOW, nullptr, log_dir.c_str(),
                       &startup, &process)) {
    ::CloseHandle(process.hThread);
    ::CloseHandle(process.hProcess);
  }
}
#endif

}  // namespace

std::wstring GaiaPipeName() {
  DWORD session = 0;
  ::ProcessIdToSessionId(::GetCurrentProcessId(), &session);
  return ProfileScopedName(L"\\\\.\\pipe\\Voyager.Gaia") + L"." +
         std::to_wstring(session);
}

GaiaPipe::GaiaPipe(HWND window) : window_(window) {}

GaiaPipe::~GaiaPipe() {
  Close();
  if (companion_) ::CloseHandle(companion_);
}

DWORD GaiaPipe::StartCompanion(const std::string& log_dir_utf8) {
  if (companion_ && ::WaitForSingleObject(companion_, 0) == WAIT_TIMEOUT &&
      stop_) {
    if (connected_) Push(Event::Kind::kConnected);
    return companion_pid_;
  }
  Close();
  if (companion_) {
    ::CloseHandle(companion_);
    companion_ = nullptr;
    companion_pid_ = 0;
  }

  const std::wstring sddl = CurrentUserOnlySddl();
  PSECURITY_DESCRIPTOR descriptor = nullptr;
  if (sddl.empty() || !::ConvertStringSecurityDescriptorToSecurityDescriptorW(
                          sddl.c_str(), SDDL_REVISION_1, &descriptor,
                          nullptr)) {
    return 0;
  }
  SECURITY_ATTRIBUTES attributes{sizeof(attributes), descriptor, FALSE};
  // First instance only, so a process that created the name first can't
  // pose as the main instance.
  HANDLE pipe = ::CreateNamedPipeW(
      GaiaPipeName().c_str(),
      PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED | FILE_FLAG_FIRST_PIPE_INSTANCE,
      PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT |
          PIPE_REJECT_REMOTE_CLIENTS,
      1, 64 * 1024, 64 * 1024, 0, &attributes);
  ::LocalFree(descriptor);
  if (pipe == INVALID_HANDLE_VALUE) return 0;

  const std::wstring exe = ExecutablePath();
  std::wstring command_line = L"\"" + exe + L"\" --companion";
  const std::wstring parent = std::to_wstring(::GetCurrentProcessId());
  // Set only around the launch, so nothing else this process starts
  // inherits it.
  ::SetEnvironmentVariableW(kGaiaParentEnv, parent.c_str());
#ifndef NDEBUG
  const std::wstring qa_port = EnvironmentVariable(kQaCompanionVmPortEnv);
  const std::wstring main_switch = EnvironmentVariable(kEngineSwitch1Env);
  if (!qa_port.empty()) {
    ::SetEnvironmentVariableW(kEngineSwitch1Env,
                              (L"vm-service-port=" + qa_port).c_str());
  }
#endif
  const std::wstring log_dir = Utf16FromUtf8(log_dir_utf8);
  HANDLE engine_log = OpenEngineLog(log_dir);
  STARTUPINFOEXW startup{};
  startup.StartupInfo.cb = sizeof(startup);
  // The log is the only handle the companion inherits.
  std::vector<BYTE> attribute_list;
  if (engine_log != INVALID_HANDLE_VALUE) {
    SIZE_T size = 0;
    ::InitializeProcThreadAttributeList(nullptr, 1, 0, &size);
    attribute_list.resize(size);
    auto* list =
        reinterpret_cast<LPPROC_THREAD_ATTRIBUTE_LIST>(attribute_list.data());
    if (::InitializeProcThreadAttributeList(list, 1, 0, &size)) {
      if (::UpdateProcThreadAttribute(list, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST,
                                      &engine_log, sizeof(engine_log), nullptr,
                                      nullptr)) {
        startup.lpAttributeList = list;
        startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
        startup.StartupInfo.hStdOutput = engine_log;
        startup.StartupInfo.hStdError = engine_log;
      } else {
        ::DeleteProcThreadAttributeList(list);
      }
    }
  }
  const bool redirected = startup.lpAttributeList != nullptr;
  PROCESS_INFORMATION process{};
  const BOOL launched = ::CreateProcessW(
      exe.c_str(), command_line.data(), nullptr, nullptr, redirected,
      redirected ? EXTENDED_STARTUPINFO_PRESENT : 0, nullptr, nullptr,
      &startup.StartupInfo, &process);
  if (redirected) ::DeleteProcThreadAttributeList(startup.lpAttributeList);
  if (engine_log != INVALID_HANDLE_VALUE) ::CloseHandle(engine_log);
  ::SetEnvironmentVariableW(kGaiaParentEnv, nullptr);
#ifndef NDEBUG
  if (!qa_port.empty()) {
    ::SetEnvironmentVariableW(
        kEngineSwitch1Env, main_switch.empty() ? nullptr : main_switch.c_str());
  }
#endif
  if (!launched) {
    ::CloseHandle(pipe);
    return 0;
  }
  ::CloseHandle(process.hThread);
  companion_ = process.hProcess;
  companion_pid_ = process.dwProcessId;
#ifndef NDEBUG
  AttachDebugger(companion_pid_, log_dir);
#endif

  if (!Open(pipe)) return 0;
  reader_ = std::thread(&GaiaPipe::Run, this, true, companion_pid_);
  return companion_pid_;
}

bool GaiaPipe::Connect() {
  const DWORD parent = ParentPidFromEnvironment();
  if (parent == 0 || stop_) return false;
  // The handle is opened by the thread, which waits for the pipe to appear.
  if (!Open(INVALID_HANDLE_VALUE)) return false;
  reader_ = std::thread(&GaiaPipe::Run, this, false, parent);
  return true;
}

bool GaiaPipe::Open(HANDLE pipe) {
  stop_ = ::CreateEventW(nullptr, TRUE, FALSE, nullptr);
  if (!stop_) {
    if (pipe != INVALID_HANDLE_VALUE) ::CloseHandle(pipe);
    return false;
  }
  pipe_ = pipe;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    outgoing_.clear();
  }
  writer_ = std::thread(&GaiaPipe::WriteLoop, this);
  return true;
}

void GaiaPipe::Send(std::string frame) {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!stop_) return;
    outgoing_.push_back(std::move(frame));
  }
  wake_writer_.notify_one();
}

void GaiaPipe::Close() {
  if (!stop_) return;
  ::SetEvent(stop_);
  wake_writer_.notify_one();
  if (reader_.joinable()) reader_.join();
  if (writer_.joinable()) writer_.join();
  if (pipe_ != INVALID_HANDLE_VALUE) ::CloseHandle(pipe_);
  pipe_ = INVALID_HANDLE_VALUE;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    ::CloseHandle(stop_);
    stop_ = nullptr;
    outgoing_.clear();
  }
  connected_ = false;
}

std::deque<GaiaPipe::Event> GaiaPipe::TakeEvents() {
  std::lock_guard<std::mutex> lock(mutex_);
  return std::exchange(events_, {});
}

void GaiaPipe::Push(Event::Kind kind, std::string data) {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    events_.push_back({kind, std::move(data)});
  }
  ::PostMessage(window_, kGaiaPipeEventMessage, 0, 0);
}

void GaiaPipe::Run(bool server, DWORD expected_pid) {
  if (server) {
    HANDLE connect_event = ::CreateEventW(nullptr, TRUE, FALSE, nullptr);
    while (true) {
      OVERLAPPED overlapped{};
      overlapped.hEvent = connect_event;
      ::ResetEvent(connect_event);
      bool connected = ::ConnectNamedPipe(pipe_, &overlapped) != 0;
      if (!connected) {
        const DWORD error = ::GetLastError();
        if (error == ERROR_PIPE_CONNECTED) {
          connected = true;
        } else if (error == ERROR_IO_PENDING) {
          // The companion exiting before it connects ends the wait too.
          HANDLE waits[] = {connect_event, stop_, companion_};
          const DWORD which = ::WaitForMultipleObjects(3, waits, FALSE, INFINITE);
          if (which != WAIT_OBJECT_0) {
            ::CancelIoEx(pipe_, &overlapped);
            DWORD ignored;
            ::GetOverlappedResult(pipe_, &overlapped, &ignored, TRUE);
            break;
          }
          DWORD ignored;
          connected =
              ::GetOverlappedResult(pipe_, &overlapped, &ignored, FALSE) != 0;
        }
      }
      if (!connected) break;
      ULONG client = 0;
      if (::GetNamedPipeClientProcessId(pipe_, &client) &&
          client == expected_pid) {
        std::lock_guard<std::mutex> lock(mutex_);
        connected_ = true;
        break;
      }
      ::DisconnectNamedPipe(pipe_);
    }
    ::CloseHandle(connect_event);
  } else {
    const std::wstring name = GaiaPipeName();
    const ULONGLONG deadline = ::GetTickCount64() + kConnectTimeoutMs;
    HANDLE pipe = INVALID_HANDLE_VALUE;
    while (::WaitForSingleObject(stop_, 0) == WAIT_TIMEOUT &&
           ::GetTickCount64() < deadline) {
      // Identification only: the server can't act as this process.
      pipe = ::CreateFileW(name.c_str(), GENERIC_READ | GENERIC_WRITE, 0,
                           nullptr, OPEN_EXISTING,
                           FILE_FLAG_OVERLAPPED | SECURITY_SQOS_PRESENT |
                               SECURITY_IDENTIFICATION,
                           nullptr);
      if (pipe != INVALID_HANDLE_VALUE) break;
      ::WaitForSingleObject(stop_, 200);
    }
    ULONG server_pid = 0;
    if (pipe != INVALID_HANDLE_VALUE &&
        (!::GetNamedPipeServerProcessId(pipe, &server_pid) ||
         server_pid != expected_pid)) {
      ::CloseHandle(pipe);
      pipe = INVALID_HANDLE_VALUE;
    }
    if (pipe != INVALID_HANDLE_VALUE) {
      std::lock_guard<std::mutex> lock(mutex_);
      pipe_ = pipe;
      connected_ = true;
    }
  }

  if (connected_) {
    Push(Event::Kind::kConnected);
    wake_writer_.notify_one();
    ReadLoop();
    connected_ = false;
  }
  Push(Event::Kind::kDisconnected);
}

void GaiaPipe::ReadLoop() {
  HANDLE read_event = ::CreateEventW(nullptr, TRUE, FALSE, nullptr);
  // Reads exactly |size| bytes into |buffer|; false on disconnect or stop.
  auto read_exact = [&](char* buffer, DWORD size) {
    DWORD done = 0;
    while (done < size) {
      OVERLAPPED overlapped{};
      overlapped.hEvent = read_event;
      ::ResetEvent(read_event);
      DWORD read = 0;
      if (!::ReadFile(pipe_, buffer + done, size - done, &read, &overlapped)) {
        if (::GetLastError() != ERROR_IO_PENDING) return false;
        HANDLE waits[] = {read_event, stop_};
        if (::WaitForMultipleObjects(2, waits, FALSE, INFINITE) !=
            WAIT_OBJECT_0) {
          ::CancelIoEx(pipe_, &overlapped);
          ::GetOverlappedResult(pipe_, &overlapped, &read, TRUE);
          return false;
        }
        if (!::GetOverlappedResult(pipe_, &overlapped, &read, FALSE)) {
          return false;
        }
      }
      if (read == 0) return false;
      done += read;
    }
    return true;
  };

  while (true) {
    unsigned char header[4];
    if (!read_exact(reinterpret_cast<char*>(header), 4)) break;
    const DWORD size = header[0] | (header[1] << 8) | (header[2] << 16) |
                       (static_cast<DWORD>(header[3]) << 24);
    if (size > kMaxFrame) break;
    std::string frame(size, '\0');
    if (size > 0 && !read_exact(frame.data(), size)) break;
    Push(Event::Kind::kMessage, std::move(frame));
  }
  ::CloseHandle(read_event);
}

void GaiaPipe::WriteLoop() {
  HANDLE write_event = ::CreateEventW(nullptr, TRUE, FALSE, nullptr);
  while (true) {
    std::string frame;
    {
      std::unique_lock<std::mutex> lock(mutex_);
      wake_writer_.wait(lock, [&] {
        return ::WaitForSingleObject(stop_, 0) != WAIT_TIMEOUT ||
               (connected_ && !outgoing_.empty());
      });
      if (::WaitForSingleObject(stop_, 0) != WAIT_TIMEOUT) break;
      frame = std::move(outgoing_.front());
      outgoing_.pop_front();
    }
    const DWORD size = static_cast<DWORD>(frame.size());
    std::string bytes;
    bytes.reserve(size + 4);
    bytes.push_back(static_cast<char>(size & 0xFF));
    bytes.push_back(static_cast<char>((size >> 8) & 0xFF));
    bytes.push_back(static_cast<char>((size >> 16) & 0xFF));
    bytes.push_back(static_cast<char>((size >> 24) & 0xFF));
    bytes += frame;

    DWORD done = 0;
    while (done < bytes.size()) {
      OVERLAPPED overlapped{};
      overlapped.hEvent = write_event;
      ::ResetEvent(write_event);
      DWORD written = 0;
      if (!::WriteFile(pipe_, bytes.data() + done,
                       static_cast<DWORD>(bytes.size()) - done, &written,
                       &overlapped)) {
        if (::GetLastError() != ERROR_IO_PENDING) break;
        HANDLE waits[] = {write_event, stop_};
        if (::WaitForMultipleObjects(2, waits, FALSE, INFINITE) !=
            WAIT_OBJECT_0) {
          ::CancelIoEx(pipe_, &overlapped);
          ::GetOverlappedResult(pipe_, &overlapped, &written, TRUE);
          break;
        }
        if (!::GetOverlappedResult(pipe_, &overlapped, &written, FALSE)) break;
      }
      done += written;
    }
    // A failed write means the other end is gone; the reader reports it.
    if (done < bytes.size()) break;
  }
  ::CloseHandle(write_event);
}
