#include "gaia_tool_pipe.h"

#include <sddl.h>
#include <tlhelp32.h>

#include <unordered_map>
#include <utility>
#include <vector>

#include "gaia_pipe.h"
#include "utils.h"

namespace {

// A line longer than this is a protocol bug; the connection is dropped
// rather than the buffer grown without end.
constexpr size_t kMaxLine = 64 * 1024 * 1024;

// How far up the ancestry is walked: the shim's parent is the CLI, under an
// npm shim's node and the cmd Gaia launched.
constexpr int kMaxAncestry = 16;

// How long the shim waits for a free pipe instance.
constexpr DWORD kShimConnectTimeoutMs = 5000;

// |pid| and its ancestors, nearest first, as "pid,parent,...".
std::string Ancestry(DWORD pid) {
  std::unordered_map<DWORD, DWORD> parents;
  HANDLE snapshot = ::CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  if (snapshot != INVALID_HANDLE_VALUE) {
    PROCESSENTRY32W entry{sizeof(entry)};
    for (BOOL more = ::Process32FirstW(snapshot, &entry); more;
         more = ::Process32NextW(snapshot, &entry)) {
      parents[entry.th32ProcessID] = entry.th32ParentProcessID;
    }
    ::CloseHandle(snapshot);
  }
  std::string ancestry = std::to_string(pid);
  for (int i = 0; i < kMaxAncestry; ++i) {
    const auto parent = parents.find(pid);
    if (parent == parents.end() || parent->second == 0 ||
        parent->second == pid) {
      break;
    }
    pid = parent->second;
    ancestry += "," + std::to_string(pid);
  }
  return ancestry;
}

std::wstring ProcessImage(DWORD pid) {
  HANDLE process =
      ::OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
  if (!process) return std::wstring();
  std::wstring path(32768, L'\0');
  DWORD size = static_cast<DWORD>(path.size());
  if (!::QueryFullProcessImageNameW(process, 0, path.data(), &size)) size = 0;
  ::CloseHandle(process);
  path.resize(size);
  return path;
}

// Waits for an overlapped operation on |handle| or |stop|; false when it
// failed or |stop| came first, which cancels it.
bool Finish(HANDLE handle, OVERLAPPED* overlapped, HANDLE stop,
            DWORD* transferred) {
  if (::GetLastError() != ERROR_IO_PENDING) return false;
  HANDLE waits[] = {overlapped->hEvent, stop};
  const DWORD count = stop ? 2 : 1;
  if (::WaitForMultipleObjects(count, waits, FALSE, INFINITE) !=
      WAIT_OBJECT_0) {
    ::CancelIoEx(handle, overlapped);
    ::GetOverlappedResult(handle, overlapped, transferred, TRUE);
    return false;
  }
  return ::GetOverlappedResult(handle, overlapped, transferred, FALSE) != 0;
}

bool WriteAll(HANDLE handle, const char* data, DWORD size, HANDLE event,
              HANDLE stop) {
  DWORD done = 0;
  while (done < size) {
    OVERLAPPED overlapped{};
    overlapped.hEvent = event;
    ::ResetEvent(event);
    DWORD written = 0;
    if (!::WriteFile(handle, data + done, size - done, &written,
                     &overlapped) &&
        !Finish(handle, &overlapped, stop, &written)) {
      return false;
    }
    done += written;
  }
  return true;
}

}  // namespace

struct GaiaToolPipe::Connection {
  int64_t id;
  HANDLE pipe;
  HANDLE stop;
  std::thread reader;
  std::thread writer;
  std::mutex mutex;
  std::condition_variable wake;
  std::deque<std::string> outgoing;
};

std::wstring GaiaToolPipeName() {
  DWORD session = 0;
  ::ProcessIdToSessionId(::GetCurrentProcessId(), &session);
  return ProfileScopedName(L"\\\\.\\pipe\\Voyager.GaiaTools") + L"." +
         std::to_wstring(session);
}

GaiaToolPipe::GaiaToolPipe(HWND window) : window_(window) {}

GaiaToolPipe::~GaiaToolPipe() {
  if (stop_) {
    ::SetEvent(stop_);
    if (acceptor_.joinable()) acceptor_.join();
  }
  std::map<int64_t, std::shared_ptr<Connection>> connections;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    connections.swap(connections_);
  }
  for (auto& [id, connection] : connections) {
    {
      // Under the writer's lock, so its wait can't miss the stop.
      std::lock_guard<std::mutex> lock(connection->mutex);
      ::SetEvent(connection->stop);
    }
    connection->wake.notify_one();
    if (connection->reader.joinable()) connection->reader.join();
    if (connection->writer.joinable()) connection->writer.join();
    ::CloseHandle(connection->pipe);
    ::CloseHandle(connection->stop);
  }
  if (stop_) ::CloseHandle(stop_);
}

