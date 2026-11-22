//! `edit_file` için metin değiştirme.
//!
//! Önce birebir eşleşme aranır. Yerel modeller `old_string`'i kopyalarken girintiyi, satır sonu boşluklarını ya da boş
//! satırları sık sık biraz farklı yazar; birebir eşleşme yoksa satır satır, giderek gevşeyen karşılaştırmalar denenir.
//! Gevşek eşleşme yalnızca dosyada tek bir yere uyuyorsa uygulanır, yeni metnin girintisi dosyanınkine uydurulur ve
//! modele bildirilir. Hiçbir yere uymazsa hata mesajında dosyadaki en benzer bölüm satır numaralarıyla gösterilir.

/// Uygulanan değişiklik.
#[derive(Debug)]
pub struct Applied {
    pub text: String,
    pub count: usize,
    /// Metin birebir uygulanmadıysa (gevşek eşleşme, girinti uydurma) açıklaması; modele bildirilir.
    pub note: Option<String>,
}

pub fn apply(text: &str, old: &str, new: &str, replace_all: bool) -> Result<Applied, String> {
    if old.is_empty() {
        return Err("old_string boş olamaz (yeni dosya için write_file kullan).".into());
    }
    if old == new {
        return Err("old_string ile new_string aynı.".into());
    }
    if let Some(r) = exact(text, old, new, replace_all) {
        return r;
    }
    // Model kaçış dizilerini harfiyen yazmış olabilir ("satır1\\nsatır2"): çözülmüş hâliyle de dene.
    let unescaped = (!old.contains('\n') && old.contains("\\n")).then(|| (unescape(old), unescape(new)));
    if let Some((o, n)) = &unescaped {
        if let Some(r) = exact(text, o, n, replace_all) {
            return r.map(|mut a| {
                a.note = Some("old_string'deki \\n, \\t gibi kaçış dizileri gerçek karakter sayılarak eşleşti.".into());
                a
            });
        }
    }
    let (o, n) = unescaped.as_ref().map(|(o, n)| (o.as_str(), n.as_str())).unwrap_or((old, new));
    if replace_all {
        return Err(not_found(text, o, true));
    }
    fuzzy(text, o, n).unwrap_or_else(|| Err(not_found(text, o, false)))
}

fn exact(text: &str, old: &str, new: &str, replace_all: bool) -> Option<Result<Applied, String>> {
    let crlf = text.contains("\r\n");
    // Dosya CRLF ise eklenen satırlar da CRLF olmalı.
    let new = if crlf { new.replace("\r\n", "\n").replace('\n', "\r\n") } else { new.to_string() };
    let try_one = |o: &str| -> Option<Result<Applied, String>> {
        let count = text.matches(o).count();
        if count == 0 {
            return None;
        }
        if count > 1 && !replace_all {
            return Some(Err(format!(
                "old_string dosyada {count} kez geçiyor. Benzersiz olması için çevresinden daha fazla satır ekle ya da replace_all=true kullan."
            )));
        }
        if replace_all {
            return Some(Ok(Applied { text: text.replace(o, &new), count, note: None }));
        }
        let pos = text.find(o)?;
        let (n, note) = fit_indent(text, pos, o, &new);
        let mut out = String::with_capacity(text.len() + n.len());
        out.push_str(&text[..pos]);
        out.push_str(&n);
        out.push_str(&text[pos + o.len()..]);
        Some(Ok(Applied { text: out, count: 1, note }))
    };
    if let Some(r) = try_one(old) {
        return Some(r);
    }
    // Dosya CRLF, model LF yazmış.
    if crlf && old.contains('\n') && !old.contains("\r\n") {
        return try_one(&old.replace('\n', "\r\n"));
    }
    None
}

