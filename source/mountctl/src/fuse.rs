use crate::{os, Result};
pub fn run(a: &[String]) -> Result<i32> {
    let mut opts = Vec::<String>::new();
    let mut pos = vec![];
    let mut i = 0;
    while i < a.len() {
        let s = &a[i];
        let csv = if s == "-o" {
            i += 1;
            a.get(i).map(String::as_str)
        } else {
            s.strip_prefix("-o").filter(|s| !s.is_empty())
        };
        if let Some(csv) = csv {
            for t in csv.split(',').map(str::trim) {
                if (matches!(
                    t,
                    "ro" | "rw" | "relatime" | "allow_other" | "default_permissions"
                ) || [
                    "fd=",
                    "rootmode=",
                    "user_id=",
                    "group_id=",
                    "max_read=",
                    "blksize=",
                    "max_write=",
                ]
                .iter()
                .any(|p| t.starts_with(p)))
                    && !opts.iter().any(|o| o == t)
                {
                    opts.push(t.into());
                }
            }
        } else if !s.starts_with('-') {
            pos.push(s.as_str())
        }
        i += 1
    }
    let target = pos.last().ok_or("missing FUSE target")?;
    if !opts.iter().any(|s| s.starts_with("fd=")) {
        let fd = pos.iter().rev().nth(1).ok_or("missing FUSE fd")?;
        crate::number(fd)?;
        opts.push(format!("fd={fd}"))
    }
    for (k, v) in [
        ("user_id", unsafe { libc::getuid() }),
        ("group_id", unsafe { libc::getgid() }),
    ] {
        if !opts.iter().any(|s| s.starts_with(&format!("{k}="))) {
            opts.push(format!("{k}={v}"))
        }
    }
    let flags = libc::MS_NOSUID
        | libc::MS_NODEV
        | if opts.iter().any(|s| s == "ro") {
            libc::MS_RDONLY
        } else {
            0
        }
        | if opts.iter().any(|s| s == "relatime") {
            libc::MS_RELATIME
        } else {
            0
        };
    if !opts.iter().any(|s| s.starts_with("rootmode=")) {
        opts.push("rootmode=40000".into())
    }
    let data = opts.join(",");
    if data.len() >= 2048 {
        return Err("FUSE options too long".into());
    }
    os::mount("bindfs_shared", target, "fuse", flags, &data)?;
    Ok(0)
}
