//! The GPU process on Linux: sealed memfds, a socket pair as the doorbell (its end is the end of the other side), a second one to
//! pass a section's descriptor, PR_SET_PDEATHSIG, and what can be taken away without touching a driver's needs.

use super::IpcError;
use std::os::fd::RawFd;
use std::os::unix::process::CommandExt;
use std::path::Path;
use std::ptr::null_mut;
use std::sync::Mutex;

/// The descriptors the child finds, whatever they were here. Everything else is closed before it starts.
const FD_CONTROL: RawFd = 3;
const FD_BELL: RawFd = 4;
const FD_PASS: RawFd = 5;

fn last_error() -> String {
    std::io::Error::last_os_error().to_string()
}

// ---- shared memory ----

/// A memfd, mapped here. It is sealed at its size: a child that could shrink it would make the parent fault on a copy (SIGBUS).
pub struct Section {
    fd: RawFd,
    base: *mut u8,
    bytes: u64,
}

unsafe impl Send for Section {}
unsafe impl Sync for Section {}

fn map(fd: RawFd, bytes: u64) -> Option<*mut u8> {
    let p = unsafe { libc::mmap(null_mut(), bytes as usize, libc::PROT_READ | libc::PROT_WRITE, libc::MAP_SHARED, fd, 0) };
    if p == libc::MAP_FAILED {
        None
    } else {
        Some(p as *mut u8)
    }
}

impl Section {
    pub fn create(bytes: u64) -> Result<Section, String> {
        unsafe {
            let fd = libc::memfd_create(c"wren-webgl".as_ptr(), libc::MFD_CLOEXEC | libc::MFD_ALLOW_SEALING);
            if fd < 0 {
                return Err(last_error());
            }
            if libc::ftruncate(fd, bytes as libc::off_t) != 0 {
                let e = last_error();
                libc::close(fd);
                return Err(e);
            }
            libc::fcntl(fd, libc::F_ADD_SEALS, libc::F_SEAL_SHRINK | libc::F_SEAL_GROW | libc::F_SEAL_SEAL);
            match map(fd, bytes) {
                Some(base) => Ok(Section { fd, base, bytes }),
                None => {
                    let e = last_error();
                    libc::close(fd);
                    Err(e)
                }
            }
        }
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
            libc::munmap(self.base as *mut libc::c_void, self.bytes as usize);
            libc::close(self.fd);
        }
    }
}

/// A section as the child gets it: nothing in the message, its descriptor comes over the passing socket.
pub type SectionToken = u64;

static PASS_CHILD: Mutex<RawFd> = Mutex::new(-1);

/// Takes the next descriptor from the parent and maps it; its size is checked first.
pub fn map_token(_token: SectionToken, bytes: u64) -> Option<*mut u8> {
    let sock = *PASS_CHILD.lock().ok()?;
    let fd = recv_fd(sock)?;
    let mut st: libc::stat = unsafe { std::mem::zeroed() };
    let sized = unsafe { libc::fstat(fd, &mut st) } == 0 && st.st_size as u64 >= bytes;
    let p = if sized { map(fd, bytes) } else { None };
    unsafe { libc::close(fd) };
    p
}

pub unsafe fn unmap(base: *mut u8, bytes: u64) {
    libc::munmap(base as *mut libc::c_void, bytes as usize);
}

