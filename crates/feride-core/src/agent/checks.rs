//! Dosya yazıldıktan ya da düzenlendikten sonra hızlı hata denetimi. Sonuç aynı araç çıktısında modele verilir: yerel
//! model bozduğu bir dosyayı (kapanmamış parantez, yanlış girinti, tanımsız ad…) böylece hemen görür ve düzeltir.
//!
//! - Her izin modunda: dosyayı çalıştırmayan sözdizimi denetimleri (JSON, TOML, Python derlemesi, `node --check`,
//!   `bash -n`, `gofmt -e`, `rustfmt --check`).
//! - Yalnızca "Tam otonom" modunda: projenin kodunu çalıştırabilen tür denetimleri (`cargo check` derleme
//!   betiklerini ve makroları, `tsc` projedeki node_modules'u çalıştırır). Diğer modlarda komutlar onaya bağlı olduğu
//!   için bunlar kendiliğinden çalıştırılmaz.

use crate::paths::Paths;
use crate::util::truncate_end;
use regex::Regex;
use std::path::{Path, PathBuf};
use std::sync::LazyLock;
use std::time::Duration;

enum Res {
    Clean,
    /// Bu dosyadaki hatalar ve projenin başka dosyalarındaki hata sayısı.
    Errors(Vec<String>, usize),
    TimedOut(u64),
}

struct Outcome {
    tool: &'static str,
    res: Res,
}

/// Dosyayı dilinin denetleyicisiyle denetler ve modele eklenecek metni döndürür. Dil desteklenmiyorsa ya da araç bu
/// bilgisayarda yoksa `None`. `full`: kod çalıştırabilen proje denetimlerine izin var mı.
pub async fn after_write(paths: &Paths, file: &Path, full: bool) -> Option<String> {
    let content = std::fs::read_to_string(file).ok()?;
    let ext = file.extension()?.to_string_lossy().to_lowercase();
    let out = match ext.as_str() {
        "json" => json(file, &content),
        "toml" => Some(toml_check(&content)),
        "py" | "pyw" => python(paths, file).await,
        "js" | "mjs" | "cjs" => node(paths, file, &content).await,
        "ts" | "tsx" | "mts" | "cts" if full => tsc(paths, file).await,
        "rs" if full => match cargo(paths, file).await {
            Some(o) => Some(o),
            None => rustfmt(paths, file).await,
        },
        "rs" => rustfmt(paths, file).await,
        "go" => gofmt(paths, file).await,
        "sh" | "bash" => bash(paths, file).await,
        _ => None,
    }?;
    Some(render(out))
}

fn render(o: Outcome) -> String {
    match o.res {
        Res::Clean => format!("\n\nOtomatik denetim ({}): hata yok.", o.tool),
        Res::TimedOut(s) => format!("\n\nOtomatik denetim ({}) {s} sn içinde bitmedi; atlandı.", o.tool),
        Res::Errors(lines, elsewhere) if lines.is_empty() => {
            format!("\n\nOtomatik denetim ({}): bu dosyada hata yok; projenin başka dosyalarında {elsewhere} hata var.", o.tool)
        }
        Res::Errors(lines, elsewhere) => {
            let mut s = format!("\n\nOtomatik denetim ({}) bu dosyada hata buldu:\n", o.tool);
            for l in lines.iter().take(20) {
                s.push_str("  ");
                s.push_str(&truncate_end(l, 300));
                s.push('\n');
            }
            if lines.len() > 20 {
                s.push_str(&format!("  … {} satır daha\n", lines.len() - 20));
            }
            if elsewhere > 0 {
                s.push_str(&format!("(Projenin başka dosyalarında {elsewhere} hata daha var.)\n"));
            }
            s.push_str("Bu hataları düzelt.");
            s
        }
    }
}

// ------------------------------------------------------------------ süreç içi denetimler

fn json(file: &Path, content: &str) -> Option<Outcome> {
    let name = file.file_name()?.to_string_lossy().to_lowercase();
    // Yorum içerebilen JSON (tsconfig, VS Code ayarları…) katı JSON değildir: yanlış alarm vermesin.
    let jsonc = name.starts_with("tsconfig")
        || name.starts_with("jsconfig")
        || name.ends_with(".jsonc")
        || name == "devcontainer.json"
        || file.components().any(|c| c.as_os_str() == ".vscode");
    if jsonc {
        return None;
    }
    let res = match serde_json::from_str::<serde_json::Value>(content.trim_start_matches('\u{feff}')) {
        Ok(_) => Res::Clean,
        Err(e) => Res::Errors(vec![e.to_string()], 0),
    };
    Some(Outcome { tool: "JSON", res })
}

