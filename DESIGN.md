# Remvel 설계

개인용 macOS 클립보드 히스토리 매니저. Maccy를 대체한다.
목표는 두 가지다.

1. 히스토리를 수만~수십만 개로 늘려도 팝업, 검색, 스크롤이 즉시 반응한다.
2. 수 MB짜리 텍스트나 큰 이미지도 미리보기가 멈추지 않는다.

## 원칙

- **비싼 일은 복사할 때 한 번만, 백그라운드에서 한다.** 제목, 검색용 텍스트, 썸네일, 내용 해시를 저장 시점에 만든다. 팝업을 열 때는 아무것도 계산하지 않는다.
- **목록은 메타데이터만 읽는다.** 원본 blob은 붙여넣을 때만, 본문 텍스트는 미리보기할 때 필요한 범위만 읽는다.
- **메인 스레드는 그리기만 한다.** 저장, 검색, 디코딩은 코어 스레드에서 한다.

## 구조

```
┌──────────── Swift / AppKit (app/) ────────────┐
│ PasteboardWatcher  changeCount 폴링, UTI 수집      │
│ Preprocessor       RTF→text, ImageIO 썸네일     │  ← 백그라운드 큐
│ PopupPanel         NSPanel + NSTableView(가상화)│
│ PreviewView        NSTextView, 64KB씩 이어 로드 │
│ Paster             CGEvent ⌘V                  │
└──────────────┬────────────────────────────────┘
               │ UniFFI       
┌──────────────▼──── Rust (core/) ──────────────┐
│ Store    rusqlite, WAL, 메타와 payload 테이블 분리 │
│ ingest   blake3 해시 중복 제거, 제목, HTML→text  │
│ search   Fuzzy: nucleo (메모리 내 제목 인덱스)    │
│          Exact: FTS5 trigram (전문, 한국어 OK)  │
│ preview  byte-range substr, UTF-8 경계 보정     │
└───────────────────────────────────────────────┘
```

AppKit이 필요한 일(NSPasteboard 읽기, RTF 파싱, 이미지 다운샘플링, 붙여넣기 이벤트)은 Swift가 맡는다.
나머지는 Rust 코어가 맡는다.

## 스키마 (`core/src/schema.rs`)

| 테이블 | 내용 | 읽는 시점 |
|---|---|---|
| `items` | id, hash, kind, title(≤300자), app, 시각, 횟수, pin | 목록, 검색 결과 |
| `reps` | 원본 UTI별 blob | 붙여넣기 |
| `item_text` | 전체 plain text | 미리보기 (범위 읽기) |
| `thumbnails` | 작은 PNG | 이미지 행 표시 |
| `item_ocr` | 이미지에서 인식한 텍스트 | 검색, 이미지 텍스트 붙여넣기 |
| `item_fts` | FTS5 trigram, contentless (본문 + 인식 텍스트) | Exact 검색 |

## 정렬 규칙 (`core/src/search.rs`)

팝업, 필터, 사이드바, Shortcuts가 모두 코어의 `search` 하나로 순서를 받는다. Swift는 결과를 다시 정렬하거나 합치지 않는다.

| 화면 | 순서 |
|---|---|
| 검색어 없음 (전체 목록, `#image` 같은 필터, 사이드바) | 핀이 맨 위(핀 값 순), 그다음 최신순. `list()`와 같다. |
| 검색어 있음 | 핀 우선 없음. fuzzy 제목 점수순, 그다음 fuzzy가 못 찾은 전문 일치. 같은 점수와 전문 일치는 최신순. 핀은 배지로만 표시한다. |

"최신순"은 어디서나 `last_copied_at DESC, id DESC`다. 같은 밀리초에 복사하거나 붙여넣은 항목도 목록, 필터, 검색, 재실행 후에 순서가 같다.
Exact 검색은 3글자 이상이면 FTS5로 본문과 인식 텍스트를, 그보다 짧으면 제목만 찾는다(trigram 한계).

## 측정 (2026-11-04, `cargo run --release --example scale -- N`)

합성 데이터 사용. 1,000개 중 1개는 1MB 텍스트다. 중앙값이며, 데이터가 실제 사용 패턴과 다르다는 한계가 있다.

| 항목 | N=1,000 | N=100,000 |
|---|---|---|
| 열기(제목 인덱스 로드) | 1.4ms | 80ms |
| 목록 1페이지(50개) | 0.03ms | 0.03ms |
| Fuzzy 검색 | 0.19ms | 19ms |
| Exact 전문 검색 | 0.42ms | 20ms |
| Exact 한국어 | 0.25ms | 16ms |
| 1MB 텍스트 중간 64KB 미리보기 | 0.2ms | 0.2ms |
| 복사 1건 저장 | 0.26ms | 0.41ms |
| DB 크기 | 4MB | 373MB |

