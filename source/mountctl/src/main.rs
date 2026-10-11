mod config;
mod events;
mod fuse;
mod lifecycle;
mod os;
mod runtime;
mod transaction;
use std::{fs, path::Path};
type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Row {
    pub name: String,
    pub user: u32,
    pub src: String,
    pub target: String,
    pub lower: String,
    pub visible: String,
    pub enabled: bool,
    pub group: String,
    pub profile: String,
    pub policy: String,
    pub create: bool,
    pub migrate: String,
}
impl Row {
    fn parse(line: &str) -> Result<Self> {
        let v: Vec<_> = line.split('|').collect();
        if v.len() != 12
            || v.iter()
                .zip([128, 12, 4096, 4096, 4096, 4096, 2, 128, 128, 64, 2, 64])
                .any(|(s, n)| s.len() >= n || s.contains('\0'))
        {
            return Err("invalid row".into());
        }
        Ok(Self {
            name: v[0].into(),
            user: number(v[1])?,
            src: v[2].into(),
            target: v[3].into(),
            lower: v[4].into(),
            visible: v[5].into(),
            enabled: bit(v[6])?,
            group: v[7].into(),
            profile: v[8].into(),
            policy: if v[9].is_empty() { "preserve" } else { v[9] }.into(),
            create: bit(v[10])?,
            migrate: v[11].into(),
        })
    }
    fn line(&self) -> String {
        format!(
            "{}|{}|{}|{}|{}|{}|{}|{}|{}|{}|{}|{}\n",
            self.name,
            self.user,
            self.src,
            self.target,
            self.lower,
            self.visible,
            self.enabled as u8,
            self.group,
            self.profile,
            self.policy,
            self.create as u8,
            self.migrate
        )
    }
}
fn number(s: &str) -> Result<u32> {
    if s.is_empty() || !s.bytes().all(|c| c.is_ascii_digit()) {
        return Err("invalid unsigned integer".into());
    }
    let n: u32 = s.parse()?;
    if n > i32::MAX as u32 {
        return Err("integer overflow".into());
    }
    Ok(n)
}
fn bit(s: &str) -> Result<bool> {
    match s {
        "0" => Ok(false),
        "1" => Ok(true),
        _ => Err("expected 0 or 1".into()),
    }
}
fn read(path: impl AsRef<Path>) -> String {
    fs::read_to_string(path).unwrap_or_default()
}
fn key(path: impl AsRef<Path>, key: &str) -> String {
    let prefix = format!("{key}=");
    read(path)
        .lines()
        .find_map(|l| l.strip_prefix(&prefix).map(str::to_owned))
        .unwrap_or_default()
}
fn rows(path: impl AsRef<Path>) -> Result<Vec<Row>> {
    let s = match fs::read_to_string(path) {
        Ok(s) => s,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(vec![]),
        Err(e) => return Err(e.into()),
    };
    let r: Vec<_> = s
        .lines()
        .filter(|l| !l.is_empty())
        .map(Row::parse)
        .collect::<Result<_>>()?;
    if r.len() > 96 {
        return Err("too many rows".into());
    }
    Ok(r)
}
fn main() {
    let a: Vec<String> = std::env::args().collect();
    let result = dispatch(&a);
    let rc = match result {
        Ok(n) => n,
        Err(e) => {
            eprintln!("mountctl: {e}");
            1
        }
    };
    std::process::exit(rc)
}
fn dispatch(a: &[String]) -> Result<i32> {
    let name = Path::new(&a[0])
        .file_name()
        .unwrap_or_default()
        .to_string_lossy();
    match name.as_ref() {
        "mount.fuse3" | "mount_fusefs" => return fuse::run(&a[1..]),
        "confwatch" => return events::conf_cli(&a[1..]),
        "propwait" => return events::prop_cli(&a[1..]),
        _ => {}
    }
    if a.len() < 2 {
        return Ok(2);
    }
    match a[1].as_str() {
        "--version" => Ok({
            println!("mountctl 1.4.95 Rust NDK r30 API 28");
            0
        }),
        "parse-config" => config::run(&a[2..]),
        "profile-switch" | "source-refresh" => transaction::run(&a[1..]),
        "watch" => events::watch(&a[2..]),
        _ => runtime::run(&a[1..]),
    }
}
