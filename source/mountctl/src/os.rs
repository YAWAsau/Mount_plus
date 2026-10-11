use crate::Result;
use std::{
    ffi::CString,
    fs::{self, File, OpenOptions},
    io::Write,
    os::{
        fd::{AsRawFd, FromRawFd, OwnedFd},
        unix::fs::{MetadataExt, OpenOptionsExt},
    },
    path::Path,
};
pub fn c(s: &str) -> Result<CString> {
    Ok(CString::new(s)?)
}
pub fn fd(n: i32) -> Result<OwnedFd> {
    if n < 0 {
        Err(std::io::Error::last_os_error().into())
    } else {
        Ok(unsafe { OwnedFd::from_raw_fd(n) })
    }
}
pub fn check(n: i32) -> Result<()> {
    if n < 0 {
        Err(std::io::Error::last_os_error().into())
    } else {
        Ok(())
    }
}
pub fn identity(p: &str) -> Option<String> {
    fs::metadata(p)
        .ok()
        .map(|m| format!("{}:{}", m.dev(), m.ino()))
}
pub fn same(a: &str, b: &str) -> bool {
    identity(a).is_some_and(|id| Some(id) == identity(b))
}
pub struct Namespace(File);
impl Namespace {
    pub fn enter(pid: u32) -> Result<Self> {
        // Android kernels may disable PID namespaces. Unit tests enter a
        // private mount namespace and map init to that test thread only.
        #[cfg(test)]
        let pid = if pid == 1 {
            unsafe { libc::syscall(libc::SYS_gettid) as u32 }
        } else {
            pid
        };
        let old = File::open("/proc/thread-self/ns/mnt")?;
        let new = File::open(format!("/proc/{pid}/ns/mnt"))?;
        check(unsafe { libc::setns(new.as_raw_fd(), libc::CLONE_NEWNS) })?;
        Ok(Self(old))
    }
}
impl Drop for Namespace {
    fn drop(&mut self) {
        if unsafe { libc::setns(self.0.as_raw_fd(), libc::CLONE_NEWNS) } < 0 {
            unsafe { libc::_exit(91) }
        }
    }
}
pub fn mount(src: &str, dst: &str, kind: &str, flags: libc::c_ulong, data: &str) -> Result<()> {
    let (s, d, k, v) = (c(src)?, c(dst)?, c(kind)?, c(data)?);
    check(unsafe {
        libc::mount(
            s.as_ptr(),
            d.as_ptr(),
            if kind.is_empty() {
                std::ptr::null()
            } else {
                k.as_ptr()
            },
            flags,
            if data.is_empty() {
                std::ptr::null()
            } else {
                v.as_ptr().cast()
            },
        )
    })
}
pub fn unmount(dst: &str) -> Result<()> {
    let d = c(dst)?;
    if unsafe { libc::umount2(d.as_ptr(), 0) } == 0 {
        return Ok(());
    }
    check(unsafe { libc::umount2(d.as_ptr(), libc::MNT_DETACH) })
}
pub fn unescape(s: &str) -> String {
    let mut b = Vec::new();
    let v = s.as_bytes();
    let mut i = 0;
    while i < v.len() {
        if v[i] == b'\\' && i + 3 < v.len() {
            let t = &v[i + 1..i + 4];
            if matches!(t, b"040" | b"011" | b"012" | b"134") {
                b.push((t[0] - b'0') * 64 + (t[1] - b'0') * 8 + t[2] - b'0');
                i += 4;
                continue;
            }
        }
        b.push(v[i]);
        i += 1
    }
    String::from_utf8_lossy(&b).into_owned()
}
pub fn mount_entry(dst: &str) -> Option<(String, String)> {
    crate::read("/proc/thread-self/mounts")
        .lines()
        .filter_map(|l| {
            let v: Vec<_> = l.split_whitespace().collect();
            (v.len() > 2 && unescape(v[1]) == dst).then(|| (unescape(v[0]), v[2].into()))
        })
        .next_back()
}
pub fn fuse(dst: &str) -> bool {
    mount_entry(dst).is_some_and(|(s, t)| s == "bindfs_shared" && t.starts_with("fuse"))
}
pub fn atomic(path: impl AsRef<Path>, data: &[u8]) -> Result<()> {
    let path = path.as_ref();
    let tmp = path.with_extension(format!("tmp.{}", std::process::id()));
    let mut f = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(&tmp)?;
    let r = (|| {
        f.write_all(data)?;
        f.sync_all()?;
        fs::rename(&tmp, path)?;
        Ok(())
    })();
    if r.is_err() {
        let _ = fs::remove_file(tmp);
    }
    r
}
pub fn lock(path: &str) -> Result<File> {
    let f = OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(path)?;
    check(unsafe { libc::flock(f.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) })?;
    Ok(f)
}
pub fn poll(fds: &mut [libc::pollfd], timeout: i32) -> Result<i32> {
    loop {
        let n = unsafe { libc::poll(fds.as_mut_ptr(), fds.len() as _, timeout) };
        if n >= 0 {
            return Ok(n);
        }
        if std::io::Error::last_os_error().raw_os_error() != Some(libc::EINTR) {
            return Err(std::io::Error::last_os_error().into());
        }
    }
}
pub fn wait(child: &mut std::process::Child, timeout: i32) -> Result<i32> {
    // SIGCHLD works on API 28 kernels that predate pidfd_open. Reap only our
    // child; the signal mask and descriptor live only for this bounded command.
    struct Mask(libc::sigset_t);
    impl Drop for Mask {
        fn drop(&mut self) {
            unsafe {
                libc::pthread_sigmask(libc::SIG_SETMASK, &self.0, std::ptr::null_mut());
            }
        }
    }
    let mut set: libc::sigset_t = unsafe { std::mem::zeroed() };
    let mut old: libc::sigset_t = unsafe { std::mem::zeroed() };
    unsafe {
        libc::sigemptyset(&mut set);
        libc::sigaddset(&mut set, libc::SIGCHLD);
        libc::pthread_sigmask(libc::SIG_BLOCK, &set, &mut old);
    }
    let _mask = Mask(old);
    let signal = fd(unsafe { libc::signalfd(-1, &set, libc::SFD_CLOEXEC | libc::SFD_NONBLOCK) })?;
    let until = std::time::Instant::now() + std::time::Duration::from_millis(timeout.max(0) as u64);
    loop {
        if let Some(status) = child.try_wait()? {
            return Ok(status.code().unwrap_or(1));
        }
        let left = until.saturating_duration_since(std::time::Instant::now());
        if left.is_zero() {
            child.kill()?;
            child.wait()?;
            return Ok(124);
        }
        let mut p = [libc::pollfd {
            fd: signal.as_raw_fd(),
            events: libc::POLLIN,
            revents: 0,
        }];
        poll(&mut p, left.as_millis().max(1).min(i32::MAX as u128) as i32)?;
        let mut info: libc::signalfd_siginfo = unsafe { std::mem::zeroed() };
        unsafe {
            libc::read(
                signal.as_raw_fd(),
                (&mut info as *mut libc::signalfd_siginfo).cast(),
                std::mem::size_of_val(&info),
            );
        }
    }
}