fn send_fd(sock: RawFd, fd: RawFd) -> bool {
    unsafe {
        let mut byte = 0u8;
        let mut iov = libc::iovec { iov_base: &mut byte as *mut u8 as *mut libc::c_void, iov_len: 1 };
        let space = libc::CMSG_SPACE(std::mem::size_of::<RawFd>() as u32) as usize;
        let mut control = vec![0u8; space];
        let mut msg: libc::msghdr = std::mem::zeroed();
        msg.msg_iov = &mut iov;
        msg.msg_iovlen = 1;
        msg.msg_control = control.as_mut_ptr() as *mut libc::c_void;
        msg.msg_controllen = space as _;
        let c = libc::CMSG_FIRSTHDR(&msg);
        (*c).cmsg_level = libc::SOL_SOCKET;
        (*c).cmsg_type = libc::SCM_RIGHTS;
        (*c).cmsg_len = libc::CMSG_LEN(std::mem::size_of::<RawFd>() as u32) as _;
        std::ptr::write_unaligned(libc::CMSG_DATA(c) as *mut RawFd, fd);
        // (never waits: a stuck child costs a frame section, not the page's thread)
        libc::sendmsg(sock, &msg, libc::MSG_DONTWAIT | libc::MSG_NOSIGNAL) == 1
    }
}

fn recv_fd(sock: RawFd) -> Option<RawFd> {
    unsafe {
        let mut byte = 0u8;
        let mut iov = libc::iovec { iov_base: &mut byte as *mut u8 as *mut libc::c_void, iov_len: 1 };
        let space = libc::CMSG_SPACE(std::mem::size_of::<RawFd>() as u32) as usize;
        let mut control = vec![0u8; space];
        let mut msg: libc::msghdr = std::mem::zeroed();
        msg.msg_iov = &mut iov;
        msg.msg_iovlen = 1;
        msg.msg_control = control.as_mut_ptr() as *mut libc::c_void;
        msg.msg_controllen = space as _;
        if libc::recvmsg(sock, &mut msg, libc::MSG_CMSG_CLOEXEC) != 1 {
            return None;
        }
        let c = libc::CMSG_FIRSTHDR(&msg);
        if c.is_null() || (*c).cmsg_level != libc::SOL_SOCKET || (*c).cmsg_type != libc::SCM_RIGHTS {
            return None;
        }
        Some(std::ptr::read_unaligned(libc::CMSG_DATA(c) as *const RawFd))
    }
}

// ---- the doorbell ----

/// A stream socket between the two: a byte rings, the end of the stream says the other side is gone.
pub struct Bell {
    sock: RawFd,
}

impl Bell {
    pub fn ring(&self) {
        let b = 0u8;
        // (never blocks: when its buffer is full the other side has plenty of reasons to wake)
        unsafe { libc::send(self.sock, &b as *const u8 as *const libc::c_void, 1, libc::MSG_DONTWAIT | libc::MSG_NOSIGNAL) };
    }
    pub fn wait(&self) -> Result<(), IpcError> {
        let mut scrap = [0u8; 256];
        loop {
            let n = unsafe { libc::recv(self.sock, scrap.as_mut_ptr() as *mut libc::c_void, scrap.len(), 0) };
            if n > 0 {
                return Ok(());
            }
            if n == 0 {
                return Err(IpcError::Gone);
            }
            if std::io::Error::last_os_error().kind() != std::io::ErrorKind::Interrupted {
                return Err(IpcError::Gone);
            }
        }
    }
}

// ---- the child, from the parent ----

pub struct Child {
    process: Mutex<ChildProcess>,
    bell: Bell,
    pass: RawFd,
    control: Section,
    pid: u32,
}

struct ChildProcess {
    pid: libc::pid_t,
    ended: Option<i32>,
}