bool GaiaToolPipe::Listen() {
  if (stop_) return true;
  stop_ = ::CreateEventW(nullptr, TRUE, FALSE, nullptr);
  if (!stop_) return false;
  // The first instance is created here, so a name already taken fails now.
  const std::wstring sddl = CurrentUserOnlySddl();
  PSECURITY_DESCRIPTOR descriptor = nullptr;
  if (sddl.empty() || !::ConvertStringSecurityDescriptorToSecurityDescriptorW(
                          sddl.c_str(), SDDL_REVISION_1, &descriptor,
                          nullptr)) {
    return false;
  }
  SECURITY_ATTRIBUTES attributes{sizeof(attributes), descriptor, FALSE};
  HANDLE first = ::CreateNamedPipeW(
      GaiaToolPipeName().c_str(),
      PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED | FILE_FLAG_FIRST_PIPE_INSTANCE,
      PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT |
          PIPE_REJECT_REMOTE_CLIENTS,
      PIPE_UNLIMITED_INSTANCES, 64 * 1024, 64 * 1024, 0, &attributes);
  ::LocalFree(descriptor);
  if (first == INVALID_HANDLE_VALUE) return false;
  acceptor_ = std::thread([this, first] {
    HANDLE pipe = first;
    HANDLE connect_event = ::CreateEventW(nullptr, TRUE, FALSE, nullptr);
    while (pipe != INVALID_HANDLE_VALUE) {
      OVERLAPPED overlapped{};
      overlapped.hEvent = connect_event;
      ::ResetEvent(connect_event);
      DWORD ignored = 0;
      const bool connected =
          ::ConnectNamedPipe(pipe, &overlapped) ||
          ::GetLastError() == ERROR_PIPE_CONNECTED ||
          Finish(pipe, &overlapped, stop_, &ignored);
      if (::WaitForSingleObject(stop_, 0) != WAIT_TIMEOUT) {
        ::CloseHandle(pipe);
        break;
      }
      ULONG client = 0;
      if (!connected || !::GetNamedPipeClientProcessId(pipe, &client)) {
        ::DisconnectNamedPipe(pipe);
        continue;
      }
      auto connection = std::make_shared<Connection>();
      connection->pipe = pipe;
      connection->stop = ::CreateEventW(nullptr, TRUE, FALSE, nullptr);
      {
        std::lock_guard<std::mutex> lock(mutex_);
        connection->id = next_id_++;
        connections_[connection->id] = connection;
      }
      Push(Event::Kind::kConnected, connection->id, Ancestry(client));
      connection->reader = std::thread(&GaiaToolPipe::ReadLoop, this,
                                       connection);
      connection->writer = std::thread(&GaiaToolPipe::WriteLoop, this,
                                       connection);
      // The next shim's instance. Its security comes from the first's.
      pipe = ::CreateNamedPipeW(
          GaiaToolPipeName().c_str(), PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED,
          PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT |
              PIPE_REJECT_REMOTE_CLIENTS,
          PIPE_UNLIMITED_INSTANCES, 64 * 1024, 64 * 1024, 0, nullptr);
    }
    ::CloseHandle(connect_event);
  });
  return true;
}

void GaiaToolPipe::ReadLoop(std::shared_ptr<Connection> connection) {
  HANDLE read_event = ::CreateEventW(nullptr, TRUE, FALSE, nullptr);
  std::string line;
  char buffer[16 * 1024];
  while (true) {
    OVERLAPPED overlapped{};
    overlapped.hEvent = read_event;
    ::ResetEvent(read_event);
    DWORD read = 0;
    if (!::ReadFile(connection->pipe, buffer, sizeof(buffer), &read,
                    &overlapped) &&
        !Finish(connection->pipe, &overlapped, connection->stop, &read)) {
      break;
    }
    if (read == 0) break;
    size_t from = 0;
    for (size_t i = 0; i < read; ++i) {
      if (buffer[i] != '\n') continue;
      line.append(buffer + from, i - from);
      from = i + 1;
      if (!line.empty() && line.back() == '\r') line.pop_back();
      if (!line.empty()) {
        Push(Event::Kind::kMessage, connection->id, std::move(line));
      }
      line.clear();
    }
    line.append(buffer + from, read - from);
    if (line.size() > kMaxLine) break;
  }
  ::CloseHandle(read_event);
  Push(Event::Kind::kDisconnected, connection->id);
}

void GaiaToolPipe::WriteLoop(std::shared_ptr<Connection> connection) {
  HANDLE write_event = ::CreateEventW(nullptr, TRUE, FALSE, nullptr);
  while (true) {
    std::string line;
    {
      std::unique_lock<std::mutex> lock(connection->mutex);
      connection->wake.wait(lock, [&] {
        return ::WaitForSingleObject(connection->stop, 0) != WAIT_TIMEOUT ||
               !connection->outgoing.empty();
      });
      if (::WaitForSingleObject(connection->stop, 0) != WAIT_TIMEOUT) break;
      line = std::move(connection->outgoing.front());
      connection->outgoing.pop_front();
    }
    line.push_back('\n');
    // A failed write means the shim is gone; the reader reports it.
    if (!WriteAll(connection->pipe, line.data(),
                  static_cast<DWORD>(line.size()), write_event,
                  connection->stop)) {
      break;
    }
  }
  ::CloseHandle(write_event);
}

