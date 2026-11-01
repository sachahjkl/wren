//! The GPU process on Windows: a section of the page file, events, a Job object that ends the child with this process, and what
//! can be taken away from the child without touching a driver's needs (docs/js/webgl.md says what is and is not).

use super::IpcError;
use std::ffi::c_void;
use std::os::windows::ffi::OsStrExt;
use std::path::Path;
use std::ptr::{null, null_mut};
use windows_sys::Win32::Foundation::*;
use windows_sys::Win32::Security::*;
use windows_sys::Win32::System::Diagnostics::Debug::*;
use windows_sys::Win32::System::JobObjects::*;
use windows_sys::Win32::System::LibraryLoader::SetDllDirectoryW;
use windows_sys::Win32::System::Memory::*;
use windows_sys::Win32::System::SystemServices::*;
use windows_sys::Win32::System::Threading::*;

/// What a handle in a command line is.
fn arg_of(h: HANDLE) -> String {
    (h as usize).to_string()
}

fn handle_of(s: &str) -> Option<HANDLE> {
    s.parse::<usize>().ok().map(|v| v as HANDLE)
}

fn last_error() -> String {
    format!("system error {}", unsafe { GetLastError() })
}

fn wide(s: &std::ffi::OsStr) -> Vec<u16> {
    s.encode_wide().chain(std::iter::once(0)).collect()
}

// ---- shared memory ----

/// A section of the page file, mapped here.
pub struct Section {
    handle: HANDLE,
    base: *mut u8,
    bytes: u64,
}

unsafe impl Send for Section {}
unsafe impl Sync for Section {}

impl Section {
    pub fn create(bytes: u64) -> Result<Section, String> {
        let handle = unsafe { CreateFileMappingW(INVALID_HANDLE_VALUE, null(), PAGE_READWRITE, (bytes >> 32) as u32, bytes as u32, null()) };
        if handle.is_null() {
            return Err(last_error());
        }
        let view = unsafe { MapViewOfFile(handle, FILE_MAP_READ | FILE_MAP_WRITE, 0, 0, bytes as usize) };
        if view.Value.is_null() {
            let e = last_error();
            unsafe { CloseHandle(handle) };
            return Err(e);
        }
        Ok(Section { handle, base: view.Value as *mut u8, bytes })
    }
    pub fn base(&self) -> *mut u8 {
        self.base
    }
    pub fn bytes(&self) -> u64 {
        self.bytes
    }
}

impl Drop for Section {
    fn drop(&mut self) {
        unsafe {
            if !self.base.is_null() {
                UnmapViewOfFile(MEMORY_MAPPED_VIEW_ADDRESS { Value: self.base as *mut c_void });
            }
            if !self.handle.is_null() {
                CloseHandle(self.handle);
            }
        }
    }
}

/// A section as the child gets it: the handle's value in its process.
pub type SectionToken = u64;

/// The child's view of a section it was told of. The handle goes when mapped: the view holds the section.
pub fn map_token(token: SectionToken, bytes: u64) -> Option<*mut u8> {
    let handle = token as usize as HANDLE;
    let view = unsafe { MapViewOfFile(handle, FILE_MAP_READ | FILE_MAP_WRITE, 0, 0, bytes as usize) };
    unsafe { CloseHandle(handle) };
    if view.Value.is_null() {
        None
    } else {
        Some(view.Value as *mut u8)
    }
}

pub unsafe fn unmap(base: *mut u8, _bytes: u64) {
    UnmapViewOfFile(MEMORY_MAPPED_VIEW_ADDRESS { Value: base as *mut c_void });
}

// ---- the doorbell ----

/// One event per direction: `theirs` wakes the other side, `mine` wakes this one. Waiting also watches the other process: its end
/// is the end of the channel.
pub struct Bell {
    theirs: HANDLE,
    mine: HANDLE,
    peer: HANDLE,
}

unsafe impl Send for Bell {}
unsafe impl Sync for Bell {}

