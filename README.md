# NPC Friends × Heap of Foods — 요리 연동 패치

굶지마 투게더(DST)에서 **[NPC Friends](https://steamcommunity.com/sharedfiles/filedetails/?id=3684000581)** 의 왈리 NPC가
**[Heap of Foods](https://steamcommunity.com/sharedfiles/filedetails/?id=2334209327)** 를 비롯한 음식 모드의 요리를
전부 인식하고, 여러 가지 요리를 돌아가며 만들도록 고치는 패치입니다.

바로 쓰실 파일: **[`dist/NPC_HOF_Patch.zip`](dist/NPC_HOF_Patch.zip)** — 압축을 풀고 `install.bat` 실행.

---

## 왜 안 됐나

NPC Friends 소스를 직접 뜯어보고 원인을 확인했습니다. 두 가지입니다.

### 1. 요리 목록이 손으로 적힌 표다

`scripts/npc/npc_cooking_recipes.lua` 는 "왈리가 만들 수 있는 요리"를 861줄짜리 카드 표로
직접 적어 둡니다. 바닐라 요리와, 작성자가 손으로 추가한 일부 모드(Uncompromising Mode,
The Legion 등) 요리만 들어 있습니다.

```lua
CookingRecipes.RECIPES = {
    { name = "voltgoatjelly", score = 130, warly_only = true, cooktime = 2,
      required = { lightninggoathorn = 1 },
      min_tags = { sweetener = 2 }, ... },
    ...
}
```

Heap of Foods가 추가한 200종이 넘는 요리는 이 표에 없습니다. **창고에 재료가 아무리 많아도
후보에조차 오르지 않습니다.** 재료 인식은 멀쩡합니다 — `ScanIngredients` 는
`cooking.IsCookingIngredient()` 를 쓰기 때문에 Heap of Foods 재료도 정상적으로 집어 옵니다.
막히는 건 재료가 아니라 **요리 쪽**입니다.

### 2. 미트볼 우선 규칙이 박혀 있다

`scripts/npc/npc_cooking_recipe_scorer.lua` 의 `FindBestRecipe` 맨 앞:

```lua
-- 肉丸优先   (미트볼 우선)
if not existing_dishes["meatballs"] or existing_dishes["meatballs"] < 1 then
    local meatball_card = CookingRecipes.GetRecipeByName("meatballs")
    ...
end
```

창고에 미트볼이 1개 미만이면 무조건 미트볼부터 만듭니다. 같은 요리만 계속 나오는 이유입니다.

### 덤: 강제 바닐라 출력

`scripts/npc_tuning.lua` 의 `COOK_FORCE_VANILLA_RESULT = true` 는 냄비에 재료를 넣는 순간
`cooking.CalculateRecipe` 를 통째로 덮어써서 계획한 바닐라 요리를 강제로 출력합니다.
이 설정만 끄면 모드 요리가 "우연히" 나올 수는 있지만, 요리 표가 그대로라서
**의도적으로** 모드 요리를 만들지는 못합니다.

---

## 어떻게 고쳤나

요리 200개를 더 적어 넣는 대신, **요리 이름을 하나도 적지 않는** 방식으로 뒤집었습니다.

왈리가 손댈 수 있는 재료로 4칸 조합을 만들어 보고, 게임 자체의 요리 판정 함수에
"이 조합은 무슨 요리가 되나?" 하고 그대로 물어봅니다.

```lua
local product, cooktime = cooking.CalculateRecipe(cooker_name, names)
```

정상적인 방법(`AddCookerRecipe` / `AddIngredientValues`)으로 등록된 음식 모드라면
무엇이든 자동으로 잡힙니다. Heap of Foods가 업데이트로 요리를 더 추가해도 이 패치는
손댈 필요가 없습니다.

> 참고로 이 접근은 Heap of Foods 작성자 본인이 그 모드의 요리 로봇
> (`scripts/brains/cookrobotbrain.lua`)에서 쓰는 방식과 같습니다.

그 위에 **다양성 점수**를 얹었습니다.

```
점수 = 음식 가치
     − 이미 창고에 쌓인 개수 × 반복 감점
     − 최근에 만들었을수록 커지는 감점
     + 한 번도 안 만든 요리 보너스
     + 약간의 무작위
```

그리고 미트볼 우선 규칙은 그냥 없어집니다 — 우리 `FindBestRecipe` 에는 없으니까요.

### 실제로 다양해지는가

같은 창고·같은 25번 요리, `variety` 설정만 바꾼 결과입니다.

| variety | 나온 요리 종류 | 메뉴 |
|---|---|---|
| `off` | **1종** | 상어지느러미스프 ×25 |
| `medium` | **16종** | 베이컨파이, 치즈케이크, 버섯스프, 팬케이크, … |
| `high` | **19종** | 위 + 카프레제, 시럽케이크, 베이컨에그, … |

`off` 에서 25번 내리 같은 요리가 나오는 게 바로 원래 증상입니다.

### 서버는 안 무거운가

Heap of Foods 실제 규모(한 조리기구에 레시피 250종, 재료 40종 창고)에서 측정했습니다.

| 탐색량 | 최초 1회 | 이후 반복 |
|---|---|---|
| `low` | 14 ms | 4 ms |
| `medium` | 32 ms | 10 ms |
| `high` | 72 ms | 19 ms |

탐색 횟수에 상한을 두고, 손이 닿는 재료 종류가 바뀔 때만 다시 전체 탐색을 합니다.
그 사이는 전부 "이후 반복" 쪽 비용입니다. 직접 재보시려면 `lua5.1 tests/perf.lua`.

---

## 설치

1. [`dist/NPC_HOF_Patch.zip`](dist/NPC_HOF_Patch.zip) 을 받아 **폴더째 압축 해제**
2. DST를 완전히 종료
3. `install.bat` 더블클릭
4. DST를 다시 켜고, Heap of Foods와 NPC Friends를 둘 다 켠 채로 월드 접속
5. 왈리 NPC에게 냄비와 아이스박스를 지정하고 요리 시키기

되돌리려면 `restore.bat`. 원본은 설치할 때 `_backup` 에 보관됩니다.

설치 프로그램이 하는 일은 딱 두 가지입니다.

- `files/npc_hof_cooking.lua` 를 모드의 `scripts/npc/` 에 복사
- `scripts/npc/npc_cooking_planner.lua` 의 마지막 `return CookingPlanner` 바로 앞에 한 줄 삽입

```lua
-- [NPC_HOF_PATCH_BEGIN] NPC Friends x Heap of Foods
pcall(function() require("npc/npc_hof_cooking").Install(CookingPlanner) end)
-- [NPC_HOF_PATCH_END]
```

기존 파일은 이 한 줄 말고 **바뀌는 게 없습니다.** 남의 모드 파일을 재배포하지도 않습니다 —
백업은 설치 시점에 여러분 PC에서 만들어집니다.

### 설정 바꾸기

`files/npc_hof_cooking.lua` 를 메모장으로 열면 맨 위에 `USER_SETTINGS` 가 있습니다.
고친 뒤 `install.bat` 을 다시 실행하면 적용됩니다.

| 항목 | 기본값 | 설명 |
|---|---|---|
| `enabled` | `true` | `false` 면 원래 로직을 그대로 씁니다 |
| `variety` | `"medium"` | `off` / `low` / `medium` / `high` |
| `budget` | `"medium"` | 탐색량. `low` / `medium` / `high` |
| `same_dish_max` | `0` | 같은 요리 최대 보관량. `0` = 모드 설정을 따름 |
| `allow_negative` | `false` | 체력·정신력이 깎이는 요리도 만들지 |
| `debug` | `false` | 고른 이유를 서버 로그에 출력 |
| `protect` | `{}` | 절대 재료로 쓰지 않을 아이템 |

### 알아두실 점

- **Steam이 NPC Friends를 업데이트하면 패치가 지워집니다.** `install.bat` 을 다시 실행하세요.
- **멀티에서는 서버(호스트) 쪽에 설치되어야 합니다.** NPC의 요리 판단은 전부 서버에서 일어납니다.
- 문제가 생기면 `debug = true` 로 바꾸고 서버 로그의 `[NPCF-HOF]` 줄을 보세요.

---

## 저장소 구조

```
dist/NPC_HOF_Patch.zip              바로 쓰는 설치 패키지
build/                              빌드 산출물 (git에 올리지 않음)

npcfriends_hof_cooking/             ← 로직의 원본. 그 자체로 독립 모드이기도 함
  scripts/hofnpc_core.lua             설정 · 요리 점수 · 요리 필터
  scripts/hofnpc_variety.lua          최근에 만든 요리 기억 + 감점
  scripts/hofnpc_search.lua           핵심: 조합 탐색
  scripts/hofnpc_patch.lua            독립 모드용 런타임 후킹
  modmain.lua  modinfo.lua            독립 모드 껍데기

patch/
  build.py                          위 모듈들을 한 파일로 합쳐 zip을 만듦
  header.lua                        USER_SETTINGS 블록
  install_stub.lua                  Install(CookingPlanner) 진입점
  templates/tools/patch.ps1         설치 · 복원 (전부 여기 있음)
  templates/install.bat / restore.bat  얇은 실행기

tests/
  dst_stub.lua                      DST 요리 시스템 재현 (바닐라 + 모드 요리)
  test_search.lua                   모듈 단위 테스트
  test_merged.lua                   실제 배포 파일 + Install() 경로 통합 테스트
  test_patcher.ps1                  설치/복원을 실제 planner 파일에 대해 검증
  perf.lua                          Heap of Foods 규모 성능 측정
  run_all.sh                        전부 실행
```

### 빌드 · 테스트

```bash
python3 patch/build.py        # dist/NPC_HOF_Patch.zip 생성
tests/run_all.sh              # 문법 검사 + 단위/통합 테스트 + 성능
tests/run_all.sh /path/to/pristine/npc_cooking_planner.lua   # 설치기 테스트까지
```

필요한 것: `lua5.1`, `luac5.1`, `python3`, (설치기 테스트에만) `pwsh`.

테스트는 게임 없이 DST 요리 시스템을 재현해서 돌아갑니다 — 재료 태그 합산, 레시피
`test` 함수, 우선순위 동점 처리, 실패 시 wetgoop 까지 실제 `scripts/cooking.lua` 와 같게
동작합니다.

---

## 독립 모드로 설치하기 (대안)

`npcfriends_hof_cooking/` 폴더 자체가 정상적인 DST 모드입니다.
`...\steamapps\common\Don't Starve Together\mods\` 에 폴더째 넣고 모드 목록에서 켜면
`.bat` 패치와 같은 일을 합니다. 이쪽은 **Steam 업데이트에도 지워지지 않습니다.**
다만 모드 목록이 하나 늘어나고, 설정은 창작마당 모드처럼 모드 설정 화면에서 합니다.

**둘 중 하나만 쓰세요.** 같이 켜면 두 번 후킹되어 쓸데없이 두 번 일합니다.

---

## 한계

- 조합 탐색에는 상한이 있습니다. 창고에 재료 종류가 아주 많으면 한 번에 모든 요리를
  찾아내지는 않고, 여러 번에 걸쳐 조금씩 더 찾아냅니다. 실사용에서는 문제되지 않지만,
  "이 재료로 만들 수 있는 최고의 요리"를 항상 보장하지는 않습니다.
- Heap of Foods의 나무통·보존병(양조) 요리는 크록팟 레시피 표가 아니라 별도 체계라
  이 패치 대상이 아닙니다.
- NPC Friends가 `npc_cooking_planner.lua` 구조를 크게 바꾸면 설치기가 삽입 지점을 찾지
  못하고 **아무것도 하지 않은 채 그렇게 알려 줍니다.** 조용히 깨지지는 않습니다.
