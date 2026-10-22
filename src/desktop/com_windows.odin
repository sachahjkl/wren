package desktop

// The part of the Windows shell's COM interfaces this package uses: IShellLinkW (a .lnk shortcut), IPersistFile (its
// file) and IPropertyStore (its AppUserModelID). core:sys/windows declares IPropertyStore but with a PROPVARIANT that
// is 16 bytes (the real one is 24 on 64-bit Windows), so these are declared here, every vtable listing all its methods
// in the order of the SDK headers (shobjidl_core.h, propsys.h, objidl.h): the offsets are what matters.

import win "core:sys/windows"

GUID :: win.GUID

CLSID_ShellLink     := GUID{0x00021401, 0x0000, 0x0000, {0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46}}
IID_IShellLinkW     := GUID{0x000214F9, 0x0000, 0x0000, {0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46}}
IID_IPersistFile    := GUID{0x0000010B, 0x0000, 0x0000, {0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46}}
IID_IPropertyStore  := GUID{0x886D8EEB, 0x8CF2, 0x4446, {0x8D, 0x02, 0xCD, 0xBA, 0x1D, 0xBD, 0xCF, 0x99}}

Property_Key :: struct { fmtid: GUID, pid: u32 }

// PKEY_AppUserModel_ID: {9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3}, 5
PKEY_AppUserModel_ID := Property_Key{{0x9F4C2855, 0x9F79, 0x4B39, {0xA8, 0xD0, 0xE1, 0xD4, 0x2D, 0xE1, 0xD5, 0xF3}}, 5}

VT_LPWSTR :: u16(31)

// The real PROPVARIANT: vt, three reserved words, then a 16-byte union (here its pointer member).
Prop_Variant :: struct {
	vt:       u16,
	reserved: [3]u16,
	pointer:  rawptr,
	pad:      u64,
}
#assert(size_of(Prop_Variant) == 24)

SLGP_RAWPATH :: 0x4
STGM_READ    :: 0x0

IShellLinkW :: struct { using vtbl: ^IShellLinkW_Vtbl }
IShellLinkW_Vtbl :: struct {
	QueryInterface:      proc "system" (this: ^IShellLinkW, riid: ^GUID, out: ^rawptr) -> win.HRESULT,
	AddRef:              proc "system" (this: ^IShellLinkW) -> u32,
	Release:             proc "system" (this: ^IShellLinkW) -> u32,
	GetPath:             proc "system" (this: ^IShellLinkW, file: [^]u16, cch: i32, find_data: rawptr, flags: u32) -> win.HRESULT,
	GetIDList:           rawptr,
	SetIDList:           rawptr,
	GetDescription:      proc "system" (this: ^IShellLinkW, name: [^]u16, cch: i32) -> win.HRESULT,
	SetDescription:      proc "system" (this: ^IShellLinkW, name: cstring16) -> win.HRESULT,
	GetWorkingDirectory: proc "system" (this: ^IShellLinkW, dir: [^]u16, cch: i32) -> win.HRESULT,
	SetWorkingDirectory: proc "system" (this: ^IShellLinkW, dir: cstring16) -> win.HRESULT,
	GetArguments:        proc "system" (this: ^IShellLinkW, args: [^]u16, cch: i32) -> win.HRESULT,
	SetArguments:        proc "system" (this: ^IShellLinkW, args: cstring16) -> win.HRESULT,
	GetHotkey:           rawptr,
	SetHotkey:           rawptr,
	GetShowCmd:          rawptr,
	SetShowCmd:          proc "system" (this: ^IShellLinkW, show: i32) -> win.HRESULT,
	GetIconLocation:     proc "system" (this: ^IShellLinkW, path: [^]u16, cch: i32, index: ^i32) -> win.HRESULT,
	SetIconLocation:     proc "system" (this: ^IShellLinkW, path: cstring16, index: i32) -> win.HRESULT,
	SetRelativePath:     rawptr,
	Resolve:             rawptr,
	SetPath:             proc "system" (this: ^IShellLinkW, path: cstring16) -> win.HRESULT,
}