/// Starts the program with the role argument, from the thread that lives as long as the child: PR_SET_PDEATHSIG fires when the
/// thread that started a process ends, not the process.
pub fn spawn(exe: &Path, extra_args: &[String], role_arg_prefix: &str, hooks: bool, keep_rights: bool) -> Result<Child, String> {
    unsafe {
        let control = Section::create(super::CONTROL_BYTES as u64)?;
        super::control_init(control.base());
        let mut bell = [0 as RawFd; 2];
        let mut pass = [0 as RawFd; 2];
        if libc::socketpair(libc::AF_UNIX, libc::SOCK_STREAM | libc::SOCK_CLOEXEC, 0, bell.as_mut_ptr()) != 0 {
            return Err(last_error());
        }
        if libc::socketpair(libc::AF_UNIX, libc::SOCK_STREAM | libc::SOCK_CLOEXEC, 0, pass.as_mut_ptr()) != 0 {
            let e = last_error();
            libc::close(bell[0]);
            libc::close(bell[1]);
            return Err(e);
        }
        let parent_pid = libc::getpid();
        let (control_fd, bell_child, pass_child) = (control.fd, bell[1], pass[1]);
        let mut role = format!("{FD_CONTROL},{FD_BELL},{FD_PASS}");
        if hooks {
            role.push_str(",hooks");
        }
        if keep_rights {
            role.push_str(",keep-rights");
        }
        let mut command = std::process::Command::new(exe);
        command.args(extra_args);
        command.arg(format!("{role_arg_prefix}{role}"));
        if let Some(dir) = exe.parent() {
            command.current_dir(dir);
        }
        command.stdin(std::process::Stdio::null()).stdout(std::process::Stdio::null());
        // (between fork and exec: only what is async-signal-safe)
        command.pre_exec(move || {
            // the child ends with the parent's thread; the parent may have ended before this line
            if libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGKILL as libc::c_ulong, 0, 0, 0) != 0 || libc::getppid() != parent_pid {
                libc::_exit(1);
            }
            // (first out of the way of the fixed numbers: one of the sources may be one of them)
            let (a, b, c) = (libc::fcntl(control_fd, libc::F_DUPFD_CLOEXEC, 16), libc::fcntl(bell_child, libc::F_DUPFD_CLOEXEC, 16), libc::fcntl(pass_child, libc::F_DUPFD_CLOEXEC, 16));
            if a < 0 || b < 0 || c < 0 || libc::dup2(a, FD_CONTROL) < 0 || libc::dup2(b, FD_BELL) < 0 || libc::dup2(c, FD_PASS) < 0 {
                libc::_exit(1);
            }
            // the browser's files, sockets and databases are not the child's
            if libc::syscall(libc::SYS_close_range, FD_PASS as libc::c_uint + 1, libc::c_uint::MAX, 0 as libc::c_uint) != 0 {
                for fd in (FD_PASS + 1)..4096 {
                    libc::close(fd);
                }
            }
            Ok(())
        });
        let spawned = command.spawn();
        libc::close(bell[1]);
        libc::close(pass[1]);
        match spawned {
            Ok(child) => {
                let pid = child.id();
                // (waited for here, with waitpid: std's Child has nothing to add, and dropping it leaves the process alone)
                drop(child);
                Ok(Child { process: Mutex::new(ChildProcess { pid: pid as libc::pid_t, ended: None }), bell: Bell { sock: bell[0] }, pass: pass[0], control, pid })
            }
            Err(e) => {
                libc::close(bell[0]);
                libc::close(pass[0]);
                Err(e.to_string())
            }
        }
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
    /// Sends the section's descriptor over. The message that names it comes after.
    pub fn share(&self, s: &Section) -> Option<SectionToken> {
        if send_fd(self.pass, s.fd) {
            Some(0)
        } else {
            None
        }
    }
    pub fn kill(&self) {
        if let Ok(p) = self.process.lock() {
            if p.ended.is_none() {
                unsafe { libc::kill(p.pid, libc::SIGKILL) };
            }
        }
    }
    fn reap(&self, block: bool) -> Option<i32> {
        let mut p = self.process.lock().ok()?;
        if p.ended.is_some() {
            return p.ended;
        }
        let mut status = 0;
        let r = unsafe { libc::waitpid(p.pid, &mut status, if block { 0 } else { libc::WNOHANG }) };
        if r == p.pid {
            p.ended = Some(status);
        } else if r < 0 {
            p.ended = Some(-1);
        }
        p.ended
    }
    pub fn exit_code(&self) -> Option<u32> {
        self.reap(false).map(|s| s as u32)
    }
    pub fn wait_end(&self, ms: u32) -> bool {
        let deadline = std::time::Instant::now() + std::time::Duration::from_millis(ms as u64);
        loop {
            if self.reap(false).is_some() {
                return true;
            }
            if std::time::Instant::now() >= deadline {
                return false;
            }
            std::thread::sleep(std::time::Duration::from_millis(1));
        }
    }
}