impl Bell {
    pub fn ring(&self) {
        unsafe { SetEvent(self.theirs) };
    }
    pub fn wait(&self) -> Result<(), IpcError> {
        let objects = [self.mine, self.peer];
        let r = unsafe { WaitForMultipleObjects(2, objects.as_ptr(), 0, INFINITE) };
        if r == WAIT_OBJECT_0 {
            Ok(())
        } else {
            Err(IpcError::Gone)
        }
    }
}

// ---- the child, from the parent ----

/// The child: everything needed to tell it things, to watch it and to end it.
pub struct Child {
    process: HANDLE,
    job: HANDLE,
    bell: Bell,
    control: Section,
    pid: u32,
}

unsafe impl Send for Child {}
unsafe impl Sync for Child {}

/// Rights on the parent that a child gets: only to see it end (SYNCHRONIZE).
const PARENT_RIGHTS: u32 = 0x0010_0000;
/// What a process of the job can no longer reach (a page's GPU work has no business there, and no driver of ours needed it).
const UI_LIMITS: u32 = JOB_OBJECT_UILIMIT_DESKTOP | JOB_OBJECT_UILIMIT_DISPLAYSETTINGS | JOB_OBJECT_UILIMIT_EXITWINDOWS | JOB_OBJECT_UILIMIT_GLOBALATOMS | JOB_OBJECT_UILIMIT_HANDLES | JOB_OBJECT_UILIMIT_READCLIPBOARD | JOB_OBJECT_UILIMIT_SYSTEMPARAMETERS | JOB_OBJECT_UILIMIT_WRITECLIPBOARD;
/// The child can start no other process.
const JOB_PROCESS_LIMIT: u32 = 1;

fn make_job() -> Result<HANDLE, String> {
    unsafe {
        let job = CreateJobObjectW(null(), null());
        if job.is_null() {
            return Err(last_error());
        }
        let mut limits: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = std::mem::zeroed();
        // closing the job's last handle (this process, however it ends) ends the child; an unhandled exception ends it with no dialog
        limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE | JOB_OBJECT_LIMIT_DIE_ON_UNHANDLED_EXCEPTION | JOB_OBJECT_LIMIT_ACTIVE_PROCESS;
        limits.BasicLimitInformation.ActiveProcessLimit = JOB_PROCESS_LIMIT;
        if SetInformationJobObject(job, JobObjectExtendedLimitInformation, &limits as *const _ as *const c_void, std::mem::size_of_val(&limits) as u32) == 0 {
            let e = last_error();
            CloseHandle(job);
            return Err(e);
        }
        let ui = JOBOBJECT_BASIC_UI_RESTRICTIONS { UIRestrictionsClass: UI_LIMITS };
        SetInformationJobObject(job, JobObjectBasicUIRestrictions, &ui as *const _ as *const c_void, std::mem::size_of_val(&ui) as u32);
        Ok(job)
    }
}

/// A handle list and a job list.
const SPAWN_ATTRIBUTES: u32 = 2;