## Maccy 측정 결과와 설계 대응 (2026-11-04, M1 Pro, 합성 데이터)

| Maccy 병목 | 측정값 | 이 설계의 대응 |
|---|---|---|
| 로드 시 SwiftData 관계 fault-in (N+1, 앱 아이콘 캐시가 진입점) | plain 999개 164ms, 5000개 810ms | 목록은 `items`만 읽는다. 10만 개 열기 80ms, 페이지 0.03ms |
| HTML-only 항목의 `NSAttributedString(html:)` 파싱 | 999개 7.3초 (개당 약 7ms) | 복사 시점에 html2text로 한 번만 변환 |
| 로드 시 모든 항목에 `SizedString` 스캔 | 100KB × 999개에서 334ms | 미리보기를 열 때만 64KB 범위 읽기 |
| 메인 스레드 fuzzy 검색 (fuse-swift) | 999개 186ms, 5000개 937ms | nucleo, 10만 개 19ms, 코어 스레드 |
| 이미지 미리보기 리사이즈가 `@MainActor` | 4~6MP에서 27~49ms | 썸네일은 복사 시점에 생성, 미리보기 다운샘플은 백그라운드 |
| 큰 텍스트 전체 레이아웃 (끝까지 스크롤) | 1MB 809ms, 5MB 4.2초 | 64KB씩 이어서 로드 |

측정 방법: Maccy 저장소에 Swift Testing 벤치를 붙여 `History.load()`, `Search`, 미리보기 경로를 시나리오별로 반복 측정했다(Debug + `-O`, warm cache).

## 현재 상태 (v0.4)

- `core/`: 저장, 중복 제거, 검색, 미리보기 범위 읽기. UniFFI로 `Remvel` 객체를 노출한다.
  - 스키마 버전은 `PRAGMA user_version`으로 관리한다(`schema.rs`의 `MIGRATIONS`, 추가만 한다).
  - 종류: text, link(URL 한 줄), color, rich, image, files. 검색은 종류와 앱 필터를 받는다.
  - 이미지 속 텍스트는 Vision으로 별도 프로세스에서 인식해 `item_ocr`에 저장하고 검색에 넣는다.
  - 글자 수와 줄 수는 저장할 때 한 번 계산한다.
- `app/`: 메뉴바 앱.
  - 팝업: 가상화 목록(행 30pt, 복사한 앱 아이콘, ⌘1–9 힌트), fuzzy와 전문 검색, `#종류` 필터, 64KB 단위 미리보기.
  - 붙여넣기: 원본(⏎), 서식 없이(⇧⏎), 복사만(⌥⏎), ⌘-클릭으로 고른 순서대로 여러 개.
  - 핀(⌥P), 삭제(⌥⌫), 사이드바(종류와 앱별 개수), Shortcuts 동작.
  - 감시: 0.2초 폴링, 변화가 10번 없으면 1초로 늦춘다(Maus 방식). 숨김·임시·자동 생성 표시, 무시할 앱, Universal Clipboard(선택), Remvel 자신의 쓰기는 기록하지 않는다. 출처 앱은 `org.nspasteboard.source`를 먼저 본다.
  - 설정 창: 단축키, 팝업 위치(화면 중앙, 마우스 위치, 메뉴바 아이콘 아래), 히스토리 상한, 로그인 시 실행, 기록 일시 정지, 무시할 앱.
  - 첫 실행 때 손쉬운 사용 권한 안내 창을 띄운다.
  - 아이콘: Icon Composer 문서(`app/Remvel/AppIcon.icon`)와 메뉴바 템플릿 이미지. 방향은 "Layer Shift"(GPT 탐색), 벡터는 logo-design 스킬로 다듬었다.
- CI: GitHub Actions(`macos-26`)가 코어 lint(rustfmt, clippy)와 테스트, 앱 빌드를 하고 `Remvel.zip`을 아티팩트로 올린다. main은 nightly, `v*` 태그는 릴리스로 올린다.

## 다음 단계

1. 여러 pasteboard 항목 복사를 지원한다. 지금은 첫 항목만 저장한다(파일 여러 개는 경로를 모두 저장한다).
2. 한국어 초성 검색.
3. 비밀값 캡처 제외 규칙(정규식).
4. 변환 필터(Pastebot 방식의 단계 체인)와 핀보드.
5. 10만 개 이상에서 fuzzy 검색이 20ms를 넘으면 nucleo 병렬 검색으로 바꾼다.
6. 노터라이즈, Homebrew cask 배포.

## 참고 프로젝트

[docs/references.md](docs/references.md) 참고.