fn toml_check(content: &str) -> Outcome {
    let res = match toml::from_str::<toml::Table>(content) {
        Ok(_) => Res::Clean,
        Err(e) => Res::Errors(e.to_string().lines().filter(|l| !l.trim().is_empty()).take(8).map(String::from).collect(), 0),
    };
    Outcome { tool: "TOML", res }
}

// ------------------------------------------------------------------ dış araçlar

/// Programı FerIDE'nin araç klasörlerinde ve PATH'te arar. Windows Mağazası takma adları (çalıştırılınca Mağaza'yı
/// açar) ve WSL başlatıcısı (`System32\bash.exe`) kullanılmaz.
fn find(paths: &Paths, names: &[&str]) -> Option<PathBuf> {
    let path_var = crate::proc::child_path(paths, &[]);
    names.iter().filter_map(|n| crate::proc::which_in(n, &path_var)).find(|p| {
        let s = p.to_string_lossy().to_lowercase().replace('/', "\\");
        !(s.contains("\\windowsapps\\") || s.ends_with("\\system32\\bash.exe"))
    })
}

/// Çalıştırır; başlatılamazsa `None` (denetim atlanır), zaman aşımında `Err(saniye)`.
async fn run(paths: &Paths, exe: &Path, args: &[&str], cwd: &Path, secs: u64) -> Option<Result<(Option<i32>, String, String), u64>> {
    let args: Vec<String> = args.iter().map(|a| a.to_string()).collect();
    let mut cmd = crate::proc::command(paths, &exe.to_string_lossy(), &args);
    cmd.current_dir(cwd).env("CARGO_TERM_COLOR", "never").env("NO_COLOR", "1");
    match crate::proc::run_capture(&mut cmd, Duration::from_secs(secs)).await {
        Ok((_, _, _, true)) => Some(Err(secs)),
        Ok((code, out, err, false)) => Some(Ok((code, out, err))),
        Err(e) => {
            tracing::debug!("denetleyici başlatılamadı ({}): {e}", exe.display());
            None
        }
    }
}

fn dir_of(file: &Path) -> &Path {
    file.parent().unwrap_or(Path::new("."))
}

fn arg(file: &Path) -> String {
    file.to_string_lossy().to_string()
}

/// Sözdizimi denetleyicisinin çıktısını sonuca çevirir: çıkış kodu 0 → temiz.
fn simple(tool: &'static str, r: Result<(Option<i32>, String, String), u64>, pick: impl Fn(&str) -> Vec<String>) -> Outcome {
    let res = match r {
        Err(s) => Res::TimedOut(s),
        Ok((Some(0), _, _)) => Res::Clean,
        Ok((_, out, err)) => {
            let mut lines = pick(&format!("{err}\n{out}"));
            if lines.is_empty() {
                lines.push("denetleyici hata verdi ama ayrıntı yazmadı".into());
            }
            Res::Errors(lines, 0)
        }
    };
    Outcome { tool, res }
}

fn nonempty(s: &str) -> impl Iterator<Item = &str> {
    s.lines().map(str::trim_end).filter(|l| !l.trim().is_empty())
}

async fn python(paths: &Paths, file: &Path) -> Option<Outcome> {
    let venv = paths.pyenv_python();
    let exe = if venv.is_file() { venv } else { find(paths, &["python3", "python"])? };
    // Yalnızca derler, çalıştırmaz; __pycache__ da oluşturmaz.
    let code = "import sys;src=open(sys.argv[1],encoding='utf-8-sig').read();compile(src,sys.argv[1],'exec')";
    let r = run(paths, &exe, &["-X", "utf8", "-c", code, &arg(file)], dir_of(file), 20).await?;
    Some(simple("python", r, |t| {
        let lines: Vec<&str> = nonempty(t).collect();
        // Hatanın kendisi son "File ..." satırından sonrasıdır (öncesi -c sarmalayıcısının izi).
        let from = lines.iter().rposition(|l| l.trim_start().starts_with("File \"")).unwrap_or(0);
        lines[from..].iter().take(8).map(|l| l.to_string()).collect()
    }))
}

