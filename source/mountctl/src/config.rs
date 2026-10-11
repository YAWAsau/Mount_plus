use crate::{bit, number, os, Result, Row};
use std::{
    collections::{BTreeMap, BTreeSet},
    fs,
    path::Path,
};
fn valid_path(s: &str, absolute: bool) -> bool {
    !s.is_empty()
        && s.starts_with('/') == absolute
        && !s.bytes().any(|c| c < 32 || c == 127 || c == b'|')
        && !s.split('/').any(|c| c == "..")
        && (absolute || !(s == "." || s.starts_with("./") || s.ends_with("/.")))
        && s.len() < 4096
}
fn id(s: &str) -> bool {
    !s.is_empty()
        && s.len() < 128
        && s.bytes()
            .all(|c| c.is_ascii_alphanumeric() || b"._-".contains(&c))
}
fn source(mp: &str, s: &str) -> Result<String> {
    if !valid_path(s, s.starts_with('/')) {
        return Err("invalid source path".into());
    }
    let s = if s.starts_with('/') {
        s.into()
    } else {
        format!("{}/{s}", mp.trim_end_matches('/'))
    };
    if s.len() >= 4096 {
        return Err("path too long".into());
    }
    Ok(s)
}
fn target(u: u32, s: &str) -> Result<(String, String)> {
    if !valid_path(s, s.starts_with('/')) {
        return Err("invalid target path".into());
    }
    let sub = if s.starts_with('/') {
        let tail = s
            .strip_prefix("/data/media/")
            .or_else(|| s.strip_prefix("/storage/emulated/"))
            .ok_or("unsupported absolute target")?;
        let (user, rest) = tail.split_once('/').unwrap_or((tail, ""));
        if user != u.to_string() {
            return Err("target user mismatch".into());
        }
        rest
    } else {
        s
    };
    let suffix = if sub.is_empty() {
        String::new()
    } else {
        format!("/{sub}")
    };
    let l = format!("/data/media/{u}{suffix}");
    let v = format!("/storage/emulated/{u}{suffix}");
    if v.len() >= 4096 {
        return Err("target too long".into());
    }
    Ok((l, v))
}
struct Config {
    global: BTreeMap<String, String>,
    profiles: Vec<(String, String)>,
    dirs: Vec<(String, String)>,
    rows: Vec<Row>,
}
impl Config {
    fn parse(text: &str, users: &str, global: bool) -> Result<Self> {
        if text.contains('\0') || text.split_inclusive('\n').any(|l| l.len() >= 4096) {
            return Err("configuration contains NUL or long line".into());
        }
        let mut c = Self {
            global: BTreeMap::from([
                ("fs".into(), "auto".into()),
                ("vendor_gallery_quiesce".into(), "auto".into()),
            ]),
            profiles: vec![],
            dirs: vec![],
            rows: vec![],
        };
        let fields: Vec<_> = text
            .lines()
            .map(str::trim)
            .filter(|s| !s.is_empty() && !s.starts_with('#'))
            .collect();
        for line in &fields {
            if let Some((k, v)) = line.split_once('=') {
                if matches!(
                    k,
                    "partition" | "mount_point" | "fs" | "vendor_gallery_quiesce"
                ) {
                    c.global.insert(k.into(), v.into());
                }
            }
        }
        let mp = c
            .global
            .get("mount_point")
            .ok_or("missing mount_point")?
            .clone();
        if !valid_path(&mp, true) || !c.global.get("partition").is_some_and(|s| id(s)) {
            return Err("invalid partition/mount_point".into());
        }
        if !matches!(c.global["fs"].as_str(), "auto" | "ext4" | "f2fs")
            || !matches!(
                c.global["vendor_gallery_quiesce"].as_str(),
                "auto" | "off" | "force"
            )
        {
            return Err("invalid global option".into());
        }
        if global {
            return Ok(c);
        }
        for line in fields {
            let (k, val) = line.split_once('=').ok_or("unknown configuration line")?;
            let v: Vec<_> = val.split('|').collect();
            match k {
                "version" | "partition" | "mount_point" | "fs" | "vendor_gallery_quiesce" => {}
                "profile" => {
                    if v.len() != 2
                        || !id(v[0])
                        || !id(v[1])
                        || c.profiles.len() >= 96
                        || c.profiles.iter().any(|(g, _)| g == v[0])
                    {
                        return Err("invalid or duplicate profile".into());
                    }
                    c.profiles.push((v[0].into(), v[1].into()));
                }
                "dir" => {
                    if v.len() != 2
                        || !matches!(v[1], "preserve" | "media_rw")
                        || c.dirs.len() >= 96
                    {
                        return Err("invalid dir".into());
                    }
                    c.dirs.push((source(&mp, v[0])?, v[1].into()));
                }
                "mount" => {
                    if !(8..=10).contains(&v.len()) || c.rows.len() >= 96 {
                        return Err("mount requires 8..10 fields, at most 96 rows".into());
                    }
                    let u = number(v[1])?;
                    if u != 0 && !users.is_empty() && !users.contains(&format!("UserInfo{{{u}:")) {
                        return Err("unknown user".into());
                    }
                    let src = source(&mp, v[2])?;
                    let (lower, visible) = target(u, v[3])?;
                    let policy = if v[7].is_empty() { "preserve" } else { v[7] };
                    let create = v.get(8).filter(|s| !s.is_empty()).copied().unwrap_or("0");
                    let migrate = v
                        .get(9)
                        .filter(|s| !s.is_empty())
                        .copied()
                        .unwrap_or("none");
                    if !matches!(policy, "preserve" | "media_rw" | "bindfs_shared")
                        || !matches!(migrate, "none" | "once")
                        || ((!v[5].is_empty() || !v[6].is_empty()) && (!id(v[5]) || !id(v[6])))
                    {
                        return Err("invalid mount policy/profile".into());
                    }
                    if fs::canonicalize(&src).unwrap_or(src.clone().into())
                        == fs::canonicalize(&lower).unwrap_or(lower.clone().into())
                    {
                        return Err("source equals target".into());
                    }
                    let target = if v[3].starts_with('/') {
                        v[3].into()
                    } else {
                        visible.clone()
                    };
                    let name = if v[0].is_empty() {
                        target
                            .trim_end_matches('/')
                            .rsplit('/')
                            .next()
                            .unwrap_or("")
                    } else {
                        v[0]
                    };
                    if name.len() >= 128 || name.bytes().any(|c| c < 32 || c == 127) {
                        return Err("invalid name".into());
                    }
                    c.rows.push(Row {
                        name: name.into(),
                        user: u,
                        src,
                        target,
                        lower,
                        visible,
                        enabled: bit(v[4])?,
                        group: v[5].into(),
                        profile: v[6].into(),
                        policy: policy.into(),
                        create: bit(create)?,
                        migrate: migrate.into(),
                    });
                }
                _ => return Err("unknown configuration key".into()),
            }
        }
        let mut targets = BTreeSet::new();
        for r in &c.rows {
            if r.enabled && !r.group.is_empty() && !c.profiles.iter().any(|(g, _)| g == &r.group) {
                return Err("missing profile selection".into());
            }
            if c.active(r) && !targets.insert((r.user, &r.lower)) {
                return Err("duplicate active target".into());
            }
        }
        Ok(c)
    }
    fn active(&self, r: &Row) -> bool {
        r.enabled
            && (r.group.is_empty()
                || self
                    .profiles
                    .iter()
                    .any(|(g, v)| g == &r.group && v == &r.profile))
    }
    fn publish(&self, out: &str) -> Result<()> {
        fs::create_dir_all(out)?;
        let globals = ["partition", "mount_point", "fs", "vendor_gallery_quiesce"]
            .map(|k| format!("{k}={}\n", self.global[k]))
            .concat();
        let profiles = self
            .profiles
            .iter()
            .map(|(g, v)| format!("{g}|{v}\n"))
            .collect::<String>();
        let dirs = self
            .dirs
            .iter()
            .map(|(p, v)| format!("{p}|{v}\n"))
            .collect::<String>();
        let all = self.rows.iter().map(Row::line).collect::<String>();
        let desired = self
            .rows
            .iter()
            .filter(|r| self.active(r))
            .map(Row::line)
            .collect::<String>();
        for (n, s) in [
            ("global", globals),
            ("profiles", profiles),
            ("dirs", dirs),
            ("mounts.all", all),
            ("mounts.desired", desired),
        ] {
            os::atomic(Path::new(out).join(n), s.as_bytes())?
        }
        Ok(())
    }
}
pub fn run(a: &[String]) -> Result<i32> {
    if a.len() != 5 || !matches!(a[4].as_str(), "all" | "global") {
        return Ok(2);
    }
    let text = fs::read_to_string(&a[0])?;
    match Config::parse(&text, &a[3], a[4] == "global") {
        Ok(c) => {
            c.publish(&a[1])?;
            Ok(0)
        }
        Err(e) => {
            eprintln!("mount.conf: {e}");
            Ok(if e.to_string().contains("duplicate active") {
                4
            } else {
                3
            })
        }
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn reject_traversal_and_cross_user() {
        assert!(target(0, "/storage/emulated/10/a").is_err());
        assert!(target(0, "a/../b").is_err());
        assert!(source("/data/p", "$(touch x)").is_ok());
    }
    #[test]
    fn profiles_and_collision() {
        let s="partition=data\nmount_point=/mnt/data\nprofile=p|a\nmount=a|0|/src/a|Music|1|p|a|preserve\nmount=b|0|/src/b|Music|1|p|b|preserve\n";
        let c = Config::parse(s, "", false).unwrap();
        assert!(c.active(&c.rows[0]));
        assert!(!c.active(&c.rows[1]));
        assert!(Config::parse(&s.replace("|p|b|", "|p|a|"), "", false).is_err());
    }
}