/// Starts the program with the role argument. The handles it needs are the only ones it inherits (a handle list, not everything
/// that happens to be inheritable in the browser).
pub fn spawn(exe: &Path, extra_args: &[String], role_arg_prefix: &str, hooks: bool, keep_rights: bool) -> Result<Child, String> {
    unsafe {
        let control = Section::create(super::CONTROL_BYTES as u64)?;
        super::control_init(control.base());
        let inherit = SECURITY_ATTRIBUTES { nLength: std::mem::size_of::<SECURITY_ATTRIBUTES>() as u32, lpSecurityDescriptor: null_mut(), bInheritHandle: 1 };
        // (kept by this process for both ends: the child gets its handles to the same objects)
        let to_child = CreateEventW(&inherit, 0, 0, null());
        let to_parent = CreateEventW(&inherit, 0, 0, null());
        let mut parent_for_child: HANDLE = null_mut();
        if to_child.is_null() || to_parent.is_null() || DuplicateHandle(GetCurrentProcess(), GetCurrentProcess(), GetCurrentProcess(), &mut parent_for_child, PARENT_RIGHTS, 1, 0) == 0 {
            let e = last_error();
            for h in [to_child, to_parent] {
                if !h.is_null() {
                    CloseHandle(h);
                }
            }
            return Err(e);
        }
        // the section's handle becomes inheritable only for the moment the list names it
        SetHandleInformation(control.handle, HANDLE_FLAG_INHERIT, HANDLE_FLAG_INHERIT);
        let mut role = format!("{},{},{},{}", arg_of(control.handle), arg_of(to_child), arg_of(to_parent), arg_of(parent_for_child));
        if hooks {
            role.push_str(",hooks");
        }
        if keep_rights {
            role.push_str(",keep-rights");
        }
        let mut line = format!("\"{}\"", exe.display());
        for a in extra_args {
            line.push(' ');
            line.push_str(a);
        }
        line.push(' ');
        line.push_str(role_arg_prefix);
        line.push_str(&role);
        let mut wline: Vec<u16> = line.encode_utf16().chain(std::iter::once(0)).collect();
        let app = wide(exe.as_os_str());
        // no working directory of the caller's: what a planted DLL would count on
        let dir = exe.parent().map(|d| wide(d.as_os_str()));

        // The job is named at creation: there is no moment at which a process of ours exists outside it, so a browser killed at any
        // point leaves nothing behind. (Assigning it afterwards from a suspended start left suspended orphans here, parents killed
        // in between; this needs Windows 10 1607, which Direct3D 12 on a current driver needs anyway.)
        let closed = |e: String| {
            CloseHandle(parent_for_child);
            CloseHandle(to_child);
            CloseHandle(to_parent);
            e
        };
        let job = make_job().map_err(closed)?;
        let closed = |e: String| {
            CloseHandle(job);
            CloseHandle(parent_for_child);
            CloseHandle(to_child);
            CloseHandle(to_parent);
            e
        };
        let jobs = [job];
        let handles = [control.handle, to_child, to_parent, parent_for_child];
        let mut size = 0usize;
        InitializeProcThreadAttributeList(null_mut(), SPAWN_ATTRIBUTES, 0, &mut size);
        let mut list_mem = vec![0u64; size.div_ceil(8)];
        let list = list_mem.as_mut_ptr() as LPPROC_THREAD_ATTRIBUTE_LIST;
        if InitializeProcThreadAttributeList(list, SPAWN_ATTRIBUTES, 0, &mut size) == 0 {
            return Err(closed(last_error()));
        }
        if UpdateProcThreadAttribute(list, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST as usize, handles.as_ptr() as *const c_void, std::mem::size_of_val(&handles), null_mut(), null()) == 0
            || UpdateProcThreadAttribute(list, 0, PROC_THREAD_ATTRIBUTE_JOB_LIST as usize, jobs.as_ptr() as *const c_void, std::mem::size_of_val(&jobs), null_mut(), null()) == 0
        {
            let e = last_error();
            DeleteProcThreadAttributeList(list);
            return Err(closed(e));
        }
        let mut si: STARTUPINFOEXW = std::mem::zeroed();
        si.StartupInfo.cb = std::mem::size_of::<STARTUPINFOEXW>() as u32;
        si.StartupInfo.dwFlags = STARTF_FORCEOFFFEEDBACK;
        si.lpAttributeList = list;
        let mut pi: PROCESS_INFORMATION = std::mem::zeroed();
        let flags = EXTENDED_STARTUPINFO_PRESENT | CREATE_NO_WINDOW;
        let made = CreateProcessW(app.as_ptr(), wline.as_mut_ptr(), null(), null(), 1, flags, null(), dir.as_ref().map_or(null(), |d| d.as_ptr()), &si.StartupInfo, &mut pi);
        let spawn_error = last_error();
        DeleteProcThreadAttributeList(list);
        SetHandleInformation(control.handle, HANDLE_FLAG_INHERIT, 0);
        SetHandleInformation(to_child, HANDLE_FLAG_INHERIT, 0);
        SetHandleInformation(to_parent, HANDLE_FLAG_INHERIT, 0);
        if made == 0 {
            return Err(closed(spawn_error));
        }
        CloseHandle(parent_for_child);
        CloseHandle(pi.hThread);
        let bell = Bell { theirs: to_child, mine: to_parent, peer: pi.hProcess };

        Ok(Child { process: pi.hProcess, job, bell, control, pid: pi.dwProcessId })
    }
}

