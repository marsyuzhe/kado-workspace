#ifndef RUNNER_TOOLBOX_PLATFORM_H_
#define RUNNER_TOOLBOX_PLATFORM_H_
#include <windows.h>
#include <flutter/binary_messenger.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <memory>
#include <optional>

class ToolboxPlatform {
 public:
  ToolboxPlatform(HWND window, HWND view, flutter::BinaryMessenger* messenger);
  ~ToolboxPlatform();
  std::optional<LRESULT> HandleMessage(UINT message, WPARAM wparam, LPARAM lparam);
 private:
  void HandleCall(const flutter::MethodCall<flutter::EncodableValue>& call,
                  std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  static LRESULT CALLBACK DropSubclass(HWND,UINT,WPARAM,LPARAM,UINT_PTR,DWORD_PTR);
  void ReceiveDrop(WPARAM drop);
  HWND window_, drop_view_;
  bool drop_listening_ = false;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  bool hotkey_registered_ = false;
  UINT modifiers_ = 0, key_ = 0;
  bool clipboard_listening_ = false;
  bool close_guard_ = false, close_pending_ = false;
  ULONG_PTR image_codec_ = 0;
};
#endif
