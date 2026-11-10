//! Notes: text written or edited in Remvel's note editor. A note is an item of kind `Note`, so it is
//! listed, searched and pasted like a copy, but its text can change and the history limit never drops it.

use rusqlite::{OptionalExtension, params};

use crate::search::Entry;
use crate::store::{UTI_TEXT, content_hash, make_title};
use crate::{Error, Kind, Rep, Result, Store};

/// Remvel's own rep on every note. Its data, fixed when the note is made, keeps the note's identity
/// apart from a copy with the same text, and from another note with the same text.
pub const UTI_NOTE: &str = "io.github.remvel.note";

impl Store {
    /// Saves `text` as note `id`, or as a new note when `id` is `None`, and returns the note's id.
    /// A saved note moves to the top of the history, as a new copy would. `at` is Unix ms.
    pub fn save_note(&mut self, id: Option<i64>, text: &str, at: i64) -> Result<i64> {
        let tx = self.conn.transaction()?;
        let marker = match id {
            Some(id) => tx
                .query_row(
                    "SELECT r.data FROM reps r JOIN items i ON i.id = r.item_id
                     WHERE r.item_id = ?1 AND r.uti = ?2 AND i.kind = ?3",
                    params![id, UTI_NOTE, Kind::Note],
                    |r| r.get::<_, Vec<u8>>(0),
                )
                .optional()?
                .ok_or(Error::NotFound(id))?,
            None => at.to_string().into_bytes(),
        };
        let reps =
            [Rep { uti: UTI_TEXT.into(), data: text.as_bytes().to_vec() }, Rep { uti: UTI_NOTE.into(), data: marker }];
        let hash = *content_hash(&reps).as_bytes();
        let title = make_title(text, Kind::Note);
        let chars = text.chars().count() as i64;
        let lines = if text.is_empty() { 0 } else { text.lines().count() as i64 };

        let id = match id {
            Some(id) => {
                tx.execute(
                    "UPDATE items SET content_hash = ?2, title = ?3, text_bytes = ?4, last_copied_at = ?5,
                                      char_count = ?6, line_count = ?7
                     WHERE id = ?1",
                    params![id, &hash[..], title, text.len() as i64, at, chars, lines],
                )?;
                tx.execute("DELETE FROM reps WHERE item_id = ?1", [id])?;
                tx.execute("DELETE FROM item_text WHERE item_id = ?1", [id])?;
                tx.execute("DELETE FROM item_fts WHERE rowid = ?1", [id])?;
                id
            }
            None => {
                tx.execute(
                    "INSERT INTO items (content_hash, kind, title, app, text_bytes, first_copied_at, last_copied_at,
                                        char_count, line_count)
                     VALUES (?1, ?2, ?3, NULL, ?4, ?5, ?5, ?6, ?7)",
                    params![&hash[..], Kind::Note, title, text.len() as i64, at, chars, lines],
                )?;
                tx.last_insert_rowid()
            }
        };
        for rep in &reps {
            tx.execute("INSERT INTO reps (item_id, uti, data) VALUES (?1, ?2, ?3)", params![id, rep.uti, rep.data])?;
        }
        if !text.is_empty() {
            tx.execute("INSERT INTO item_text (item_id, body) VALUES (?1, ?2)", params![id, text])?;
            tx.execute("INSERT INTO item_fts (rowid, body) VALUES (?1, ?2)", params![id, text])?;
        }
        let pin: Option<String> = tx.query_row("SELECT pin FROM items WHERE id = ?1", [id], |r| r.get(0))?;
        tx.commit()?;

        self.titles.remove(id);
        self.titles.insert(Entry::new(id, title, Kind::Note, None, at, pin.as_deref()));
        Ok(id)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{Capture, Filter, SearchMode};

    fn copy(store: &mut Store, text: &str, at: i64) -> i64 {
        let reps = vec![Rep { uti: UTI_TEXT.into(), data: text.as_bytes().to_vec() }];
        store.ingest(Capture { reps, copied_at: at, ..Default::default() }).unwrap().id
    }

    fn found(store: &Store, query: &str) -> Vec<i64> {
        let all = Filter { kinds: vec![], apps: vec![] };
        store.search_by(query, SearchMode::Exact, &all, 10).unwrap().into_iter().map(|h| h.id).collect()
    }

    #[test]
    fn notes_are_edited_in_place_searched_and_survive_trimming() {
        let mut store = Store::open_in_memory().unwrap();
        let copied = copy(&mut store, "회의 메모 초안", 1);
        // A note with a copy's exact text is a separate item.
        let note = store.save_note(None, "회의 메모 초안", 2).unwrap();
        assert_ne!(note, copied);
        assert_eq!(store.save_note(Some(note), "회의 메모 수정본\n둘째 줄", 3).unwrap(), note);

        assert_eq!(store.full_text(note).unwrap(), "회의 메모 수정본\n둘째 줄");
        assert_eq!(found(&store, "수정본"), [note]);
        assert_eq!(found(&store, "초안"), [copied], "the old text is no longer found");
        let summary = &store.summaries(&[note]).unwrap()[0];
        assert_eq!(
            (summary.kind, summary.title.as_str(), summary.line_count),
            (Kind::Note, "회의 메모 수정본 둘째 줄", 2)
        );
        assert_eq!(store.list(0, 1).unwrap()[0].id, note, "a saved note moves to the top");

        // Pasting a note puts its reps on the pasteboard; copying those back finds the same note.
        let reps = store.reps(note).unwrap();
        let again = store.ingest(Capture { reps, copied_at: 4, ..Default::default() }).unwrap();
        assert_eq!((again.id, again.deduplicated), (note, true));

        for at in 5..10 {
            copy(&mut store, &format!("copy {at}"), at);
        }
        store.trim(2).unwrap();
        assert!(store.summaries(&[note]).unwrap().len() == 1, "notes are never trimmed");
        assert!(store.summaries(&[copied]).unwrap().is_empty());

        assert!(matches!(store.save_note(Some(9999), "x", 11), Err(Error::NotFound(9999))));
        let other = store.list(0, 1).unwrap()[0].id;
        assert!(store.save_note(Some(other), "x", 11).is_err(), "only notes can be saved over");
    }
}
