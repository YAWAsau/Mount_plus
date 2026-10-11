use crate::{os, rows, runtime, Result};
use std::{
    collections::{BTreeMap, BTreeSet},
    fs,
    io::Read,
    os::{
        fd::{AsRawFd, OwnedFd},
        unix::process::CommandExt,
    },
    path::{Path, PathBuf},
    process::{Command, Stdio},
    sync::Arc,
    time::{Duration, Instant},
};
unsafe extern "C" {
    fn __system_property_get(name: *const libc::c_char, value: *mut libc::c_char) -> i32;
    fn __system_property_find(name: *const libc::c_char) -> *const libc::c_void;
    fn __system_property_serial(pi: *const libc::c_void) -> u32;
    fn __system_property_area_serial() -> u32;
    fn __system_property_wait(
        pi: *const libc::c_void,
        old: u32,
        new: *mut u32,
        timeout: *const libc::timespec,
    ) -> bool;
}
pub fn property(key: &str) -> String {
    let Ok(k) = os::c(key) else {
        return String::new();
    };
    let mut b = [0u8; 92];
    let n = unsafe { __system_property_get(k.as_ptr(), b.as_mut_ptr().cast()) }.max(0) as usize;
    String::from_utf8_lossy(&b[..n.min(b.len())]).into_owned()
}
fn wait_property(key: &str, mut changed: impl FnMut(&str) -> bool) {
    let k = os::c(key).unwrap();
    let mut before = None;
    loop {
        let global = unsafe { __system_property_area_serial() };
        let pi = unsafe { __system_property_find(k.as_ptr()) };
        let serial = if pi.is_null() {
            global
        } else {
            unsafe { __system_property_serial(pi) }
        };
        let value = property(key);
        if before.as_ref() != Some(&value) {
            if !changed(&value) {
                return;
            }
            before = Some(value)
        }
        let mut next = serial;
        unsafe {
            __system_property_wait(pi, serial, &mut next, std::ptr::null());
        }
    }
}
pub fn prop_cli(a: &[String]) -> Result<i32> {
    if a.len() != 3 || a[0] != "equals" {
        return Ok(2);
    }
    wait_property(&a[1], |v| v != a[2]);
    Ok(0)
}
pub fn hash(path: &str) -> Result<String> {
    let mut f = fs::File::open(path)?;
    let mut buf = [0u8; 8192];
    let mut h = 1469598103934665603u64;
    let mut len = 0;
    loop {
        let n = f.read(&mut buf)?;
        if n == 0 {
            break;
        }
        for b in &buf[..n] {
            h = (h ^ *b as u64).wrapping_mul(1099511628211)
        }
        len += n
    }
    Ok(format!("{h:016x}:{len}"))
}
pub struct Inotify {
    fd: OwnedFd,
    watch: BTreeMap<PathBuf, i32>,
}
impl Inotify {
    fn new() -> Result<Self> {
        Ok(Self {
            fd: os::fd(unsafe { libc::inotify_init1(libc::IN_CLOEXEC | libc::IN_NONBLOCK) })?,
            watch: BTreeMap::new(),
        })
    }
    fn add(&mut self, p: &Path, mask: u32) -> Result<()> {
        if self.watch.contains_key(p) {
            return Ok(());
        }
        let name = os::c(&p.to_string_lossy())?;
        let wd = unsafe { libc::inotify_add_watch(self.fd.as_raw_fd(), name.as_ptr(), mask) };
        if wd < 0 {
            let e = std::io::Error::last_os_error();
            if matches!(e.raw_os_error(), Some(libc::ENOENT | libc::ENOTDIR)) {
                return Ok(());
            }
            return Err(e.into());
        }
        self.watch.insert(p.into(), wd);
        Ok(())
    }
    fn parents(&mut self, path: &Path) -> Result<()> {
        for p in path.ancestors().skip(1) {
            self.add(
                p,
                libc::IN_CREATE
                    | libc::IN_DELETE
                    | libc::IN_MOVED_FROM
                    | libc::IN_MOVED_TO
                    | libc::IN_DELETE_SELF
                    | libc::IN_MOVE_SELF
                    | libc::IN_ONLYDIR,
            )?
        }
        Ok(())
    }
    fn drain(&mut self) -> Result<()> {
        let mut b = [0u8; 65536];
        loop {
            let n = unsafe { libc::read(self.fd.as_raw_fd(), b.as_mut_ptr().cast(), b.len()) };
            if n < 0 {
                let e = std::io::Error::last_os_error();
                if e.kind() == std::io::ErrorKind::WouldBlock {
                    break;
                }
                if e.kind() == std::io::ErrorKind::Interrupted {
                    continue;
                }
                return Err(e.into());
            }
            if n == 0 {
                break;
            }
        }
        Ok(())
    }
    fn wait(&mut self, timeout: i32) -> Result<i32> {
        let n = os::poll(
            &mut [libc::pollfd {
                fd: self.fd.as_raw_fd(),
                events: libc::POLLIN,
                revents: 0,
            }],
            timeout,
        )?;
        if n > 0 {
            self.drain()?
        }
        Ok(n)
    }
}
fn file_events(path: &str) -> Result<Inotify> {
    let mut n = Inotify::new()?;
    n.parents(Path::new(path))?;
    n.add(
        Path::new(path),
        libc::IN_MODIFY
            | libc::IN_CLOSE_WRITE
            | libc::IN_ATTRIB
            | libc::IN_MOVE_SELF
            | libc::IN_DELETE_SELF,
    )?;
    Ok(n)
}
pub fn conf_cli(a: &[String]) -> Result<i32> {
    if a.len() == 2 && a[0] == "--hash" {
        println!("{}", hash(&a[1])?);
        return Ok(0);
    }
    if a.len() != 3 || a[0] != "--wait-stable-change" {
        return Ok(2);
    }
    let mut events = file_events(&a[1])?;
    loop {
        let first = hash(&a[1]).ok();
        if first.as_deref() != Some(&a[2]) && first.is_some() {
            events.wait(60)?;
            if hash(&a[1]).ok() == first {
                println!("{}", first.as_deref().unwrap_or_default());
                return Ok(0);
            }
        } else {
            events.wait(-1)?;
        }
        events = file_events(&a[1])?;
    }
}
type Snapshot = BTreeMap<String, Option<String>>;
fn source_events(file: &str) -> Result<(Inotify, Snapshot)> {
    let mut n = file_events(file)?;
    let mut s = BTreeMap::new();
    for r in rows(file)? {
        n.parents(Path::new(&r.src))?;
        if let Ok(p) = fs::canonicalize(&r.src) {
            n.parents(&p)?
        }
        s.insert(r.src.clone(), os::identity(&r.src));
    }
    Ok((n, s))
}
fn snapshot(file: &str) -> Result<Snapshot> {
    Ok(rows(file)?
        .into_iter()
        .map(|r| {
            let id = os::identity(&r.src);
            (r.src, id)
        })
        .collect())
}
fn restored(old: &Snapshot, new: &Snapshot) -> bool {
    new.iter()
        .any(|(p, id)| id.is_some() && old.get(p) != Some(id))
}
fn prop_events(users: &BTreeSet<u32>) -> Result<Arc<OwnedFd>> {
    let event = Arc::new(os::fd(unsafe {
        libc::eventfd(0, libc::EFD_CLOEXEC | libc::EFD_NONBLOCK)
    })?);
    for user in users {
        let writer = event.clone();
        let key = format!("sys.user.{user}.ce_available");
        std::thread::Builder::new()
            .name(format!("mount-ce-{user}"))
            .spawn(move || {
                wait_property(&key, |_| {
                    let one = 1u64;
                    unsafe {
                        libc::write(writer.as_raw_fd(), (&one as *const u64).cast(), 8);
                    }
                    true
                })
            })?;
    }
    Ok(event)
}
fn signals() -> Result<OwnedFd> {
    unsafe {
        let mut set: libc::sigset_t = std::mem::zeroed();
        libc::sigemptyset(&mut set);
        for s in [libc::SIGTERM, libc::SIGINT, libc::SIGCHLD] {
            libc::sigaddset(&mut set, s);
        }
        os::check(libc::pthread_sigmask(
            libc::SIG_BLOCK,
            &set,
            std::ptr::null_mut(),
        ))?;
        os::fd(libc::signalfd(
            -1,
            &set,
            libc::SFD_CLOEXEC | libc::SFD_NONBLOCK,
        ))
    }
}
fn users(file: &str) -> Result<BTreeSet<u32>> {
    Ok(rows(file)?.iter().map(|r| r.user).collect())
}
fn enqueue(queue: &mut BTreeSet<String>, event: String) {
    if let Some(u) = event.strip_prefix("unlock:") {
        queue.remove(&format!("stop:{u}"));
    }
    if let Some(u) = event.strip_prefix("stop:") {
        queue.remove(&format!("unlock:{u}"));
    }
    queue.insert(event);
}
fn child(moddir: &str, event: &str) -> Result<std::process::Child> {
    let mut c = Command::new("/system/bin/sh");
    c.args([&format!("{moddir}/service.sh"), "--event", event])
        .stdin(Stdio::null())
        .stdout(Stdio::null());
    unsafe {
        c.pre_exec(|| {
            let mut empty: libc::sigset_t = std::mem::zeroed();
            libc::sigemptyset(&mut empty);
            libc::pthread_sigmask(libc::SIG_SETMASK, &empty, std::ptr::null_mut());
            if libc::setsid() < 0 {
                return Err(std::io::Error::last_os_error());
            }
            Ok(())
        });
    }
    Ok(c.spawn()?)
}
// One resident process. Shell transactions exist only while processing events.
pub fn watch(a: &[String]) -> Result<i32> {
    if a.len() != 3 {
        return Ok(2);
    }
    let (moddir, rt, stop) = (&a[0], &a[1], &a[2]);
    fs::create_dir_all(rt)?;
    let _lock = match os::lock(&format!("{rt}/watch.rust.lock")) {
        Ok(l) => l,
        Err(e) => {
            if runtime::live(&format!("{rt}/watch.rust.supervisor")).is_some() {
                return Ok(0);
            }
            return Err(e);
        }
    };
    let sig = signals()?;
    let conf = format!(
        "{}/mount.conf",
        Path::new(rt).parent().ok_or("bad runtime")?.display()
    );
    let file = format!("{rt}/parsed/mounts.desired");
    let selected = users(&file)?;
    let needs_log = |users: &BTreeSet<u32>| {
        users
            .iter()
            .any(|u| *u != 0 || property(&format!("sys.user.{u}.ce_available")).is_empty())
    };
    let mut lifecycle = if needs_log(&selected) {
        crate::lifecycle::connect().ok()
    } else {
        None
    };
    let mut log_retry = if needs_log(&selected) && lifecycle.is_none() {
        Some(Instant::now() + Duration::from_secs(2))
    } else {
        None
    };
    let ce = prop_events(&selected)?;
    let mut ce_values: BTreeMap<u32, String> = BTreeMap::new();
    let mut config = file_events(&conf)?;
    let (mut source, mut previous) = source_events(&file)?;
    let mut config_hash = hash(&conf).ok();
    let mut queue = BTreeSet::<String>::from(["recover".into(), "source".into()]);
    let applied = crate::read(format!("{rt}/config.applied.cksum"));
    if !applied.trim().is_empty() && config_hash.as_deref() != Some(applied.trim()) {
        queue.insert("config".into());
    }
    let mut running: Option<(std::process::Child, String)> = None;
    let mut deadline: Option<Instant> = None;
    let mut attempts = BTreeMap::<String, u32>::new();
    runtime::record(&format!("{rt}/watch.rust.supervisor"), std::process::id())?;
    loop {
        if Path::new(stop).exists() {
            break;
        }
        if running.is_none() && deadline.is_none() {
            if let Some(event) = queue.pop_first() {
                let c = child(moddir, &event)?;
                running = Some((c, event));
            }
        }
        let timeout = deadline
            .into_iter()
            .chain(log_retry)
            .min()
            .map(|d| {
                d.saturating_duration_since(Instant::now())
                    .as_millis()
                    .min(i32::MAX as u128) as i32
            })
            .unwrap_or(-1);
        let mut fds = vec![
            libc::pollfd {
                fd: config.fd.as_raw_fd(),
                events: libc::POLLIN,
                revents: 0,
            },
            libc::pollfd {
                fd: source.fd.as_raw_fd(),
                events: libc::POLLIN,
                revents: 0,
            },
            libc::pollfd {
                fd: ce.as_raw_fd(),
                events: libc::POLLIN,
                revents: 0,
            },
            libc::pollfd {
                fd: sig.as_raw_fd(),
                events: libc::POLLIN,
                revents: 0,
            },
            libc::pollfd {
                fd: lifecycle.as_ref().map(AsRawFd::as_raw_fd).unwrap_or(-1),
                events: libc::POLLIN,
                revents: 0,
            },
        ];
        os::poll(&mut fds, timeout)?;
        let mut child_ready = false;
        let mut stopping = false;
        if fds[3].revents != 0 {
            loop {
                let mut info: libc::signalfd_siginfo = unsafe { std::mem::zeroed() };
                let n = unsafe {
                    libc::read(
                        sig.as_raw_fd(),
                        (&mut info as *mut libc::signalfd_siginfo).cast(),
                        std::mem::size_of_val(&info),
                    )
                };
                if n <= 0 {
                    break;
                }
                if info.ssi_signo == libc::SIGCHLD as u32 {
                    child_ready = true;
                } else {
                    stopping = true;
                }
            }
        }
        if stopping {
            break;
        }
        if fds[0].revents != 0 {
            config.drain()?;
            config = file_events(&conf)?;
            if hash(&conf).ok() != config_hash {
                deadline = Some(Instant::now() + Duration::from_millis(120));
            }
        }
        if fds[1].revents != 0 {
            source.drain()?;
            let (next, current) = source_events(&file)?;
            if restored(&previous, &current) {
                queue.insert("source".into());
            }
            previous = current;
            source = next;
            if snapshot(&file)? != previous {
                queue.insert("source".into());
            }
            if users(&file)? != selected {
                queue.insert("reexec".into());
            }
        }
        if fds[2].revents != 0 {
            let mut n = 0u64;
            unsafe {
                libc::read(ce.as_raw_fd(), (&mut n as *mut u64).cast(), 8);
            }
            for u in &selected {
                let value = property(&format!("sys.user.{u}.ce_available"));
                if ce_values.get(u) != Some(&value) {
                    let before = ce_values.insert(*u, value.clone());
                    if matches!(value.as_str(), "true" | "1") {
                        enqueue(&mut queue, format!("unlock:{u}"));
                    } else if matches!(value.as_str(), "false" | "0") && before.is_some() {
                        enqueue(&mut queue, format!("stop:{u}"));
                    }
                }
            }
        }
        if fds[4].revents != 0 {
            match crate::lifecycle::drain(lifecycle.as_ref().unwrap()) {
                Ok(events) => {
                    for event in events {
                        enqueue(&mut queue, event);
                    }
                }
                Err(e) => {
                    eprintln!("lifecycle: {e}");
                    lifecycle = None;
                    log_retry = Some(Instant::now() + Duration::from_secs(2));
                }
            }
        }
        if log_retry.is_some_and(|d| Instant::now() >= d) {
            lifecycle = crate::lifecycle::connect().ok();
            log_retry = lifecycle
                .is_none()
                .then(|| Instant::now() + Duration::from_secs(30));
            if lifecycle.is_some() {
                queue.insert("recover".into());
            }
        }
        if !needs_log(&selected) {
            lifecycle = None;
            log_retry = None;
        }
        let completed = if child_ready {
            match running.as_mut() {
                Some((c, _)) => c.try_wait()?,
                None => None,
            }
        } else {
            None
        };
        if let Some(status) = completed {
            let (_, event) = running.take().unwrap();
            if !status.success() {
                let superseded = event
                    .strip_prefix("unlock:")
                    .is_some_and(|u| queue.contains(&format!("stop:{u}")))
                    || event
                        .strip_prefix("stop:")
                        .is_some_and(|u| queue.contains(&format!("unlock:{u}")));
                let n = attempts.entry(event.clone()).or_default();
                *n += 1;
                if *n <= 3 && !superseded {
                    queue.insert(event);
                    deadline = Some(Instant::now() + Duration::from_secs(1 << *n));
                }
            } else {
                attempts.remove(&event);
            }
        }
        if deadline.is_some_and(|d| Instant::now() >= d) {
            deadline = None;
            let now = hash(&conf).ok();
            if now.is_some() && now != config_hash {
                config_hash = now;
                queue.insert("config".into());
            }
        }
        if running.is_none() && queue.remove("reexec") {
            let err = Command::new(std::env::current_exe()?)
                .arg("watch")
                .args(a)
                .exec();
            return Err(err.into());
        }
    }
    // Let the active transaction finish; stopping a watcher must not tear a mount commit.
    if let Some((mut c, _)) = running {
        c.wait()?;
    }
    fs::remove_file(format!("{rt}/watch.rust.supervisor"))?;
    Ok(0)
}