async fn node(paths: &Paths, file: &Path, content: &str) -> Option<Outcome> {
    // JSX içeren .js dosyalarını node ayrıştıramaz: yanlış alarm vermesin.
    if content.contains("</") || content.contains("/>") {
        return None;
    }
    let exe = find(paths, &["node"])?;
    let r = run(paths, &exe, &["--check", &arg(file)], dir_of(file), 20).await?;
    Some(simple("node --check", r, |t| {
        let mut v = vec![];
        for l in nonempty(t) {
            if l.trim_start().starts_with("at ") || l.starts_with("Node.js v") {
                continue;
            }
            v.push(l.to_string());
            if l.contains("Error:") {
                break;
            }
        }
        v.truncate(8);
        v
    }))
}

async fn bash(paths: &Paths, file: &Path) -> Option<Outcome> {
    let exe = find(paths, &["bash"])?;
    let f = arg(file).replace('\\', "/");
    let r = run(paths, &exe, &["-n", &f], dir_of(file), 15).await?;
    Some(simple("bash -n", r, |t| nonempty(t).take(8).map(String::from).collect()))
}

async fn gofmt(paths: &Paths, file: &Path) -> Option<Outcome> {
    let exe = find(paths, &["gofmt"])?;
    let r = run(paths, &exe, &["-e", "-l", &arg(file)], dir_of(file), 20).await?;
    // -l biçim farkı olan dosyanın adını stdout'a yazar; bu hata değildir. Sözdizimi hataları stderr'dedir.
    let r = r.map(|(code, _out, err)| (if err.trim().is_empty() { Some(0) } else { code.or(Some(2)) }, String::new(), err));
    Some(simple("gofmt", r, |t| nonempty(t).take(10).map(String::from).collect()))
}

/// Dosyanın üstündeki ilk `name` dosyasının klasörü.
fn nearest_with(file: &Path, name: &str) -> Option<PathBuf> {
    dir_of(file).ancestors().find(|d| d.join(name).is_file()).map(Path::to_path_buf)
}

