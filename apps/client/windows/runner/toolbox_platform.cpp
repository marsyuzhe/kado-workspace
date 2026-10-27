#include "toolbox_platform.h"
#include <winhttp.h>
#include <commctrl.h>
#include <cstdint>
#include <gdiplus.h>
#include <wrl/client.h>
#include <string>
#include <vector>
#include <wintrust.h>
#include <softpub.h>
#include <shellapi.h>
#include <utility>

namespace {
constexpr int kHotkeyId = 0x4C54;
constexpr SIZE_T kMaxImage = 2 * 1024 * 1024;
constexpr uint64_t kMaxPixels = 8 * 1024 * 1024;
const CLSID kPngCodec={0x557cf406,0x1a04,0x11d3,{0x9a,0x73,0x00,0x00,0xf8,0x1e,0xf3,0x2e}};
std::string Utf8(const wchar_t* text,int length) {
  const int size=WideCharToMultiByte(CP_UTF8,WC_ERR_INVALID_CHARS,text,length,nullptr,0,nullptr,nullptr);
  if(size<=0)return {};
  std::string output(static_cast<size_t>(size),'\0');
  WideCharToMultiByte(CP_UTF8,WC_ERR_INVALID_CHARS,text,length,output.data(),size,nullptr,nullptr);return output;
}
bool ValidDimensions(Gdiplus::Bitmap& image){
  const UINT w=image.GetWidth(),h=image.GetHeight();
  return image.GetLastStatus()==Gdiplus::Ok && w>0 && h>0 && w<=4096 && h<=4096 && static_cast<uint64_t>(w)*h<=kMaxPixels;
}
Microsoft::WRL::ComPtr<IStream> ByteStream(const std::vector<uint8_t>& bytes){
  Microsoft::WRL::ComPtr<IStream> stream;
  if(FAILED(CreateStreamOnHGlobal(nullptr,TRUE,stream.GetAddressOf())))return {};
  ULONG written=0;
  if(FAILED(stream->Write(bytes.data(),static_cast<ULONG>(bytes.size()),&written)) || written!=bytes.size())return {};
  LARGE_INTEGER zero={};stream->Seek(zero,STREAM_SEEK_SET,nullptr);return stream;
}
std::vector<uint8_t> EncodePng(Gdiplus::Bitmap& image){
  if(!ValidDimensions(image))return {};
  Microsoft::WRL::ComPtr<IStream> stream;
  if(FAILED(CreateStreamOnHGlobal(nullptr,TRUE,stream.GetAddressOf())) || image.Save(stream.Get(),&kPngCodec,nullptr)!=Gdiplus::Ok)return {};
  STATSTG info={};if(FAILED(stream->Stat(&info,STATFLAG_NONAME)) || info.cbSize.QuadPart>kMaxImage)return {};
  HGLOBAL memory=nullptr;if(FAILED(GetHGlobalFromStream(stream.Get(),&memory)))return {};
  const auto* raw=static_cast<const uint8_t*>(GlobalLock(memory));if(!raw)return {};
  std::vector<uint8_t> bytes(raw,raw+static_cast<size_t>(info.cbSize.QuadPart));GlobalUnlock(memory);return bytes;
}
std::string ClipboardOwnerName(){
  const HWND owner=GetClipboardOwner();DWORD pid=0;GetWindowThreadProcessId(owner,&pid);
  HANDLE process=OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION,FALSE,pid);if(!process)return {};
  wchar_t path[32768];DWORD size=32768;std::string name;
  if(QueryFullProcessImageNameW(process,0,path,&size)){
    std::wstring full(path,size);const auto start=full.find_last_of(L"\\/");const auto base=full.substr(start==std::wstring::npos?0:start+1);name=Utf8(base.data(),static_cast<int>(base.size()));
  }CloseHandle(process);return name;
}
struct ClipboardGuard {bool open;explicit ClipboardGuard(HWND owner):open(OpenClipboard(owner)!=0){}~ClipboardGuard(){if(open)CloseClipboard();}};
int ReadInt(const flutter::EncodableMap& args, const char* key) {
  const auto entry = args.find(flutter::EncodableValue(key));
  if (entry == args.end()) return -1;
  if (const auto value = std::get_if<int32_t>(&entry->second)) return *value;
  return -1;
}
bool ReadWidePath(const flutter::EncodableValue* argument,std::wstring& path) {
  const auto* value=argument?std::get_if<std::string>(argument):nullptr;
  if(!value||value->empty()||value->size()>32768||value->find('\0')!=std::string::npos)return false;
  const int count=MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,value->data(),static_cast<int>(value->size()),nullptr,0);
  if(count<=0)return false;path.resize(static_cast<size_t>(count));
  return MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,value->data(),static_cast<int>(value->size()),path.data(),count)>0;
}
std::string VersionString(std::vector<uint8_t>& data,const wchar_t* key,WORD language,WORD codepage) {
  wchar_t block[128];swprintf_s(block,128,L"\\StringFileInfo\\%04x%04x\\%ls",language,codepage,key);
  void* value=nullptr;UINT size=0;
  if(!VerQueryValueW(data.data(),block,&value,&size)||!value||size<=1)return {};
  return Utf8(static_cast<const wchar_t*>(value),static_cast<int>(size-1));
}
}
ToolboxPlatform::ToolboxPlatform(HWND window, HWND view, flutter::BinaryMessenger* messenger) : window_(window), drop_view_(view) {
  Gdiplus::GdiplusStartupInput startup;
  if(Gdiplus::GdiplusStartup(&image_codec_,&startup,nullptr)!=Gdiplus::Ok)image_codec_=0;
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
    messenger,"com.linkstam.links_toolbox/platform",&flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result){HandleCall(call,std::move(result));});
}
ToolboxPlatform::~ToolboxPlatform() {
  if(drop_view_ && IsWindow(drop_view_)){DragAcceptFiles(drop_view_,FALSE);RemoveWindowSubclass(drop_view_,DropSubclass,0x4B44);}
  DragAcceptFiles(window_,FALSE);
  if(clipboard_listening_)RemoveClipboardFormatListener(window_);
  if(image_codec_)Gdiplus::GdiplusShutdown(image_codec_);
  if(hotkey_registered_) UnregisterHotKey(window_, kHotkeyId);
  channel_->SetMethodCallHandler(nullptr);
}
void ToolboxPlatform::HandleCall(const flutter::MethodCall<flutter::EncodableValue>& call,
  std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if(call.method_name()=="listenFileDrops") {
    const auto* enabled=call.arguments()?std::get_if<bool>(call.arguments()):nullptr;
    if(!enabled || !drop_view_ || !IsWindow(drop_view_)){result->Error("drop_unavailable","File drop window unavailable");return;}
    if(*enabled && !SetWindowSubclass(drop_view_,DropSubclass,0x4B44,reinterpret_cast<DWORD_PTR>(this))){result->Error("drop_unavailable","Cannot attach drop handler");return;}
    drop_listening_=*enabled;DragAcceptFiles(drop_view_,drop_listening_?TRUE:FALSE);DragAcceptFiles(window_,drop_listening_?TRUE:FALSE);
    if(!drop_listening_)RemoveWindowSubclass(drop_view_,DropSubclass,0x4B44);
    result->Success(flutter::EncodableValue(true));return;
  }
  if(call.method_name()=="fileDropTargetHandle") {
    if(!drop_listening_){result->Error("drop_inactive","Open Hash Inspector first");return;}
    result->Success(flutter::EncodableValue(static_cast<int64_t>(reinterpret_cast<intptr_t>(drop_view_))));return;
  }
  if(call.method_name()=="allowsDirectMetadata") {
    // Optional metadata policy is queried only on request; avoid loading WinHTTP at startup.
    const auto library=LoadLibraryExW(L"winhttp.dll",nullptr,LOAD_LIBRARY_SEARCH_SYSTEM32);
    if(!library){result->Success(flutter::EncodableValue(false));return;}
    using ReadUserProxy=BOOL(WINAPI*)(WINHTTP_CURRENT_USER_IE_PROXY_CONFIG*);
    using ReadDefaultProxy=BOOL(WINAPI*)(WINHTTP_PROXY_INFO*);
    const auto read_user=reinterpret_cast<ReadUserProxy>(GetProcAddress(library,"WinHttpGetIEProxyConfigForCurrentUser"));
    const auto read_default=reinterpret_cast<ReadDefaultProxy>(GetProcAddress(library,"WinHttpGetDefaultProxyConfiguration"));
    if(!read_user||!read_default){FreeLibrary(library);result->Success(flutter::EncodableValue(false));return;}
    WINHTTP_CURRENT_USER_IE_PROXY_CONFIG user{};
    WINHTTP_PROXY_INFO machine{};
    const bool user_ok=read_user(&user)!=FALSE;
    const bool machine_ok=read_default(&machine)!=FALSE;
    const bool allowed=user_ok && machine_ok && !user.fAutoDetect &&
      (!user.lpszAutoConfigUrl || !*user.lpszAutoConfigUrl) &&
      (!user.lpszProxy || !*user.lpszProxy) &&
      machine.dwAccessType==WINHTTP_ACCESS_TYPE_NO_PROXY;
    if(user.lpszProxy) GlobalFree(user.lpszProxy);
    if(user.lpszProxyBypass) GlobalFree(user.lpszProxyBypass);
    if(user.lpszAutoConfigUrl) GlobalFree(user.lpszAutoConfigUrl);
    if(machine.lpszProxy) GlobalFree(machine.lpszProxy);
    if(machine.lpszProxyBypass) GlobalFree(machine.lpszProxyBypass);
    FreeLibrary(library);
    result->Success(flutter::EncodableValue(allowed));return;
  }
  if(call.method_name()=="currentWindowHandle") {
    result->Success(flutter::EncodableValue(static_cast<int64_t>(reinterpret_cast<intptr_t>(window_))));return;
  }
  if(call.method_name()=="setCloseGuard"){
    const auto* enabled=call.arguments()?std::get_if<bool>(call.arguments()):nullptr;
    close_guard_=enabled&&*enabled;close_pending_=false;result->Success();return;
  }
  if(call.method_name()=="completeClose"){
    if(close_pending_){close_guard_=false;close_pending_=false;PostMessage(window_,WM_CLOSE,0,0);}result->Success();return;
  }
  if(call.method_name()=="cancelClose"){close_pending_=false;result->Success();return;}
  if(call.method_name()=="systemEnvironmentSummary") {
    SYSTEM_INFO system={};GetNativeSystemInfo(&system);
    MEMORYSTATUSEX memory={};memory.dwLength=sizeof(memory);const bool memory_ok=GlobalMemoryStatusEx(&memory)!=0;
    wchar_t cpu[512]={};DWORD cpu_bytes=sizeof(cpu);
    const LSTATUS cpu_status=RegGetValueW(HKEY_LOCAL_MACHINE,L"HARDWARE\\DESCRIPTION\\System\\CentralProcessor\\0",L"ProcessorNameString",RRF_RT_REG_SZ,nullptr,cpu,&cpu_bytes);
    wchar_t windows[32768]={};const UINT windows_length=GetWindowsDirectoryW(windows,32768);
    flutter::EncodableList disks;
    const DWORD mask=GetLogicalDrives();
    for(int i=0;i<26;i++) {
      if(!(mask&(1UL<<i)))continue;
      wchar_t root[4]={static_cast<wchar_t>(L'A'+i),L':',L'\\',L'\0'};
      if(GetDriveTypeW(root)!=DRIVE_FIXED)continue;
      ULARGE_INTEGER available={},total={},free={};const bool ok=GetDiskFreeSpaceExW(root,&available,&total,&free)!=0;
      flutter::EncodableMap disk{{flutter::EncodableValue("drive"),flutter::EncodableValue(Utf8(root,2))},{flutter::EncodableValue("available"),flutter::EncodableValue(ok)}};
      if(ok){disk[flutter::EncodableValue("totalBytes")]=flutter::EncodableValue(static_cast<int64_t>(total.QuadPart));disk[flutter::EncodableValue("freeBytes")]=flutter::EncodableValue(static_cast<int64_t>(available.QuadPart));}
      disks.push_back(flutter::EncodableValue(disk));
    }
    flutter::EncodableMap summary{
      {flutter::EncodableValue("processorCount"),flutter::EncodableValue(static_cast<int64_t>(system.dwNumberOfProcessors))},
      {flutter::EncodableValue("architectureCode"),flutter::EncodableValue(static_cast<int32_t>(system.wProcessorArchitecture))},
      {flutter::EncodableValue("cpuName"),flutter::EncodableValue(cpu_status==ERROR_SUCCESS?Utf8(cpu,static_cast<int>(wcsnlen_s(cpu,512))):std::string())},
      {flutter::EncodableValue("memoryAvailable"),flutter::EncodableValue(memory_ok)},
      {flutter::EncodableValue("disks"),flutter::EncodableValue(disks)},
      {flutter::EncodableValue("windowsDirectory"),flutter::EncodableValue(windows_length>0&&windows_length<32768?Utf8(windows,static_cast<int>(windows_length)):std::string())}};
    if(memory_ok)summary[flutter::EncodableValue("totalMemoryBytes")]=flutter::EncodableValue(static_cast<int64_t>(memory.ullTotalPhys));
    result->Success(flutter::EncodableValue(summary));return;
  }
  if(call.method_name()=="installerMetadata"||call.method_name()=="showFileProperties") {
    std::wstring path;
    if(!ReadWidePath(call.arguments(),path)){result->Error("invalid","Invalid file path");return;}
    const DWORD attributes=GetFileAttributesW(path.c_str());
    if(attributes==INVALID_FILE_ATTRIBUTES||(attributes&FILE_ATTRIBUTE_DIRECTORY)||(attributes&FILE_ATTRIBUTE_REPARSE_POINT)){result->Error("file_missing","File missing or reparse point");return;}
    if(call.method_name()=="showFileProperties"){
      SHELLEXECUTEINFOW info={};info.cbSize=sizeof(info);info.fMask=SEE_MASK_INVOKEIDLIST;info.hwnd=window_;info.lpVerb=L"properties";info.lpFile=path.c_str();info.nShow=SW_SHOWNORMAL;
      if(!ShellExecuteExW(&info)){result->Error("properties_failed","Properties dialog unavailable");return;}result->Success();return;
    }
    flutter::EncodableMap metadata;
    DWORD ignored=0;const DWORD size=GetFileVersionInfoSizeW(path.c_str(),&ignored);
    if(size>0&&size<=8*1024*1024){
      std::vector<uint8_t> data(size);
      if(GetFileVersionInfoW(path.c_str(),0,size,data.data())){
        struct Translation{WORD language,codepage;};Translation* translation=nullptr;UINT length=0;WORD language=0x0409,codepage=0x04b0;
        if(VerQueryValueW(data.data(),L"\\VarFileInfo\\Translation",reinterpret_cast<void**>(&translation),&length)&&length>=sizeof(Translation)){language=translation[0].language;codepage=translation[0].codepage;}
        for(const auto& field:std::vector<std::pair<const char*,const wchar_t*>>{{"name",L"ProductName"},{"version",L"FileVersion"},{"publisher",L"CompanyName"}}){
          metadata[flutter::EncodableValue(field.first)]=flutter::EncodableValue(VersionString(data,field.second,language,codepage));
        }
      }
    }
    std::string signature="not_supported";LONG status=TRUST_E_PROVIDER_UNKNOWN;
    const auto extension=path.size()>=4?path.substr(path.size()-4):L"";
    if(_wcsicmp(extension.c_str(),L".exe")==0||_wcsicmp(extension.c_str(),L".msi")==0){
      WINTRUST_FILE_INFO file={};file.cbStruct=sizeof(file);file.pcwszFilePath=path.c_str();
      WINTRUST_DATA trust={};trust.cbStruct=sizeof(trust);trust.dwUIChoice=WTD_UI_NONE;trust.fdwRevocationChecks=WTD_REVOKE_NONE;trust.dwUnionChoice=WTD_CHOICE_FILE;trust.pFile=&file;trust.dwStateAction=WTD_STATEACTION_VERIFY;trust.dwProvFlags=WTD_CACHE_ONLY_URL_RETRIEVAL|WTD_REVOCATION_CHECK_NONE;
      GUID action=WINTRUST_ACTION_GENERIC_VERIFY_V2;
      status=WinVerifyTrust(nullptr,&action,&trust);
      signature=status==ERROR_SUCCESS?"valid_offline":status==TRUST_E_NOSIGNATURE?"unsigned":status==TRUST_E_BAD_DIGEST?"invalid_digest":"unverified";
      trust.dwStateAction=WTD_STATEACTION_CLOSE;WinVerifyTrust(nullptr,&action,&trust);
    }
    metadata[flutter::EncodableValue("signatureStatus")]=flutter::EncodableValue(signature);
    metadata[flutter::EncodableValue("signatureCode")]=flutter::EncodableValue(static_cast<int64_t>(status));
    metadata[flutter::EncodableValue("source")]=flutter::EncodableValue("Windows version resource; offline WinVerifyTrust; does not execute installer");
    result->Success(flutter::EncodableValue(metadata));return;
  }
  if(call.method_name()=="availableDiskBytes") {
    const auto* path=call.arguments()?std::get_if<std::string>(call.arguments()):nullptr;
    if(!path||path->empty()||path->find('\0')!=std::string::npos){result->Error("invalid","Invalid directory");return;}
    const int count=MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,path->data(),static_cast<int>(path->size()),nullptr,0);
    if(count<=0){result->Error("invalid","Invalid UTF8 directory");return;}
    std::wstring wide(static_cast<size_t>(count),L'\0');
    MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,path->data(),static_cast<int>(path->size()),wide.data(),count);
    ULARGE_INTEGER available={};
    if(!GetDiskFreeSpaceExW(wide.c_str(),&available,nullptr,nullptr)){result->Error("disk_space","Cannot read available bytes");return;}
    result->Success(flutter::EncodableValue(static_cast<int64_t>(available.QuadPart)));return;
  }
  if(call.method_name()=="moveFileExclusive") {
    const auto* args=call.arguments()?std::get_if<flutter::EncodableMap>(call.arguments()):nullptr;
    std::wstring paths[2];int index=0;
    for(const char* key:{"source","target"}) {
      if(!args){result->Error("invalid","Missing paths");return;}
      const auto it=args->find(flutter::EncodableValue(key));
      const auto* value=it==args->end()?nullptr:std::get_if<std::string>(&it->second);
      if(!value||value->empty()||value->find('\0')!=std::string::npos){result->Error("invalid","Invalid path");return;}
      const int count=MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,value->data(),static_cast<int>(value->size()),nullptr,0);
      if(count<=0){result->Error("invalid","Invalid UTF8 path");return;}
      paths[index].resize(static_cast<size_t>(count));
      MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,value->data(),static_cast<int>(value->size()),paths[index].data(),count);++index;
    }
    if(!MoveFileW(paths[0].c_str(),paths[1].c_str())){result->Error("move_failed","Move without replacement failed");return;}
    result->Success();return;
  }
  if(call.method_name()=="capabilities"){
    result->Success(flutter::EncodableValue(flutter::EncodableMap{
      {flutter::EncodableValue("hotkeys"),flutter::EncodableValue(true)},
      {flutter::EncodableValue("clipboardEvents"),flutter::EncodableValue(true)},
      {flutter::EncodableValue("clipboardImages"),flutter::EncodableValue(image_codec_!=0)}}));return;
  }
  if(call.method_name()=="startClipboard"){
    if(!clipboard_listening_ && !AddClipboardFormatListener(window_)){result->Error("clipboard_listen","OS rejected listener");return;}
    clipboard_listening_=true;result->Success();return;
  }
  if(call.method_name()=="stopClipboard"){
    if(clipboard_listening_ && !RemoveClipboardFormatListener(window_)){result->Error("clipboard_stop","OS rejected listener removal");return;}
    clipboard_listening_=false;result->Success();return;
  }
  if(call.method_name()=="clipboardSnapshot"){
    ClipboardGuard guard(window_);if(!guard.open){result->Error("clipboard_busy","Clipboard is locked by another process");return;}
    flutter::EncodableMap value{{flutter::EncodableValue("sourceName"),flutter::EncodableValue(ClipboardOwnerName())},
      {flutter::EncodableValue("sequence"),flutter::EncodableValue(static_cast<int64_t>(GetClipboardSequenceNumber()))}};
    if(IsClipboardFormatAvailable(CF_UNICODETEXT)){
      const HANDLE memory=GetClipboardData(CF_UNICODETEXT);const SIZE_T size=memory?GlobalSize(memory):0;
      if(size>256*1024){result->Error("clipboard_size","Text exceeds capture limit");return;}
      const auto* text=memory?static_cast<const wchar_t*>(GlobalLock(memory)):nullptr;
      if(text){const auto length=wcsnlen_s(text,size/sizeof(wchar_t));const auto encoded=Utf8(text,static_cast<int>(length));GlobalUnlock(memory);
        if(!encoded.empty()){value[flutter::EncodableValue("type")]=flutter::EncodableValue("text");value[flutter::EncodableValue("text")]=flutter::EncodableValue(encoded);result->Success(flutter::EncodableValue(value));return;}}
    }
    if(!image_codec_){result->Success();return;}
    std::vector<uint8_t> png;const UINT png_format=RegisterClipboardFormatW(L"PNG");
    if(IsClipboardFormatAvailable(png_format)){
      const HANDLE memory=GetClipboardData(png_format);const SIZE_T size=memory?GlobalSize(memory):0;
      if(size>kMaxImage){result->Error("clipboard_size","Image exceeds capture limit");return;}
      const auto* raw=memory?static_cast<const uint8_t*>(GlobalLock(memory)):nullptr;
      if(raw){png.assign(raw,raw+size);GlobalUnlock(memory);auto stream=ByteStream(png);
        if(!stream){result->Error("clipboard_image","Invalid image data");return;}
        Gdiplus::Bitmap image(stream.Get());if(!ValidDimensions(image)){result->Error("clipboard_image","Image dimensions exceed limit or image is invalid");return;}}
    }else if(IsClipboardFormatAvailable(CF_BITMAP)){
      const auto bitmap=static_cast<HBITMAP>(GetClipboardData(CF_BITMAP));if(bitmap){Gdiplus::Bitmap image(bitmap,nullptr);png=EncodePng(image);}
      if(png.empty()){result->Error("clipboard_image","Image cannot be encoded within limits");return;}
    }
    if(png.empty()){result->Success();return;}
    value[flutter::EncodableValue("type")]=flutter::EncodableValue("image");value[flutter::EncodableValue("bytes")]=flutter::EncodableValue(png);result->Success(flutter::EncodableValue(value));return;
  }
  if(call.method_name()=="copyImage"){
    const auto* args=call.arguments()?std::get_if<flutter::EncodableMap>(call.arguments()):nullptr;
    const auto entry=args?args->find(flutter::EncodableValue("bytes")):flutter::EncodableMap::const_iterator{};
    const auto* bytes=args&&entry!=args->end()?std::get_if<std::vector<uint8_t>>(&entry->second):nullptr;
    if(!image_codec_||!bytes||bytes->empty()||bytes->size()>kMaxImage){result->Error("clipboard_image","Invalid or oversized image");return;}
    auto stream=ByteStream(*bytes);if(!stream){result->Error("clipboard_image","Image stream failed");return;}
    Gdiplus::Bitmap image(stream.Get());if(!ValidDimensions(image)){result->Error("clipboard_image","Invalid image dimensions");return;}
    HBITMAP bitmap=nullptr;image.GetHBITMAP(Gdiplus::Color(255,255,255),&bitmap);
    HGLOBAL memory=GlobalAlloc(GMEM_MOVEABLE,bytes->size());
    void* raw=memory?GlobalLock(memory):nullptr;if(!raw){if(memory)GlobalFree(memory);if(bitmap)DeleteObject(bitmap);result->Error("clipboard_image","Image allocation failed");return;}
    memcpy(raw,bytes->data(),bytes->size());GlobalUnlock(memory);
    ClipboardGuard guard(window_);if(!guard.open){GlobalFree(memory);if(bitmap)DeleteObject(bitmap);result->Error("clipboard_busy","Clipboard is locked");return;}
    if(!EmptyClipboard()){GlobalFree(memory);if(bitmap)DeleteObject(bitmap);result->Error("clipboard_write","Cannot clear clipboard");return;}
    const bool png_ok=SetClipboardData(RegisterClipboardFormatW(L"PNG"),memory)!=nullptr;
    if(!png_ok)GlobalFree(memory);
    const bool bitmap_ok=bitmap&&SetClipboardData(CF_BITMAP,bitmap)!=nullptr;
    if(bitmap&&!bitmap_ok)DeleteObject(bitmap);
    if(!png_ok&&!bitmap_ok){result->Error("clipboard_write","Cannot write image");return;}result->Success();return;
  }
  if(call.method_name()=="registerHotkey") {
    const auto* args=call.arguments()?std::get_if<flutter::EncodableMap>(call.arguments()):nullptr;
    if(!args){result->Error("invalid","Missing hotkey arguments");return;}
    const int mods=ReadInt(*args,"modifiers"), key=ReadInt(*args,"key");
    if(mods<1 || (mods & ~15)!=0 || key<32 || key>135){result->Error("invalid","Unsupported key combination");return;}
    const bool previous=hotkey_registered_;
    if(previous) UnregisterHotKey(window_, kHotkeyId);
    if(!RegisterHotKey(window_,kHotkeyId,static_cast<UINT>(mods)|MOD_NOREPEAT,static_cast<UINT>(key))) {
      const DWORD error=GetLastError();
      hotkey_registered_=previous && RegisterHotKey(window_,kHotkeyId,modifiers_|MOD_NOREPEAT,key_)!=0;
      result->Error("hotkey_conflict","OS rejected hotkey",flutter::EncodableValue(static_cast<int32_t>(error)));return;
    }
    hotkey_registered_=true;modifiers_=static_cast<UINT>(mods);key_=static_cast<UINT>(key);
    result->Success();return;
  }
  if(call.method_name()=="unregisterHotkey") {
    if(hotkey_registered_ && !UnregisterHotKey(window_,kHotkeyId)){result->Error("hotkey_remove","OS rejected unregister");return;}
    hotkey_registered_=false;result->Success();return;
  }
  result->NotImplemented();
}
std::optional<LRESULT> ToolboxPlatform::HandleMessage(UINT message, WPARAM wparam, LPARAM) {
  if(message==WM_DROPFILES && drop_listening_){ReceiveDrop(wparam);return 0;}
  if(message==WM_CLOSE&&close_guard_){
    if(!close_pending_){close_pending_=true;channel_->InvokeMethod("windowClosing",nullptr);}return 0;
  }
  if(message==WM_CLIPBOARDUPDATE && clipboard_listening_){channel_->InvokeMethod("clipboardChanged",nullptr);return 0;}
  if(message==WM_HOTKEY && static_cast<int>(wparam)==kHotkeyId) {
    ShowWindow(window_,SW_RESTORE);SetForegroundWindow(window_);
    channel_->InvokeMethod("hotkey",nullptr);return 0;
  }
  return std::nullopt;
}

