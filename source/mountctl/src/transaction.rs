use crate::{key, os, read, rows, runtime, Result, Row};
use std::{collections::BTreeMap, fs, io::Write, path::Path, process::Command, time::Duration};
struct Tx {
    opts: BTreeMap<String, String>,
}
impl Tx {
    fn get(&self, k: &str) -> &str {
        self.opts.get(k).map(String::as_str).unwrap_or("")
    }
    fn current(&self) -> bool {
        read(self.get("generation-file")).lines().next() == Some(self.get("generation"))
    }
    fn log(&self, s: &str) {
        if let Ok(mut f) = fs::OpenOptions::new()
            .append(true)
            .create(true)
            .open(self.get("log"))
        {
            let _ = writeln!(f, "[mountctl] {s}");
        }
    }
    fn unmount(&self, r: &Row) {
        for pid in runtime::core() {
            if !self.current() {
                return;
            }
            if let Ok(_n) = os::Namespace::enter(pid) {
                if runtime::owned(r, self.get("runtime")) {
                    let _ = os::unmount(&r.lower);
                }
            }
        }
    }
    fn mount(&self, r: &Row) -> Result<()> {
        let fuse = r.policy == "bindfs_shared";
        let mp = runtime::media(r.user, self.get("runtime"));
        let pids = if fuse {
            let mut p = vec![1];
            if let Some(m) = mp {
                if runtime::ns(1) != runtime::ns(m) {
                    p.push(m)
                }
            }
            p
        } else {
            runtime::core()
        };
        let mut good = 0;
        for pid in pids {
            if !self.current() {
                return Err("generation changed".into());
            }
            let _n = match os::Namespace::enter(pid) {
                Ok(n) => n,
                Err(_) => continue,
            };
            fs::create_dir_all(&r.lower)?;
            if fuse {
                if !os::fuse(&r.lower) {
                    if os::mount_entry(&r.lower).is_some() {
                        if !runtime::owned(r, self.get("runtime")) {
                            return Err("foreign mount at target".into());
                        }
                        os::unmount(&r.lower)?
                    }
                    let uid = key(
                        format!("{}/media_provider_ns.{}.cache", self.get("runtime"), r.user),
                        "UID",
                    )
                    .parse::<u32>()
                    .unwrap_or(r.user * 100000 + 10513);
                    let mut child = Command::new(format!("{}/bin/bindfs", self.get("moddir")))
                        .args([
                            "-o",
                            "fsname=bindfs_shared,allow_other",
                            "-u",
                            &uid.to_string(),
                            "-g",
                            "1023",
                            "-p",
                            "770",
                            "--create-for-user=0",
                            "--create-for-group=1023",
                            "--create-with-perms=660",
                            "--chown-ignore",
                            "--chgrp-ignore",
                            "--chmod-ignore",
                            &r.src,
                            &r.lower,
                        ])
                        .env(
                            "PATH",
                            format!(
                                "{}/bin:/system/bin:/system/xbin:/vendor/bin",
                                self.get("moddir")
                            ),
                        )
                        .env(
                            "FUSE_MOUNT_HELPER",
                            format!("{}/bin/mount.fuse3", self.get("moddir")),
                        )
                        .spawn()?;
                    if os::wait(&mut child, self.get("timeout-ms").parse().unwrap_or(9000))? != 0 {
                        return Err("bindfs helper failed".into());
                    }
                }
                if os::fuse(&r.lower) {
                    good += 1
                }
            } else {
                if !os::same(&r.src, &r.lower) {
                    if os::mount_entry(&r.lower).is_some() {
                        return Err("target still occupied".into());
                    }
                    os::mount(&r.src, &r.lower, "", libc::MS_BIND, "")?
                }
                if os::same(&r.src, &r.lower) {
                    good += 1
                }
            }
        }
        let verified = if fuse {
            os::Namespace::enter(mp.unwrap_or(1)).is_ok_and(|_n| os::fuse(&r.lower))
        } else {
            runtime::mounted(r, self.get("runtime"))
        };
        if good == 0 || !verified {
            return Err("mount verification failed".into());
        }
        Ok(())
    }
    fn visible(&self, r: &Row) -> bool {
        for delay in [0, 120, 250, 450] {
            if delay > 0 {
                std::thread::sleep(Duration::from_millis(delay))
            }
            if runtime::probe(r, self.get("runtime"), false) {
                return true;
            }
        }
        false
    }
    fn rollback(&self, new: &[Row], old: &[Row]) -> i32 {
        self.log("rollback begin");
        for delay in [0, 150, 300, 600] {
            std::thread::sleep(Duration::from_millis(delay));
            for r in new {
                self.unmount(r)
            }
            if old.iter().all(|r| self.mount(r).is_ok() && self.visible(r)) {
                self.log("rollback verified");
                return 10;
            }
        }
        self.log("rollback failed");
        11
    }
    fn restore_dir(&self, r: &Row) -> Result<()> {
        fs::create_dir_all(&r.lower)?;
        let c = os::c(&r.lower)?;
        unsafe {
            if r.lower.starts_with("/data/media/") || r.lower.starts_with("/storage/emulated/") {
                libc::chown(c.as_ptr(), 1023, 1023);
                libc::chmod(c.as_ptr(), 0o2770);
            } else {
                libc::chmod(c.as_ptr(), 0o770);
            }
        }
        Ok(())
    }
    fn kill_bindfs(&self, r: &Row) -> Result<()> {
        let expected = fs::canonicalize(format!("{}/bin/bindfs", self.get("moddir")))?;
        for pid in runtime::pids() {
            if fs::read_link(format!("/proc/{pid}/exe")).ok().as_ref() != Some(&expected) {
                continue;
            }
            let args = runtime::cmd(pid);
            if args.last() != Some(&r.lower) {
                continue;
            }
            let Ok(fd) = os::fd(unsafe { libc::syscall(libc::SYS_pidfd_open, pid, 0) as i32 })
            else {
                continue;
            };
            use std::os::fd::AsRawFd;
            unsafe {
                libc::syscall(
                    libc::SYS_pidfd_send_signal,
                    fd.as_raw_fd(),
                    libc::SIGTERM,
                    0,
                    0,
                );
            }
            let mut p = [libc::pollfd {
                fd: fd.as_raw_fd(),
                events: libc::POLLIN,
                revents: 0,
            }];
            if os::poll(&mut p, 1000)? == 0 {
                unsafe {
                    libc::syscall(
                        libc::SYS_pidfd_send_signal,
                        fd.as_raw_fd(),
                        libc::SIGKILL,
                        0,
                        0,
                    );
                }
            }
        }
        Ok(())
    }
}
pub fn run(a: &[String]) -> Result<i32> {
    if a.len() % 2 != 1 {
        return Ok(2);
    }
    let opts: BTreeMap<_, _> = a[1..]
        .chunks_exact(2)
        .map(|p| (p[0].trim_start_matches("--").into(), p[1].clone()))
        .collect();
    let tx = Tx { opts };
    for k in ["runtime", "moddir", "log", "generation-file", "generation"] {
        if tx.get(k).is_empty() {
            return Ok(2);
        }
    }
    if !tx.current() {
        return Ok(75);
    }
    if a[0] == "profile-switch" {
        if tx.get("old").is_empty() || tx.get("new").is_empty() {
            return Ok(2);
        }
        let old = rows(tx.get("old"))?;
        let new = rows(tx.get("new"))?;
        for r in &old {
            tx.unmount(r)
        }
        for r in &new {
            if !tx.current() || tx.mount(r).is_err() || !tx.visible(r) {
                return Ok(tx.rollback(&new, &old));
            }
        }
        tx.log("profile switch verified");
        Ok(0)
    } else {
        if tx.get("rows").is_empty() {
            return Ok(2);
        }
        let mut failed = false;
        for r in rows(tx.get("rows"))? {
            if !tx.current() {
                return Ok(75);
            }
            if !Path::new(&r.src).is_dir() && r.create {
                fs::create_dir_all(&r.src)?
            }
            if !Path::new(&r.src).is_dir() {
                failed = true;
                continue;
            }
            tx.unmount(&r);
            if r.policy == "bindfs_shared" {
                tx.kill_bindfs(&r)?;
                tx.unmount(&r)
            }
            {
                let _n = os::Namespace::enter(1)?;
                if os::mount_entry(&r.lower).is_some() && !runtime::owned(&r, tx.get("runtime")) {
                    failed = true;
                    tx.log("refresh refused foreign mount before changing target permissions");
                    continue;
                }
            }
            tx.restore_dir(&r)?;
            if tx.mount(&r).is_err() || !tx.visible(&r) {
                failed = true;
                tx.log(&format!("refresh verification failed: {}", r.name));
            }
        }
        Ok(if failed { 1 } else { 0 })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn private_namespace_transactions() {
        unsafe {
            assert_eq!(libc::unshare(libc::CLONE_NEWNS | libc::CLONE_FS), 0);
        }
        os::mount("", "/", "", libc::MS_REC | libc::MS_PRIVATE, "").unwrap();
        let base = format!("/data/local/tmp/yaw1495-unit-{}", std::process::id());
        fs::create_dir(&base).unwrap();
        for d in ["a", "b", "dst", "foreign"] {
            fs::create_dir(format!("{base}/{d}")).unwrap();
        }
        fs::write(format!("{base}/a/value"), "a").unwrap();
        fs::write(format!("{base}/b/value"), "b").unwrap();
        fs::write(format!("{base}/generation"), "1").unwrap();
        let tx = Tx {
            opts: BTreeMap::from([
                ("runtime".into(), base.clone()),
                (
                    "moddir".into(),
                    "/data/local/tmp/yaw1495-test/module".into(),
                ),
                ("generation-file".into(), format!("{base}/generation")),
                ("generation".into(), "1".into()),
                ("log".into(), format!("{base}/tx.log")),
            ]),
        };
        let a = Row::parse(&format!(
            "a|0|{base}/a|{base}/dst|{base}/dst|{base}/dst|1|||preserve|0|none"
        ))
        .unwrap();
        let mut b = a.clone();
        b.src = format!("{base}/b");
        tx.mount(&a).unwrap();
        assert!(tx.visible(&a));
        assert_eq!(read(format!("{base}/dst/value")), "a");
        tx.unmount(&a);
        tx.mount(&b).unwrap();
        assert_eq!(read(format!("{base}/dst/value")), "b");
        let mut bad = a.clone();
        bad.src = format!("{base}/missing");
        tx.unmount(&b);
        assert!(tx.mount(&bad).is_err());
        assert_eq!(tx.rollback(&[bad], std::slice::from_ref(&b)), 10);
        let sig = os::identity(&b.src).unwrap();
        fs::write(
            format!("{base}/active_source_state.tsv"),
            format!("0|{}|{}|preserve|{sig}\n", b.lower, b.src),
        )
        .unwrap();
        fs::rename(&b.src, format!("{base}/b.old")).unwrap();
        fs::create_dir(&b.src).unwrap();
        fs::write(format!("{}/value", b.src), "recreated").unwrap();
        assert!(runtime::stale(&b, &base));
        assert!(runtime::owned(&b, &base));
        tx.unmount(&b);
        tx.mount(&b).unwrap();
        assert_eq!(read(format!("{base}/dst/value")), "recreated");
        os::unmount(&b.lower).unwrap();
        os::mount(&format!("{base}/foreign"), &b.lower, "", libc::MS_BIND, "").unwrap();
        assert!(!runtime::owned(&b, &base));
        tx.unmount(&b);
        assert!(os::mount_entry(&b.lower).is_some());
        assert!(tx.mount(&b).is_err());
        os::unmount(&b.lower).unwrap();
        let mut fuse = a.clone();
        fuse.policy = "bindfs_shared".into();
        tx.mount(&fuse).unwrap();
        assert!(os::fuse(&fuse.lower));
        assert!(tx.visible(&fuse));
        assert_eq!(read(format!("{base}/dst/value")), "a");
        os::unmount(&fuse.lower).unwrap();
        fs::write(format!("{base}/generation"), "2").unwrap();
        assert!(!tx.current());
        assert!(tx.mount(&a).is_err());
    }
}