impl Drop for Child {
    fn drop(&mut self) {
        unsafe {
            libc::close(self.bell.sock);
            libc::close(self.pass);
        }
        // (no zombie, even if nobody asked; it was killed before it got here)
        let _ = self.reap(true);
    }
}

// ---- the child's side ----

pub struct ChildEnd {
    pub bell: Bell,
    pub control: *mut u8,
    pub hooks: bool,
    pub keep_rights: bool,
}

pub fn open_child(role: &str) -> Result<ChildEnd, String> {
    let mut f = role.split(',');
    let mut next = || f.next().and_then(|s| s.parse::<RawFd>().ok()).ok_or("the role argument is malformed".to_string());
    let (control, bell, pass) = (next()?, next()?, next()?);
    let rest: Vec<&str> = f.collect();
    let hooks = rest.contains(&"hooks");
    let keep_rights = rest.contains(&"keep-rights");
    let mut st: libc::stat = unsafe { std::mem::zeroed() };
    if unsafe { libc::fstat(control, &mut st) } != 0 || (st.st_size as u64) < super::CONTROL_BYTES as u64 {
        return Err("the control section is not there".to_string());
    }
    let base = map(control, super::CONTROL_BYTES as u64).ok_or_else(last_error)?;
    unsafe { libc::close(control) };
    if let Ok(mut p) = PASS_CHILD.lock() {
        *p = pass;
    }
    // (nothing else starts from here: the descriptors stay out of whatever a driver starts)
    unsafe {
        libc::fcntl(bell, libc::F_SETFD, libc::FD_CLOEXEC);
        libc::fcntl(pass, libc::F_SETFD, libc::FD_CLOEXEC);
    }
    Ok(ChildEnd { bell: Bell { sock: bell }, control: base, hooks, keep_rights })
}

pub fn exit_now(code: u32) -> ! {
    unsafe { libc::_exit(code as i32) }
}

/// What the child gives up as soon as it runs. No seccomp and no namespaces: drivers open /dev/dri and /sys, read shader caches,
/// and call ioctls no list here could name; docs/js/webgl.md says so.
pub fn lower_rights(_low_integrity: bool) -> Vec<&'static str> {
    let mut done = Vec::new();
    unsafe {
        if libc::prctl(libc::PR_SET_NO_NEW_PRIVS, 1 as libc::c_ulong, 0 as libc::c_ulong, 0 as libc::c_ulong, 0 as libc::c_ulong) == 0 {
            done.push("no-new-privs");
        }
        let none = libc::rlimit { rlim_cur: 0, rlim_max: 0 };
        if libc::setrlimit(libc::RLIMIT_CORE, &none) == 0 {
            done.push("no-core");
        }
    }
    done
}

pub fn args() -> Vec<String> {
    std::env::args_os().skip(1).map(|a| a.to_string_lossy().into_owned()).collect()
}

/// A pair of bells on one socket pair (ring tests).
#[cfg(test)]
pub fn test_bell_pair() -> (Bell, Bell) {
    let mut fds = [0 as RawFd; 2];
    unsafe { libc::socketpair(libc::AF_UNIX, libc::SOCK_STREAM | libc::SOCK_CLOEXEC, 0, fds.as_mut_ptr()) };
    (Bell { sock: fds[0] }, Bell { sock: fds[1] })
}

/// Is that process still there (a zombie is not)?
#[cfg(test)]
pub fn test_pid_alive(pid: u32) -> bool {
    match std::fs::read_to_string(format!("/proc/{pid}/stat")) {
        Ok(s) => s.rfind(')').and_then(|i| s[i + 1..].trim_start().chars().next()).is_some_and(|c| c != 'Z' && c != 'X'),
        Err(_) => false,
    }
}