/// Birebir eşleşme bir satırın girintisinin ortasından başlıyorsa model girintiyi eksik kopyalamıştır (ör. 8 boşluk
/// yerine 4); yeni metnin sonraki satırları da aynı kadar eksik olur, onları gerçek girintiye taşır.
fn fit_indent(text: &str, pos: usize, old: &str, new: &str) -> (String, Option<String>) {
    let line_start = text[..pos].rfind('\n').map(|i| i + 1).unwrap_or(0);
    let before = &text[line_start..pos];
    let old_ind = indent_of(old.split('\n').next().unwrap_or(""));
    if before.is_empty() || !before.chars().all(|c| c == ' ' || c == '\t') || old_ind.is_empty() || !new.contains('\n') {
        return (new.to_string(), None);
    }
    let to = format!("{before}{old_ind}");
    let (first, rest) = new.split_once('\n').unwrap_or((new, ""));
    let rest: Vec<&str> = rest.split('\n').collect();
    let moved = reindent(&rest, old_ind, &to);
    if moved.iter().zip(&rest).all(|(a, b)| a == b) {
        return (new.to_string(), None);
    }
    (
        format!("{first}\n{}", moved.join("\n")),
        Some("old_string girintisi dosyadakinden eksikti; yeni metnin sonraki satırları dosyadaki girintiye uyduruldu. Sonucu kontrol et.".into()),
    )
}

fn unescape(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut it = s.chars().peekable();
    while let Some(c) = it.next() {
        if c != '\\' {
            out.push(c);
            continue;
        }
        match it.peek().copied() {
            Some('n') => out.push('\n'),
            Some('t') => out.push('\t'),
            Some('r') => {} // satır sonu dosyaya göre ayarlanır
            Some(q @ ('"' | '\'' | '\\')) => out.push(q),
            _ => {
                out.push('\\');
                continue;
            }
        }
        it.next();
    }
    out
}

/// Dosyanın bir satırı: bayt aralıkları (`end` satır sonu karakterleri hariç, `next` sonraki satırın başı).
struct Line<'a> {
    start: usize,
    end: usize,
    next: usize,
    text: &'a str,
}

fn lines_of(text: &str) -> Vec<Line<'_>> {
    let mut v = Vec::new();
    let mut start = 0;
    for seg in text.split_inclusive('\n') {
        let next = start + seg.len();
        let content = seg.strip_suffix('\n').map(|s| s.strip_suffix('\r').unwrap_or(s)).unwrap_or(seg);
        v.push(Line { start, end: start + content.len(), next, text: content });
        start = next;
    }
    v
}

fn split_block(s: &str) -> Vec<&str> {
    s.split('\n').map(|l| l.strip_suffix('\r').unwrap_or(l)).collect()
}

fn blank(l: &str) -> bool {
    l.trim().is_empty()
}

fn indent_of(l: &str) -> &str {
    &l[..l.len() - l.trim_start().len()]
}

/// Ortak en küçük girinti çıkarılınca (satır sonu boşlukları hariç) aynı mı? Göreli girinti korunmalı.
fn same_dedented(w: &[&str], o: &[&str]) -> bool {
    let min = |ls: &[&str]| ls.iter().filter(|l| !blank(l)).map(|l| indent_of(l).len()).min().unwrap_or(0);
    let (mw, mo) = (min(w), min(o));
    w.iter().zip(o).all(|(a, b)| {
        let (a, b) = (a.trim_end(), b.trim_end());
        if a.is_empty() || b.is_empty() {
            return a.is_empty() && b.is_empty();
        }
        matches!((a.get(mw..), b.get(mo..)), (Some(x), Some(y)) if x == y)
    })
}

/// Satır başı ve sonundaki boşluklar yok sayılınca aynı mı?
fn same_trimmed(w: &[&str], o: &[&str]) -> bool {
    w.iter().zip(o).all(|(a, b)| a.trim() == b.trim())
}

/// Satır içindeki boşluk dizileri de tek boşluk sayılınca aynı mı?
fn same_collapsed(w: &[&str], o: &[&str]) -> bool {
    w.iter().zip(o).all(|(a, b)| a.split_whitespace().eq(b.split_whitespace()))
}