fn rust_edition(file: &Path) -> String {
    static ED: LazyLock<Regex> = LazyLock::new(|| Regex::new(r#"(?m)^\s*edition\s*=\s*"(\d{4})""#).unwrap());
    for d in dir_of(file).ancestors() {
        if let Ok(t) = std::fs::read_to_string(d.join("Cargo.toml")) {
            if let Some(c) = ED.captures(&t) {
                return c[1].to_string();
            }
        }
    }
    "2021".into()
}

async fn rustfmt(paths: &Paths, file: &Path) -> Option<Outcome> {
    let exe = find(paths, &["rustfmt"])?;
    let edition = rust_edition(file);
    let r = run(paths, &exe, &["--check", "--edition", &edition, &arg(file)], dir_of(file), 20).await?;
    // --check biçim farkını stdout'a yazıp 1 ile çıkar (hata değil); ayrıştırma hataları stderr'de "error" ile gelir.
    let r = r.map(|(code, _out, err)| {
        let has_error = err.lines().any(|l| l.trim_start().starts_with("error"));
        (if has_error { code.or(Some(1)) } else { Some(0) }, String::new(), err)
    });
    Some(simple("rustfmt", r, |t| {
        nonempty(t).filter(|l| !l.trim_start().starts_with("Warning")).take(12).map(String::from).collect()
    }))
}

/// Tanılama satırının yolu düzenlenen dosyayı mı gösteriyor? (Göreli yollar çalışma alanının köküne göredir.)
fn same_file(diag: &str, file: &Path) -> bool {
    let norm = |s: &str| {
        let s = s.trim().replace('\\', "/");
        if cfg!(windows) {
            s.to_lowercase()
        } else {
            s
        }
    };
    let (d, f) = (norm(diag), norm(&file.to_string_lossy()));
    let d = d.trim_start_matches("./");
    f == d || f.ends_with(&format!("/{d}"))
}

/// `yol:satır:sütun: error...` ya da `yol(satır,sütun): error ...` biçimindeki tanılamaları bu dosya / diğerleri diye ayırır.
fn split_diags(text: &str, re: &Regex, file: &Path) -> (Vec<String>, usize) {
    let (mut mine, mut others) = (vec![], 0);
    for l in text.lines() {
        if let Some(c) = re.captures(l.trim_end()) {
            if same_file(&c["path"], file) {
                mine.push(format!("satır {}: {}", &c["line"], c["msg"].trim()));
            } else {
                others += 1;
            }
        }
    }
    (mine, others)
}

async fn cargo(paths: &Paths, file: &Path) -> Option<Outcome> {
    let dir = nearest_with(file, "Cargo.toml")?;
    let exe = find(paths, &["cargo"])?;
    let r = run(paths, &exe, &["check", "--message-format", "short", "--quiet"], &dir, 120).await?;
    static DIAG: LazyLock<Regex> =
        LazyLock::new(|| Regex::new(r"^(?P<path>.+?):(?P<line>\d+):(?P<col>\d+): (?P<msg>error(\[\w+\])?: .+)$").unwrap());
    let res = match r {
        Err(s) => Res::TimedOut(s),
        Ok((Some(0), _, _)) => Res::Clean,
        Ok((_, out, err)) => {
            let (mine, others) = split_diags(&err, &DIAG, file);
            if mine.is_empty() && others == 0 {
                // Tanılama yok ama başarısız (ör. Cargo.toml bozuk): ilk satırları göster.
                Res::Errors(nonempty(&format!("{err}\n{out}")).take(6).map(String::from).collect(), 0)
            } else {
                Res::Errors(mine, others)
            }
        }
    };
    Some(Outcome { tool: "cargo check", res })
}

async fn tsc(paths: &Paths, file: &Path) -> Option<Outcome> {
    let proj = nearest_with(file, "tsconfig.json")?;
    let bin_name = if cfg!(windows) { "tsc.cmd" } else { "tsc" };
    let tsc = proj.ancestors().map(|d| d.join("node_modules").join(".bin").join(bin_name)).find(|p| p.is_file())?;
    let r = run(paths, &tsc, &["--noEmit", "--pretty", "false", "-p", "."], &proj, 90).await?;
    static DIAG: LazyLock<Regex> =
        LazyLock::new(|| Regex::new(r"^(?P<path>.+?)\((?P<line>\d+),(?P<col>\d+)\): (?P<msg>error TS\d+: .+)$").unwrap());
    let res = match r {
        Err(s) => Res::TimedOut(s),
        Ok((Some(0), _, _)) => Res::Clean,
        Ok((_, out, err)) => {
            let (mine, others) = split_diags(&out, &DIAG, file);
            if mine.is_empty() && others == 0 {
                Res::Errors(nonempty(&format!("{out}\n{err}")).take(6).map(String::from).collect(), 0)
            } else {
                Res::Errors(mine, others)
            }
        }
    };
    Some(Outcome { tool: "tsc", res })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmp(name: &str, content: &str) -> (PathBuf, PathBuf) {
        let d = std::env::temp_dir().join(format!("feride-checks-{}-{}", std::process::id(), name.replace('.', "-")));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        let f = d.join(name);
        std::fs::write(&f, content).unwrap();
        (d, f)
    }

    fn paths() -> Paths {
        Paths::with_data_dir(std::env::temp_dir().join(format!("feride-checks-data-{}", std::process::id())))
    }

    fn rt() -> tokio::runtime::Runtime {
        tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap()
    }

    #[test]
    fn json_and_toml_in_process() {
        let (d, f) = tmp("a.json", "{\"a\": 1,}");
        let out = rt().block_on(after_write(&paths(), &f, false)).unwrap();
        assert!(out.contains("JSON") && out.contains("hata buldu") && out.contains("line 1"), "{out}");
        std::fs::write(&f, "{\"a\": [1, 2]}").unwrap();
        assert!(rt().block_on(after_write(&paths(), &f, false)).unwrap().contains("hata yok"));
        let _ = std::fs::remove_dir_all(d);
        // Yorumlu JSON denetlenmez.
        let (d, f) = tmp("tsconfig.json", "{ // yorum\n \"compilerOptions\": {} }");
        assert!(rt().block_on(after_write(&paths(), &f, false)).is_none());
        let _ = std::fs::remove_dir_all(d);
        let (d, f) = tmp("Cargo.toml", "[package]\nname = \"x\"\nversion = \n");
        let out = rt().block_on(after_write(&paths(), &f, false)).unwrap();
        assert!(out.contains("TOML") && out.contains("hata buldu"), "{out}");
        let _ = std::fs::remove_dir_all(d);
    }

    #[test]
    fn unsupported_files_are_skipped() {
        let (d, f) = tmp("notlar.md", "# başlık");
        assert!(rt().block_on(after_write(&paths(), &f, false)).is_none());
        let _ = std::fs::remove_dir_all(d);
    }

    #[test]
    fn python_syntax_error_is_reported_when_python_exists() {
        let p = paths();
        if find(&p, &["python3", "python"]).is_none() && !p.pyenv_python().is_file() {
            return; // bu makinede Python yok
        }
        let (d, f) = tmp("a.py", "def f(:\n    return 1\n");
        let out = rt().block_on(after_write(&p, &f, false)).unwrap();
        assert!(out.contains("python") && out.contains("SyntaxError"), "{out}");
        std::fs::write(&f, "def f():\n    return 1\n").unwrap();
        assert!(rt().block_on(after_write(&p, &f, false)).unwrap().contains("hata yok"));
        assert!(!d.join("__pycache__").exists(), "denetim __pycache__ oluşturmamalı");
        let _ = std::fs::remove_dir_all(d);
    }

    #[test]
    fn node_syntax_error_is_reported_when_node_exists() {
        let p = paths();
        if find(&p, &["node"]).is_none() {
            return;
        }
        let (d, f) = tmp("a.js", "function f( {\n  return 1;\n}\n");
        let out = rt().block_on(after_write(&p, &f, false)).unwrap();
        assert!(out.contains("node --check") && out.contains("SyntaxError"), "{out}");
        // JSX denetlenmez.
        std::fs::write(&f, "const A = () => <div>merhaba</div>;\n").unwrap();
        assert!(rt().block_on(after_write(&p, &f, false)).is_none());
        let _ = std::fs::remove_dir_all(d);
    }

    #[test]
    fn rust_checks_when_toolchain_exists() {
        let p = paths();
        let (d, f) = tmp("main.rs", "fn main() {\n    let x: i32 = \"metin\";\n}\n");
        std::fs::write(
            d.join("Cargo.toml"),
            "[package]\nname = \"denetim-deneme\"\nversion = \"0.1.0\"\nedition = \"2021\"\n\n[[bin]]\nname = \"d\"\npath = \"main.rs\"\n",
        )
        .unwrap();
        if find(&p, &["cargo"]).is_some() {
            let out = rt().block_on(after_write(&p, &f, true)).unwrap();
            assert!(out.contains("cargo check") && out.contains("satır 2") && out.contains("E0308"), "{out}");
        }
        if find(&p, &["rustfmt"]).is_some() {
            std::fs::write(&f, "fn main() {\n    let x = ;\n}\n").unwrap();
            let out = rt().block_on(after_write(&p, &f, false)).unwrap();
            assert!(out.contains("rustfmt") && out.contains("hata buldu"), "{out}");
            // Yalnızca biçim farkı hata sayılmaz.
            std::fs::write(&f, "fn main() {\n  let x  =  1;\n}\n").unwrap();
            assert!(rt().block_on(after_write(&p, &f, false)).unwrap().contains("hata yok"));
        }
        let _ = std::fs::remove_dir_all(d);
    }

    #[test]
    fn diagnostics_are_split_by_file() {
        static R: LazyLock<Regex> =
            LazyLock::new(|| Regex::new(r"^(?P<path>.+?):(?P<line>\d+):(?P<col>\d+): (?P<msg>error(\[\w+\])?: .+)$").unwrap());
        let file = Path::new("C:\\proje\\crates\\core\\src\\lib.rs");
        let text = "crates\\core\\src\\lib.rs:3:5: error[E0425]: cannot find value `x` in this scope\n\
                    crates/core/src/main.rs:9:1: error: expected item\n\
                    warning: unused import\n\
                    error: could not compile `core` (lib) due to 2 previous errors\n";
        let (mine, others) = split_diags(text, &R, file);
        assert_eq!(mine, vec!["satır 3: error[E0425]: cannot find value `x` in this scope"]);
        assert_eq!(others, 1);
        assert!(same_file("./src/a.ts", Path::new("/p/src/a.ts")));
        assert!(!same_file("b.ts", Path::new("/p/src/a.ts")));
    }

    #[test]
    fn render_messages() {
        let r = render(Outcome { tool: "tsc", res: Res::Errors(vec![], 3) });
        assert!(r.contains("bu dosyada hata yok") && r.contains("3 hata"), "{r}");
        let r = render(Outcome { tool: "cargo check", res: Res::TimedOut(120) });
        assert!(r.contains("120 sn"), "{r}");
    }
}
