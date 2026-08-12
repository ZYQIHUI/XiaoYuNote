//! 知识库工具 — 日期提取、时间词解析、凭据脱敏。

use std::path::Path;
use chrono::Datelike;

/// 从路径提取日期（YYYYMMDD 整数），优先级：祖先目录名 > 文件名 > mtime。
pub fn extract_date_from_path(path: &Path) -> (Option<i64>, &'static str) {
    for parent in path.ancestors().skip(1) {
        if let Some(name) = parent.file_name().and_then(|n| n.to_str()) {
            if let Some(d) = extract_date_from_text(name) {
                return (Some(d), "dirname");
            }
        }
    }
    if let Some(name) = path.file_name().and_then(|n| n.to_str()) {
        if let Some(d) = extract_date_from_text(name) {
            return (Some(d), "filename");
        }
    }
    if let Ok(meta) = std::fs::metadata(path) {
        if let Ok(mtime) = meta.modified() {
            if let Ok(dur) = mtime.duration_since(std::time::UNIX_EPOCH) {
                let days = (dur.as_secs() / 86400) as i64;
                let (y, m, d) = civil_from_days(days + 719468);
                return (Some(y * 10000 + m * 100 + d), "mtime");
            }
        }
    }
    (None, "none")
}

/// 从文本首行提取日期（优先级：内容头部）。
pub fn extract_date_from_content(first_lines: &[String]) -> (Option<i64>, &'static str) {
    for line in first_lines.iter().take(3) {
        if let Some(d) = extract_date_from_text(line) {
            return (Some(d), "content");
        }
    }
    (None, "none")
}

/// 从任意文本提取第一个日期（YYYYMMDD）。
pub fn extract_date_from_text(text: &str) -> Option<i64> {
    let _bytes = text.as_bytes();
    let chars: Vec<char> = text.chars().collect();
    // 匹配 YYYY[-/.年]MM[-/.月]DD
    for i in 0..chars.len().saturating_sub(9) {
        if chars[i].is_ascii_digit() && chars[i + 1].is_ascii_digit()
            && chars[i + 2].is_ascii_digit() && chars[i + 3].is_ascii_digit()
        {
            let y: i64 = chars[i..i + 4].iter().collect::<String>().parse().ok()?;
            // 分隔符：- / . 年 或直接数字
            let mut j = i + 4;
            let sep1 = if j < chars.len() {
                let c = chars[j];
                if c == '-' || c == '/' || c == '.' || c == '年' { Some(c) } else { None }
            } else { None };
            if let Some(sep) = sep1 {
                j += 1;
                // 月份 1-2 位
                let m_start = j;
                let mut m_end = j;
                while m_end < chars.len() && chars[m_end].is_ascii_digit() && m_end - m_start < 2 {
                    m_end += 1;
                }
                if m_end == m_start { return None; }
                let mo: i64 = chars[m_start..m_end].iter().collect::<String>().parse().ok()?;
                j = m_end;
                let sep2 = if j < chars.len() {
                    let c = chars[j];
                    if c == '-' || c == '/' || c == '.' || c == '月' { Some(c) } else { None }
                } else { None };
                if let Some(_sep2) = sep2 {
                    j += 1;
                    let d_start = j;
                    let mut d_end = j;
                    while d_end < chars.len() && chars[d_end].is_ascii_digit() && d_end - d_start < 2 {
                        d_end += 1;
                    }
                    if d_end == d_start { return None; }
                    let d: i64 = chars[d_start..d_end].iter().collect::<String>().parse().ok()?;
                    if (2000..=2099).contains(&y) && (1..=12).contains(&mo) && (1..=31).contains(&d) {
                        return Some(y * 10000 + mo * 100 + d);
                    }
                }
                let _ = sep;
            }
            // 8 位纯数字 YYYYMMDD
            if j + 4 <= chars.len() && chars[j..j + 4].iter().all(|c| c.is_ascii_digit()) {
                let rest: String = chars[j..j + 4].iter().collect();
                let d = rest.parse::<i64>().ok()?;
                let mo = y % 100;
                let y4 = y / 100;
                if (2000..=2099).contains(&y4) && (1..=12).contains(&mo) {
                    return Some(y4 * 10000 + mo * 100 + d);
                }
            }
        }
    }
    // 简化：直接找 8 位数字
    let digits: String = text.chars().filter(|c| c.is_ascii_digit()).collect();
    if digits.len() >= 8 {
        if let Ok(v) = digits[0..8].parse::<i64>() {
            let y = v / 10000;
            let mo = (v / 100) % 100;
            let d = v % 100;
            if (2000..=2099).contains(&y) && (1..=12).contains(&mo) && (1..=31).contains(&d) {
                return Some(v);
            }
        }
    }
    None
}

