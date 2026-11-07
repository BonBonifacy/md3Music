use kugou_server::audio_tags;
use lofty::{
    config::WriteOptions,
    file::TaggedFileExt,
    id3::v2::{CommentFrame, ExtendedTextFrame, Frame, Id3v2Tag},
    ogg::tag::VorbisComments,
    prelude::*,
    probe::Probe,
    tag::{ItemKey, Tag, TagType},
    TextEncoding,
};
use serde_json::json;
use sha2::{Digest, Sha256};
use std::{fs, path::PathBuf};

fn root() -> PathBuf {
    let root = std::env::temp_dir().join(format!(
        "md3-tags-{}-{}",
        std::process::id(),
        rand::random::<u64>()
    ));
    fs::create_dir_all(&root).unwrap();
    root
}
const ID: &str = "12345678-1234-1234-1234-123456789abc";
#[test]
fn mp3_flac_roundtrip_preserves_audio_and_picture_and_word_timing() {
    for extension in ["mp3", "flac"] {
        let root = root();
        let fixtures = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/audio_tags");
        fs::copy(
            fixtures.join(format!("tone.{extension}")),
            root.join(format!("{ID}.source")),
        )
        .unwrap();
        fs::copy(fixtures.join("cover.png"), root.join(format!("{ID}.cover"))).unwrap();
        let original = fs::read(root.join(format!("{ID}.source"))).unwrap();
        let digest = format!(
            "{:x}",
            Sha256::digest(fs::read(fixtures.join("cover.png")).unwrap())
        );
        let request = json!({"schemaVersion":1,"jobId":ID,"fields":{
            "title":"歌名🎵","artists":["歌手甲","歌手乙"],"album":"测试专辑","albumArtists":["专辑歌手"],
            "trackNumber":2,"trackTotal":10,"discNumber":1,"discTotal":2,"date":"2024-02-29",
            "genres":["Pop"],"composers":["曲作者"],"lyricists":["词作者"],
            "lyrics":{"format":"eslyric_enhanced","wordTimed":true,"text":"[00:01.000]<00:01.000>你<00:01.200>好<00:01.800>\n[00:02.000]<00:02.000>a=b<00:02.500>"},
            "cover":{"sha256":digest,"width":32,"height":32}
        }});
        let result = audio_tags::write(&root, &request.to_string()).unwrap();
        assert_eq!(result["ok"], true);
        assert_eq!(
            fs::read(root.join(format!("{ID}.source"))).unwrap(),
            original
        );
        assert!(root.join(format!("{ID}.tagged")).exists());
        fs::remove_dir_all(root).unwrap();
    }
}
#[test]
fn invalid_fields_and_traversal_are_rejected_before_writes() {
    let root = root();
    for request in [
        json!({"schemaVersion":1,"jobId":"../outside","fields":{}}),
        json!({"schemaVersion":1,"jobId":ID,"fields":{"arbitraryFrame":"x"}}),
        json!({"schemaVersion":1,"jobId":ID,"fields":{"comment":"not allowed"}}),
        json!({"schemaVersion":1,"jobId":ID,"fields":{"date":"2025-02-29"}}),
        json!({"schemaVersion":1,"jobId":ID,"fields":{"lyrics":{"format":"plain","text":"text","wordTimed":true}}}),
        json!({"schemaVersion":1,"jobId":ID,"fields":{"lyrics":{"format":"eslyric_enhanced","text":"[00:00.000]<bad>word<00:01.000>","wordTimed":true}}}),
        json!({"schemaVersion":1,"jobId":ID,"fields":{"lyrics":{"format":"eslyric_enhanced","text":"[00:00.000]<00:02.000>word<00:01.000>","wordTimed":true}}}),
    ] {
        assert!(audio_tags::write(&root, &request.to_string()).is_err());
        assert_eq!(fs::read_dir(&root).unwrap().count(), 0);
    }
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn mp3_removes_all_comment_frames_and_secondary_comments_without_touching_source() {
    for secondary_comment_only in [true, false] {
        let root = root();
        let source = root.join(format!("{ID}.source"));
        fs::copy(
            PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/audio_tags/tone.mp3"),
            &source,
        )
        .unwrap();
        let mut id3 = Id3v2Tag::new();
        for (language, description) in [(*b"eng", ""), (*b"zho", "custom")] {
            id3.insert(Frame::Comment(CommentFrame::new(
                TextEncoding::UTF8,
                language,
                description,
                "remove me",
            )));
        }
        id3.insert(Frame::UserText(ExtendedTextFrame::new(
            TextEncoding::UTF8,
            "CoMmEnT",
            "remove custom alias",
        )));
        id3.insert(Frame::UserText(ExtendedTextFrame::new(
            TextEncoding::UTF8,
            "KEEP",
            "preserve me",
        )));
        id3.set_artist("Original artist".into());
        id3.save_to_path(&source, WriteOptions::default()).unwrap();
        for kind in [TagType::Id3v1, TagType::Ape] {
            let mut secondary = Tag::new(kind);
            secondary.set_comment("secondary comment".into());
            if !secondary_comment_only {
                secondary.set_artist("Secondary artist".into());
            }
            secondary
                .save_to_path(&source, WriteOptions::default())
                .unwrap();
        }
        let original = fs::read(&source).unwrap();
        let written = audio_tags::write(
            &root,
            &json!({"schemaVersion":1,"jobId":ID,"fields":{"title":"New title"}}).to_string(),
        )
        .unwrap();
        assert_eq!(written["commentFree"], true);
        assert_eq!(fs::read(&source).unwrap(), original);
        let result = Probe::open(root.join(format!("{ID}.tagged")))
            .unwrap()
            .guess_file_type()
            .unwrap()
            .read()
            .unwrap();
        for tag in result.tags() {
            assert!(tag.get(ItemKey::Comment).is_none());
        }
        let primary = result.primary_tag().unwrap();
        assert_eq!(primary.title().as_deref(), Some("New title"));
        assert_eq!(primary.artist().as_deref(), Some("Original artist"));
        let native = Id3v2Tag::from(primary.clone());
        assert!(!native.iter().any(|f| matches!(f, Frame::Comment(_))
            || matches!(f, Frame::UserText(t) if t.description.eq_ignore_ascii_case("COMMENT"))));
        assert!(native.iter().any(
            |f| matches!(f, Frame::UserText(t) if t.description=="KEEP" && t.content=="preserve me")
        ));
        fs::remove_dir_all(root).unwrap();
    }
}

#[test]
fn flac_removes_comment_aliases_and_preserves_lyrics_and_other_fields() {
    let root = root();
    let source = root.join(format!("{ID}.source"));
    fs::copy(
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/audio_tags/tone.flac"),
        &source,
    )
    .unwrap();
    let mut tag = VorbisComments::new();
    for key in ["COMMENT", "CoMmEnT", "DESCRIPTION", "DeScRiPtIoN"] {
        tag.push(key.into(), "remove me".into());
    }
    for (key, value) in [
        ("ARTIST", "Original artist"),
        ("LYRICS", "[00:01.000]<00:01.000>字<00:01.200>"),
        ("CUSTOM", "preserve me"),
    ] {
        tag.push(key.into(), value.into());
    }
    tag.save_to_path(&source, WriteOptions::default()).unwrap();
    let original = fs::read(&source).unwrap();
    // Empty fields is also the comment-only cleanup used after other metadata fails.
    let result = audio_tags::write(
        &root,
        &json!({"schemaVersion":1,"jobId":ID,"fields":{}}).to_string(),
    )
    .unwrap();
    assert_eq!(result["commentFree"], true);
    assert_eq!(fs::read(&source).unwrap(), original);
    let read = Probe::open(root.join(format!("{ID}.tagged")))
        .unwrap()
        .guess_file_type()
        .unwrap()
        .read()
        .unwrap();
    let native = VorbisComments::from(read.primary_tag().unwrap().clone());
    assert_eq!(native.get("COMMENT"), None);
    assert_eq!(native.get("DESCRIPTION"), None);
    assert_eq!(native.get("ARTIST"), Some("Original artist"));
    assert_eq!(
        native.get("LYRICS"),
        Some("[00:01.000]<00:01.000>字<00:01.200>")
    );
    assert_eq!(native.get("CUSTOM"), Some("preserve me"));
    fs::remove_dir_all(root).unwrap();
}
