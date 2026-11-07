//! Download-only metadata writer. No HTTP route accepts local paths.
use lofty::{
    ape::ApeTag,
    config::WriteOptions,
    file::{AudioFile, FileType, TaggedFile, TaggedFileExt},
    id3::v2::{Frame, Id3v2Tag},
    ogg::tag::VorbisComments,
    picture::{Picture, PictureInformation, PictureType},
    probe::Probe,
    tag::{ItemKey, ItemValue, Tag, TagExt, TagItem, TagType},
};
use serde::Deserialize;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    collections::HashMap,
    ffi::{CStr, CString},
    fs::{self, OpenOptions},
    io::{self, Cursor},
    os::raw::c_char,
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicU64, Ordering},
        Arc, Mutex, OnceLock,
    },
};

const MAX_PICTURE: u64 = 64 * 1024 * 1024;
static ROOTS: OnceLock<Mutex<HashMap<u64, Arc<PathBuf>>>> = OnceLock::new();
static NEXT: AtomicU64 = AtomicU64::new(1);
static WRITE_LOCK: Mutex<()> = Mutex::new(());
fn roots() -> &'static Mutex<HashMap<u64, Arc<PathBuf>>> {
    ROOTS.get_or_init(Default::default)
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Request {
    pub schema_version: u32,
    pub job_id: String,
    pub fields: Fields,
}
#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Fields {
    pub title: Option<String>,
    pub artists: Option<Vec<String>>,
    pub album: Option<String>,
    pub album_artists: Option<Vec<String>>,
    pub track_number: Option<u32>,
    pub track_total: Option<u32>,
    pub disc_number: Option<u32>,
    pub disc_total: Option<u32>,
    pub date: Option<String>,
    pub genres: Option<Vec<String>>,
    pub composers: Option<Vec<String>>,
    pub lyricists: Option<Vec<String>>,
    pub lyrics: Option<Lyrics>,
    pub cover: Option<Cover>,
}
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Lyrics {
    pub format: String,
    pub text: String,
    pub word_timed: bool,
}
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Cover {
    pub sha256: String,
    pub width: u32,
    pub height: u32,
}

fn text_ok(s: &str, max: usize) -> bool {
    s.len() <= max
        && !s
            .chars()
            .any(|c| c.is_control() && c != '\n' && c != '\r' && c != '\t')
}
fn lyric_time(s: &str) -> Option<u64> {
    let (minutes, rest) = s.split_once(':')?;
    let (seconds, fraction) = rest.split_once('.')?;
    if minutes.is_empty()
        || seconds.len() != 2
        || !(2..=3).contains(&fraction.len())
        || !minutes
            .bytes()
            .chain(seconds.bytes())
            .chain(fraction.bytes())
            .all(|b| b.is_ascii_digit())
    {
        return None;
    }
    let second = seconds.parse::<u64>().ok()?;
    if second >= 60 {
        return None;
    }
    minutes
        .parse::<u64>()
        .ok()?
        .checked_mul(60_000)?
        .checked_add(
            second * 1000
                + fraction.parse::<u64>().ok()? * if fraction.len() == 2 { 10 } else { 1 },
        )
}

fn enhanced_lyrics_valid(text: &str) -> bool {
    let mut timed = false;
    for line in text.lines() {
        if !line.contains('<') {
            continue;
        }
        let Some((stamp, _)) = line.strip_prefix('[').and_then(|s| s.split_once(']')) else {
            return false;
        };
        let Some(mut previous) = lyric_time(stamp) else {
            return false;
        };
        let mut rest = line;
        let mut count = 0;
        while let Some((_, tail)) = rest.split_once('<') {
            let Some((stamp, tail)) = tail.split_once('>') else {
                return false;
            };
            let Some(time) = lyric_time(stamp) else {
                return false;
            };
            if time < previous {
                return false;
            }
            previous = time;
            rest = tail;
            count += 1;
        }
        if count < 2 {
            return false;
        }
        timed = true;
    }
    timed
}

