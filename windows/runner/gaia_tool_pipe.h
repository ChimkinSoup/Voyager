#ifndef RUNNER_GAIA_TOOL_PIPE_H_
#define RUNNER_GAIA_TOOL_PIPE_H_

#include <windows.h>

#include <condition_variable>
#include <cstdint>
#include <deque>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <thread>

// Posted to the owning window whenever GaiaToolPipe has events queued; the
// window drains them with TakeEvents on the platform thread.
inline constexpr UINT kGaiaToolPipeEventMessage = WM_APP + 0x49;

// The companion's pipe for Gaia's MCP shims (GAIA_HLD.md §5.3): a CLI that
// can't host Gaia's tools itself (Codex) launches `voyager.exe --gaia-mcp`,
// which relays its stdio here byte for byte. Lines are MCP's newline-
// delimited JSON-RPC, opaque here.
//
// Created for the current user only, rejecting remote clients. Each client
// is reported with its process ancestry, client first, so the companion can
// accept only shims started under an agent process it launched, and bind the
// connection to that run; it drops any other.
class GaiaToolPipe {
 public:
  struct Event {
    enum class Kind { kConnected, kMessage, kDisconnected } kind;
    int64_t id;
    // kConnected: the ancestry's PIDs, comma-separated. kMessage: a line.
    std::string data;
  };

  explicit GaiaToolPipe(HWND window);
  ~GaiaToolPipe();

  // Starts accepting shims. False when the pipe couldn't be created, as
  // when another process already holds the name.
  bool Listen();

  void Send(int64_t id, std::string line);

  // Disconnects |id|, and forgets it.
  void Drop(int64_t id);

  std::deque<Event> TakeEvents();

 private:
  struct Connection;

  void AcceptLoop();
  void ReadLoop(std::shared_ptr<Connection> connection);
  void WriteLoop(std::shared_ptr<Connection> connection);
  void Push(Event::Kind kind, int64_t id, std::string data = std::string());

  HWND window_;
  HANDLE stop_ = nullptr;
  std::thread acceptor_;

  std::mutex mutex_;
  std::map<int64_t, std::shared_ptr<Connection>> connections_;
  std::deque<Event> events_;
  int64_t next_id_ = 1;
};

// The pipe's name: per Windows session and dev profile.
std::wstring GaiaToolPipeName();

// `voyager.exe --gaia-mcp`: relays stdin to the companion's tool pipe and
// the pipe to stdout until either side closes. Returns the exit code.
int RunGaiaMcpShim();

#endif  // RUNNER_GAIA_TOOL_PIPE_H_