/// Satır satır gevşek eşleşme. Eşleşme yoksa `None`, birden çok yere uyuyorsa hata.
fn fuzzy(text: &str, old: &str, new: &str) -> Option<Result<Applied, String>> {
    // Baştaki/sondaki boş satırlar çerçevedir (model çoğu zaman son satır sonunu da ekler); yeni metinden de aynı kadarı
    // atılır ki dosyaya fazladan boş satır girmesin.
    let old_all = split_block(old);
    let lead = old_all.iter().take_while(|l| blank(l)).count();
    if lead == old_all.len() {
        return None;
    }
    let trail = old_all.iter().rev().take_while(|l| blank(l)).count();
    let old_lines = &old_all[lead..old_all.len() - trail];
    let new_lines: Vec<&str> = if new.trim().is_empty() {
        vec![] // satırları sil
    } else {
        let all = split_block(new);
        let nl = all.iter().take_while(|l| blank(l)).count().min(lead);
        let nt = all.iter().rev().take_while(|l| blank(l)).count().min(trail);
        all[nl..all.len() - nt].to_vec()
    };

    let flines = lines_of(text);
    let ftext: Vec<&str> = flines.iter().map(|l| l.text).collect();
    let k = old_lines.len();
    type Cmp = fn(&[&str], &[&str]) -> bool;
    let steps: [(Cmp, &str); 3] =
        [(same_dedented, "girinti"), (same_trimmed, "satır başı/sonu boşluğu"), (same_collapsed, "boşluk")];
    if k <= ftext.len() {
        for (cmp, what) in steps {
            let hits: Vec<usize> = (0..=ftext.len() - k).filter(|&i| cmp(&ftext[i..i + k], old_lines)).collect();
            match hits.len() {
                0 => continue,
                1 => return Some(Ok(splice(text, &flines, hits[0], hits[0] + k - 1, old_lines, &new_lines, what))),
                n => return Some(Err(ambiguous(what, n))),
            }
        }
    }

    // Son çare: boş satırlar da yok sayılır (model blok içindeki bir boş satırı atlamış ya da eklemiş olabilir).
    let old_nb: Vec<&str> = old_lines.iter().filter(|l| !blank(l)).map(|l| l.trim()).collect();
    let nb: Vec<usize> = (0..ftext.len()).filter(|&i| !blank(ftext[i])).collect();
    let m = old_nb.len();
    if m == 0 || m > nb.len() {
        return None;
    }
    let hits: Vec<usize> = (0..=nb.len() - m).filter(|&p| (0..m).all(|j| ftext[nb[p + j]].trim() == old_nb[j])).collect();
    match hits.len() {
        0 => None,
        1 => {
            let (first, last) = (nb[hits[0]], nb[hits[0] + m - 1]);
            Some(Ok(splice(text, &flines, first, last, old_lines, &new_lines, "boş satır ve boşluk")))
        }
        n => Some(Err(ambiguous("boş satır ve boşluk", n))),
    }
}

fn ambiguous(what: &str, n: usize) -> String {
    format!(
        "old_string birebir bulunamadı; {what} farkı yok sayılınca {n} yerde eşleşiyor. Benzersiz olması için çevresinden daha fazla satır ekle."
    )
}