fn validate(r: &Request) -> Result<(), String> {
    if r.schema_version != 1
        || r.job_id.len() != 36
        || !r.job_id.bytes().all(|b| b.is_ascii_hexdigit() || b == b'-')
    {
        return Err("invalid_request".into());
    }
    let f = &r.fields;
    if f.genres
        .as_ref()
        .is_some_and(|a| a.len() > 16 || a.iter().any(|s| !text_ok(s, 128)))
    {
        return Err("invalid_genres".into());
    }
    for s in [&f.title, &f.album].into_iter().flatten() {
        if !text_ok(s, 1024) {
            return Err("invalid_text".into());
        }
    }
    for a in [
        &f.artists,
        &f.album_artists,
        &f.genres,
        &f.composers,
        &f.lyricists,
    ]
    .into_iter()
    .flatten()
    {
        if a.len() > 32 || a.iter().any(|s| !text_ok(s, 512)) {
            return Err("invalid_text_array".into());
        }
    }
    for n in [f.track_number, f.track_total, f.disc_number, f.disc_total]
        .into_iter()
        .flatten()
    {
        if n == 0 || n > 65535 {
            return Err("invalid_number".into());
        }
    }
    for (n, t) in [
        (f.track_number, f.track_total),
        (f.disc_number, f.disc_total),
    ] {
        if matches!((n,t),(Some(n),Some(t)) if n>t) {
            return Err("invalid_number".into());
        }
    }
    if let Some(d) = &f.date {
        if !valid_date(d) {
            return Err("invalid_date".into());
        }
    }
    if let Some(l) = &f.lyrics {
        if !text_ok(&l.text, 1024 * 1024)
            || !["plain", "lrc", "eslyric_enhanced"].contains(&l.format.as_str())
        {
            return Err("invalid_lyrics".into());
        }
        if l.word_timed && (l.format != "eslyric_enhanced" || !enhanced_lyrics_valid(&l.text)) {
            return Err("word_timing_required".into());
        }
    }
    if let Some(p) = &f.cover {
        if p.width == 0
            || p.height == 0
            || u64::from(p.width) * u64::from(p.height) > 100_000_000
            || p.sha256.len() != 64
        {
            return Err("invalid_picture".into());
        }
    }
    Ok(())
}
fn valid_date(d: &str) -> bool {
    let parts: Vec<_> = d.split('-').collect();
    if parts.is_empty()
        || parts.len() > 3
        || parts[0].len() != 4
        || !d.bytes().all(|b| b.is_ascii_digit() || b == b'-')
    {
        return false;
    }
    let y = parts[0].parse::<u32>().unwrap_or(0);
    if y == 0 {
        return false;
    }
    if parts.len() == 1 {
        return true;
    }
    let m = parts[1].parse::<usize>().unwrap_or(0);
    if parts[1].len() != 2 || !(1..=12).contains(&m) {
        return false;
    }
    if parts.len() == 2 {
        return true;
    }
    let days = [
        31,
        if y % 4 == 0 && (y % 100 != 0 || y % 400 == 0) {
            29
        } else {
            28
        },
        31,
        30,
        31,
        30,
        31,
        31,
        30,
        31,
        30,
        31,
    ];
    let day = parts[2].parse::<u32>().unwrap_or(0);
    parts[2].len() == 2 && day > 0 && day <= days[m - 1]
}
fn owned_file(root: &Path, name: &str) -> Result<PathBuf, String> {
    let path = root.join(name);
    let m = fs::symlink_metadata(&path).map_err(|_| "missing_source")?;
    if !m.is_file() || m.file_type().is_symlink() {
        return Err("invalid_source".into());
    }
    let canonical = path.canonicalize().map_err(|_| "invalid_source")?;
    if canonical.parent() != Some(root) {
        return Err("path_outside_staging".into());
    }
    Ok(canonical)
}

/// Removes comment fields from every tag, including secondary ID3v1/APE tags.
/// Consume and reinsert tags so large embedded pictures are moved, not cloned.
fn remove_comments(audio: &mut TaggedFile) -> bool {
    let kinds: Vec<_> = audio.tags().iter().map(Tag::tag_type).collect();
    let mut found = false;
    for kind in kinds {
        let Some(mut tag) = audio.remove(kind) else {
            continue;
        };
        found |= tag.items().any(|item| {
            item.key() == ItemKey::Comment
                || (kind == TagType::VorbisComments && item.key() == ItemKey::Description)
        });
        tag.remove_key(ItemKey::Comment);
        if kind == TagType::VorbisComments {
            tag.remove_key(ItemKey::Description);
        }
        // Unknown/case-varied fields can live in Lofty's format-specific remainder.
        if tag.has_format_specific_items() {
            tag = match kind {
                TagType::Id3v2 => {
                    let mut native = Id3v2Tag::from(tag);
                    native.retain(|frame| {
                        let comment = matches!(frame, Frame::Comment(_)) ||
                            matches!(frame, Frame::UserText(text) if text.description.eq_ignore_ascii_case("COMMENT"));
                        found |= comment;
                        !comment
                    });
                    native.into()
                }
                TagType::VorbisComments => {
                    let mut native = VorbisComments::from(tag);
                    found |= native.remove("COMMENT").count() > 0;
                    found |= native.remove("DESCRIPTION").count() > 0;
                    native.into()
                }
                TagType::Ape => {
                    let mut native = ApeTag::from(tag);
                    found |= native.get("Comment").is_some();
                    native.remove("Comment");
                    native.into()
                }
                _ => tag,
            };
        }
        audio.insert_tag(tag);
    }
    found
}

