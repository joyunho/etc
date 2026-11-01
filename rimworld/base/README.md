# 둥근 기지 설계 생성기

[`../README.md`](../README.md) 5장의 둥근 기지 설계도(기본판과 최고 난이도판)를 만드는 스크립트입니다.

- `gen_base.py`: 설계를 칸 단위로 만들고 `plan.json`(방, 문, 단계, 동선 거리)을 씁니다. `--hard`를 붙이면 바깥 성벽을 두른 최고 난이도판 `plan_hard.json`을 씁니다. 파이썬 표준 라이브러리만 씁니다.
- `render_png.py`: 설계를 그림(`round-base.png`, `round-base-hard.png`)으로 그립니다. Pillow가 필요합니다.
- `sim_raids.py`: 설계를 큰 평지 한가운데에 놓고, 습격대가 주인 있는 침대까지 어느 길로 오는지 계산합니다. 규칙은 1.6 게임 코드(디컴파일 1.6.9371)를 따르고, 주석에 파일과 줄 번호를 적었습니다. 공병(`sapper`)은 포탑 회피 격자를 피하고 함정의 30%를 알며 벽과 문을 팝니다. 돌파병(`breach`)이 부술 줄은 1.6 `BreachingGrid` 수치로 정합니다. 벽은 20 + 내구도×0.015, 부서지는 건물마다 같은 값을 한 번 더 붙이고, 노이즈 칸은 +30이며, 포탑은 보지 않습니다. 영리한 돌파(`smart_breach`)도 부술 줄은 일반 돌파와 같아서 `breach`로 계산합니다. 문을 못 여는 일반·영리한 습격(`walker`, `smart_walker`)도 계산합니다. 이들은 출발한 구역 안에 침대가 있으면 그 침대로, 없으면 그 구역에서 침대에 가장 가까운 칸으로 갑니다(`sealed off` 줄). 지도 가장자리에서 걸어서 어디까지 닿는지(봉쇄 확인)도 보여 줍니다. 표준 라이브러리만 쓰고, `--png`를 줄 때만 Pillow가 필요합니다.
- `test_sim_raids.py`: 작은 설계로 위 규칙(문 값은 둘 중 큰 값, 아는 함정 800, 벽 뒤 시야 차단, 돌파 벽 값, 닫힌 문, 대각선 벽, 자기 구역 침대, 아직 안 지은 침대, 울타리 문)과 가구 역할(바리케이드·모드 울타리, 돌 가시 함정, 살롱 문, 모드 포탑, `fill_percent`, 벽 위에 놓은 문)을 확인합니다.

```bash
python gen_base.py .
```

```bash
python gen_base.py . --hard
```

```bash
python render_png.py plan.json round-base.png
```

```bash
python render_png.py plan_hard.json round-base-hard.png
```

끝에 단계 번호를 붙이면 그 단계까지 지은 모습만 그립니다(기본판 1~5, 최고 난이도판 1~6).

```bash
python render_png.py plan_hard.json phase4.png 4
```

```bash
python sim_raids.py plan_hard.json --phase 5 --step 10
```

```bash
python test_sim_raids.py
```

`sim_raids.py`는 길마다 바깥 방어를 어떻게 넘었는지(뱀길, 뱀길 블록 벽·문, 바깥 성벽, 쪽문, 바깥 성문 틈)와 안쪽 성에 어떻게 들어왔는지(구멍, 성벽)를 나눠 보여 줍니다. 성 안 방과 방 사이의 벽·문을 부순 것은 `castle interior wall/door`로 따로 셉니다. 설계에 길 구역(`hole`, `gategap`, `court`, `lane`, `maint`, `store`, `postern`)이 하나도 없으면 바깥 벽 이름을 짐작하지 않고 `unlabelled`로 적습니다. 구멍 비율 옆의 `margin`은 옹성 마당과 구멍을 막았을 때 가장 싼 길 값을 가장 싼 길 값으로 나눈 것입니다. 1에 가까울수록 다른 길로 바뀌기 쉽습니다. 돌파는 노이즈 없이 한 번, 노이즈 시드 0~3으로 한 번씩 계산해 범위를 보여 줍니다.