/// 计算文件 SHA256 十六进制（增量判重用）。
pub fn file_sha256(path: &Path) -> std::io::Result<String> {
    use sha2::{Digest, Sha256};
    use std::io::Read;
    let mut file = std::fs::File::open(path)?;
    let mut hasher = Sha256::new();
    let mut buf = [0u8; 8192];
    loop {
        let n = file.read(&mut buf)?;
        if n == 0 { break; }
        hasher.update(&buf[..n]);
    }
    Ok(hasher.finalize().iter().map(|b| format!("{b:02x}")).collect())
}

// ------------------------------------------------------------------
// 时间词解析
// ------------------------------------------------------------------

/// 解析时间词为 date_range (start, end)。
pub fn parse_time_query(query: &str, today: chrono::NaiveDate) -> Option<(i64, i64)> {
    if query.contains("上周") {
        let (start, end) = week_range(today, -1);
        Some((date_to_int(start), date_to_int(end)))
    } else if query.contains("本周") {
        let (start, end) = week_range(today, 0);
        Some((date_to_int(start), date_to_int(end)))
    } else if query.contains("下周") {
        let (start, end) = week_range(today, 1);
        Some((date_to_int(start), date_to_int(end)))
    } else if query.contains("上月") {
        let (start, end) = month_range(today, -1);
        Some((date_to_int(start), date_to_int(end)))
    } else if query.contains("本月") {
        let (start, end) = month_range(today, 0);
        Some((date_to_int(start), date_to_int(end)))
    } else if query.contains("下月") {
        let (start, end) = month_range(today, 1);
        Some((date_to_int(start), date_to_int(end)))
    } else {
        None
    }
}

fn week_range(d: chrono::NaiveDate, offset: i64) -> (chrono::NaiveDate, chrono::NaiveDate) {
    let weekday = d.weekday().num_days_from_monday() as i64;
    let monday = d - chrono::Duration::days(weekday) + chrono::Duration::weeks(offset);
    (monday, monday + chrono::Duration::days(6))
}

fn month_range(d: chrono::NaiveDate, offset: i64) -> (chrono::NaiveDate, chrono::NaiveDate) {
    let year = d.year() + ((d.month() as i64 + offset - 1).div_euclid(12)) as i32;
    let month = ((d.month() as i64 - 1 + offset).rem_euclid(12)) as u32 + 1;
    let first = chrono::NaiveDate::from_ymd_opt(year, month, 1).unwrap();
    let last_day = days_in_month(year, month);
    let last = chrono::NaiveDate::from_ymd_opt(year, month, last_day).unwrap();
    (first, last)
}