IPersistFile :: struct { using vtbl: ^IPersistFile_Vtbl }
IPersistFile_Vtbl :: struct {
	QueryInterface: proc "system" (this: ^IPersistFile, riid: ^GUID, out: ^rawptr) -> win.HRESULT,
	AddRef:         proc "system" (this: ^IPersistFile) -> u32,
	Release:        proc "system" (this: ^IPersistFile) -> u32,
	GetClassID:     rawptr,
	IsDirty:        rawptr,
	Load:           proc "system" (this: ^IPersistFile, file: cstring16, mode: u32) -> win.HRESULT,
	Save:           proc "system" (this: ^IPersistFile, file: cstring16, remember: win.BOOL) -> win.HRESULT,
	SaveCompleted:  rawptr,
	GetCurFile:     rawptr,
}

IPropertyStore :: struct { using vtbl: ^IPropertyStore_Vtbl }
IPropertyStore_Vtbl :: struct {
	QueryInterface: proc "system" (this: ^IPropertyStore, riid: ^GUID, out: ^rawptr) -> win.HRESULT,
	AddRef:         proc "system" (this: ^IPropertyStore) -> u32,
	Release:        proc "system" (this: ^IPropertyStore) -> u32,
	GetCount:       rawptr,
	GetAt:          rawptr,
	GetValue:       proc "system" (this: ^IPropertyStore, key: ^Property_Key, value: ^Prop_Variant) -> win.HRESULT,
	SetValue:       proc "system" (this: ^IPropertyStore, key: ^Property_Key, value: ^Prop_Variant) -> win.HRESULT,
	Commit:         proc "system" (this: ^IPropertyStore) -> win.HRESULT,
}

foreign import ole32_ "system:Ole32.lib"
foreign import shell32_ "system:Shell32.lib"
foreign import advapi32_ "system:Advapi32.lib"

@(default_calling_convention = "system", private)
foreign ole32_ {
	PropVariantClear :: proc(pv: ^Prop_Variant) -> win.HRESULT ---
}

@(default_calling_convention = "system", private)
foreign shell32_ {
	SetCurrentProcessExplicitAppUserModelID :: proc(app_id: cstring16) -> win.HRESULT ---
	GetCurrentProcessExplicitAppUserModelID :: proc(app_id: ^cstring16) -> win.HRESULT ---   // (the string is CoTaskMem's)
}

@(default_calling_convention = "system", private)
foreign advapi32_ {
	RegDeleteTreeW  :: proc(key: win.HKEY, sub_key: cstring16) -> win.LSTATUS ---
	RegDeleteKeyW   :: proc(key: win.HKEY, sub_key: cstring16) -> win.LSTATUS ---
	RegDeleteValueW :: proc(key: win.HKEY, name: cstring16) -> win.LSTATUS ---
}

// A COM apartment for the calling thread, for the length of one operation. Another apartment already there
// (RPC_E_CHANGED_MODE) is fine: the shell link classes work in either.
@(private)
Com :: struct { uninit: bool }

@(private)
com_enter :: proc() -> Com {
	hr := win.CoInitializeEx(nil, .APARTMENTTHREADED)
	return Com{uninit = hr >= 0}   // S_OK and S_FALSE are both balanced by CoUninitialize
}

@(private)
com_leave :: proc(c: Com) { if c.uninit { win.CoUninitialize() } }

@(private)
wide :: proc(s: string, allocator := context.temp_allocator) -> cstring16 { return win.utf8_to_wstring(s, allocator) }

// The text of a NUL-terminated UTF-16 buffer.
@(private)
narrow :: proc(buf: []u16, allocator := context.temp_allocator) -> string {
	n := 0
	for n < len(buf) && buf[n] != 0 { n += 1 }
	s, err := win.utf16_to_utf8(buf[:n], allocator)
	return err == nil ? s : ""
}
