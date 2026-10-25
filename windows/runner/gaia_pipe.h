#ifndef RUNNER_GAIA_PIPE_H_
#define RUNNER_GAIA_PIPE_H_

#include <windows.h>

#include <atomic>
#include <condition_variable>
#include <deque>
#include <mutex>
#include <string>
#include <thread>

// Posted to the owning window whenever GaiaPipe has events queued; the window
// drains them with TakeEvents on the platform thread (GAIA_HLD.md §3.2).
inline constexpr UINT kGaiaPipeEventMessage = WM_APP + 0x47;

// Set by the main instance on the companion it launches: the main instance's
// PID. Its absence marks a `--companion` launch by anything else.
inline constexpr wchar_t kGaiaParentEnv[] = L"VOYAGER_GAIA_PARENT";

// One end of the main instance <-> companion named pipe. Frames are a 4-byte
// little-endian length and that many bytes of UTF-8 JSON, opaque here.
//
// The main instance is the server: the pipe is created with a DACL for the
// current user only, rejects remote clients, and accepts only the companion
// it launched, checked with GetNamedPipeClientProcessId. The companion is the
// client, and checks the server is the main instance that launched it.
class GaiaPipe {
 public:
  struct Event {
    enum class Kind { kConnected, kMessage, kDisconnected } kind;
    std::string data;
  };

  explicit GaiaPipe(HWND window);
  ~GaiaPipe();

  // Main instance: creates the pipe, launches `<this exe> --companion` and
  // waits for it to connect. Returns the companion's PID, or 0 on failure.
  // While the last launch is still running, returns its PID and reports it
  // connected again, so a Dart hot restart picks the companion back up.
  DWORD StartCompanion();

  // Companion: connects to the main instance's pipe.
  bool Connect();

  void Send(std::string frame);
  void Close();

  std::deque<Event> TakeEvents();

 private:
  bool Open(HANDLE pipe);
  void Run(bool server, DWORD expected_pid);
  void ReadLoop();
  void WriteLoop();
  void Push(Event::Kind kind, std::string data = std::string());

  HWND window_;
  HANDLE pipe_ = INVALID_HANDLE_VALUE;
  HANDLE stop_ = nullptr;
  HANDLE companion_ = nullptr;
  DWORD companion_pid_ = 0;
  std::atomic<bool> connected_ = false;
  std::thread reader_;
  std::thread writer_;

  std::mutex mutex_;
  std::condition_variable wake_writer_;
  std::deque<std::string> outgoing_;
  std::deque<Event> events_;
};

// The pipe's name: per Windows session and dev profile.
std::wstring GaiaPipeName();

#endif  // RUNNER_GAIA_PIPE_H_
