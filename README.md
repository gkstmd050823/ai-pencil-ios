# AI 펜슬 (아이패드)

PDF에 애플 펜슬로 필기하다가 모르는 부분에 동그라미를 치면 그 부분을 설명해 주는 앱의 아이패드판. 안드로이드판을 Swift, PencilKit, PDFKit으로 다시 만드는 중이다.

지금 들어 있는 것: PDF 가져오기와 빈 노트 만들기, 쪽 위에 펜슬로 필기(펜·형광펜·지우개·올가미), 문서 중간에 빈 쪽 넣기, LaTeX로 수식 넣기. 동그라미 설명은 아직 없다.

## 맥 없이 빌드하기

개발 PC가 Windows라서 빌드는 GitHub Actions의 macOS 러너가 한다.

- `project.yml`: XcodeGen 설정. 빌드 서버가 여기서 Xcode 프로젝트를 만든다(프로젝트 파일은 저장소에 두지 않는다).
- `.github/workflows/build.yml`: `main`에 올릴 때마다 시뮬레이터용으로 빌드해 화면을 찍고, 아이패드용으로 빌드해 서명 없는 IPA를 만든다.
- 결과물은 Actions → 해당 실행 → Artifacts에 있다: `AIPencil-ipa`(설치 파일), `screenshots`(시뮬레이터 화면), 실패하면 `logs`.

## 아이패드에 설치하기

IPA에는 서명이 없어서 그대로는 설치되지 않는다. Windows의 Sideloadly가 본인 Apple ID로 서명해 넣어 준다.

1. Artifacts에서 `AIPencil-ipa`를 내려받아 압축을 풀면 `AIPencil.ipa`가 나온다.
2. PC에 Sideloadly와 iTunes(Apple 기기 드라이버)를 설치하고, 아이패드를 USB로 연결해 "이 컴퓨터를 신뢰"를 누른다.
3. Sideloadly에 `AIPencil.ipa`를 끌어다 놓고 Apple ID를 입력한 뒤 Start.
4. 아이패드에서 설정 → 일반 → VPN 및 기기 관리 → 본인 Apple ID → 신뢰.
5. 설정 → 개인정보 보호 및 보안 → 개발자 모드를 켜고 재시동한다(iPadOS 16 이상).

무료 Apple ID로 서명한 앱은 7일 뒤 만료된다. 같은 방법으로 다시 설치하면 되고, 앱 안의 문서와 필기는 남는다. Sideloadly의 자동 갱신을 켜 두면 PC와 같은 Wi-Fi에 있을 때 알아서 갱신한다.

## 구조

```
AIPencil/
  AIPencilApp.swift   앱 시작점
  Library.swift       가져온 문서 목록과 파일 보관
  LibraryView.swift   서재 화면
  ReaderView.swift    문서 화면
  PDFInkView.swift    PDFKit 쪽 위에 PencilKit 캔버스를 얹는 부분
  DrawingStore.swift  쪽별 필기 저장
  MathStore.swift     수식 저장, 수식 그림 다듬기
  MathEditorView.swift 수식 입력 창(KaTeX 미리보기)
  MathWeb/            KaTeX와 글꼴(앱 번들에 폴더째 들어간다)
  Sample.pdf          빌드 서버가 화면을 찍을 때 여는 샘플
```

필기는 PDFKit의 쪽 오버레이(iPadOS 16)에 쪽마다 PencilKit 캔버스를 하나씩 얹어 받는다. 캔버스의 좌표는 쪽 왼쪽 위에서 잰 쪽 좌표와 같다(빌드 서버에서 제목 둘레에 고리를 그려 확인했다). 펜, 형광펜, 지우개, 올가미는 화면 위쪽의 도구 막대에서 고른다.

수식은 상단의 Σ 버튼에서 LaTeX로 입력한다. KaTeX로 조판한 미리보기를 그림으로 떠서(글자 모양만 남기고 색은 그릴 때 입힌다) 쪽의 필기 아래에 놓는다. 도구 막대의 "수식 옮기기"를 고르면 필기 캔버스가 비켜서, 수식을 끌어 옮기거나 길게 눌러 수정·복제·삭제할 수 있다.

빈 쪽은 PDF 자체에 끼워 넣고, 그 뒤 쪽들의 필기 파일과 수식의 쪽 번호를 한 쪽씩 뒤로 옮긴다.