impl Child {
    pub fn bell(&self) -> &Bell {
        &self.bell
    }
    pub fn control(&self) -> *mut u8 {
        self.control.base()
    }
    pub fn pid(&self) -> u32 {
        self.pid
    }
    /// The section as a handle in the child's table: it may read and write it, and do nothing else with it.
    pub fn share(&self, s: &Section) -> Option<SectionToken> {
        let mut theirs: HANDLE = null_mut();
        let ok = unsafe { DuplicateHandle(GetCurrentProcess(), s.handle, self.process, &mut theirs, FILE_MAP_READ | FILE_MAP_WRITE, 0, 0) };
        if ok == 0 {
            None
        } else {
            Some(theirs as usize as u64)
        }
    }
    pub fn kill(&self) {
        unsafe { TerminateProcess(self.process, 1) };
    }
    /// The exit code once it ended.
    pub fn exit_code(&self) -> Option<u32> {
        let mut code = 0u32;
        if unsafe { GetExitCodeProcess(self.process, &mut code) } == 0 || code == STILL_ACTIVE as u32 {
            None
        } else {
            Some(code)
        }
    }
    /// Waits for it to end, for at most `ms`.
    pub fn wait_end(&self, ms: u32) -> bool {
        unsafe { WaitForSingleObject(self.process, ms) == WAIT_OBJECT_0 }
    }
}

impl Drop for Child {
    fn drop(&mut self) {
        unsafe {
            CloseHandle(self.bell.theirs);
            CloseHandle(self.bell.mine);
            CloseHandle(self.process);
            CloseHandle(self.job);
        }
    }
}

// ---- the child's side ----

pub struct ChildEnd {
    pub bell: Bell,
    pub control: *mut u8,
    pub hooks: bool,
    pub keep_rights: bool,
}

/// What a child takes from its argument, checked: a number that is no handle of the right kind maps nothing.
pub fn open_child(role: &str) -> Result<ChildEnd, String> {
    let mut f = role.split(',');
    let mut next = || f.next().and_then(handle_of).ok_or("the role argument is malformed".to_string());
    let (section, to_child, to_parent, parent) = (next()?, next()?, next()?, next()?);
    let rest: Vec<&str> = f.collect();
    let hooks = rest.contains(&"hooks");
    let keep_rights = rest.contains(&"keep-rights");
    let view = unsafe { MapViewOfFile(section, FILE_MAP_READ | FILE_MAP_WRITE, 0, 0, super::CONTROL_BYTES) };
    if view.Value.is_null() {
        return Err(last_error());
    }
    unsafe { CloseHandle(section) };
    Ok(ChildEnd { bell: Bell { theirs: to_parent, mine: to_child, peer: parent }, control: view.Value as *mut u8, hooks, keep_rights })
}

/// Ends this process at once: no destructor, no DLL detach (a hung driver's lock would hold those up).
pub fn exit_now(code: u32) -> ! {
    unsafe { TerminateProcess(GetCurrentProcess(), code) };
    std::process::abort()
}

/// Mandatory integrity level of a token: Low. A process at Low cannot write to what the user's programs own, files or registry,
/// nor open their processes.
const LOW_INTEGRITY_RID: u32 = SECURITY_MANDATORY_LOW_RID as u32;