fn days_in_month(year: i32, month: u32) -> u32 {
    match month {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        2 => {
            if (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 { 29 } else { 28 }
        }
        _ => 30,
    }
}

fn date_to_int(d: chrono::NaiveDate) -> i64 {
    d.format("%Y%m%d").to_string().parse().unwrap()
}

// ------------------------------------------------------------------
// 凭据脱敏
// ------------------------------------------------------------------

/// 对文本执行凭据脱敏，返回（脱敏后文本, 命中次数）。
pub fn desensitize(text: &str) -> (String, usize) {
    let mut count = 0;
    let mut result = text.to_string();

    // 密码类字段后跟长值：密码/口令/password/secret/支付密码/登录密码
    let patterns = [
        r"(密码|口令|password|secret|支付密码|登录密码)[:：= ]\S{8,}",
        r"(账号|appid|api[_-]?key|sqycKey|token)[:：= ]\S+.{0,80}(密码|口令|password|secret)",
        r"(密码|口令|password|secret).{0,80}(账号|appid|api[_-]?key|sqycKey|token)[:：= ]\S+",
    ];
    for pattern in patterns {
        let re = match regex::Regex::new(&format!("(?i){pattern}")) {
            Ok(re) => re,
            Err(_) => continue,
        };
        let mut new_result = result.clone();
        let mut replaced = false;
        for cap in re.captures_iter(&result) {
            if let Some(m) = cap.get(0) {
                new_result.replace_range(m.start()..m.end(), "[已脱敏]");
                count += 1;
                replaced = true;
            }
        }
        if replaced {
            result = new_result;
        }
    }
    (result, count)
}

/// 判断文件是否应标记为敏感（脱敏次数 > 3 或路径命中特征）。
pub fn is_sensitive_file(desensitize_count: usize, path_hint: &str) -> bool {
    if desensitize_count > 3 {
        return true;
    }
    let hint = path_hint.to_lowercase();
    ["实操环境", "source", ".env", "config"]
        .iter()
        .any(|kw| hint.contains(kw))
}

// ------------------------------------------------------------------
// 内部
// ------------------------------------------------------------------

/// 天数 → 公历日期（返回 年/月/日，日序自 1970-01-01 起）。
fn civil_from_days(z: i64) -> (i64, i64, i64) {
    let z = z + 719468;
    let era = if z >= 0 { z } else { z - 146096 } / 146097;
    let doe = (z - era * 146097) as u64;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = yoe as i64 + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    (if m <= 2 { y + 1 } else { y }, m as i64, d as i64)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extracts_date_from_filename() {
        let p = Path::new("/data/notes/daily/2026-07-21.md");
        let (date, source) = extract_date_from_path(p);
        assert_eq!(date, Some(20260721));
        assert_eq!(source, "filename");
    }

    #[test]
    fn extracts_date_from_dirname() {
        let p = Path::new("/data/2026-07-21/notes.md");
        let (date, source) = extract_date_from_path(p);
        assert_eq!(date, Some(20260721));
        assert_eq!(source, "dirname");
    }

    #[test]
    fn extracts_date_from_chinese_format() {
        let (date, _) = extract_date_from_content(&["2026年7月15日 工作总结".to_string()]);
        assert_eq!(date, Some(20260715));
    }

    #[test]
    fn parses_week_time_query() {
        let today = chrono::NaiveDate::from_ymd_opt(2026, 8, 12).unwrap(); // 周三
        let range = parse_time_query("上周的工作", today);
        let (start, end) = range.unwrap();
        assert_eq!(start, 20260803);
        assert_eq!(end, 20260809);
    }

    #[test]
    fn parses_month_time_query() {
        let today = chrono::NaiveDate::from_ymd_opt(2026, 8, 12).unwrap();
        let range = parse_time_query("上月的对账", today);
        let (start, end) = range.unwrap();
        assert_eq!(start, 20260701);
        assert_eq!(end, 20260731);
    }

    #[test]
    fn desensitizes_password() {
        let (text, count) = desensitize("密码：Abcdef123456，其余内容保留");
        assert!(count >= 1);
        assert!(text.contains("[已脱敏]"));
        assert!(!text.contains("Abcdef123456"));
    }

    #[test]
    fn sha256_is_stable() {
        let dir = std::env::temp_dir().join(format!("xyn_sha_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let f = dir.join("t.txt");
        std::fs::write(&f, "hello world").unwrap();
        let a = file_sha256(&f).unwrap();
        let b = file_sha256(&f).unwrap();
        assert_eq!(a, b);
        std::fs::remove_dir_all(&dir).ok();
    }
}