pub fn write(root: &Path, request: &str) -> Result<Value, String> {
    if request.len() > 2 * 1024 * 1024 {
        return Err("request_too_large".into());
    }
    let r: Request = serde_json::from_str(request).map_err(|e| format!("invalid_request: {e}"))?;
    validate(&r)?;
    let _guard = WRITE_LOCK.lock().map_err(|_| "writer_unavailable")?;
    let root = root.canonicalize().map_err(|_| "invalid_root")?;
    let source = owned_file(&root, &format!("{}.source", r.job_id))?;
    let mut audio = Probe::open(&source)
        .and_then(|p| Ok(p.guess_file_type()?))
        .and_then(|p| p.read())
        .map_err(|e| format!("invalid_audio: {e}"))?;
    if !matches!(audio.file_type(), FileType::Mpeg | FileType::Flac) {
        return Err("unsupported_format".into());
    }
    let before = (
        audio.properties().duration(),
        audio.properties().sample_rate(),
        audio.properties().channels(),
    );
    remove_comments(&mut audio);
    let mut picture = None;
    if let Some(c) = &r.fields.cover {
        let path = owned_file(&root, &format!("{}.cover", r.job_id))?;
        let size = path.metadata().map_err(|e| e.to_string())?.len();
        if size > MAX_PICTURE || (audio.file_type() == FileType::Flac && size + 128 > 0xff_ffff) {
            return Err("cover_format_limit_exceeded".into());
        }
        let bytes = fs::read(path).map_err(|e| e.to_string())?;
        if format!("{:x}", Sha256::digest(&bytes)) != c.sha256 {
            return Err("cover_integrity_failed".into());
        }
        let mut p = Picture::from_reader(&mut Cursor::new(bytes))
            .map_err(|e| format!("invalid_picture: {e}"))?;
        let info =
            PictureInformation::from_picture(&p).map_err(|e| format!("invalid_picture: {e}"))?;
        if info.width != c.width
            || info.height != c.height
            || u64::from(info.width) * u64::from(info.height) > 100_000_000
        {
            return Err("picture_dimensions_mismatch".into());
        }
        p.set_pic_type(PictureType::CoverFront);
        picture = Some(p);
    }
    let kind = audio.primary_tag_type();
    if audio.primary_tag().is_none() {
        audio.insert_tag(Tag::new(kind));
    }
    let mp3 = audio.file_type() == FileType::Mpeg;
    let tag = audio.primary_tag_mut().ok_or("missing_tag")?;
    let f = &r.fields;
    let mut expected: Vec<(ItemKey, Vec<String>)> = Vec::new();
    for (key, value) in [
        (ItemKey::TrackTitle, &f.title),
        (ItemKey::AlbumTitle, &f.album),
        (ItemKey::RecordingDate, &f.date),
    ] {
        if let Some(s) = value {
            if !s.trim().is_empty() {
                expected.push((key, vec![s.clone()]));
            }
        }
    }
    for (key, value) in [
        (ItemKey::TrackArtist, &f.artists),
        (ItemKey::AlbumArtist, &f.album_artists),
        (ItemKey::Genre, &f.genres),
        (ItemKey::Composer, &f.composers),
        (ItemKey::Lyricist, &f.lyricists),
    ] {
        if let Some(a) = value {
            let a: Vec<_> = a.iter().filter(|s| !s.trim().is_empty()).cloned().collect();
            if !a.is_empty() {
                expected.push((key, a));
            }
        }
    }
    for (key, value) in [
        (ItemKey::TrackNumber, f.track_number),
        (ItemKey::TrackTotal, f.track_total),
        (ItemKey::DiscNumber, f.disc_number),
        (ItemKey::DiscTotal, f.disc_total),
    ] {
        if let Some(n) = value {
            expected.push((key, vec![n.to_string()]));
        }
    }
    if let Some(l) = &f.lyrics {
        if !l.text.trim().is_empty() {
            expected.push((
                if mp3 {
                    ItemKey::UnsyncLyrics
                } else {
                    ItemKey::Lyrics
                },
                vec![l.text.clone()],
            ));
        }
    }
    for (key, values) in &expected {
        tag.remove_key(*key);
        for value in values {
            tag.push(TagItem::new(*key, ItemValue::Text(value.clone())));
        }
    }
    if let Some(p) = picture {
        tag.remove_picture_type(PictureType::CoverFront);
        tag.push_picture(p);
    }
    let temp = root.join(format!("{}.tagging.tmp", r.job_id));
    let output = root.join(format!("{}.tagged", r.job_id));
    // Exclusive creation prevents following a pre-existing temporary symlink.
    let mut created = false;
    let result = (|| -> Result<Value, String> {
        let mut dst = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temp)
            .map_err(|e| format!("create_tag_copy: {e}"))?;
        created = true;
        io::copy(
            &mut fs::File::open(&source).map_err(|e| e.to_string())?,
            &mut dst,
        )
        .map_err(|e| e.to_string())?;
        dst.sync_all().map_err(|e| e.to_string())?;
        drop(dst);
        // Lofty's generic Vorbis writer drops its format-specific remainder.
        // Write the concrete tag to retain unrelated custom fields while omitting comments.
        let vorbis = audio
            .remove(TagType::VorbisComments)
            .map(VorbisComments::from);
        audio
            .save_to_path(
                &temp,
                WriteOptions::default()
                    .remove_others(false)
                    .respect_read_only(true)
                    .lossy_text_encoding(false),
            )
            .map_err(|e| format!("tag_write_failed: {e}"))?;
        if let Some(vorbis) = vorbis {
            vorbis
                .save_to_path(
                    &temp,
                    WriteOptions::default()
                        .remove_others(false)
                        .respect_read_only(true)
                        .lossy_text_encoding(false),
                )
                .map_err(|e| format!("tag_write_failed: {e}"))?;
        }
        let mut read = Probe::open(&temp)
            .and_then(|p| Ok(p.guess_file_type()?))
            .and_then(|p| p.read())
            .map_err(|e| format!("tag_readback_failed: {e}"))?;
        let after = (
            read.properties().duration(),
            read.properties().sample_rate(),
            read.properties().channels(),
        );
        if before != after {
            return Err("audio_properties_changed".into());
        }
        if remove_comments(&mut read) {
            return Err("comment_readback_failed".into());
        }
        let tag = read.primary_tag().ok_or("tag_readback_failed")?;
        for (key, values) in &expected {
            let actual: Vec<_> = tag.get_strings(*key).map(str::to_owned).collect();
            if actual != *values {
                return Err(format!("tag_readback_mismatch: {key:?}"));
            }
        }
        if let Some(c) = &f.cover {
            let p = tag
                .pictures()
                .iter()
                .find(|p| p.pic_type() == PictureType::CoverFront)
                .ok_or("cover_readback_failed")?;
            if format!("{:x}", Sha256::digest(p.data())) != c.sha256 {
                return Err("cover_readback_failed".into());
            }
        }
        if output.exists() {
            owned_file(&root, &format!("{}.tagged", r.job_id))?;
            fs::remove_file(&output).map_err(|e| e.to_string())?;
        }
        fs::rename(&temp, &output).map_err(|e| e.to_string())?;
        Ok(
            json!({"ok":true,"outputKind":"tagged","commentFree":true,"appliedFields":expected.iter().map(|(k,_)|format!("{k:?}")).collect::<Vec<_>>(),"lyricProfile":f.lyrics.as_ref().map(|l| &l.format)}),
        )
    })();
    if result.is_err() && created {
        let _ = fs::remove_file(&temp);
    }
    result
}

