//! Optional presentation metadata, deliberately outside sealed/canonical values.
use axum::http::HeaderMap;
use unicode_normalization::UnicodeNormalization;

pub const HEADER: &str = "fuminiwa-device-label";

pub fn from_headers(headers: &HeaderMap) -> Option<String> {
    let mut values = headers.get_all(HEADER).iter();
    let value = values.next()?.to_str().ok()?;
    if values.next().is_some() {
        return None;
    }
    decode(value)
}

pub fn decode(encoded: &str) -> Option<String> {
    // Bounded decoding permits decomposed input before NFC normalization.
    if encoded.len() > 4096 || !encoded.is_ascii() {
        return None;
    }
    let mut bytes = Vec::with_capacity(encoded.len());
    let mut input = encoded.as_bytes().iter().copied();
    while let Some(byte) = input.next() {
        if byte == b'%' {
            let high = (input.next()? as char).to_digit(16)?;
            let low = (input.next()? as char).to_digit(16)?;
            bytes.push((high * 16 + low) as u8);
        } else if byte.is_ascii_alphanumeric() || b"-._~".contains(&byte) {
            bytes.push(byte);
        } else {
            return None;
        }
    }
    let decoded = String::from_utf8(bytes).ok()?;
    let normalized: String = decoded.nfc().collect();
    let count = normalized.chars().count();
    if !(1..=40).contains(&count)
        || normalized
            .chars()
            .any(|c| c.is_control() || matches!(c, '\u{2028}' | '\u{2029}'))
    {
        return None;
    }
    Some(normalized)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn optional_header_validation() {
        assert_eq!(
            decode("%E4%BB%95%E4%BA%8B%E7%94%A8Mac").as_deref(),
            Some("仕事用Mac")
        );
        assert_eq!(decode("e%CC%81").as_deref(), Some("é"));
        assert_eq!(
            decode(&"a".repeat(40)).as_deref(),
            Some("a".repeat(40).as_str())
        );
        for invalid in [
            "",
            "%",
            "%GG",
            "%FF",
            "a%0Ab",
            "a%0Db",
            "%00",
            "%7F",
            "%C2%85",
            "%E2%80%A8",
            "raw space",
            &"a".repeat(41),
        ] {
            assert_eq!(decode(invalid), None);
        }
        assert_eq!(from_headers(&HeaderMap::new()), None);
        let mut headers = HeaderMap::new();
        headers.append(HEADER, "Mac".parse().unwrap());
        headers.append(HEADER, "iPhone".parse().unwrap());
        assert_eq!(from_headers(&headers), None);
    }
}
