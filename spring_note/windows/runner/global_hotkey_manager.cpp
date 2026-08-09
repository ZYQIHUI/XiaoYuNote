#include "global_hotkey_manager.h"

#include <algorithm>
#include <cctype>
#include <cstdlib>
#include <optional>
#include <sstream>
#include <string>
#include <vector>

namespace {

constexpr int kToggleWindowHotkeyId = 0x5350;
constexpr int kProbeHotkeyId = 0x5351;

struct HotkeySpec {
  UINT modifiers = 0;
  UINT virtual_key = 0;
};

std::string Trim(const std::string& value) {
  const auto start =
      std::find_if_not(value.begin(), value.end(), [](unsigned char ch) {
        return std::isspace(ch) != 0;
      });
  const auto end =
      std::find_if_not(value.rbegin(), value.rend(), [](unsigned char ch) {
        return std::isspace(ch) != 0;
      }).base();
  if (start >= end) {
    return "";
  }
  return std::string(start, end);
}

std::string ToUpperAscii(std::string value) {
  std::transform(value.begin(), value.end(), value.begin(),
                 [](unsigned char ch) {
                   return static_cast<char>(std::toupper(ch));
                 });
  return value;
}

std::vector<std::string> SplitHotkey(const std::string& hotkey) {
  std::vector<std::string> tokens;
  std::stringstream stream(hotkey);
  std::string token;
  while (std::getline(stream, token, '+')) {
    const std::string trimmed = Trim(token);
    if (!trimmed.empty()) {
      tokens.push_back(ToUpperAscii(trimmed));
    }
  }
  return tokens;
}

std::optional<UINT> VirtualKeyForToken(const std::string& token) {
  if (token.size() == 1) {
    const char ch = token[0];
    if ((ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9')) {
      return static_cast<UINT>(ch);
    }
  }

  if (token.size() >= 2 && token[0] == 'F') {
    const int number = std::atoi(token.c_str() + 1);
    if (number >= 1 && number <= 24) {
      return VK_F1 + number - 1;
    }
  }

  if (token == "SPACE") return VK_SPACE;
  if (token == "TAB") return VK_TAB;
  if (token == "ENTER" || token == "RETURN") return VK_RETURN;
  if (token == "ESC" || token == "ESCAPE") return VK_ESCAPE;
  if (token == "BACKSPACE") return VK_BACK;
  if (token == "DELETE" || token == "DEL") return VK_DELETE;
  if (token == "INSERT" || token == "INS") return VK_INSERT;
  if (token == "HOME") return VK_HOME;
  if (token == "END") return VK_END;
  if (token == "PAGEUP" || token == "PGUP") return VK_PRIOR;
  if (token == "PAGEDOWN" || token == "PGDN") return VK_NEXT;
  if (token == "UP") return VK_UP;
  if (token == "DOWN") return VK_DOWN;
  if (token == "LEFT") return VK_LEFT;
  if (token == "RIGHT") return VK_RIGHT;

  return std::nullopt;
}

std::optional<HotkeySpec> ParseHotkey(const std::string& hotkey) {
  UINT modifiers = MOD_NOREPEAT;
  std::optional<UINT> virtual_key;

  for (const std::string& token : SplitHotkey(hotkey)) {
    if (token == "CTRL" || token == "CONTROL") {
      modifiers |= MOD_CONTROL;
      continue;
    }
    if (token == "SHIFT") {
      modifiers |= MOD_SHIFT;
      continue;
    }
    if (token == "ALT" || token == "OPTION") {
      modifiers |= MOD_ALT;
      continue;
    }
    if (token == "WIN" || token == "WINDOWS" || token == "META" ||
        token == "CMD" || token == "COMMAND" || token == "SUPER") {
      modifiers |= MOD_WIN;
      continue;
    }

    const auto key = VirtualKeyForToken(token);
    if (!key || virtual_key.has_value()) {
      return std::nullopt;
    }
    virtual_key = key;
  }

  if (!virtual_key.has_value()) {
    return std::nullopt;
  }

  return HotkeySpec{modifiers, *virtual_key};
}

bool RegisterHotkey(HWND window, int id, const HotkeySpec& spec) {
  return RegisterHotKey(window, id, spec.modifiers, spec.virtual_key) != FALSE;
}

}  // namespace

GlobalHotkeyManager::GlobalHotkeyManager(flutter::BinaryMessenger* messenger,
                                         HWND main_window)
    : messenger_(messenger), main_window_(main_window) {
  if (messenger) {
    RegisterChannelHandler();
  }
}

GlobalHotkeyManager::~GlobalHotkeyManager() {
  UnregisterToggleWindowHotkey();
  if (channel_) {
    channel_->SetMethodCallHandler(nullptr);
  }
}

void GlobalHotkeyManager::RegisterChannelHandler() {
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger_, "spring_note/global_hotkeys",
      &flutter::StandardMethodCodec::GetInstance());

  channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() == "setToggleWindowHotkey") {
          const auto* hotkey = std::get_if<std::string>(call.arguments());
          if (!hotkey) {
            result->Error("bad_args", "setToggleWindowHotkey expects a string");
            return;
          }
          result->Success(flutter::EncodableValue(
              static_cast<bool>(SetToggleWindowHotkey(*hotkey))));
          return;
        }

        if (call.method_name() == "unregisterToggleWindowHotkey") {
          UnregisterToggleWindowHotkey();
          result->Success();
          return;
        }

        result->NotImplemented();
      });
}

bool GlobalHotkeyManager::HandleMessage(HWND hwnd,
                                        UINT message,
                                        WPARAM wparam,
                                        LPARAM lparam) {
  (void)lparam;
  if (message != WM_HOTKEY || hwnd != main_window_) {
    return false;
  }
  if (static_cast<int>(wparam) != kToggleWindowHotkeyId) {
    return false;
  }

  ToggleMainWindow();
  return true;
}

bool GlobalHotkeyManager::SetToggleWindowHotkey(const std::string& hotkey) {
  const auto parsed = ParseHotkey(hotkey);
  if (!parsed || !main_window_) {
    return false;
  }

  if (registered_ && current_modifiers_ == parsed->modifiers &&
      current_virtual_key_ == parsed->virtual_key) {
    return true;
  }

  if (registered_) {
    if (!RegisterHotkey(main_window_, kProbeHotkeyId, *parsed)) {
      return false;
    }
    UnregisterHotKey(main_window_, kProbeHotkeyId);
    UnregisterHotKey(main_window_, kToggleWindowHotkeyId);
    if (!RegisterHotkey(main_window_, kToggleWindowHotkeyId, *parsed)) {
      RegisterHotKey(main_window_, kToggleWindowHotkeyId, current_modifiers_,
                     current_virtual_key_);
      return false;
    }
  } else if (!RegisterHotkey(main_window_, kToggleWindowHotkeyId, *parsed)) {
    return false;
  }

  registered_ = true;
  current_modifiers_ = parsed->modifiers;
  current_virtual_key_ = parsed->virtual_key;
  return true;
}

void GlobalHotkeyManager::UnregisterToggleWindowHotkey() {
  if (!registered_ || !main_window_) {
    return;
  }
  UnregisterHotKey(main_window_, kToggleWindowHotkeyId);
  registered_ = false;
  current_modifiers_ = 0;
  current_virtual_key_ = 0;
}

void GlobalHotkeyManager::ToggleMainWindow() {
  if (!main_window_) {
    return;
  }

  if (!IsWindowVisible(main_window_)) {
    ShowWindow(main_window_, SW_SHOW);
    SetForegroundWindow(main_window_);
    return;
  }

  if (IsIconic(main_window_)) {
    ShowWindow(main_window_, SW_RESTORE);
    SetForegroundWindow(main_window_);
    return;
  }

  ShowWindow(main_window_, SW_HIDE);
}