/// What the child gives up as soon as it runs, before any driver is loaded. Each is a thing a driver has been seen not to
/// need; the rest is said in docs/js/webgl.md. Failures are not fatal: this is defence in depth.
pub fn lower_rights(low_integrity: bool) -> Vec<&'static str> {
    let mut done = Vec::new();
    unsafe {
        // the DLL search no longer looks in the working directory
        if SetDllDirectoryW([0u16].as_ptr()) != 0 {
            done.push("dll-search");
        }
        SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX | SEM_NOOPENFILEERRORBOX);
        let mut ext: PROCESS_MITIGATION_EXTENSION_POINT_DISABLE_POLICY = std::mem::zeroed();
        ext.Anonymous.Flags = 1; // DisableExtensionPoints: AppInit DLLs, IME, window hooks
        if SetProcessMitigationPolicy(ProcessExtensionPointDisablePolicy, &ext as *const _ as *const c_void, std::mem::size_of_val(&ext)) != 0 {
            done.push("extension-points");
        }
        let mut image: PROCESS_MITIGATION_IMAGE_LOAD_POLICY = std::mem::zeroed();
        image.Anonymous.Flags = 1 | 2; // NoRemoteImages, NoLowMandatoryLabelImages
        if SetProcessMitigationPolicy(ProcessImageLoadPolicy, &image as *const _ as *const c_void, std::mem::size_of_val(&image)) != 0 {
            done.push("image-load");
        }
        let mut token: HANDLE = null_mut();
        if OpenProcessToken(GetCurrentProcess(), TOKEN_ADJUST_DEFAULT | TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, &mut token) != 0 {
            // every privilege is dropped
            if drop_privileges(token) {
                done.push("privileges");
            }
            if low_integrity && set_low_integrity(token) {
                done.push("low-integrity");
            }
            CloseHandle(token);
        }
    }
    done
}

unsafe fn drop_privileges(token: HANDLE) -> bool {
    let mut size = 0u32;
    GetTokenInformation(token, TokenPrivileges, null_mut(), 0, &mut size);
    if size == 0 {
        return false;
    }
    let mut mem = vec![0u64; (size as usize).div_ceil(8)];
    if GetTokenInformation(token, TokenPrivileges, mem.as_mut_ptr() as *mut c_void, size, &mut size) == 0 {
        return false;
    }
    let list = mem.as_mut_ptr() as *mut TOKEN_PRIVILEGES;
    let count = (*list).PrivilegeCount as usize;
    let first = std::ptr::addr_of_mut!((*list).Privileges) as *mut LUID_AND_ATTRIBUTES;
    for i in 0..count {
        (*first.add(i)).Attributes = SE_PRIVILEGE_REMOVED;
    }
    AdjustTokenPrivileges(token, 0, list, 0, null_mut(), null_mut()) != 0 && GetLastError() == ERROR_SUCCESS
}

unsafe fn set_low_integrity(token: HANDLE) -> bool {
    let authority = SECURITY_MANDATORY_LABEL_AUTHORITY;
    let mut sid: PSID = null_mut();
    if AllocateAndInitializeSid(&authority, 1, LOW_INTEGRITY_RID, 0, 0, 0, 0, 0, 0, 0, &mut sid) == 0 {
        return false;
    }
    let label = TOKEN_MANDATORY_LABEL { Label: SID_AND_ATTRIBUTES { Sid: sid, Attributes: SE_GROUP_INTEGRITY as u32 } };
    let ok = SetTokenInformation(token, TokenIntegrityLevel, &label as *const _ as *const c_void, (std::mem::size_of::<TOKEN_MANDATORY_LABEL>() as u32) + GetLengthSid(sid));
    FreeSid(sid);
    ok != 0
}

/// The child's arguments, without the program, as UTF-8.
pub fn args() -> Vec<String> {
    std::env::args_os().skip(1).map(|a| a.to_string_lossy().into_owned()).collect()
}

/// A pair of bells on two ends of nothing but this process (ring tests): neither ever sees the other go.
#[cfg(test)]
pub fn test_bell_pair() -> (Bell, Bell) {
    unsafe {
        let (a, b) = (CreateEventW(null(), 0, 0, null()), CreateEventW(null(), 0, 0, null()));
        // (an event nobody sets: nobody goes)
        let never = CreateEventW(null(), 0, 0, null());
        (Bell { theirs: a, mine: b, peer: never }, Bell { theirs: b, mine: a, peer: never })
    }
}

/// Is that process still there?
#[cfg(test)]
pub fn test_pid_alive(pid: u32) -> bool {
    unsafe {
        let h = OpenProcess(PARENT_RIGHTS, 0, pid);
        if h.is_null() {
            return false;
        }
        let alive = WaitForSingleObject(h, 0) == WAIT_TIMEOUT;
        CloseHandle(h);
        alive
    }
}
