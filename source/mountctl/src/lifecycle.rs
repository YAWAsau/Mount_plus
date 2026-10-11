// Android logd reader protocol; filter system_server in logd, then inspect only
// UserController.UserState payloads. No logcat process or formatted log stream.
use crate::{os, runtime, Result};
use std::os::fd::{AsRawFd, OwnedFd};
pub fn connect() -> Result<OwnedFd> {
    let pid = runtime::pids()
        .into_iter()
        .find(|p| {
            runtime::cmd(*p)
                .first()
                .is_some_and(|s| s == "system_server")
        })
        .ok_or("system_server not ready")?;
    let fd = os::fd(unsafe {
        libc::socket(libc::AF_UNIX, libc::SOCK_SEQPACKET | libc::SOCK_CLOEXEC, 0)
    })?;
    let mut addr: libc::sockaddr_un = unsafe { std::mem::zeroed() };
    addr.sun_family = libc::AF_UNIX as _;
    let path = b"/dev/socket/logdr\0";
    for (i, b) in path.iter().enumerate() {
        addr.sun_path[i] = *b as _;
    }
    os::check(unsafe {
        libc::connect(
            fd.as_raw_fd(),
            (&addr as *const libc::sockaddr_un).cast(),
            (std::mem::size_of::<libc::sa_family_t>() + path.len()) as _,
        )
    })?;
    let request = format!("stream lids=0,3 tail=1 pid={pid}");
    let n = unsafe { libc::write(fd.as_raw_fd(), request.as_ptr().cast(), request.len()) };
    if n != request.len() as isize {
        return Err("logd subscription failed".into());
    }
    os::check(unsafe { libc::fcntl(fd.as_raw_fd(), libc::F_SETFL, libc::O_NONBLOCK) })?;
    Ok(fd)
}
fn parse(b: &[u8]) -> Option<String> {
    if b.len() < 4 {
        return None;
    }
    let len = u16::from_le_bytes([b[0], b[1]]) as usize;
    let header = u16::from_le_bytes([b[2], b[3]]) as usize;
    if header < 20 || header + len > b.len() {
        return None;
    }
    let payload = &b[header..header + len];
    let (tag, msg) = payload
        .get(1..)?
        .split_at(payload.get(1..)?.iter().position(|b| *b == 0)?);
    if tag != b"UserController.UserState" {
        return None;
    }
    let msg = std::str::from_utf8(msg.get(1..)?)
        .ok()?
        .trim_end_matches('\0');
    let user = msg
        .split("User ")
        .nth(1)?
        .split_whitespace()
        .next()?
        .parse::<u32>()
        .ok()?;
    if msg.contains("to RUNNING_UNLOCKED") {
        Some(format!("unlock:{user}"))
    } else if msg.contains("to STOPPING") || msg.contains("to SHUTDOWN") {
        Some(format!("stop:{user}"))
    } else {
        None
    }
}
pub fn drain(fd: &OwnedFd) -> Result<Vec<String>> {
    let mut out = vec![];
    let mut b = [0u8; 8192];
    loop {
        let n = unsafe { libc::recv(fd.as_raw_fd(), b.as_mut_ptr().cast(), b.len(), 0) };
        if n == 0 {
            return Err("logd disconnected".into());
        }
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
        if let Some(s) = parse(&b[..n as usize]) {
            out.push(s)
        }
    }
    Ok(out)
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn lifecycle_payload() {
        let mut b = vec![0u8; 28];
        let p=b"\x04UserController.UserState\0User 10 state changed from RUNNING_LOCKED to RUNNING_UNLOCKED\0";
        b[0..2].copy_from_slice(&(p.len() as u16).to_le_bytes());
        b[2..4].copy_from_slice(&28u16.to_le_bytes());
        b.extend_from_slice(p);
        assert_eq!(parse(&b).as_deref(), Some("unlock:10"));
        b[29] = b'X';
        assert!(parse(&b).is_none());
    }
}
