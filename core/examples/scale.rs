//! cargo run --release --example scale -- 100000
use std::time::Instant;

use remvel_core::{Capture, Rep, SearchMode, Store};

fn median(mut xs: Vec<f64>) -> f64 {
    xs.sort_by(|a, b| a.partial_cmp(b).unwrap());
    xs[xs.len() / 2]
}

fn main() {
    let n: usize = std::env::args().nth(1).and_then(|s| s.parse().ok()).unwrap_or(100_000);
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("bench.sqlite");
    let mut store = Store::open(&path).unwrap();

    let words = ["git", "commit", "cargo", "클립보드", "검색", "deploy", "kubectl", "select", "from", "where"];
    let big = "lorem ipsum dolor sit amet\n".repeat(40_000); // ~1 MB
    let t = Instant::now();
    for i in 0..n {
        let body = if i % 1000 == 0 {
            format!("{i} {big}")
        } else {
            let w = |k: usize| words[(i * 7 + k * 13) % words.len()];
            format!("{} {} {} {} line {i}", w(0), w(1), w(2), w(3))
        };
        store
            .ingest(Capture {
                reps: vec![Rep { uti: "public.utf8-plain-text".into(), data: body.into_bytes() }],
                copied_at: i as i64,
                ..Default::default()
            })
            .unwrap();
    }
    let ingest = t.elapsed();
    drop(store);

    let t = Instant::now();
    let store = Store::open(&path).unwrap();
    let open = t.elapsed();
    assert_eq!(store.len(), n);

    let time = |f: &mut dyn FnMut() -> usize| {
        let mut runs = Vec::new();
        let mut count = 0;
        for _ in 0..15 {
            let t = Instant::now();
            count = f();
            runs.push(t.elapsed().as_secs_f64() * 1000.0);
        }
        (median(runs[3..].to_vec()), count)
    };

    let (list_ms, rows) = time(&mut || store.list(0, 50).unwrap().len());
    let (search_ms, sh) = time(&mut || store.search("deploy", &Default::default(), 1000).unwrap().len());
    let (fuzzy_ms, fz) =
        time(&mut || store.search_by("gcm", SearchMode::Fuzzy, &Default::default(), 200).unwrap().len());
    let (exact_ms, ex) =
        time(&mut || store.search_by("deploy from commit", SearchMode::Exact, &Default::default(), 200).unwrap().len());
    let (ko_ms, ko) =
        time(&mut || store.search_by("검색 select", SearchMode::Exact, &Default::default(), 200).unwrap().len());
    let (prev_ms, pb) = time(&mut || store.preview_text(1, 500_000, 64 * 1024).unwrap().len());
    let db_mb = std::fs::metadata(&path).unwrap().len() as f64 / 1e6;

    println!(
        "items={n} db={db_mb:.0}MB ingest_total={:.1}s ({:.3}ms/item)",
        ingest.as_secs_f64(),
        ingest.as_secs_f64() * 1000.0 / n as f64
    );
    println!("open(load titles)={:.1}ms", open.as_secs_f64() * 1000.0);
    println!("list page 50       {list_ms:.3}ms rows={rows}");
    println!("search 'deploy'    {search_ms:.2}ms hits={sh}");
    println!("fuzzy 'gcm'        {fuzzy_ms:.2}ms hits={fz}");
    println!("exact full-text    {exact_ms:.2}ms hits={ex}");
    println!("exact korean       {ko_ms:.2}ms hits={ko}");
    println!("preview 64KB @500K {prev_ms:.3}ms bytes={pb}");
}
