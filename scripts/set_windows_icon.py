"""Replace PE group/icon resources on a NEW owned release, preserving overlay bytes."""
import ctypes,struct,sys
from ctypes import wintypes as w
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
def pointer(value):
 return ctypes.c_void_p(value) if isinstance(value,int) else ctypes.cast(ctypes.c_wchar_p(value),ctypes.c_void_p)
def section_end(data):
 pe=struct.unpack_from('<I',data,0x3c)[0];count=struct.unpack_from('<H',data,pe+6)[0];size=struct.unpack_from('<H',data,pe+20)[0];base=pe+24+size
 return max(struct.unpack_from('<II',data,base+i*40+16)[0]+struct.unpack_from('<II',data,base+i*40+16)[1] for i in range(count))
def update(executable,ico):
 executable=executable.resolve();ico=ico.resolve()
 if not executable.is_relative_to(ROOT/'artifacts'):raise ValueError('Only owned unsealed artifacts may be edited.')
 for parent in executable.parents:
  marker=parent/'MILESTONE_STATUS.json'
  if marker.exists():
   import json
   if json.loads(marker.read_text(encoding='utf-8-sig')).get('sealed'):raise ValueError('Refuse sealed milestone.')
  if parent==ROOT/'artifacts':break
 original=executable.read_bytes();overlay=original[section_end(original):]
 raw=ico.read_bytes();_,kind,count=struct.unpack_from('<HHH',raw)
 if kind!=1 or not 1<=count<=32:raise ValueError('Invalid ICO.')
 kernel=ctypes.WinDLL('kernel32',use_last_error=True)
 kernel.LoadLibraryExW.argtypes=[w.LPCWSTR,w.HANDLE,w.DWORD];kernel.LoadLibraryExW.restype=w.HMODULE
 kernel.FreeLibrary.argtypes=[w.HMODULE]
 module=kernel.LoadLibraryExW(str(executable),None,0x22)
 if not module:raise ctypes.WinError(ctypes.get_last_error())
 groups=[]
 CALLBACK=ctypes.WINFUNCTYPE(w.BOOL,w.HMODULE,ctypes.c_void_p,ctypes.c_void_p,w.LPARAM)
 LANGCALL=ctypes.WINFUNCTYPE(w.BOOL,w.HMODULE,ctypes.c_void_p,ctypes.c_void_p,w.WORD,w.LPARAM)
 kernel.EnumResourceLanguagesW.argtypes=[w.HMODULE,ctypes.c_void_p,ctypes.c_void_p,LANGCALL,w.LPARAM]
 def name_callback(h,t,n,l):
  name=n if n<=0xffff else ctypes.wstring_at(n)
  langs=[]
  cb=LANGCALL(lambda h,t,n,language,l:langs.append(language) is None)
  kernel.EnumResourceLanguagesW(h,t,n,cb,0)
  groups.extend((name,language) for language in langs)
  return True
 cb=CALLBACK(name_callback)
 kernel.EnumResourceNamesW.argtypes=[w.HMODULE,ctypes.c_void_p,CALLBACK,w.LPARAM]
 kernel.EnumResourceNamesW(module,pointer(14),cb,0);kernel.FreeLibrary(module)
 if not groups:groups=[(1,1033)]
 kernel.BeginUpdateResourceW.argtypes=[w.LPCWSTR,w.BOOL];kernel.BeginUpdateResourceW.restype=w.HANDLE
 kernel.UpdateResourceW.argtypes=[w.HANDLE,ctypes.c_void_p,ctypes.c_void_p,w.WORD,ctypes.c_void_p,w.DWORD]
 kernel.EndUpdateResourceW.argtypes=[w.HANDLE,w.BOOL]
 handle=kernel.BeginUpdateResourceW(str(executable),False)
 if not handle:raise ctypes.WinError(ctypes.get_last_error())
 def put(kind,name,language,data):
  buffer=ctypes.create_string_buffer(data)
  if not kernel.UpdateResourceW(handle,pointer(kind),pointer(name),language,buffer,len(data)):raise ctypes.WinError(ctypes.get_last_error())
 try:
  group=bytearray(struct.pack('<HHH',0,1,count))
  entries=[]
  for i in range(count):
   width,height,colors,reserved,planes,bits,size,offset=struct.unpack_from('<BBBBHHII',raw,6+i*16)
   data=raw[offset:offset+size]
   if len(data)!=size:raise ValueError('Truncated ICO.')
   identity=1001+i;entries.append((identity,data));group.extend(struct.pack('<BBBBHHIH',width,height,colors,reserved,planes,bits,size,identity))
  for language in {language for _,language in groups}:
   for identity,data in entries:put(3,identity,language,data)
  for name,language in groups:put(14,name,language,bytes(group))
 except BaseException:
  kernel.EndUpdateResourceW(handle,True);raise
 if not kernel.EndUpdateResourceW(handle,False):raise ctypes.WinError(ctypes.get_last_error())
 modified=executable.read_bytes();end=section_end(modified)
 if overlay and modified[end:]!=overlay:
  # UpdateResource may drop a self-extracting CAB overlay. Restore byte-for-byte.
  executable.write_bytes(modified[:end]+overlay)
 print('Updated',len(groups),'icon groups;',count,'sizes; original overlay',len(overlay),'bytes preserved.')
if __name__=='__main__':update(Path(sys.argv[1]),Path(sys.argv[2]))