/// Dosyanın `first..=last` satırlarını yeni satırlarla değiştirir; yeni metnin girintisi dosyanınkine uydurulur.
fn splice(text: &str, flines: &[Line], first: usize, last: usize, old_lines: &[&str], new_lines: &[&str], what: &str) -> Applied {
    let eol = if text.contains("\r\n") { "\r\n" } else { "\n" };
    let from = old_lines.iter().find(|l| !blank(l)).map(|l| indent_of(l)).unwrap_or("");
    let to = flines[first..=last].iter().find(|l| !blank(l.text)).map(|l| indent_of(l.text)).unwrap_or("");
    let body = reindent(new_lines, from, to);
    let (start, end) = if body.is_empty() {
        (flines[first].start, flines[last].next) // satırlar satır sonlarıyla birlikte silinir
    } else {
        (flines[first].start, flines[last].end) // son satırın kendi satır sonu korunur
    };
    let mut out = String::with_capacity(text.len() + new_lines.len() * 8);
    out.push_str(&text[..start]);
    out.push_str(&body.join(eol));
    out.push_str(&text[end..]);
    let lines = if first == last { format!("{}. satır", first + 1) } else { format!("{}–{}. satırlar", first + 1, last + 1) };
    Applied {
        text: out,
        count: 1,
        note: Some(format!(
            "old_string birebir bulunamadı; {what} farkı yok sayılarak {lines} değiştirildi ve yeni metnin girintisi dosyaya \
             uyduruldu. Sonucu kontrol et."
        )),
    }
}

/// Satırların baştaki girintisini `from` tabanından `to` tabanına taşır.
/// - Aynı tür girinti (yalnız boşluk ya da yalnız sekme) ya da bir taraf girintisiz: fark kadar ekler/çıkarır.
/// - Farklı tür ve bir taraf tek karakter (ör. 4 boşluk ↔ 1 sekme): girintiyi seviye seviye çevirir.
/// - Diğer durumlar: yalnızca `from` ile başlayan satırların ön ekini `to` yapar.
fn reindent(lines: &[&str], from: &str, to: &str) -> Vec<String> {
    if from == to {
        return lines.iter().map(|l| l.to_string()).collect();
    }
    let uniform = |s: &str| -> Option<char> {
        let mut c = s.chars();
        let x = c.next()?;
        c.all(|y| y == x).then_some(x)
    };
    let (uf, ut) = (uniform(from), uniform(to));
    let (fw, tw) = (from.chars().count(), to.chars().count());
    let shift = |l: &str, c: char, delta: isize| -> String {
        let lead = l.chars().take_while(|&x| x == c).count();
        let keep = (lead as isize + delta).max(0) as usize;
        format!("{}{}", c.to_string().repeat(keep), &l[lead * c.len_utf8()..])
    };
    let prefix = |l: &str| -> String {
        match l.strip_prefix(from) {
            Some(rest) => format!("{to}{rest}"),
            None => l.to_string(),
        }
    };
    lines
        .iter()
        .map(|l| {
            if blank(l) {
                return l.to_string();
            }
            match (uf, ut) {
                (Some(a), Some(b)) if a == b => shift(l, a, tw as isize - fw as isize),
                (None, Some(b)) if from.is_empty() => shift(l, b, tw as isize),
                (Some(a), None) if to.is_empty() => shift(l, a, -(fw as isize)),
                (Some(a), Some(b)) if fw == 1 || tw == 1 => {
                    let lead = l.chars().take_while(|&x| x == a).count();
                    let rest = &l[lead * a.len_utf8()..];
                    if rest.starts_with([' ', '\t']) {
                        return prefix(l); // karışık girinti: dokunmadan ön eki taşı
                    }
                    let ind = if tw == 1 {
                        // ör. her 4 boşluk = 1 sekme, artan boşluklar korunur
                        format!("{}{}", b.to_string().repeat(lead / fw), a.to_string().repeat(lead % fw))
                    } else {
                        // ör. her sekme = 4 boşluk
                        b.to_string().repeat(lead * tw)
                    };
                    format!("{ind}{rest}")
                }
                _ => prefix(l),
            }
        })
        .collect()
}