fn response(value: Value) -> *mut c_char {
    CString::new(value.to_string()).map_or(std::ptr::null_mut(), CString::into_raw)
}
/// Inspect the audio container before any metadata or publication. Does not modify the source.
/// # Safety
/// `job` must be a valid NUL-terminated UTF-8 string for this call.
#[no_mangle]
pub unsafe extern "C" fn md3_tag_writer_inspect(handle: u64, job: *const c_char) -> *mut c_char {
    let result = (|| -> Result<Value, String> {
        let root = roots()
            .lock()
            .ok()
            .and_then(|m| m.get(&handle).cloned())
            .ok_or("invalid_handle")?;
        if job.is_null() {
            return Err("invalid_request".into());
        }
        let id = unsafe { CStr::from_ptr(job) }
            .to_str()
            .map_err(|_| "invalid_request")?;
        if id.len() != 36 || !id.bytes().all(|b| b.is_ascii_hexdigit() || b == b'-') {
            return Err("invalid_request".into());
        }
        let path = owned_file(&root, &format!("{id}.source"))?;
        let mut audio = Probe::open(&path)
            .and_then(|p| Ok(p.guess_file_type()?))
            .and_then(|p| p.read())
            .map_err(|e| format!("invalid_audio: {e}"))?;
        let has_comments = remove_comments(&mut audio);
        let p = audio.properties();
        if p.duration().is_zero()
            || p.sample_rate().unwrap_or(0) == 0
            || p.channels().unwrap_or(0) == 0
        {
            return Err("invalid_audio_properties".into());
        }
        let mut hash = Sha256::new();
        io::copy(
            &mut fs::File::open(&path).map_err(|e| e.to_string())?,
            &mut hash,
        )
        .map_err(|e| e.to_string())?;
        Ok(
            json!({"ok":true,"durationMs":p.duration().as_millis(),"sha256":format!("{:x}",hash.finalize()),"sampleRate":p.sample_rate(),"channels":p.channels(),"hasComments":has_comments}),
        )
    })();
    response(result.unwrap_or_else(|e| json!({"ok":false,"errorCode":e})))
}
/// # Safety
/// `root` must point to a valid NUL-terminated UTF-8 string for this call.
#[no_mangle]
pub unsafe extern "C" fn md3_tag_writer_open(root: *const c_char) -> u64 {
    if root.is_null() {
        return 0;
    }
    let Ok(s) = unsafe { CStr::from_ptr(root) }.to_str() else {
        return 0;
    };
    let Ok(p) = Path::new(s).canonicalize() else {
        return 0;
    };
    if !p.is_dir() {
        return 0;
    }
    let id = NEXT.fetch_add(1, Ordering::Relaxed);
    let Ok(mut m) = roots().lock() else {
        return 0;
    };
    m.insert(id, Arc::new(p));
    id
}
#[no_mangle]
pub extern "C" fn md3_tag_writer_close(handle: u64) {
    if let Ok(mut m) = roots().lock() {
        m.remove(&handle);
    }
}
#[no_mangle]
pub extern "C" fn md3_tag_writer_capabilities(handle: u64) -> *mut c_char {
    if !roots().lock().is_ok_and(|m| m.contains_key(&handle)) {
        return response(json!({"ok":false,"errorCode":"invalid_handle"}));
    }
    response(
        json!({"ok":true,"schemaVersion":1,"library":"lofty-0.25.5","formats":["mp3","flac"],"allowedFields":["title","artists","album","albumArtists","trackNumber","trackTotal","discNumber","discTotal","date","genres","composers","lyricists","lyrics","cover"],"lyricProfiles":["eslyric_enhanced","lrc","plain"],"eslyricPlayerVerified":false}),
    )
}
/// # Safety
/// `request` must point to a valid NUL-terminated UTF-8 string. Free the result with md3_tag_writer_free_json.
#[no_mangle]
pub unsafe extern "C" fn md3_tag_writer_write(handle: u64, request: *const c_char) -> *mut c_char {
    let root = roots().lock().ok().and_then(|m| m.get(&handle).cloned());
    let result = (|| {
        let root = root.ok_or("invalid_handle".to_string())?;
        if request.is_null() {
            return Err("invalid_request".into());
        }
        let s = unsafe { CStr::from_ptr(request) }
            .to_str()
            .map_err(|_| "invalid_utf8".to_string())?;
        write(&root, s)
    })();
    response(result.unwrap_or_else(|e| json!({"ok":false,"errorCode":e,"retryable":false})))
}
/// # Safety
/// `ptr` must be null or a live result allocated by this module, freed exactly once.
#[no_mangle]
pub unsafe extern "C" fn md3_tag_writer_free_json(ptr: *mut c_char) {
    if !ptr.is_null() {
        drop(unsafe { CString::from_raw(ptr) });
    }
}
