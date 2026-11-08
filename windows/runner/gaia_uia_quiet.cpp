#include "gaia_uia_quiet.h"

#include <windows.h>

#include <delayimp.h>

#include <atomic>
#include <cstring>

namespace {

std::atomic<bool> g_done{false};

UINT WINAPI NoSendInput(UINT, LPINPUT, int) {
  SetLastError(ERROR_ACCESS_DENIED);
  return 0;
}

// Points every SendInput in one import table of |base| at NoSendInput.
bool StubThunks(BYTE* base, DWORD names, DWORD slots) {
  if (names == 0 || slots == 0) return false;
  auto name = reinterpret_cast<IMAGE_THUNK_DATA*>(base + names);
  auto slot = reinterpret_cast<IMAGE_THUNK_DATA*>(base + slots);
  bool stubbed = false;
  for (; name->u1.AddressOfData != 0; ++name, ++slot) {
    if (IMAGE_SNAP_BY_ORDINAL(name->u1.Ordinal)) continue;
    auto by_name =
        reinterpret_cast<IMAGE_IMPORT_BY_NAME*>(base + name->u1.AddressOfData);
    if (std::strcmp(reinterpret_cast<const char*>(by_name->Name),
                    "SendInput") != 0) {
      continue;
    }
    DWORD old;
    if (!VirtualProtect(&slot->u1.Function, sizeof(slot->u1.Function),
                        PAGE_READWRITE, &old)) {
      continue;
    }
    slot->u1.Function = reinterpret_cast<ULONG_PTR>(&NoSendInput);
    VirtualProtect(&slot->u1.Function, sizeof(slot->u1.Function), old, &old);
    stubbed = true;
  }
  return stubbed;
}

}  // namespace

int GaiaKeepUiaBehind() {
  if (g_done.load()) return 1;
  // Never freed: unloaded and loaded again, it would come back unstubbed.
  HMODULE module =
      LoadLibraryExW(L"UIAutomationCore.dll", nullptr,
                     LOAD_LIBRARY_SEARCH_SYSTEM32);
  if (module == nullptr) return 0;
  auto base = reinterpret_cast<BYTE*>(module);
  auto nt = reinterpret_cast<IMAGE_NT_HEADERS*>(
      base + reinterpret_cast<IMAGE_DOS_HEADER*>(base)->e_lfanew);
  bool stubbed = false;
  // UIAutomationCore delay-loads it today; a plain import is covered too.
  const auto& imports =
      nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT];
  if (imports.Size != 0) {
    for (auto d = reinterpret_cast<IMAGE_IMPORT_DESCRIPTOR*>(
             base + imports.VirtualAddress);
         d->Name != 0; ++d) {
      stubbed |= StubThunks(base, d->OriginalFirstThunk, d->FirstThunk);
    }
  }
  const auto& delayed =
      nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_DELAY_IMPORT];
  if (delayed.Size != 0) {
    for (auto d = reinterpret_cast<IMAGE_DELAYLOAD_DESCRIPTOR*>(
             base + delayed.VirtualAddress);
         d->DllNameRVA != 0; ++d) {
      stubbed |=
          StubThunks(base, d->ImportNameTableRVA, d->ImportAddressTableRVA);
    }
  }
  if (stubbed) g_done.store(true);
  return stubbed ? 1 : 0;
}