void GaiaToolPipe::Send(int64_t id, std::string line) {
  std::shared_ptr<Connection> connection;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    const auto found = connections_.find(id);
    if (found == connections_.end()) return;
    connection = found->second;
  }
  {
    std::lock_guard<std::mutex> lock(connection->mutex);
    connection->outgoing.push_back(std::move(line));
  }
  connection->wake.notify_one();
}

void GaiaToolPipe::Drop(int64_t id) {
  std::shared_ptr<Connection> connection;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    const auto found = connections_.find(id);
    if (found == connections_.end()) return;
    connection = found->second;
    connections_.erase(found);
  }
  {
    // Under the writer's lock, so its wait can't miss the stop.
    std::lock_guard<std::mutex> lock(connection->mutex);
    ::SetEvent(connection->stop);
  }
  connection->wake.notify_one();
  if (connection->reader.joinable()) connection->reader.join();
  if (connection->writer.joinable()) connection->writer.join();
  ::DisconnectNamedPipe(connection->pipe);
  ::CloseHandle(connection->pipe);
  ::CloseHandle(connection->stop);
}

std::deque<GaiaToolPipe::Event> GaiaToolPipe::TakeEvents() {
  std::lock_guard<std::mutex> lock(mutex_);
  return std::exchange(events_, {});
}

void GaiaToolPipe::Push(Event::Kind kind, int64_t id, std::string data) {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    events_.push_back({kind, id, std::move(data)});
  }
  ::PostMessage(window_, kGaiaToolPipeEventMessage, 0, 0);
}

int RunGaiaMcpShim() {
  HANDLE in = ::GetStdHandle(STD_INPUT_HANDLE);
  HANDLE out = ::GetStdHandle(STD_OUTPUT_HANDLE);
  if (in == nullptr || in == INVALID_HANDLE_VALUE || out == nullptr ||
      out == INVALID_HANDLE_VALUE) {
    return EXIT_FAILURE;
  }
  const std::wstring name = GaiaToolPipeName();
  const ULONGLONG deadline = ::GetTickCount64() + kShimConnectTimeoutMs;
  HANDLE pipe = INVALID_HANDLE_VALUE;
  while (::GetTickCount64() < deadline) {
    // Identification only: the companion can't act as this process.
    pipe = ::CreateFileW(name.c_str(), GENERIC_READ | GENERIC_WRITE, 0,
                         nullptr, OPEN_EXISTING,
                         FILE_FLAG_OVERLAPPED | SECURITY_SQOS_PRESENT |
                             SECURITY_IDENTIFICATION,
                         nullptr);
    if (pipe != INVALID_HANDLE_VALUE) break;
    if (::GetLastError() != ERROR_PIPE_BUSY) return EXIT_FAILURE;
    ::WaitNamedPipeW(name.c_str(), 200);
  }
  if (pipe == INVALID_HANDLE_VALUE) return EXIT_FAILURE;
  // Only Gaia's companion, this same exe, gets the agent's calls.
  ULONG server = 0;
  std::wstring self(32768, L'\0');
  self.resize(::GetModuleFileNameW(nullptr, self.data(),
                                   static_cast<DWORD>(self.size())));
  if (!::GetNamedPipeServerProcessId(pipe, &server) ||
      ::CompareStringOrdinal(ProcessImage(server).c_str(), -1, self.c_str(),
                             -1, TRUE) != CSTR_EQUAL) {
    ::CloseHandle(pipe);
    return EXIT_FAILURE;
  }

  // The pipe's two directions on their own threads, each with its own
  // event: an overlapped handle lets a read and a write overlap.
  std::thread upstream([&] {
    HANDLE event = ::CreateEventW(nullptr, TRUE, FALSE, nullptr);
    char buffer[16 * 1024];
    DWORD read = 0;
    while (::ReadFile(in, buffer, sizeof(buffer), &read, nullptr) &&
           read > 0 && WriteAll(pipe, buffer, read, event, nullptr)) {
    }
    ::CloseHandle(event);
    // The CLI closed stdin: it's done with Gaia's tools.
    ::CancelIoEx(pipe, nullptr);
    ::ExitProcess(EXIT_SUCCESS);
  });
  HANDLE event = ::CreateEventW(nullptr, TRUE, FALSE, nullptr);
  char buffer[16 * 1024];
  while (true) {
    OVERLAPPED overlapped{};
    overlapped.hEvent = event;
    ::ResetEvent(event);
    DWORD read = 0;
    if (!::ReadFile(pipe, buffer, sizeof(buffer), &read, &overlapped) &&
        !Finish(pipe, &overlapped, nullptr, &read)) {
      break;
    }
    if (read == 0) break;
    DWORD written = 0;
    if (!::WriteFile(out, buffer, read, &written, nullptr)) break;
  }
  // The companion dropped this shim, or went away.
  ::ExitProcess(EXIT_SUCCESS);
}