// Only the currently active Hash Inspector enables this same-thread view hook.
// Paths are bounded references; reading starts in Dart after the explicit drop.
void ToolboxPlatform::ReceiveDrop(WPARAM parameter) {
  auto drop=reinterpret_cast<HDROP>(parameter);
  flutter::EncodableList files;
  const UINT count=DragQueryFileW(drop,0xFFFFFFFF,nullptr,0);
  for(UINT i=0;i<count && i<101;i++) {
    const UINT length=DragQueryFileW(drop,i,nullptr,0);
    if(length==0 || length>32767)continue;
    std::vector<wchar_t> text(length+1);
    if(DragQueryFileW(drop,i,text.data(),length+1)==length)files.emplace_back(Utf8(text.data(),static_cast<int>(length)));
  }
  DragFinish(drop);
  channel_->InvokeMethod("filesDropped",std::make_unique<flutter::EncodableValue>(files));
}
LRESULT CALLBACK ToolboxPlatform::DropSubclass(HWND window,UINT message,WPARAM wparam,LPARAM lparam,UINT_PTR id,DWORD_PTR data) {
  auto* owner=reinterpret_cast<ToolboxPlatform*>(data);
  if(message==WM_DROPFILES && owner->drop_listening_){owner->ReceiveDrop(wparam);return 0;}
  if(message==WM_NCDESTROY){RemoveWindowSubclass(window,DropSubclass,id);owner->drop_view_=nullptr;}
  return DefSubclassProc(window,message,wparam,lparam);
}
