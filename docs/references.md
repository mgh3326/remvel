# 참고 프로젝트

설계만 참고한다. 다른 프로젝트의 코드는 복사하지 않는다. 특히 GPL과 AGPL 프로젝트는 코드를 들여다본 뒤 비슷하게 옮겨 쓰는 것도 피한다.
스타 수와 최근 활동은 2026-11-04 기준이다.

## 구조 참고 (가장 가까운 사례)

| 프로젝트 | 라이선스 | 무엇을 참고하나 |
|---|---|---|
| [huangy7/lokii](https://github.com/huangy7/lokii) | MIT | AppKit + UniFFI + nucleo-matcher로 만든 macOS 앱이다. Makefile과 uniffi-bindgen 빌드 구성, 가상화 테이블, 선택된 결과만 materialize하는 방식을 참고한다. |
| [SUPERCILEX/clipboard-history](https://github.com/SUPERCILEX/clipboard-history) (Ringboard) | Apache-2.0 | 100만 항목을 목표로 필요한 것만 로드하는 저장소 설계. [설계 글](https://alexsaveau.dev/blog/ringboard)을 참고한다. |
| [yuzeguitarist/Deck](https://github.com/yuzeguitarist/Deck) | AGPL-3.0 + ARR | FTS5 trigram + BM25, fuzzy 길이 제한. [검색 아키텍처 글](https://deckclip.app/blog/search-architecture)만 참고하고 코드는 보지 않는다. |
| [EcoPasteHub/EcoPaste](https://github.com/EcoPasteHub/EcoPaste) | Apache-2.0 | Tauri + SQLite FTS5 클립보드 앱. 비밀값 캡처 제외 기능을 참고한다. |
| [Ruszero01/clippi](https://github.com/Ruszero01/clippi) | MIT | `docs/code-quality-performance-review.md`(FTS5, keyset pagination, 읽기 전용 연결)를 성능 체크리스트로 쓴다. |

## UniFFI 배포 사례

| 프로젝트 | 무엇을 참고하나 |
|---|---|
| [element-hq/matrix-rust-components-swift](https://github.com/element-hq/matrix-rust-components-swift) | Rust SDK를 XCFramework와 SPM 패키지로 배포하는 방식 |
| [mozilla/application-services](https://github.com/mozilla/application-services) | UniFFI를 만든 쪽이 Rust와 SQLite를 Swift에 노출하는 방식 |
| [ianthetechie/uniffi-starter](https://github.com/ianthetechie/uniffi-starter) | UniFFI 프로젝트 템플릿 |

## 핵심 라이브러리

| 라이브러리 | 라이선스 | 메모 |
|---|---|---|
| [rusqlite](https://github.com/rusqlite/rusqlite) | MIT | `bundled` feature로 FTS5 포함 |
| [nucleo](https://github.com/helix-editor/nucleo) (`nucleo-matcher`) | MPL-2.0 | Helix에서 쓰는 fuzzy matcher. 파일 단위 copyleft라 수정 없이 의존성으로만 쓴다. |
| [uniffi-rs](https://github.com/mozilla/uniffi-rs) | MPL-2.0 | 0.x라 버전마다 breaking change가 있다. 버전을 고정한다. |
| [html2text](https://github.com/jugglerchris/rust-html2text) | MIT | HTML-only 복사본을 텍스트로 바꾼다. |
| [GRDB.swift](https://github.com/groue/GRDB.swift) | MIT | 순수 Swift 대안. 비교 기준 |

## 기존 클립보드 앱 (UX 참고)

- [p0deje/Maccy](https://github.com/p0deje/Maccy) (MIT): 출발점. 성능 이슈는 #1372, #1091(큰 히스토리), #845(검색), #1559(긴 텍스트 미리보기), #1496(저장소 비대), #1520(CoreText 무한루프를 일으키는 문자).
- [hluk/CopyQ](https://github.com/hluk/CopyQ) (GPL-3.0): 탭과 스크립팅 UX
- [TermiT/Flycut](https://github.com/TermiT/Flycut) (MIT): 최소한의 UX
