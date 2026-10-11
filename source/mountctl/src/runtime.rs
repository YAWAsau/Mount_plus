use crate::{key, number, os, read, rows, Result, Row};
use serde_json::json;
use std::{collections::BTreeSet, fs, path::Path};
pub fn pids() -> Vec<u32> {
    fs::read_dir("/proc")
        .into_iter()
        .flatten()
        .filter_map(|e| e.ok()?.file_name().to_str()?.parse().ok())
        .collect()
}
pub fn cmd(pid: u32) -> Vec<String> {
    fs::read(format!("/proc/{pid}/cmdline"))
        .unwrap_or_default()
        .split(|b| *b == 0)
        .filter(|v| !v.is_empty())
        .map(|v| String::from_utf8_lossy(v).into_owned())
        .collect()
}
fn matches(pid: u32, names: &[&str]) -> bool {
    cmd(pid).first().is_some_and(|s| {
        names
            .iter()
            .any(|n| s == n || s.starts_with(&format!("{n}:")))
    })
}
pub fn ns(pid: u32) -> Option<std::path::PathBuf> {
    fs::read_link(format!("/proc/{pid}/ns/mnt")).ok()
}
const MEDIA: &[&str] = &[
    "com.android.providers.media.module",
    "com.google.android.providers.media.module",
    "com.android.providers.media",
];
pub fn core() -> Vec<u32> {
    if cfg!(test) {
        return vec![1];
    }
    let mut seen = BTreeSet::new();
    std::iter::once(1)
        .chain(pids().into_iter().filter(|p| {
            matches(
                *p,
                &[
                    "system_server",
                    "zygote64",
                    "zygote",
                    "android.process.media",
                    "com.android.externalstorage",
                    "sdcard",
                    "vold",
                ],
            ) || matches(*p, MEDIA)
        }))
        .filter(|p| ns(*p).is_some_and(|n| seen.insert(n)))
        .collect()
}
pub fn media(user: u32, runtime: &str) -> Option<u32> {
    if cfg!(test) {
        return Some(1);
    }
    let cache = format!("{runtime}/media_provider_ns.{user}.cache");
    if let Ok(pid) = key(&cache, "PID").parse() {
        let saved = key(&cache, "NS");
        if matches(pid, MEDIA)
            && ns(pid).is_some_and(|n| saved.is_empty() || n.to_string_lossy() == saved)
        {
            return Some(pid);
        }
    }
    let list: Vec<_> = pids().into_iter().filter(|p| matches(*p, MEDIA)).collect();
    list.iter()
        .copied()
        .find(|p| {
            os::Namespace::enter(*p)
                .is_ok_and(|_ns| Path::new(&format!("/storage/emulated/{user}")).exists())
        })
        .or_else(|| list.first().copied())
}
pub fn saved(r: &Row, runtime: &str) -> Option<String> {
    read(format!("{runtime}/active_source_state.tsv"))
        .lines()
        .find_map(|l| {
            let v: Vec<_> = l.split('|').collect();
            (v.len() == 5
                && v[0] == r.user.to_string()
                && v[1] == r.lower
                && v[2] == r.src
                && v[3] == r.policy)
                .then(|| v[4].into())
        })
}
pub fn stale(r: &Row, runtime: &str) -> bool {
    let Some(now) = os::identity(&r.src) else {
        return true;
    };
    match saved(r, runtime) {
        Some(s) => s != now,
        None => r.policy == "bindfs_shared",
    }
}
pub fn owned(r: &Row, runtime: &str) -> bool {
    if os::mount_entry(&r.lower).is_none() {
        return false;
    }
    if r.policy == "bindfs_shared" {
        os::fuse(&r.lower)
    } else {
        os::same(&r.src, &r.lower)
            || saved(r, runtime).is_some_and(|s| Some(s) == os::identity(&r.lower))
    }
}
pub fn mounted(r: &Row, runtime: &str) -> bool {
    let pid = if r.policy == "bindfs_shared" {
        media(r.user, runtime)
    } else {
        Some(1)
    };
    pid.and_then(|p| os::Namespace::enter(p).ok())
        .is_some_and(|_n| {
            if r.policy == "bindfs_shared" {
                os::fuse(&r.lower)
            } else {
                os::mount_entry(&r.lower).is_some() && os::same(&r.src, &r.lower)
            }
        })
}
pub fn probe(r: &Row, runtime: &str, strict: bool) -> bool {
    use std::os::fd::AsRawFd;
    let _ns = if strict {
        match media(r.user, runtime).and_then(|p| os::Namespace::enter(p).ok()) {
            Some(n) => Some(n),
            None => return false,
        }
    } else {
        None
    };
    if r.visible.is_empty() {
        return true;
    }
    let Ok(dir) = fs::File::open(&r.src) else {
        return false;
    };
    let before = os::identity(&format!("/proc/self/fd/{}", dir.as_raw_fd()));
    let name = format!(
        ".yawasau_mounttx_probe.{}.{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos()
    );
    let Ok(c) = os::c(&name) else { return false };
    let Ok(_fd) = os::fd(unsafe {
        libc::openat(
            dir.as_raw_fd(),
            c.as_ptr(),
            libc::O_CREAT | libc::O_EXCL | libc::O_WRONLY | libc::O_CLOEXEC | libc::O_NOFOLLOW,
            0o600,
        )
    }) else {
        return false;
    };
    let target = format!("{}/{name}", r.visible);
    let mut ok = Path::new(&target).exists();
    if !ok && !strict {
        if let Some(_n) = media(r.user, runtime).and_then(|p| os::Namespace::enter(p).ok()) {
            ok = Path::new(&target).exists()
        }
    }
    let clean = unsafe { libc::unlinkat(dir.as_raw_fd(), c.as_ptr(), 0) } == 0;
    ok && clean && before.is_some() && before == os::identity(&r.src)
}
pub fn identity(pid: u32) -> Option<String> {
    let s = read(format!("/proc/{pid}/stat"));
    let v: Vec<_> = s.rsplit_once(") ")?.1.split_whitespace().collect();
    if matches!(*v.first()?, "Z" | "X") {
        return None;
    }
    Some(v.get(19)?.to_string())
}
pub fn record(path: &str, pid: u32) -> Result<()> {
    let start = identity(pid).ok_or("process gone")?;
    os::atomic(
        path,
        format!(
            "{pid} {start} {}\n",
            read("/proc/sys/kernel/random/boot_id").trim()
        )
        .as_bytes(),
    )
}
pub fn live(path: &str) -> Option<u32> {
    let s = read(path);
    let v: Vec<_> = s.split_whitespace().collect();
    if v.len() != 3 {
        return None;
    }
    let pid = number(v[0]).ok()?;
    if pid <= 1
        || identity(pid).as_deref() != Some(v[1])
        || v[2] != read("/proc/sys/kernel/random/boot_id").trim()
    {
        return None;
    }
    Some(pid)
}
fn row_args(a: &[String]) -> Result<Row> {
    Ok(Row {
        name: String::new(),
        user: number(&a[0])?,
        src: a[1].clone(),
        target: a[2].clone(),
        lower: a[2].clone(),
        visible: a[4].clone(),
        policy: a[3].clone(),
        enabled: true,
        create: false,
        group: String::new(),
        profile: String::new(),
        migrate: "none".into(),
    })
}
pub fn run(a: &[String]) -> Result<i32> {
    let ok = match (a[0].as_str(), a.len()) {
        ("source-sig", 2) => {
            if let Some(s) = os::identity(&a[1]) {
                println!("{s}");
                true
            } else {
                false
            }
        }
        ("watch-identity", 2) => {
            if let Some(s) = identity(number(&a[1])?) {
                println!("{s}");
                true
            } else {
                false
            }
        }
        ("watch-write", 3) => {
            record(&a[1], number(&a[2])?)?;
            true
        }
        ("watch-live", 2) => live(&a[1]).is_some(),
        ("watch-signal", 3) => {
            if let Some(p) = live(&a[1]) {
                let group = a[2] == "group" && unsafe { libc::getpgid(p as i32) } == p as i32;
                os::check(unsafe {
                    libc::kill(if group { -(p as i32) } else { p as i32 }, libc::SIGTERM)
                })?
            }
            true
        }
        ("pids", 3) => {
            let user = number(&a[1])?;
            let mode = a[2].as_str();
            if !matches!(mode, "core" | "all" | "apps" | "user") {
                return Ok(2);
            }
            let base = core();
            let mut seen = BTreeSet::new();
            if mode != "user" {
                for p in base {
                    if let Some(n) = ns(p) {
                        seen.insert(n);
                        if mode != "apps" {
                            println!("{p}")
                        }
                    }
                }
            }
            if mode != "core" {
                for p in pids() {
                    let uid = read(format!("/proc/{p}/status")).lines().find_map(|l| {
                        l.strip_prefix("Uid:")?
                            .split_whitespace()
                            .next()?
                            .parse::<u64>()
                            .ok()
                    });
                    if uid.is_some_and(|u| {
                        u / 100000 == user as u64 && (mode != "apps" || u % 100000 >= 10000)
                    }) {
                        if let Some(n) = ns(p) {
                            if mode == "user" || seen.insert(n) {
                                println!("{p}")
                            }
                        }
                    }
                }
            }
            true
        }
        ("mount-query", 4 | 5) => {
            let _n = os::Namespace::enter(number(&a[2])?)?;
            match a[1].as_str() {
                "same" if a.len() == 5 => os::same(&a[3], &a[4]),
                "fuse" => os::fuse(&a[3]),
                mode => match os::mount_entry(&a[3]) {
                    Some((s, t)) => {
                        match mode {
                            "source" => println!("{s}"),
                            "type" => println!("{t}"),
                            "present" => {}
                            _ => return Ok(2),
                        }
                        true
                    }
                    None => false,
                },
            }
        }
        ("health", 8) => {
            let r = row_args(&a[2..7])?;
            match a[1].as_str() {
                "stale" => stale(&r, &a[7]),
                "mounted" => mounted(&r, &a[7]),
                "visible" => probe(&r, &a[7], false),
                "scan" => !stale(&r, &a[7]) && mounted(&r, &a[7]) && probe(&r, &a[7], true),
                _ => return Ok(2),
            }
        }
        ("occupied", 5) => {
            let _n = os::Namespace::enter(1)?;
            let user = a[2]
                .strip_prefix("/data/media/")
                .and_then(|s| s.split('/').next())
                .unwrap_or("0");
            let r = row_args(&[
                user.into(),
                a[1].clone(),
                a[2].clone(),
                a[3].clone(),
                String::new(),
            ])?;
            os::mount_entry(&r.lower).is_some() && !owned(&r, &a[4])
        }
        ("unmount-owned", 6) => {
            let user = a[3]
                .strip_prefix("/data/media/")
                .and_then(|s| s.split('/').next())
                .ok_or("invalid lower")?;
            let r = row_args(&[
                user.into(),
                a[2].clone(),
                a[3].clone(),
                a[4].clone(),
                String::new(),
            ])?;
            let _n = os::Namespace::enter(number(&a[1])?)?;
            if owned(&r, &a[5]) {
                os::unmount(&r.lower)?
            }
            true
        }
        ("status", 6) => {
            let rs = rows(format!("{}/mounts.all", a[3]))?;
            let global = format!("{}/global", a[3]);
            let mp = key(&global, "mount_point");
            let entry = os::Namespace::enter(1)
                .ok()
                .and_then(|_n| os::mount_entry(&mp));
            let profiles: Vec<_> = read(format!("{}/profiles", a[3]))
                .lines()
                .filter_map(|l| l.split_once('|').map(|(g, v)| (g.to_owned(), v.to_owned())))
                .collect();
            let ps:Vec<_>=profiles.iter().map(|(g,v)|{let mut seen=BTreeSet::new();let opts:Vec<_>=rs.iter().filter(|r|r.group==*g&&seen.insert(&r.profile)).map(|r|json!({"value":r.profile,"name":r.name,"source":r.src,"target":r.target})).collect();json!({"group":g,"selected":v,"options":opts})}).collect();
            let mounts:Vec<_>=rs.iter().map(|r|{let m=Path::new(&r.src).is_dir()&&!stale(r,&a[4])&&mounted(r,&a[4]);json!({"name":r.name,"user":r.user,"source":r.src,"target":r.target,"enabled":r.enabled,"active":r.enabled&&(r.group.is_empty()||profiles.contains(&(r.group.clone(),r.profile.clone()))),"mounted":m,"visible":m&&probe(r,&a[4],false),"group":r.group,"profile":r.profile,"policy":r.policy,"create":r.create,"migrate":r.migrate})}).collect();
            println!(
                "{}",
                json!({"version":a[1],"config":a[2],"configValid":key(format!("{}/config.state",a[4]),"STATE")=="valid","partition":key(&global,"partition"),"device":a[5],"mountPoint":mp,"fsType":entry.as_ref().map(|e|e.1.as_str()).unwrap_or("-"),"partitionMounted":entry.is_some(),"profiles":ps,"mounts":mounts})
            );
            true
        }
        _ => return Ok(2),
    };
    Ok(if ok { 0 } else { 1 })
}
