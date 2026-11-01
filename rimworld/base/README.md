# 둥근 기지 설계 생성기

[`../README.md`](../README.md) 5장의 둥근 기지 설계도(기본판과 최고 난이도판)를 만드는 스크립트입니다.

- `gen_base.py`: 설계를 칸 단위로 만들고 `plan.json`(방, 문, 단계, 동선 거리)을 씁니다. `--hard`를 붙이면 바깥 성벽을 두른 최고 난이도판 `plan_hard.json`을 씁니다. 파이썬 표준 라이브러리만 씁니다.
- `render_png.py`: 설계를 그림(`round-base.png`, `round-base-hard.png`)으로 그립니다. Pillow가 필요합니다.
- `sim_raids.py`: 설계를 큰 평지 한가운데에 놓고, 지도 가장자리에서 들어온 습격대(일반, 공병, 영리한 돌파, 일반 돌파)가 주인 있는 침대까지 어느 길로 오는지 계산합니다. 길 값은 1.6 게임 코드의 수치(포탑 회피 격자, 벽·문 부수는 값)를 따릅니다. 표준 라이브러리만 쓰고, `--png`를 줄 때만 Pillow가 필요합니다.

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

`gen_base.py`는 방이 모두 닫혀 있는지, 「중력닻」 자리(4×4)가 모두 창고 바닥인지, 포탑이 기지 벽에서 충분히 떨어져 있는지 확인합니다. 최고 난이도판에서는 옹성 마당·뜰·뱀길·정비 복도가 서로 새지 않는지, 뱀길이 바깥 성문까지 이어지는지도 확인하고, 하나라도 어긋나면 멈춥니다.

지름(`R_HALL`, `R_IN`, `R_MID`, `R_OUT`, 바깥 성벽 `R_C`)이나 방 배치(`ROOMS`의 각도 범위), 고리 포탑 각도(`TURRET_ANGLES`)를 바꾸고 다시 돌리면 새 설계가 나옵니다. 바꾼 뒤에는 `sim_raids.py`로 공병이 아직 구멍으로 오는지 확인하세요.