/// Bulunamadı mesajı: dosyada `old_string`'in ilk satırına en çok benzeyen yer, satır numaralarıyla.
fn not_found(text: &str, old: &str, replace_all: bool) -> String {
    let mut msg = if replace_all {
        "old_string dosyada birebir bulunamadı (replace_all yalnızca birebir eşleşmeyle çalışır).".to_string()
    } else {
        "old_string dosyada bulunamadı (girinti ve boşluk farkları yok sayılınca da).".to_string()
    };
    match closest(text, old) {
        Some(snippet) => {
            msg.push_str(" Dosyadaki en benzer bölüm aşağıda; old_string'i buradan aynen kopyala:\n");
            msg.push_str(&snippet);
        }
        None => msg.push_str(" Dosyayı read_file ile yeniden oku ve metni aynen kopyala."),
    }
    msg
}

fn closest(text: &str, old: &str) -> Option<String> {
    let old_lines: Vec<&str> = old.lines().filter(|l| !blank(l)).collect();
    let first = old_lines.first()?.trim();
    let flines: Vec<&str> = text.lines().collect();
    if flines.len() > 20_000 || first.chars().count() > 400 {
        return None;
    }
    let mut best: Option<(f32, usize)> = None;
    for (i, l) in flines.iter().enumerate() {
        let t = l.trim();
        if t.is_empty() || t.chars().count() > 400 {
            continue;
        }
        let r = similar::TextDiff::from_chars(first, t).ratio();
        if best.is_none_or(|(b, _)| r > b) {
            best = Some((r, i));
        }
    }
    let (ratio, at) = best?;
    if ratio < 0.6 {
        return None;
    }
    let from = at.saturating_sub(1);
    let to = (at + old_lines.len() + 2).min(flines.len()).min(from + 40);
    Some(flines[from..to].iter().enumerate().map(|(j, l)| format!("{:>6}\t{}\n", from + j + 1, l)).collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ok(text: &str, old: &str, new: &str) -> Applied {
        apply(text, old, new, false).unwrap_or_else(|e| panic!("uygulanmalıydı: {e}"))
    }

    #[test]
    fn exact_and_crlf_still_work() {
        let a = ok("fn a() {}\nfn b() {}\n", "fn b() {}", "fn c() {}");
        assert_eq!(a.text, "fn a() {}\nfn c() {}\n");
        assert!(a.note.is_none());
        let a = ok("x\r\ny\r\nz\r\n", "x\ny", "A\nB");
        assert_eq!(a.text, "A\r\nB\r\nz\r\n");
        assert!(apply("fn x() {}\nfn x() {}\n", "fn x() {}", "y", false).unwrap_err().contains("2 kez"));
        let a = apply("fn x() {}\nfn x() {}\n", "fn x() {}", "y", true).unwrap();
        assert_eq!((a.text.as_str(), a.count), ("y\ny\n", 2));
        // Satırın ortasındaki parça birebir değişir; girintiye dokunulmaz.
        let a = ok("    let a = f(1);\n", "f(1)", "f(2)");
        assert_eq!(a.text, "    let a = f(2);\n");
    }

    #[test]
    fn wrong_indentation_is_tolerated_and_new_text_reindented() {
        let file = "impl A {\n    fn run(&self) {\n        let x = 1;\n        println!(\"{x}\");\n    }\n}\n";
        // Model girintiyi 4 boşluk eksik yazmış; yeni metin de aynı kaymayla.
        let a = ok(file, "fn run(&self) {\n    let x = 1;\n", "fn run(&self) {\n    let x = 2;\n");
        assert_eq!(a.text, file.replace("let x = 1;", "let x = 2;"));
        assert!(a.note.as_deref().unwrap().contains("girinti"));
        // Yeni satır eklendiğinde de doğru girintiyle girer.
        let a = ok(file, "let x = 1;\nprintln!(\"{x}\");", "let x = 1;\nlet y = x + 1;\nprintln!(\"{y}\");");
        assert!(a.text.contains("        let x = 1;\n        let y = x + 1;\n        println!(\"{y}\");\n"), "{}", a.text);
    }

    #[test]
    fn under_indented_single_line_keeps_indent_and_crlf() {
        // "    go();" birebir olarak 8 boşluklu satırın içinde bulunur; eklenen satır da 8 boşlukla ve CRLF ile girmeli.
        let a = ok("if x {\r\n        go();\r\n}\r\n", "    go();", "    stop();\n    go();");
        assert_eq!(a.text, "if x {\r\n        stop();\r\n        go();\r\n}\r\n");
        assert!(a.note.is_some());
        // Model girintisiz başladıysa sonraki satırlara dokunulmaz (çoğu zaman tam girintiyle yazar).
        let a = ok("fn f() {\n    go();\n}\n", "go();", "go();\n    stop();");
        assert_eq!(a.text, "fn f() {\n    go();\n    stop();\n}\n");
        assert!(a.note.is_none());
    }

    #[test]
    fn trailing_spaces_tabs_and_inner_spaces() {
        // Dosyada satır sonu boşluğu var, modelde yok.
        let a = ok("a = 1   \nb = 2\n", "a = 1\nb = 2", "a = 10\nb = 20");
        assert_eq!(a.text, "a = 10\nb = 20\n");
        // Dosya sekme, model boşluk kullanmış: yeni metin sekmeye çevrilir.
        let a = ok("def f():\n\tif x:\n\t\treturn 1\n", "    if x:\n        return 1", "    if x:\n        return 2");
        assert_eq!(a.text, "def f():\n\tif x:\n\t\treturn 2\n");
        // Satır içinde fazladan boşluklar.
        let a = ok("let  total =  a + b;\n", "let total = a + b;\n", "let total = a - b;\n");
        assert_eq!(a.text, "let total = a - b;\n");
    }

    #[test]
    fn skipped_blank_line_framing_and_deletion() {
        let file = "fn main() {\n    let a = 1;\n\n    let b = 2;\n}\n";
        let a = ok(file, "\n    let a = 1;\n    let b = 2;\n", "\n    let a = 3;\n    let b = 4;\n");
        assert_eq!(a.text, "fn main() {\n    let a = 3;\n    let b = 4;\n}\n");
        // Silme: yeni metin boş; girintisi yanlış satır da satır sonuyla birlikte silinir.
        let a = ok("a\n  b\nc\n", "    b\n", "");
        assert_eq!(a.text, "a\nc\n");
        let a = ok("a\n  b  \nc\n", "  b  \n", "");
        assert_eq!(a.text, "a\nc\n");
    }

    #[test]
    fn escaped_newlines_and_ambiguity() {
        let a = ok("a\nb\nc\n", "a\\nb", "x\\ny");
        assert_eq!(a.text, "x\ny\nc\n");
        assert!(a.note.unwrap().contains("kaçış"));
        let e = apply("  x = 1\nfoo\n    x = 1\n", "x = 1 ", "x = 2", false).unwrap_err();
        assert!(e.contains("2 yerde"), "{e}");
    }

    #[test]
    fn not_found_shows_closest_lines() {
        let file = "fn main() {\n    let total = compute(a, b);\n    println!(\"{total}\");\n}\n";
        let e = apply(file, "let totl = compute(a, b);", "x", false).unwrap_err();
        assert!(e.contains("en benzer bölüm") && e.contains("     2\t    let total = compute(a, b);"), "{e}");
        let e = apply(file, "tamamen alakasız bir satır", "x", false).unwrap_err();
        assert!(e.contains("read_file ile yeniden oku"), "{e}");
    }

    #[test]
    fn reindent_rules() {
        assert_eq!(reindent(&["  a", "    b", "", "c"], "  ", "    "), vec!["    a", "      b", "", "  c"]);
        assert_eq!(reindent(&["\ta", "\t\tb"], "\t", "\t\t"), vec!["\t\ta", "\t\t\tb"]);
        assert_eq!(reindent(&["    a"], "    ", ""), vec!["a"]);
        assert_eq!(reindent(&["  a", "b"], "  ", "\t"), vec!["\ta", "b"]);
        assert_eq!(reindent(&["\ta", "\t\tb"], "\t", "    "), vec!["    a", "        b"]);
    }
}