- `--spawns edge|yard|court|lane|inside|all`: 지도 가장자리 말고 뜰, 옹성 마당, 뱀길, 안쪽 성에서 시작하는 경우(수송 포드)도 계산합니다.
- `--kill "x,y;x,y"`: 그 자리 포탑을 없애고 계산합니다. `--kill-pairs`는 이웃한 고리 포탑을 두 대씩, `--kill-each`는 한 대씩 없애 보고 가장 나쁜 경우를 알려 줍니다.
- `--astar`: 게임처럼 먼 길은 휴리스틱을 2배로 둔 A*로 길을 찾습니다. `--replan`은 공병이 막힌 것을 부수고 500틱마다 길을 다시 찾는 것까지 흉내 냅니다. 느리니 `--step 25 --beds bed_ne1,prison`처럼 작게 돌리세요.
- `--noise libnoise|audit|off`, `--noise-seeds none,0,1,2,3`: 돌파 노이즈입니다. 기본값 `libnoise`는 게임의 `Verse.Noise.Perlin`을 그대로 옮긴 것입니다.
- `--params params.json`: 수치를 바꿉니다. 예를 들어 `{"WALL_HP": 195, "DOOR_HP": 104}`는 재료가 없는 칸을 나무 벽·문으로 계산합니다.

새 설계 형식도 읽습니다. 칸은 `[종류, 방, 단계, 문 단계, 재료]`이고 종류에 대각선 벽 `diag`가 더해집니다. `materials`(재료 → 벽 내구도), `furniture`(가구: 자리, 회전, 단계, 통행, 길 값, 내구도, 주인 있는 침대 여부), `beds`(습격 목표 침대 칸)를 줄 수 있습니다. `beds`가 없으면 가구의 주인 있는 침대를, 그것도 없으면 침실·수감실·학교 방 가운데를 목표로 씁니다. 그 단계까지 지은 침대가 하나도 없으면 계획된 침대 자리를 그대로 목표로 쓰고 알려 줍니다.

가구가 문·울타리·함정·포탑인지는 이름이 아니라 1.6 정의(def)와 클래스로 정해집니다. 바닐라, DLC, 쓰는 모드의 보안·문 가구는 `sim_raids.py`의 `DEF_ROLES` 표에 있습니다. 예를 들어 `Barricade`, `VFEArch_ChainlinkFence`는 울타리, `FSFStoneTrapSpike`, `HunterDroneTrap`은 함정, `DoorSaloon`은 문, `PPCHEL`은 포탑입니다. `ToiletStallDoor`, `VFEPD_FakeDoor`는 문이 아니고, `Turret_Mortar`, `APM_GazerEmplacement`는 포탑 회피 격자에 찍히지 않습니다. 표에 없는 가구는 이름으로 짐작하고 `note:` 줄에 적으니, 생성기는 가구마다 아래 키도 함께 쓰는 것이 좋습니다.

- `door`, `free_passage`(진공 차단막처럼 누구나 지나가는 문), `fence`, `trap`, `turret`과 `range`, `min_range`
- `fill`(또는 `fill_percent`): 1이면 시야와 대각선 이동을 막습니다. 없으면 통행 값으로 짐작하고 알려 줍니다. 덜 찬 통행 불가 건물은 공병도 파지 못하고 시야도 막지 않습니다.
- `pass`(또는 `passability`), `hp`(또는 `max_hit_points`), `edifice`(벽등·전선·깔개는 `false`), `over_wall`(벽 위에 지어 벽을 대신하는 건물), `thing_class`, `stuff`
- 문 가구를 벽이나 문 칸에 놓으면 그 칸은 그 문(가구의 내구도)이 됩니다. 다른 건물을 벽 칸에 놓으면 벽을 그대로 두고 알려 줍니다.

`gen_base.py`는 방이 모두 닫혀 있는지, 「중력닻」 자리(4×4)가 모두 창고 바닥인지, 포탑이 기지 벽에서 충분히 떨어져 있는지 확인합니다. 최고 난이도판에서는 옹성 마당·뜰·뱀길·정비 복도가 서로 새지 않는지, 뱀길이 바깥 성문까지 이어지는지도 확인하고, 하나라도 어긋나면 멈춥니다.

지름(`R_HALL`, `R_IN`, `R_MID`, `R_OUT`, 바깥 성벽 `R_C`)이나 방 배치(`ROOMS`의 각도 범위), 고리 포탑 각도(`TURRET_ANGLES`)를 바꾸고 다시 돌리면 새 설계가 나옵니다. 바꾼 뒤에는 `sim_raids.py`로 공병이 아직 구멍으로 오는지, `--kill-pairs`로 포탑 두 대를 잃어도 버티는지 확인하세요.
