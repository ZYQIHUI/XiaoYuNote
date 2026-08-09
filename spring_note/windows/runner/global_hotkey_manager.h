#ifndef RUNNER_GLOBAL_HOTKEY_MANAGER_H_
#define RUNNER_GLOBAL_HOTKEY_MANAGER_H_

#include <flutter/binary_messenger.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <windows.h>

#include <memory>

class GlobalHotkeyManager {
 public:
  GlobalHotkeyManager(flutter::BinaryMessenger* messenger, HWND main_window);
  ~GlobalHotkeyManager();

  GlobalHotkeyManager(const GlobalHotkeyManager&) = delete;
  GlobalHotkeyManager& operator=(const GlobalHotkeyManager&) = delete;

  bool HandleMessage(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam);

 private:
  void RegisterChannelHandler();
  bool SetToggleWindowHotkey(const std::string& hotkey);
  void UnregisterToggleWindowHotkey();
  void ToggleMainWindow();

  flutter::BinaryMessenger* messenger_ = nullptr;
  HWND main_window_ = nullptr;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  bool registered_ = false;
  UINT current_modifiers_ = 0;
  UINT current_virtual_key_ = 0;
};

#endif  // RUNNER_GLOBAL_HOTKEY_MANAGER_H_
